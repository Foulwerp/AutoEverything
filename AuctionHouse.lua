----------------------------------------------------------------------
-- AuctionHouse.lua - event-driven market scan and guarded automatic posting.
-- WoW 3.3.5 / Ascension compatible. A supported get-all query is tried first;
-- incomplete or timed-out responses fall back to reliable page-by-page scans.
----------------------------------------------------------------------

AutoAuction = AutoAuction or {}
local Auction = AutoAuction
local Core = AutoCore

local PAGE_SIZE = 50
local QUERY_TIMEOUT = 10
local MAX_RETRIES = 5
local SOFT_RETRY_DELAY = 0.1
local HARD_RETRY_AFTER = 2
-- The AH does not expose a reliable maximum page count. Server-reported totals
-- stop normal scans earlier; this is only a runaway-response circuit breaker.
local MAX_PAGES = 5000
local MAX_HISTORY = 20
local MAX_SAVED_PRICES = 100
local DATABASE_MAX_AGE = 60 * 24 * 60 * 60

local scan, posting, marketQuery, upgradeAnalysis, window, statusText, scanStatusText, scanStatsText
local scanButton, postButton, modeButton
local queue = {}
local queueRows = {}
local auctionLauncher
local manual = { entries = {}, inventory = {} }
local owned = { results = {} }
local upgrades = { results = {}, filtered = {} }
local RefreshSellGrid, RefreshShoppingResults, RefreshOwnedAuctions, RefreshManualCompetition
local RefreshUpgradeResults, StartUpgradeAnalysis, ProcessUpgradeAnalysis
local shopping = { results = {}, sessionSpent = 0 }
local currentPage = "sell"
local pageFrames, pageButtons, scanFooters = {}, {}, {}
local events = CreateFrame("Frame")
local ProcessAuctionWork

-- Attach the rapid progress worker only while a scan or posting queue is
-- active. Leaving an idle OnUpdate installed costs a Lua call every frame.
local function UpdateWorkerState()
    if scan or posting or marketQuery or upgradeAnalysis then events:SetScript("OnUpdate", ProcessAuctionWork)
    else events:SetScript("OnUpdate", nil) end
end

local function Info(message)
    if Core and Core.Info then Core.Info("Auction", message) else print("AutoAuction: " .. message) end
end
local function Warn(message)
    if Core and Core.Warn then Core.Warn("Auction", message) else print("AutoAuction: " .. message) end
end
local function WorkStatus(message)
    if statusText then statusText:SetText(message) end
    if scanStatusText then scanStatusText:SetText(message) end
end
local function Setting(key, fallback)
    if Core and Core.GetSetting then return Core.GetSetting("auction", key, fallback) end
    return AutoAuctionConfig and AutoAuctionConfig[key] ~= nil and AutoAuctionConfig[key] or fallback
end
local function SetSetting(key, value)
    if Core and Core.SetSetting then Core.SetSetting("auction", key, value) end
end
local function UndercutPercent()
    return math.max(0, math.min(25, tonumber(Setting("undercutPercent", 1)) or 1))
end
local function UndercutUnitPrice(unitPrice, percent)
    local unit = math.max(1, math.floor(tonumber(unitPrice) or 1))
    local amount = math.max(0, math.min(25, tonumber(percent) or 0))
    if unit <= 1 or amount <= 0 then return unit end
    local price = math.floor(unit * (1 - amount / 100))
    -- Any positive undercut must move by at least one copper. A one-copper
    -- listing cannot go lower, so it remains at one copper.
    if price >= unit then price = unit - 1 end
    return math.max(1, price)
end
Auction.UndercutUnitPrice = UndercutUnitPrice
local function Money(copper)
    copper = math.max(0, math.floor(tonumber(copper) or 0))
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local coins = copper % 100
    if gold > 0 then return gold .. "g " .. silver .. "s " .. coins .. "c" end
    if silver > 0 then return silver .. "s " .. coins .. "c" end
    return coins .. "c"
end

local function TooltipMoney(copper)
    copper = math.max(0, math.floor(tonumber(copper) or 0))
    if GetCoinTextureString then return GetCoinTextureString(copper) end
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local coins = copper % 100
    local values = {}
    if gold > 0 then
        table.insert(values, gold .. " |TInterface\\MoneyFrame\\UI-GoldIcon:12:12:2:0|t")
    end
    if silver > 0 or gold > 0 then
        table.insert(values, silver .. " |TInterface\\MoneyFrame\\UI-SilverIcon:12:12:2:0|t")
    end
    table.insert(values, coins .. " |TInterface\\MoneyFrame\\UI-CopperIcon:12:12:2:0|t")
    return table.concat(values, " ")
end

local function AgeText(timestamp)
    if not timestamp then return "unknown" end
    local elapsed = math.max(0, time() - timestamp)
    if elapsed < 60 then return "less than 1m ago" end
    local days = math.floor(elapsed / 86400)
    local hours = math.floor((elapsed % 86400) / 3600)
    local minutes = math.floor((elapsed % 3600) / 60)
    local parts = {}
    if days > 0 then table.insert(parts, days .. "d") end
    if hours > 0 then table.insert(parts, hours .. "h") end
    if minutes > 0 then table.insert(parts, minutes .. "m") end
    return table.concat(parts, " ") .. " ago"
end

local function MarketKey()
    local realm = GetRealmName and GetRealmName() or "UnknownRealm"
    local faction = UnitFactionGroup and UnitFactionGroup("player") or "Neutral"
    return tostring(realm) .. "-" .. tostring(faction)
end

local function EnsureDB()
    AutoEverythingAuctionDB = type(AutoEverythingAuctionDB) == "table" and AutoEverythingAuctionDB or {}
    AutoEverythingAuctionDB.markets = type(AutoEverythingAuctionDB.markets) == "table" and AutoEverythingAuctionDB.markets or {}
    local key = MarketKey()
    local market = AutoEverythingAuctionDB.markets[key]
    if type(market) ~= "table" then
        market = { version = 2, items = {}, shopping = {} }
        AutoEverythingAuctionDB.markets[key] = market
    end
    market.version = 2
    market.items = type(market.items) == "table" and market.items or {}
    market.shopping = type(market.shopping) == "table" and market.shopping or {}
    return market
end

local function ItemID(link)
    return tonumber(link and link:match("item:(%-?%d+)"))
end

local function ItemString(link)
    return link and (link:match("|H(item:[^|]+)|h") or link:match("(item:[^|]+)"))
end

local function ItemVariantString(link)
    local itemString = ItemString(link)
    if not itemString then return nil end
    local fields = {}
    for field in (itemString .. ":"):gmatch("(.-):") do table.insert(fields, field) end
    if #fields >= 9 then fields[9] = "0" end
    return table.concat(fields, ":")
end

local function IsEquipment(itemType)
    return itemType == "Armor" or itemType == "Weapon"
        or itemType == (ARMOR or "Armor") or itemType == (WEAPON or "Weapon")
end

local function IsMarketPriceEligible(link, itemType)
    if not IsEquipment(itemType) then return true end
    if not link or not GetItemInfo then return false end
    local requiredLevel = select(5, GetItemInfo(link))
    requiredLevel = tonumber(requiredLevel)
    return requiredLevel == 60
end

local function UpgradeStatWeights()
    local profile = Core and Core.GetProfile and Core.GetProfile(AutoUpgradeConfig)
    if profile and type(profile.weights) == "table" then return profile.weights end
    if AutoUpgradeConfig and type(AutoUpgradeConfig.weights) == "table" then return AutoUpgradeConfig.weights end
    if AutoUpgradeConfig and type(AutoUpgradeConfig.default) == "table"
        and type(AutoUpgradeConfig.default.weights) == "table"
    then return AutoUpgradeConfig.default.weights end
    return {}
end

local function CaptureMarketGearStats(link, itemType, auctionIndex)
    if not IsEquipment(itemType) or not IsMarketPriceEligible(link, itemType) then return nil end
    local _, _, _, itemLevel, requiredLevel, _, _, _, equipSlot = GetItemInfo(link)
    -- Required-level-60 gear is fully scaled. Prefer the auction-row setter so
    -- random variants are parsed exactly as displayed instead of as a base link.
    local location = auctionIndex and { auctionType = "list", auctionIndex = auctionIndex } or nil
    local stats = Core and Core.GetItemStats and Core.GetItemStats(link, UpgradeStatWeights(), location) or {}
    return stats, tonumber(itemLevel), tonumber(requiredLevel), equipSlot
end

local function MarketItemKey(link, itemType)
    local id = ItemID(link)
    if not id then return nil end
    if IsEquipment(itemType) then
        local itemString = ItemVariantString(link)
        return itemString and ("gear:" .. itemString) or ("item:" .. tostring(id))
    end
    return tostring(id)
end

local function FindMarketItem(market, link, itemType)
    local key = MarketItemKey(link, itemType)
    local item = key and market.items[key]
    -- Version-one databases keyed every item by ID. This fallback preserves
    -- tooltip history until a new scan records an exact equipment variant.
    if not item then item = market.items[tostring(ItemID(link))] end
    return item, key
end

local function InsertLowest(prices, row)
    local inserted
    for index, old in ipairs(prices) do
        if row.unit < old.unit then table.insert(prices, index, row); inserted = true; break end
    end
    if not inserted then table.insert(prices, row) end
    while #prices > MAX_SAVED_PRICES do table.remove(prices) end
end

local function Median(values)
    if #values == 0 then return nil end
    table.sort(values)
    local middle = math.floor((#values + 1) / 2)
    if #values % 2 == 1 then return values[middle] end
    return math.floor((values[middle] + values[middle + 1]) / 2)
end

local function SellerKey(row, index)
    local owner = row and row.owner
    if type(owner) == "string" and owner ~= "" then return string.lower(owner) end
    -- Old saved observations may not have an owner. Keep those rows usable,
    -- but do not merge unrelated unknown sellers into one participant.
    return "unknown:" .. tostring(index)
end

local function IsPlayerSeller(owner)
    if type(owner) ~= "string" or owner == "" or not UnitName then return false end
    local player = UnitName("player")
    if type(player) ~= "string" or player == "" then return false end
    -- Some clients append a realm to auction owners while UnitName returns only
    -- the character name. Character names themselves cannot contain a hyphen.
    owner = owner:match("^([^-]+)") or owner
    player = player:match("^([^-]+)") or player
    return string.lower(owner) == string.lower(player)
end

-- Skip isolated bait listings, but prefer the first pair of closely matched
-- auctions from different sellers instead of allowing one seller's many small
-- listings to manufacture support for a false market floor.
local function SupportedLowPrice(prices)
    for first = 1, #prices do
        local floor = tonumber(prices[first].unit)
        if floor and floor > 0 then
            local ceiling = floor * 1.15
            local support, sellers = 0, {}
            for index = first, #prices do
                local row = prices[index]
                local unit = tonumber(row.unit)
                if not unit or unit <= 0 then
                    -- Ignore malformed rows without treating them as support.
                elseif unit > ceiling then
                    break
                else
                    local seller = SellerKey(row, index)
                    if not sellers[seller] then
                        sellers[seller] = true
                        support = support + 1
                        if support >= 2 then return unit end
                    end
                end
            end
        end
    end
end

-- Estimate a supported market level from independent sellers. Each seller's
-- total quantity is capped so splitting stock across many one-item auctions
-- cannot manufacture confidence. Recent scan history guards against abrupt
-- manipulated floors. UI confidence deliberately describes the outcome rather
-- than publishing the safety thresholds as a recipe.
local function ReasonablePrice(item)
    local prices = item and item.current or {}
    if #prices < 3 then return nil, #prices, "Weak", "insufficient market support" end

    local totalWeight, listingSupport, sellerWeights = 0, 0, {}
    for index, row in ipairs(prices) do
        if row.unit and row.unit > 0 then
            local seller = SellerKey(row, index)
            local previous = sellerWeights[seller] or 0
            local combined = math.min(previous + math.max(1, tonumber(row.count) or 1), 20)
            sellerWeights[seller] = combined
            totalWeight = totalWeight + combined - previous
            if previous == 0 then listingSupport = listingSupport + 1 end
        end
    end
    if listingSupport < 3 or totalWeight < 4 then
        return nil, listingSupport, "Weak", "insufficient market support"
    end

    local estimate = SupportedLowPrice(prices)
    if not estimate then return nil, listingSupport, "Weak", "no independently supported price" end

    local history = {}
    for _, observation in ipairs(item.history or {}) do
        if observation.floor and observation.floor > 0
            and observation.time and time() - observation.time <= 14 * 24 * 60 * 60
        then table.insert(history, observation.floor) end
    end
    local historical = Median(history)
    -- For a seller, only a collapsing supported floor is dangerous. A strongly
    -- supported upward move is favorable and should become the new estimate.
    if historical and estimate < historical * 0.45 then
        return nil, listingSupport, "Suspicious", "market moved outside recent safety bounds"
    end

    local confidence = listingSupport >= 8 and totalWeight >= 12 and "Trusted" or "Guarded"
    if confidence ~= "Trusted" then
        return estimate, listingSupport, confidence, "limited independent support"
    end
    return estimate, listingSupport, confidence, "supported current market"
end
Auction.GetReasonablePrice = ReasonablePrice
Auction.GetMarketItemKey = MarketItemKey

local function UpdateCheckedMarketItem(link, itemType, rows)
    local market = EnsureDB()
    local key = MarketItemKey(link, itemType)
    if not key then return nil end
    if not IsMarketPriceEligible(link, itemType) then
        market.items[key] = nil
        return nil
    end
    local item = market.items[key] or { history = {} }
    local name, _, quality, _, _, resolvedType, subType = GetItemInfo(link)
    local stats, itemLevel, requiredLevel, equipSlot = CaptureMarketGearStats(link, resolvedType or itemType)
    local current, listings, quantity = {}, 0, 0
    for _, row in ipairs(rows or {}) do
        local unit, count = tonumber(row.unit), math.max(1, tonumber(row.count) or 1)
        if unit and unit > 0 then
            InsertLowest(current, { unit = math.max(1, math.floor(unit)), count = count, owner = row.owner })
            listings = listings + 1
            quantity = quantity + count
        end
    end
    local now = time()
    item.name, item.link, item.itemID = name or item.name, link, ItemID(link)
    item.quality, item.itemType, item.subType = quality, resolvedType or itemType, subType
    if stats then
        item.stats, item.itemLevel, item.requiredLevel, item.equipSlot = stats, itemLevel, requiredLevel, equipSlot
    end
    item.current, item.listings, item.quantity = current, listings, quantity
    item.lastChecked = now
    if #current > 0 then item.lastSeen = now end
    item.history = type(item.history) == "table" and item.history or {}
    -- Current-only support allows a legitimate upward move to become the new
    -- cached per-item price without an older observation vetoing it.
    local price = ReasonablePrice({ current = current, history = {} })
    item.price = price or (current[1] and current[1].unit) or item.price
    item.priceTime = #current > 0 and now or item.priceTime
    table.insert(item.history, { time = now, floor = price, listings = item.listings, quantity = item.quantity })
    while #item.history > MAX_HISTORY do table.remove(item.history, 1) end
    market.items[key] = item
    market.lastIncrementalUpdate = now
    return item
end

local function InventoryItemCount(unit, slot)
    if not GetInventoryItemCount then return nil end
    local count = tonumber(GetInventoryItemCount(unit, slot))
    if count and count > 0 then return count end
    return nil
end

local function NumericStackCount(value)
    if type(value) ~= "number" and type(value) ~= "string" then return nil end
    local normalized = tostring(value):gsub("[,%.]", "")
    local count = tonumber(normalized)
    if count and count > 1 then return count end
    return nil
end

local function RegionStackCount(region)
    if not region then return nil end
    local kind = type(region)
    if kind == "number" or kind == "string" then return NumericStackCount(region) end
    if kind ~= "table" and kind ~= "userdata" then return nil end
    if not region.GetText then return nil end
    return NumericStackCount(region:GetText())
end

local function ButtonStackCount(button)
    if not button then return nil end
    for _, key in ipairs({ "itemCount", "stackCount", "quantity" }) do
        local count = NumericStackCount(button[key])
        if count then return count end
    end

    local countRegion = button.Count or button.count or button.CountText or button.countText
    if not countRegion and button.GetName then
        local name = button:GetName()
        if name then countRegion = _G[name .. "Count"] end
    end
    local count = RegionStackCount(countRegion)
    if count then return count end

    -- Ascension's bank count can be an unnamed FontString. Prefer a region
    -- explicitly named as a count, then a numeric bottom-right icon overlay.
    if button.GetRegions then
        local regions = { button:GetRegions() }
        local cornerCount
        for _, region in ipairs(regions) do
            count = RegionStackCount(region)
            if count then
                local name = region.GetName and region:GetName()
                if name and name:lower():find("count", 1, true) then return count end
                local point = region.GetPoint and region:GetPoint(1)
                if point and point:find("BOTTOM", 1, true) and point:find("RIGHT", 1, true) then
                    cornerCount = count
                end
            end
        end
        if cornerCount then return cornerCount end
    end
    return nil
end

local function FrameStackCount(frame, link)
    -- Some bag addons put the tooltip or mouse on a child region instead of
    -- the item button, so walk up through its owners before giving up.
    for _ = 1, 6 do
        if not frame then break end
        local slot = frame.slotID or frame.SlotID or (frame.GetID and frame:GetID())
        local parent = frame.GetParent and frame:GetParent()
        local bag = frame.bagID or frame.BagID or (parent and parent.GetID and parent:GetID())
        if type(bag) == "number" and type(slot) == "number"
            and GetContainerItemLink(bag, slot) == link then
            local _, count = GetContainerItemInfo(bag, slot)
            if tonumber(count) and count > 0 then return count end
        end

        -- Main-bank buttons can use SetInventoryItem rather than SetBagItem.
        local inventorySlot = frame.GetInventorySlot and frame:GetInventorySlot()
        if type(inventorySlot) == "number" and GetInventoryItemLink("player", inventorySlot) == link then
            local count = InventoryItemCount("player", inventorySlot)
            if count then return count end
        end

        -- Ascension's personal-bank buttons do not always expose their count
        -- through either standard item API, but their visible Count region is
        -- still authoritative for the stack currently under the tooltip.
        local count = ButtonStackCount(frame)
        if count then return count end
        frame = parent
    end
    return nil
end

local function TooltipStackCount(tooltip, link)
    local owner = tooltip and tooltip.GetOwner and tooltip:GetOwner()
    local count = FrameStackCount(owner, link)
    if count then return count end
    return FrameStackCount(GetMouseFocus and GetMouseFocus(), link)
end

local function AddTooltipPrice(tooltip, link, stackCount)
    if Setting("showTooltipPrices", true) == false or not tooltip then return end
    if not link and tooltip.GetItem then
        local _, tooltipLink = tooltip:GetItem()
        link = tooltipLink
    end
    local itemID = ItemID(link)
    local marker = tostring(link) .. ":" .. tostring(stackCount or "auto")
        .. ":" .. tostring(IsShiftKeyDown and IsShiftKeyDown())
    if not itemID or tooltip.aeAuctionMarketLink == marker then return end
    tooltip.aeAuctionMarketLink = marker

    local _, _, _, _, _, itemType, _, _, _, _, vendorPrice = GetItemInfo(link)
    local market = EnsureDB()
    local item = IsMarketPriceEligible(link, itemType) and FindMarketItem(market, link, itemType) or nil
    local unit, support, estimateConfidence = ReasonablePrice(item)
    local priceTime = unit and item and (item.priceTime or item.lastSeen) or market.lastScan
    local fresh = priceTime and time() - priceTime <= 24 * 60 * 60
    local confidence, source = "Low", "stale market data"

    if unit and fresh then
        confidence = estimateConfidence == "Trusted" and "High" or "Medium"
        source = "supported current market"
    elseif not unit and item and item.current and item.current[1] then
        unit = item.current[1].unit
        priceTime = item.lastSeen or item.priceTime or market.lastScan
        fresh = priceTime and time() - priceTime <= 24 * 60 * 60
        confidence = fresh and "Medium" or "Low"
        source = "sparse current listings"
    end
    if not unit and item and type(item.history) == "table" then
        for index = #item.history, 1, -1 do
            if item.history[index].floor then
                unit = item.history[index].floor
                priceTime = item.history[index].time
                confidence = "Low"
                source = "historical price"
                break
            end
        end
    end

    local r, g, b = 1, 0.25, 0.25
    if confidence == "High" then
        r, g, b = 0.25, 1, 0.35
    elseif confidence == "Medium" then
        r, g, b = 1, 0.82, 0.2
    end

    tooltip:AddDoubleLine("Vendor", vendorPrice and TooltipMoney(vendorPrice) or "No sell price", 0.75, 0.75, 0.75, 1, 1, 1)
    if unit then
        local stack = tonumber(stackCount)
        local buttonCount = TooltipStackCount(tooltip, link)
        if buttonCount and (not stack or buttonCount > stack) then stack = buttonCount end
        tooltip:AddDoubleLine("Auction", TooltipMoney(unit), r, g, b, r, g, b)
        if stack and stack > 1 then
            tooltip:AddDoubleLine("Auction Stack (x" .. stack .. ")", TooltipMoney(unit * stack), r, g, b, r, g, b)
        end
        if IsEquipment(itemType) then
            tooltip:AddLine("Scaled gear may not match this market variant or value.", 1, 0.55, 0.2, true)
        end
        if IsShiftKeyDown and IsShiftKeyDown() then
            tooltip:AddLine("  " .. confidence .. " confidence - " .. source .. " - price seen " .. AgeText(priceTime), r, g, b, true)
        end
    else
        tooltip:AddDoubleLine("Auction", "No scanned price", r, g, b, r, g, b)
        if IsEquipment(itemType) then
            tooltip:AddLine("Scaled gear requires exact-variant price review.", 1, 0.55, 0.2, true)
        end
        if IsShiftKeyDown and IsShiftKeyDown() then
            tooltip:AddLine("  Low confidence - run an Auction House scan to collect a price", r, g, b, true)
        end
    end
    -- Recalculate ElvUI's backdrop so the coin lines remain inside it.
    tooltip:Show()
end

local function TooltipLink(tooltip)
    if not tooltip or not tooltip.GetItem then return nil end
    local _, link = tooltip:GetItem()
    return link
end

local function HookPriceMethod(tooltip, method, resolver)
    if not tooltip or not tooltip[method] then return end
    hooksecurefunc(tooltip, method, function(self, ...)
        local arguments = { ... }
        self.__aeAuctionPendingLink = nil
        self.aeAuctionRefresh = function()
            self[method](self, unpack(arguments))
        end
        local link, count = resolver and resolver(self, ...) or TooltipLink(self)
        AddTooltipPrice(self, link or TooltipLink(self), count)
    end)
end

local function HookTooltip(tooltip)
    if not tooltip or not tooltip.HookScript or tooltip.__aeAuctionTooltipHooked then return end
    tooltip.__aeAuctionTooltipHooked = true
    tooltip:HookScript("OnTooltipCleared", function(self)
        self.aeAuctionMarketLink = nil
        self.aeAuctionRefresh = nil
        self.__aeAuctionPendingLink = nil
    end)
    -- Some custom frames and tooltip addons fill item tooltips without using a
    -- standard setter we can resolve directly. Queue a next-frame fallback so
    -- a named hook can still provide its authoritative stack count first.
    tooltip:HookScript("OnTooltipSetItem", function(self)
        self.__aeAuctionPendingLink = TooltipLink(self)
    end)
    tooltip:HookScript("OnUpdate", function(self)
        local link = self.__aeAuctionPendingLink
        if not link then return end
        self.__aeAuctionPendingLink = nil
        AddTooltipPrice(self, link)
    end)
    HookPriceMethod(tooltip, "SetHyperlink", function(_, link, count)
        -- Ascension/custom UIs may pass the displayed quantity as a second
        -- argument even though Blizzard's original method only needs a link.
        return link, count
    end)
    HookPriceMethod(tooltip, "SetBagItem", function(_, bag, slot)
        local _, count = GetContainerItemInfo(bag, slot)
        return GetContainerItemLink(bag, slot), count
    end)
    HookPriceMethod(tooltip, "SetInventoryItem", function(_, unit, slot)
        return GetInventoryItemLink(unit, slot), InventoryItemCount(unit, slot)
    end)
    HookPriceMethod(tooltip, "SetMerchantItem", function(_, index)
        local _, _, _, quantity = GetMerchantItemInfo(index)
        return GetMerchantItemLink(index), quantity
    end)
    HookPriceMethod(tooltip, "SetMerchantCostItem")
    HookPriceMethod(tooltip, "SetBuybackItem", function(self, index)
        local quantity
        if GetBuybackItemInfo then quantity = select(4, GetBuybackItemInfo(index)) end
        return TooltipLink(self), quantity
    end)
    HookPriceMethod(tooltip, "SetInboxItem", function(self, inboxIndex, attachmentIndex)
        local quantity
        if GetInboxItem then quantity = select(4, GetInboxItem(inboxIndex, attachmentIndex)) end
        return TooltipLink(self), quantity
    end)
    HookPriceMethod(tooltip, "SetSendMailItem", function(self, index)
        local quantity
        if GetSendMailItem then quantity = select(3, GetSendMailItem(index)) end
        return TooltipLink(self), quantity
    end)
    HookPriceMethod(tooltip, "SetTradePlayerItem", function(self, index)
        local quantity
        if GetTradePlayerItemInfo then quantity = select(3, GetTradePlayerItemInfo(index)) end
        return TooltipLink(self), quantity
    end)
    HookPriceMethod(tooltip, "SetTradeTargetItem", function(self, index)
        local quantity
        if GetTradeTargetItemInfo then quantity = select(3, GetTradeTargetItemInfo(index)) end
        return TooltipLink(self), quantity
    end)
    HookPriceMethod(tooltip, "SetAuctionItem", function(_, listType, index)
        local _, _, count = GetAuctionItemInfo(listType, index)
        return GetAuctionItemLink(listType, index), count
    end)
    HookPriceMethod(tooltip, "SetLootItem", function(_, slot)
        local _, _, quantity = GetLootSlotInfo(slot)
        return GetLootSlotLink(slot), quantity
    end)
    HookPriceMethod(tooltip, "SetLootRollItem", function(_, rollID)
        local quantity
        if GetLootRollItemInfo then quantity = select(3, GetLootRollItemInfo(rollID)) end
        return GetLootRollItemLink and GetLootRollItemLink(rollID), quantity
    end)
    HookPriceMethod(tooltip, "SetQuestItem", function(_, questType, index)
        local quantity
        if GetQuestItemInfo then quantity = select(3, GetQuestItemInfo(questType, index)) end
        return GetQuestItemLink(questType, index), quantity
    end)
    HookPriceMethod(tooltip, "SetQuestLogItem", function(_, itemType, index)
        local quantity
        if itemType == "choice" and GetQuestLogChoiceInfo then
            quantity = select(3, GetQuestLogChoiceInfo(index))
        elseif GetQuestLogRewardInfo then
            quantity = select(3, GetQuestLogRewardInfo(index))
        end
        return GetQuestLogItemLink(itemType, index), quantity
    end)
    HookPriceMethod(tooltip, "SetTradeSkillItem", function(_, index)
        local quantity
        if GetTradeSkillNumMade then quantity = GetTradeSkillNumMade(index) end
        return GetTradeSkillItemLink and GetTradeSkillItemLink(index), quantity
    end)
    HookPriceMethod(tooltip, "SetTradeSkillReagent", function(_, index, reagent)
        local quantity
        if GetTradeSkillReagentInfo then quantity = select(3, GetTradeSkillReagentInfo(index, reagent)) end
        return GetTradeSkillReagentItemLink and GetTradeSkillReagentItemLink(index, reagent), quantity
    end)
    HookPriceMethod(tooltip, "SetCraftItem", function(_, index)
        local quantity
        if GetCraftNumMade then quantity = GetCraftNumMade(index) end
        return GetCraftItemLink and GetCraftItemLink(index), quantity
    end)
    HookPriceMethod(tooltip, "SetCraftReagent", function(_, index, reagent)
        local quantity
        if GetCraftReagentInfo then quantity = select(3, GetCraftReagentInfo(index, reagent)) end
        return GetCraftReagentItemLink and GetCraftReagentItemLink(index, reagent), quantity
    end)
    HookPriceMethod(tooltip, "SetGuildBankItem", function(_, tab, slot)
        local quantity
        if GetGuildBankItemInfo then quantity = select(2, GetGuildBankItemInfo(tab, slot)) end
        return GetGuildBankItemLink and GetGuildBankItemLink(tab, slot), quantity
    end)
    HookPriceMethod(tooltip, "SetAuctionSellItem", function(self)
        local quantity
        if GetAuctionSellItemInfo then quantity = select(3, GetAuctionSellItemInfo()) end
        return TooltipLink(self), quantity
    end)
    HookPriceMethod(tooltip, "SetHyperlinkCompareItem", function(self)
        -- The argument is the hovered candidate; GetItem returns the equipped
        -- item actually rendered in this comparison panel.
        return TooltipLink(self)
    end)
end

local function AuctionTooltipFrames()
    return {
        GameTooltip, ItemRefTooltip,
        ShoppingTooltip1, ShoppingTooltip2, ShoppingTooltip3,
        ItemRefShoppingTooltip1, ItemRefShoppingTooltip2, ItemRefShoppingTooltip3,
    }
end

local function HookAuctionTooltips()
    for _, tooltip in pairs(AuctionTooltipFrames()) do
        HookTooltip(tooltip)
    end
end

HookAuctionTooltips()

local modifierFrame = CreateFrame("Frame")
modifierFrame:RegisterEvent("MODIFIER_STATE_CHANGED")
modifierFrame:SetScript("OnEvent", function(_, _, key)
    if not key or not key:find("SHIFT") then return end
    for _, tooltip in pairs(AuctionTooltipFrames()) do
        if tooltip and tooltip:IsShown() and tooltip.aeAuctionRefresh then
            tooltip.aeAuctionRefresh()
        end
    end
end)

local function AbortScan(reason)
    scan = nil
    UpdateWorkerState()
    if scanButton then scanButton:SetText("Scan Market") end
    WorkStatus(reason or "Scan stopped.")
    if reason then Warn(reason) end
end

local function RefreshScanFooters(market)
    market = market or EnsureDB()
    local scanned = market.lastScan and date("%Y-%m-%d %H:%M", market.lastScan) or "never"
    local latest = math.max(tonumber(market.lastScan) or 0, tonumber(market.lastIncrementalUpdate) or 0)
    local updated = latest > 0 and date("%Y-%m-%d %H:%M", latest) or "never"
    local text = "Market updated: " .. updated .. " | Full scan: " .. scanned
    for _, footer in ipairs(scanFooters) do footer:SetText(text) end
    if scanStatsText then
        local itemCount, gearStatCount = 0, 0
        for _, item in pairs(market.items or {}) do
            itemCount = itemCount + 1
            if IsEquipment(item.itemType) and type(item.stats) == "table" and next(item.stats) then
                gearStatCount = gearStatCount + 1
            end
        end
        local freshness = latest > 0 and AgeText(latest) or "no observations"
        scanStatsText:SetText(itemCount .. " item variants tracked | "
            .. gearStatCount .. " gear stat sets | "
            .. tostring(market.lastAuctionCount or 0) .. " auction rows | " .. freshness)
    end
end

local function RefreshWindow()
    if not window then return end
    local market = EnsureDB()
    RefreshScanFooters(market)
    local mode = Setting("postingMode", "queue")
    if modeButton then modeButton:SetText(mode == "auto" and "Mode: Auto Post" or "Mode: Preview Queue") end
    if postButton then
        if posting then postButton:SetText("Stop Posting")
        elseif #queue > 0 then postButton:SetText("Post Queue (" .. #queue .. ")")
        else postButton:SetText("Build Queue") end
    end
    if not scan and statusText then statusText:SetText(#queue .. " queued") end
    if manual.undercutBox and not manual.undercutBox:HasFocus() then
        manual.undercutBox:SetText(tostring(UndercutPercent()))
    end
    for index, row in ipairs(queueRows) do
        local entry = queue[index]
        if entry then
            local stackSize = tonumber(entry.stackSize) or entry.count
            local numStacks = tonumber(entry.numStacks) or 1
            local quantity = numStacks > 1 and (numStacks .. " x " .. stackSize) or ("x" .. stackSize)
            if row.name then
                row.name:SetText(entry.link or entry.name)
                row.quantity:SetText(quantity)
                row.unit:SetText(entry.unitPrice and TooltipMoney(entry.unitPrice) or "Live check")
                row.total:SetText(entry.unitPrice and TooltipMoney(entry.unitPrice * stackSize * numStacks) or "-")
                row.source:SetText(entry.manualPrice and "Manual" or (entry.unitPrice and "Cached" or "Pending"))
            else
                row:SetText(entry.name .. " " .. quantity .. "   "
                    .. (entry.unitPrice and (Money(entry.unitPrice) .. " each") or "live price pending"))
            end
            row:Show()
        else row:Hide() end
    end
    -- The selected bag stack is temporarily locked while an auction is being
    -- created. Rescanning it here would remove the selection and reset both
    -- quantity controls in the middle of a multisell.
    if RefreshSellGrid and not posting then RefreshSellGrid() end
end
Auction.Refresh = RefreshWindow

local function FinishScan()
    if not scan then return end
    local expected = tonumber(scan.expectedTotal) or 0
    if expected > 0 and scan.auctions < math.floor(expected * 0.90) then
        AbortScan("Incomplete scan (" .. scan.auctions .. "/" .. expected .. "); old database preserved.")
        return
    end
    local market = EnsureDB()
    local now = time()
    for key, old in pairs(market.items) do
        if not IsMarketPriceEligible(old.link, old.itemType) then
            market.items[key] = nil
        else
            old.current = {}
            if old.lastSeen and now - old.lastSeen > DATABASE_MAX_AGE then market.items[key] = nil end
        end
    end
    local itemCount = 0
    for key, gathered in pairs(scan.items) do
        local item = market.items[key] or { history = {} }
        item.name, item.link, item.itemID = gathered.name, gathered.link, gathered.itemID
        item.quality, item.itemType, item.subType = gathered.quality, gathered.itemType, gathered.subType
        item.stats, item.itemLevel = gathered.stats, gathered.itemLevel
        item.requiredLevel, item.equipSlot = gathered.requiredLevel, gathered.equipSlot
        item.current, item.listings, item.quantity = gathered.current, gathered.listings, gathered.quantity
        item.lastSeen = now
        item.history = type(item.history) == "table" and item.history or {}
        local floor = ReasonablePrice(item)
        item.price, item.priceTime = floor or (item.current[1] and item.current[1].unit), now
        table.insert(item.history, { time = now, floor = floor, listings = item.listings, quantity = item.quantity })
        while #item.history > MAX_HISTORY do table.remove(item.history, 1) end
        market.items[key] = item
        itemCount = itemCount + 1
    end
    market.lastScan, market.lastIncrementalUpdate, market.lastAuctionCount = now, now, scan.auctions
    local elapsed = GetTime() - scan.startedAt
    scan = nil
    UpdateWorkerState()
    if scanButton then scanButton:SetText("Scan Market") end
    Auction.BuildQueue()
    local completion = "Scan complete: " .. itemCount .. " item variants from " .. market.lastAuctionCount
        .. " auction rows in " .. string.format("%.1f", elapsed) .. " seconds."
    Info(completion)
    WorkStatus(completion)
    RefreshWindow()
    if Setting("postingMode", "queue") == "auto" and #queue > 0 then Auction.StartPosting() end
end

local SendQuery

local function StoreRecord(record)
    if not IsMarketPriceEligible(record.link, record.itemType) then return end
    local key = MarketItemKey(record.link, record.itemType)
    if not key then return end
    local item = scan.items[key]
    if not item then
        local stats, itemLevel, requiredLevel, equipSlot =
            CaptureMarketGearStats(record.link, record.itemType, record.index)
        item = { name = record.name, link = record.link, itemID = record.itemID, quality = record.quality,
            itemType = record.itemType, subType = record.subType,
            stats = stats, itemLevel = itemLevel, requiredLevel = requiredLevel, equipSlot = equipSlot,
            current = {}, listings = 0, quantity = 0 }
        scan.items[key] = item
    end
    item.listings = item.listings + 1
    item.quantity = item.quantity + record.count
    InsertLowest(item.current, { unit = math.max(1, math.floor(record.buyout / record.count)),
        count = record.count, owner = record.owner })
end

-- Ascension returns 0 for an active browse row and 1 for a completed row.
-- Lua treats both numbers as truthy, so the raw value cannot be used as a
-- boolean without hiding every active auction.
local function IsSoldAuction(value)
    return value == true or value == 1 or value == "1"
end

local function CapturePage()
    local num, total = GetNumAuctionItems("list")
    num, total = tonumber(num) or 0, tonumber(total) or 0
    local records, fingerprint, allIdentical = {}, {}, true
    local previousRow
    for index = 1, num do
        local name, _, count, quality, _, _, minBid, _, buyout, bidAmount, _, owner, sold = GetAuctionItemInfo("list", index)
        local link = GetAuctionItemLink("list", index)
        count, buyout = tonumber(count) or 0, tonumber(buyout) or 0
        local rowKey = table.concat({ tostring(name), tostring(count), tostring(minBid),
            tostring(buyout), tostring(bidAmount), tostring(sold) }, ":")
        fingerprint[#fingerprint + 1] = rowKey
        if previousRow and previousRow ~= rowKey then allIdentical = false end
        previousRow = rowKey

        -- Bid-only rows need no item metadata because they cannot produce a
        -- per-item buyout. Priced rows must be complete before this page is
        -- committed; Ascension often fills links a frame after the event.
        if not IsSoldAuction(sold) and (not name or name == "") then return nil, "missing item name" end
        if not IsSoldAuction(sold) and count > 0 and buyout > 0 then
            if not link then return nil, "missing item link" end
            local itemID = ItemID(link)
            local _, _, cachedQuality, _, _, itemType, subType = GetItemInfo(link)
            if not itemID or not itemType then return nil, "uncached item metadata" end
            records[#records + 1] = {
                name = name, link = link, itemID = itemID, count = count, quality = quality or cachedQuality,
                itemType = itemType, subType = subType, buyout = buyout, owner = owner, index = index,
            }
        end
    end
    return { num = num, total = total, records = records,
        fingerprint = table.concat(fingerprint, "|"), allIdentical = allIdentical }
end

local function ReadPage()
    if not scan or not scan.waiting then return end
    local page, badReason = CapturePage()
    if not page then
        local now = GetTime()
        scan.softRetries = (scan.softRetries or 0) + 1
        if now - (scan.responseAt or now) < HARD_RETRY_AFTER then
            scan.readyAt = now + SOFT_RETRY_DELAY
            WorkStatus("Page " .. (scan.page + 1) .. " settling: " .. badReason)
        else
            scan.waiting, scan.readyAt = false, nil
            scan.retries = scan.retries + 1
            if scan.retries > MAX_RETRIES then AbortScan("Incomplete data on page " .. (scan.page + 1) .. ".")
            else scan.nextQuery = now end
        end
        return
    end

    -- A server can occasionally answer a new page request with the preceding
    -- page again. Do not reject pages made of genuinely identical auctions.
    if scan.previousFingerprint and page.fingerprint == scan.previousFingerprint and not page.allIdentical then
        scan.waiting, scan.readyAt = false, nil
        scan.retries = scan.retries + 1
        if scan.retries > MAX_RETRIES then AbortScan("Repeated duplicate page " .. (scan.page + 1) .. ".")
        else scan.nextQuery = GetTime() end
        return
    end

    scan.waiting, scan.readyAt = false, nil
    scan.expectedTotal = math.max(scan.expectedTotal or 0, page.total)
    scan.retries, scan.softRetries = 0, 0
    scan.previousFingerprint = page.fingerprint
    for _, record in ipairs(page.records) do StoreRecord(record) end
    scan.auctions = scan.auctions + page.num
    -- A final page can contain exactly PAGE_SIZE rows. Some Ascension realms
    -- answer an out-of-range page request with that same final page instead
    -- of an empty page, so waiting only for a short page can scan forever.
    -- The server-reported total lets us finish without issuing that request.
    if scan.expectedTotal > 0 and scan.auctions >= scan.expectedTotal then FinishScan(); return end
    if page.num < PAGE_SIZE then FinishScan(); return end
    scan.page = scan.page + 1
    if scan.page >= MAX_PAGES then AbortScan("Scan stopped at the page safety limit."); return end
    scan.nextQuery = GetTime()
    SendQuery()
end

local function FallBackToPagedScan(reason)
    if not scan then return end
    scan.mode, scan.page, scan.items, scan.auctions = "pages", 0, {}, 0
    scan.expectedTotal, scan.waiting, scan.readyAt = 0, false, nil
    scan.fastCapture, scan.retries, scan.nextQuery = nil, 0, GetTime()
    WorkStatus((reason or "Get-all unavailable") .. "; using page-by-page scan.")
    SendQuery()
end

local function ProcessGetAllChunk()
    if not scan or not scan.fastCapture then return end
    local capture = scan.fastCapture
    local last = math.min(capture.num, capture.index + 49)
    for index = capture.index, last do
        local name, _, count, quality, _, _, _, _, buyout, _, _, owner, sold = GetAuctionItemInfo("list", index)
        local link = GetAuctionItemLink("list", index)
        count, buyout = tonumber(count) or 0, tonumber(buyout) or 0
        if not IsSoldAuction(sold) and (not name or name == "" or (count > 0 and buyout > 0 and not link)) then
            FallBackToPagedScan("Get-all returned incomplete rows")
            return
        end
        if not IsSoldAuction(sold) and link and count > 0 and buyout > 0 then
            local itemID = ItemID(link)
            local _, _, cachedQuality, _, _, itemType, subType = GetItemInfo(link)
            if not itemID or not itemType then
                FallBackToPagedScan("Get-all returned uncached item data")
                return
            end
            StoreRecord({ name = name, link = link, itemID = itemID, count = count,
                quality = quality or cachedQuality, itemType = itemType, subType = subType,
                buyout = buyout, owner = owner, index = index })
        end
    end
    capture.index = last + 1
    scan.auctions = last
    WorkStatus("Analyzing get-all data: " .. last .. "/" .. capture.num)
    if capture.index > capture.num then
        scan.fastCapture = nil
        if capture.total > capture.num then
            FallBackToPagedScan("Get-all returned only " .. capture.num .. "/" .. capture.total .. " rows")
        else
            scan.expectedTotal = capture.total
            FinishScan()
        end
    end
end

SendQuery = function()
    if not scan or scan.mode ~= "pages" or scan.waiting or GetTime() < (scan.nextQuery or 0) then return end
    if CanSendAuctionQuery and not CanSendAuctionQuery("list") then return end
    if SortAuctionClearSort then SortAuctionClearSort("list") end
    QueryAuctionItems("", nil, nil, nil, nil, nil, scan.page, nil, nil)
    scan.waiting, scan.sentAt, scan.readyAt, scan.responseAt = true, GetTime(), nil, nil
    WorkStatus("Scanning page " .. (scan.page + 1) .. " | " .. scan.auctions .. " auction rows read")
end

function Auction.StartScan()
    if scan then AbortScan("Scan stopped."); return end
    if posting or marketQuery then Warn("Stop other Auction House work before starting a scan."); return end
    if upgradeAnalysis then upgradeAnalysis = nil; UpdateWorkerState() end
    if not AuctionFrame or not AuctionFrame:IsShown() then Warn("Open the Auction House first."); return end
    local auctionatorScanning = Atr_IsFullScanActive and Atr_IsFullScanActive()
    if not auctionatorScanning and gAtr_FullScanState ~= nil then
        auctionatorScanning = gAtr_FullScanState ~= (ATR_FS_NULL or 0)
    end
    if auctionatorScanning then Warn("Auctionator is already scanning."); return end
    queue = {}
    scan = { page = 0, items = {}, auctions = 0, expectedTotal = 0, retries = 0,
        waiting = false, nextQuery = 0, startedAt = GetTime(), mode = "pages" }
    UpdateWorkerState()
    if scanButton then scanButton:SetText("Stop Scan") end
    local canQuery, canGetAll
    if CanSendAuctionQuery then canQuery, canGetAll = CanSendAuctionQuery("list") end
    if canQuery and canGetAll then
        scan.mode, scan.waiting, scan.sentAt = "getall", true, GetTime()
        WorkStatus("Trying server get-all scan...")
        QueryAuctionItems("", nil, nil, nil, nil, nil, 0, nil, nil, true)
    else
        SendQuery()
    end
    RefreshWindow()
end

local function RuleMatches(rule, data, boundStatus, usable, playerLevel)
    local unsupported = Core.GetUnsupportedEntryFields(rule)
    if #unsupported > 0 then return false end
    for _, exception in ipairs(rule.exceptions or {}) do
        if #Core.GetUnsupportedEntryFields(exception) > 0
            or Core.EntryMatches(exception, data, boundStatus, usable, playerLevel)
        then return false end
    end
    return Core.EntryMatches(rule, data, boundStatus, usable, playerLevel)
end

local function IsAuctionableBinding(boundStatus)
    return boundStatus == "unbound" or boundStatus == "boe" or boundStatus == "bou"
end

local function ShouldQueue(link, bag, slot)
    local config = Core.BuildActiveConfig(AutoAuctionConfig, "neverAuction",
        { "postingMode", "undercutPercent", "bidPercent", "duration", "maxPriceDropPercent" })
    if not config or config.enabled == false then return false end
    local location = { bag = bag, slot = slot, link = link }
    local data = Core.GetItemData(link, location)
    if not data or not data.id or data.itemType == "Quest" or data.itemType == "Key" then return false end
    if not IsMarketPriceEligible(link, data.itemType) then return false end
    if Core.IsActiveQuestItem(data.id) then return false end
    if AutoUpgrade and AutoUpgrade.IsBestPvPSetItem
        and AutoUpgrade.IsBestPvPSetItem(link, location)
    then return false end
    local boundStatus, usable = Core.ScanTooltip(link, nil, location)
    if not IsAuctionableBinding(boundStatus) then return false end
    local playerLevel = UnitLevel("player") or 0
    for _, rule in ipairs(config.never or {}) do
        if Core.EntryMatches(rule, data, boundStatus, usable, playerLevel) then return false end
    end
    for _, rule in ipairs(config.rules or {}) do
        if RuleMatches(rule, data, boundStatus, usable, playerLevel) then return true, data end
    end
    return false
end

function Auction.BuildQueue()
    queue = {}
    local market = EnsureDB()
    for bag = 0, NUM_BAG_SLOTS or 4 do
        for slot = 1, GetContainerNumSlots(bag) do
            local link = GetContainerItemLink(bag, slot)
            local _, count, locked = GetContainerItemInfo(bag, slot)
            count = tonumber(count) or 0
            if link and count > 0 and not locked then
                local matched, data = ShouldQueue(link, bag, slot)
                if matched then
                    local item = FindMarketItem(market, link, data.itemType)
                    local reasonable = ReasonablePrice(item)
                    local unit = reasonable and UndercutUnitPrice(reasonable, UndercutPercent()) or nil
                    table.insert(queue, { bag = bag, slot = slot, link = link, itemID = data.id,
                        itemType = data.itemType, name = data.name or link, count = count, unitPrice = unit })
                end
            end
        end
    end
    table.sort(queue, function(a, b)
        if a.name == b.name then return a.bag < b.bag or (a.bag == b.bag and a.slot < b.slot) end
        return a.name < b.name
    end)
    RefreshWindow()
    if #queue == 0 then Info("No bag stacks matched the active auction rules.")
    else Info(#queue .. " bag stack(s) queued; each will receive a targeted live price check before posting.") end
    return queue
end

local function StopPosting(reason)
    posting, marketQuery = nil, nil
    UpdateWorkerState()
    ClearCursor()
    if reason then Warn(reason) end
    RefreshWindow()
end

local function ExactMarketMatch(target, link)
    if target.broad then return link ~= nil end
    if not link then return false end
    if target.equipment then return ItemVariantString(link) == ItemVariantString(target.link) end
    return ItemID(link) == target.itemID
end

local SendMarketQuery

local function FinishMarketQuery(reason)
    local work = marketQuery
    marketQuery = nil
    UpdateWorkerState()
    if not work then return end
    if work.callback then work.callback(reason, work.rows or {}, work.lastPage or {}) end
end

local function ReadMarketQueryPage()
    if not marketQuery or not marketQuery.waiting then return end
    local num, total = GetNumAuctionItems("list")
    num, total = tonumber(num) or 0, tonumber(total) or 0
    local pageRows = {}
    for index = 1, num do
        local name, _, count, _, _, _, _, _, buyout, _, _, owner, sold = GetAuctionItemInfo("list", index)
        local link = GetAuctionItemLink("list", index)
        count, buyout = tonumber(count) or 0, tonumber(buyout) or 0
        if not IsSoldAuction(sold) and (not name or (count > 0 and buyout > 0 and not link)) then
            marketQuery.readyAt = GetTime() + SOFT_RETRY_DELAY
            return
        end
        if not IsSoldAuction(sold) and count > 0 and buyout > 0 and ExactMarketMatch(marketQuery.target, link) then
            local row = { unit = math.max(1, math.floor(buyout / count)), count = count,
                buyout = buyout, owner = owner, link = link, name = name,
                index = index, page = marketQuery.page }
            table.insert(marketQuery.rows, row)
            table.insert(pageRows, row)
        end
    end
    marketQuery.waiting = false
    if marketQuery.target.notice == "shopping" then shopping.loadedPage = marketQuery.page end
    marketQuery.lastPage = pageRows
    marketQuery.total = math.max(marketQuery.total or 0, total)
    marketQuery.read = (marketQuery.read or 0) + num
    if marketQuery.target.singlePage or (marketQuery.total > 0 and marketQuery.read >= marketQuery.total) or num < PAGE_SIZE then
        FinishMarketQuery()
    else
        marketQuery.page = marketQuery.page + 1
        if marketQuery.page >= MAX_PAGES then FinishMarketQuery("Live query reached the page safety limit."); return end
        marketQuery.nextAt = GetTime()
        SendMarketQuery()
    end
end

SendMarketQuery = function()
    if not marketQuery or marketQuery.waiting or GetTime() < (marketQuery.nextAt or 0) then return end
    if CanSendAuctionQuery and not CanSendAuctionQuery("list") then return end
    QueryAuctionItems(marketQuery.target.name or "", nil, nil, nil, nil, nil, marketQuery.page, nil, nil)
    marketQuery.waiting, marketQuery.sentAt, marketQuery.readyAt = true, GetTime(), nil
    local message = "Checking live market page " .. (marketQuery.page + 1) .. "..."
    if marketQuery.target.notice == "manual" and manual.warning then
        manual.warning:SetText(message)
    elseif marketQuery.target.notice == "shopping" and shopping.resultText then
        shopping.resultText:SetText(message)
    elseif statusText or scanStatusText then
        WorkStatus(message)
    end
end

local function BeginMarketQuery(target, callback)
    if scan or marketQuery then return false end
    if upgradeAnalysis then upgradeAnalysis = nil; UpdateWorkerState() end
    local auctionatorScanning = Atr_IsFullScanActive and Atr_IsFullScanActive()
    if not auctionatorScanning and gAtr_FullScanState ~= nil then auctionatorScanning = gAtr_FullScanState ~= (ATR_FS_NULL or 0) end
    if auctionatorScanning then Warn("Auctionator is already scanning."); return false end
    if not QueryAuctionItems or not GetNumAuctionItems or not GetAuctionItemInfo then
        Warn("This client does not expose the required Auction House query APIs."); return false
    end
    marketQuery = { target = target, callback = callback, rows = {}, page = target.page or 0,
        read = 0, total = 0, nextAt = GetTime(), waiting = false }
    UpdateWorkerState()
    SendMarketQuery()
    return true
end

local function LiveSafePrice(entry, rows)
    local market = EnsureDB()
    local item = FindMarketItem(market, entry.link, entry.itemType)
    local liveItem = { current = rows, history = item and item.history or {} }
    table.sort(liveItem.current, function(a, b) return a.unit < b.unit end)
    if entry.manualPrice then
        -- Manual prices are authoritative. Judge them against current listings
        -- only: an old scan can lag a legitimate market move, as with several
        -- sellers converging at a new price. Any concern is advisory, never a
        -- blocker for a price the player explicitly reviewed.
        local currentOnly = { current = liveItem.current, history = {} }
        local liveUnit, _, _, liveReason = ReasonablePrice(currentOnly)
        local manualPrice = math.max(1, math.floor(entry.manualPrice))
        if not liveUnit then
            return manualPrice, "Live-market warning: " .. (liveReason or "insufficient current listings")
        end
        local drop = math.max(0, math.min(95, tonumber(Setting("maxPriceDropPercent", 40)) or 40))
        if manualPrice < liveUnit * (1 - drop / 100) then
            return manualPrice, "Price warning: reviewed price is far below the supported live market"
        end
        return manualPrice
    end
    local unit, _, confidence, reason = ReasonablePrice(liveItem)
    if not unit or confidence ~= "Trusted" then return nil, reason or "weak live market" end
    local historical = item and ReasonablePrice(item)
    local drop = math.max(0, math.min(95, tonumber(Setting("maxPriceDropPercent", 40)) or 40))
    if historical and unit < historical * (1 - drop / 100) then return nil, "live price is below the safety floor" end
    local lowest = liveItem.current[1] and liveItem.current[1].unit
    if lowest then
        -- If any listing tied at the cheapest unit price is ours, matching it
        -- avoids competing with ourselves. Only undercut when another seller
        -- owns the live floor.
        for _, row in ipairs(liveItem.current) do
            if row.unit ~= lowest then break end
            if IsPlayerSeller(row.owner) then return math.max(1, math.floor(lowest)) end
        end
    end
    local competitive = UndercutUnitPrice(unit, UndercutPercent())
    return competitive
end

local function PostValidated(entry, unitPrice)
    if not posting then return end
    local link = GetContainerItemLink(entry.bag, entry.slot)
    local _, count, locked = GetContainerItemInfo(entry.bag, entry.slot)
    count = tonumber(count) or 0
    local stackSize = math.max(1, math.floor(tonumber(entry.stackSize) or tonumber(entry.count) or 1))
    local numStacks = math.max(1, math.floor(tonumber(entry.numStacks) or 1))
    local required = stackSize * numStacks
    if link ~= entry.link or count < required or locked then
        posting.skipped = posting.skipped + 1
        return
    end
    if not IsMarketPriceEligible(link, entry.itemType) then
        posting.skipped = posting.skipped + 1
        return
    end
    if AutoUpgrade and AutoUpgrade.IsBestPvPSetItem
        and AutoUpgrade.IsBestPvPSetItem(link, { link=link, bag=entry.bag, slot=entry.slot })
    then
        posting.skipped = posting.skipped + 1
        return
    end
    local boundStatus = Core.ScanTooltip(link, nil, { bag = entry.bag, slot = entry.slot })
    if not IsAuctionableBinding(boundStatus) then posting.skipped = posting.skipped + 1; return end
    local buyout = unitPrice * stackSize
    local bidPercent = math.max(1, math.min(100, tonumber(Setting("bidPercent", 95)) or 95))
    local bid = math.max(1, math.floor(buyout * bidPercent / 100))
    local duration = tonumber(entry.duration or Setting("duration", 2)) or 2
    if duration < 1 or duration > 3 then duration = 2 end
    ClearCursor()
    if required < count and SplitContainerItem then SplitContainerItem(entry.bag, entry.slot, required)
    else PickupContainerItem(entry.bag, entry.slot) end
    if CursorHasItem and not CursorHasItem() then posting.skipped = posting.skipped + 1; return end
    if not ClickAuctionSellItemButton or not StartAuction then
        ClearCursor(); posting.skipped = posting.skipped + 1; Warn("Auction posting API is unavailable."); return
    end
    ClickAuctionSellItemButton()
    -- StartAuction may dispatch multisell progress immediately. Publish the
    -- waiting state first so those events cannot be missed and strand the
    -- queue until its timeout.
    posting.multisellExpected = numStacks > 1 and numStacks or nil
    posting.waiting, posting.sentAt, posting.current = true, GetTime(), entry
    StartAuction(bid, buyout, duration, stackSize, numStacks)
    if not posting then return end
    RefreshWindow()
end

local function PostNext()
    if not posting or posting.waiting or marketQuery then return end
    if #queue == 0 then
        posting = nil; UpdateWorkerState(); Info("Posting queue complete."); RefreshWindow(); return
    end
    local entry = table.remove(queue, 1)
    posting.current = entry
    local liveKey = MarketItemKey(entry.link, entry.itemType)
    local cached = not entry.manualPrice and liveKey and posting.livePrices and posting.livePrices[liveKey]
    if cached and GetTime() - cached.checkedAt <= 60 then
        PostValidated(entry, cached.unitPrice)
        return
    end
    local target = { link = entry.link, itemID = entry.itemID, name = entry.name,
        equipment = IsEquipment(entry.itemType) }
    local started = BeginMarketQuery(target, function(reason, rows)
        if not posting then return end
        if reason then
            if entry.manualPrice then
                if manual.warning then
                    manual.warning:SetText("Live-market warning: " .. reason .. " Manual post continued at your reviewed price.")
                end
                PostValidated(entry, math.max(1, math.floor(entry.manualPrice)))
            else
                posting.skipped = posting.skipped + 1
                Warn(reason)
            end
            return
        end
        local price, unsafe = LiveSafePrice(entry, rows)
        -- Persist only after the complete targeted query has been evaluated so
        -- the safety comparison still sees the prior database observation.
        UpdateCheckedMarketItem(entry.link, entry.itemType, rows)
        if not price then
            posting.skipped = posting.skipped + 1
            Warn("Skipped " .. entry.name .. ": " .. (unsafe or "unsafe live price") .. ".")
            return
        end
        if unsafe and entry.manualPrice and manual.warning then
            manual.warning:SetText(unsafe .. ". Manual post continued at your reviewed price.")
        end
        if not entry.manualPrice and liveKey then
            posting.livePrices = posting.livePrices or {}
            posting.livePrices[liveKey] = { unitPrice = price, checkedAt = GetTime() }
        end
        PostValidated(entry, price)
    end)
    if not started then
        if entry.manualPrice then
            if manual.warning then
                manual.warning:SetText("Live price check unavailable. Manual post continued at your reviewed price.")
            end
            PostValidated(entry, math.max(1, math.floor(entry.manualPrice)))
        else
            posting.skipped = posting.skipped + 1
        end
    end
end

function Auction.StartPosting()
    if posting then StopPosting("Posting stopped."); return end
    if scan then Warn("Wait for the market scan to finish."); return end
    if upgradeAnalysis then upgradeAnalysis = nil; UpdateWorkerState() end
    if not AuctionFrame or not AuctionFrame:IsShown() then Warn("Open the Auction House first."); return end
    if #queue == 0 then Auction.BuildQueue() end
    if #queue == 0 then return end
    posting = { waiting = false, nextAt = GetTime(), posted = 0, skipped = 0, livePrices = {} }
    UpdateWorkerState()
    Info("Posting " .. #queue .. " queued stack(s).")
    RefreshWindow()
end

local THEME = Core and Core.UI
local COLORS = THEME and THEME.Colors or {}
local WHITE_TEX = THEME and THEME.Textures.white or "Interface\\Buttons\\WHITE8X8"
local BRAND = COLORS.brand or { 0.345, 0.651, 1.000 }
local BORDER = COLORS.border or { 0.188, 0.212, 0.239 }
local CTRL_BG = COLORS.control or { 0.129, 0.149, 0.176 }
local WINDOW_BG = COLORS.window or { 0.051, 0.067, 0.090 }
local DANGER = COLORS.danger or { 0.973, 0.318, 0.286 }

local function Skin(frame)
    frame:SetBackdrop({ bgFile = WHITE_TEX, edgeFile = WHITE_TEX, edgeSize = 1 })
    frame:SetBackdropColor(WINDOW_BG[1], WINDOW_BG[2], WINDOW_BG[3], 0.99)
    frame:SetBackdropBorderColor(BORDER[1], BORDER[2], BORDER[3], 1)
end

local function StripButtonArt(button)
    for _, kind in ipairs({ "Normal", "Pushed", "Disabled", "Highlight" }) do
        local setter = button["Set" .. kind .. "Texture"]
        if setter then setter(button, "") end
        local getter = button["Get" .. kind .. "Texture"]
        local texture = getter and getter(button)
        if texture then texture:SetTexture(nil); texture:SetAlpha(0) end
    end
end

local function ClearAuctionTextFocus()
    local focus = GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus()
    if focus and focus.ClearFocus then focus:ClearFocus() end
end

local function StyleButton(button, kind)
    StripButtonArt(button)
    -- Buttons are an explicit "done editing" click everywhere in this window.
    button:HookScript("OnMouseDown", ClearAuctionTextFocus)
    Skin(button)
    if button.SetNormalFontObject then
        button:SetNormalFontObject("GameFontHighlight")
        button:SetHighlightFontObject("GameFontHighlight")
        if button.SetDisabledFontObject then button:SetDisabledFontObject("GameFontDisable") end
    end
    local function Paint(hovered)
        hovered = hovered or button.forceHovered
        local color = kind == "danger" and DANGER or BRAND
        if kind == "primary" then
            local strength = hovered and 0.24 or 0.14
            button:SetBackdropColor(color[1] * strength, color[2] * strength, color[3] * strength, 1)
            button:SetBackdropBorderColor(color[1], color[2], color[3], hovered and 1 or 0.78)
        else
            button:SetBackdropColor(CTRL_BG[1], CTRL_BG[2], CTRL_BG[3], 1)
            if hovered or kind == "danger" then
                button:SetBackdropBorderColor(color[1], color[2], color[3], hovered and 1 or 0.8)
            else
                button:SetBackdropBorderColor(BORDER[1], BORDER[2], BORDER[3], 1)
            end
        end
        -- Selection is persistent state, not merely a hover highlight.
        if button.forceSelected then button:SetBackdropBorderColor(BRAND[1], BRAND[2], BRAND[3], 1) end
        local font = button:GetFontString()
        if font then
            if kind == "danger" then font:SetTextColor(DANGER[1], DANGER[2], DANGER[3])
            elseif button.forceActive then font:SetTextColor(BRAND[1], BRAND[2], BRAND[3])
            else font:SetTextColor(1, 1, 1) end
        end
    end
    button.RefreshAuctionStyle = function() Paint(false) end
    button:HookScript("OnEnter", function() Paint(true) end)
    button:HookScript("OnLeave", function() Paint(false) end)
    Paint(false)
end

local function Button(parent, text, width, kind)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width, 24); button:SetText(text); StyleButton(button, kind)
    return button
end

local function EditBox(parent, width, numeric)
    local box = CreateFrame("EditBox", nil, parent)
    box:SetSize(width, 22); box:SetAutoFocus(false); box:SetFontObject(ChatFontNormal)
    box:SetTextInsets(6, 6, 0, 0)
    Skin(box)
    box:SetBackdropColor(CTRL_BG[1], CTRL_BG[2], CTRL_BG[3], 1)
    box:HookScript("OnEditFocusGained", function(self)
        self:SetBackdropBorderColor(BRAND[1], BRAND[2], BRAND[3], 1)
    end)
    box:HookScript("OnEditFocusLost", function(self)
        self:SetBackdropBorderColor(BORDER[1], BORDER[2], BORDER[3], 1)
    end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    if numeric and box.SetNumeric then box:SetNumeric(true) end
    return box
end

local function ItemSlot(parent)
    local slot = CreateFrame("Button", nil, parent)
    slot:SetSize(54, 54); Skin(slot)
    slot:SetBackdropColor(CTRL_BG[1], CTRL_BG[2], CTRL_BG[3], 1)
    slot.icon = slot:CreateTexture(nil, "ARTWORK")
    slot.icon:SetPoint("TOPLEFT", 4, -4); slot.icon:SetPoint("BOTTOMRIGHT", -4, 4)
    slot.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
    slot.count = slot:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    slot.count:SetPoint("BOTTOMRIGHT", -6, 5)
    slot:HookScript("OnEnter", function(self) self:SetBackdropBorderColor(BRAND[1], BRAND[2], BRAND[3], 1) end)
    slot:HookScript("OnLeave", function(self) self:SetBackdropBorderColor(BORDER[1], BORDER[2], BORDER[3], 1) end)
    return slot
end

local function MoneyInput(parent)
    local input = CreateFrame("Frame", nil, parent)
    input:SetSize(180, 22)
    local fields = {
        { "gold", "|TInterface\\MoneyFrame\\UI-GoldIcon:16:16:1:0|t" },
        { "silver", "|TInterface\\MoneyFrame\\UI-SilverIcon:16:16:1:0|t" },
        { "copper", "|TInterface\\MoneyFrame\\UI-CopperIcon:16:16:1:0|t" },
    }
    local previous
    for _, spec in ipairs(fields) do
        local box = EditBox(input, 40, true)
        if previous then box:SetPoint("LEFT", previous, "RIGHT", 16, 0) else box:SetPoint("LEFT", 0, 0) end
        local suffix = input:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        suffix:SetPoint("LEFT", box, "RIGHT", 4, 0); suffix:SetText(spec[2])
        input[spec[1]], previous = box, box
    end
    function input:GetValue()
        local gold = math.max(0, math.floor(tonumber(self.gold:GetText()) or 0))
        local silver = math.max(0, math.floor(tonumber(self.silver:GetText()) or 0))
        local copper = math.max(0, math.floor(tonumber(self.copper:GetText()) or 0))
        return gold * 10000 + silver * 100 + copper
    end
    function input:SetValue(value)
        value = math.max(0, math.floor(tonumber(value) or 0))
        self.gold:SetText(math.floor(value / 10000) or "")
        self.silver:SetText(math.floor((value % 10000) / 100) or "")
        self.copper:SetText(value % 100 or "")
    end
    input:SetValue(0)
    return input
end

local function AddHelp(frame, title, text)
    frame:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(title, 1, 1, 1)
        GameTooltip:AddLine(text, nil, nil, nil, true)
        GameTooltip:Show()
    end)
    frame:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

local function FindBagItem(link)
    for bag = 0, NUM_BAG_SLOTS or 4 do
        for slot = 1, GetContainerNumSlots(bag) do
            if GetContainerItemLink(bag, slot) == link then
                local _, count, locked = GetContainerItemInfo(bag, slot)
                if not locked then return bag, slot, tonumber(count) or 1 end
            end
        end
    end
end

local function ManualKey(bag, slot)
    return tostring(bag) .. ":" .. tostring(slot)
end

local function RefreshManualActive()
    local entry = manual.activeKey and manual.entries[manual.activeKey]
    if not entry then
        manual.link, manual.bag, manual.slot, manual.count = nil, nil, nil, nil
        manual.itemID, manual.itemType, manual.name, manual.suggested = nil, nil, nil, nil
        if manual.priceInput then manual.priceInput:SetValue(0) end
        if manual.countBox then manual.countBox:SetText("1") end
        if manual.stacksBox then manual.stacksBox:SetText("1") end
        return
    end
    entry.count = math.max(1, math.min(tonumber(entry.available) or entry.count or 1, tonumber(entry.count) or 1))
    entry.numStacks = math.max(1, math.min(math.floor((entry.available or 1) / entry.count),
        tonumber(entry.numStacks) or 1))
    manual.link, manual.bag, manual.slot, manual.count = entry.link, entry.bag, entry.slot, entry.count
    manual.itemID, manual.itemType, manual.name, manual.suggested = entry.itemID, entry.itemType, entry.name, entry.suggested
    -- The review field is the full listing buyout, while pricing safeguards
    -- retain a unit price internally.
    if manual.priceInput then manual.priceInput:SetValue((entry.manualPrice or entry.suggested or 0) * entry.count) end
    -- Background auction and bag refreshes must not replace a value while the
    -- player is typing it. The focus-lost handlers validate and commit it.
    if manual.countBox and not manual.countBox:HasFocus() then
        manual.countBox:SetText(tostring(entry.count))
    end
    if manual.stacksBox and not manual.stacksBox:HasFocus() then
        manual.stacksBox:SetText(tostring(entry.numStacks))
    end
end

local function ManualPriceNotice(entry)
    if not manual.warning or not entry or not entry.manualPrice then return end
    if not manual.liveRows or #manual.liveRows == 0 then
        manual.warning:SetText("Manual price accepted. Check Live to compare it with current listings before posting.")
        return
    end
    local currentOnly = { current = manual.liveRows, history = {} }
    local liveUnit, _, _, reason = ReasonablePrice(currentOnly)
    if not liveUnit then
        manual.warning:SetText("Price warning: " .. (reason or "current listings have weak support") .. ". Manual posting is still allowed.")
        return
    end
    local drop = math.max(0, math.min(95, tonumber(Setting("maxPriceDropPercent", 40)) or 40))
    if entry.manualPrice < liveUnit * (1 - drop / 100) then
        manual.warning:SetText("Price warning: your buyout is far below the supported live market. Manual posting is still allowed.")
    else
        manual.warning:SetText("Reviewed price is at or above the current live safety floor.")
    end
end

local function ApplyManualQuantity()
    local entry = manual.activeKey and manual.entries[manual.activeKey]
    if not entry then if manual.countBox then manual.countBox:SetText("1") end; return end
    local count = tonumber(manual.countBox:GetText())
    -- Empty, zero, and invalid entries are a single item, not an unusable row.
    entry.count = math.max(1, math.min(entry.available or 1, math.floor(count or 1)))
    entry.numStacks = math.max(1, math.min(tonumber(entry.numStacks) or 1,
        math.floor((entry.available or 1) / entry.count)))
    RefreshManualActive()
    if RefreshSellGrid then RefreshSellGrid() end
end

local function ApplyManualStacks()
    local entry = manual.activeKey and manual.entries[manual.activeKey]
    if not entry then if manual.stacksBox then manual.stacksBox:SetText("1") end; return end
    local maximum = math.max(1, math.floor((entry.available or 1) / math.max(1, entry.count)))
    entry.numStacks = math.max(1, math.min(maximum,
        math.floor(tonumber(manual.stacksBox:GetText()) or 1)))
    RefreshManualActive()
    if RefreshSellGrid then RefreshSellGrid() end
end

local function ApplyManualBuyout()
    local entry = manual.activeKey and manual.entries[manual.activeKey]
    if not entry then return end
    local buyout = math.max(0, math.floor(manual.priceInput:GetValue() or 0))
    entry.manualPrice = buyout > 0 and math.max(1, math.floor(buyout / math.max(1, entry.count))) or nil
    RefreshManualActive()
    ManualPriceNotice(entry)
    if RefreshSellGrid then RefreshSellGrid() end
end

local function IsManualSellable(link, bag, slot)
    local data = Core.GetItemData(link, { bag = bag, slot = slot, link = link })
    if not data or not data.id or data.itemType == "Quest" or data.itemType == "Key" then return false end
    if not IsMarketPriceEligible(link, data.itemType) then return false end
    if Core.IsActiveQuestItem(data.id) then return false end
    if AutoUpgrade and AutoUpgrade.IsBestPvPSetItem
        and AutoUpgrade.IsBestPvPSetItem(link, { link=link, bag=bag, slot=slot })
    then return false end
    local bound = Core.ScanTooltip(link, nil, { bag = bag, slot = slot })
    return IsAuctionableBinding(bound)
end

local function ScanSellInventory()
    local inventory, present = {}, {}
    for bag = 0, NUM_BAG_SLOTS or 4 do
        for slot = 1, GetContainerNumSlots(bag) do
            local link = GetContainerItemLink(bag, slot)
            local _, count, locked = GetContainerItemInfo(bag, slot)
            count = tonumber(count) or 0
            -- Keep the sell list focused: only unlocked, auctionable bag
            -- items appear. Quest and key items are never manual listings.
            if link and count > 0 and not locked and IsManualSellable(link, bag, slot) then
                local name, _, _, _, _, itemType = GetItemInfo(link)
                local key = ManualKey(bag, slot)
                local old = manual.entries[key]
                local entry = { bag = bag, slot = slot, link = link,
                    count = old and math.min(tonumber(old.count) or 1, count) or 1,
                    numStacks = old and tonumber(old.numStacks) or 1,
                    available = count, itemID = ItemID(link),
                    itemType = itemType, name = name or link, selected = old and old.selected,
                    manualPrice = old and old.manualPrice }
                local marketItem = FindMarketItem(EnsureDB(), link, itemType)
                local suggested, _, confidence = ReasonablePrice(marketItem)
                entry.suggested, entry.confidence = suggested, confidence
                entry.numStacks = math.max(1, math.min(math.floor(count / entry.count), entry.numStacks or 1))
                if entry.selected then manual.entries[key] = entry else manual.entries[key] = nil end
                inventory[#inventory + 1], present[key] = entry, true
            end
        end
    end
    for key in pairs(manual.entries) do if not present[key] then manual.entries[key] = nil end end
    table.sort(inventory, function(a, b)
        if tostring(a.name) == tostring(b.name) then
            return a.bag < b.bag or (a.bag == b.bag and a.slot < b.slot)
        end
        return tostring(a.name) < tostring(b.name)
    end)
    manual.inventory = inventory
    if manual.activeKey and not present[manual.activeKey] then manual.activeKey = nil end
    RefreshManualActive()
end

local function SetManualSelection(entry, selected)
    if not entry then return end
    local key = ManualKey(entry.bag, entry.slot)
    -- Manual selling is deliberately single-select: the active bag row owns
    -- the live comparison, stack controls, and reviewed posting price.
    wipe(manual.entries)
    if selected then
        entry.selected = true
        manual.entries[key], manual.activeKey = entry, key
    else
        manual.activeKey = nil
    end
    manual.liveRows, manual.marketSelection = {}, nil
    RefreshManualActive()
    if RefreshSellGrid then RefreshSellGrid() end
    if RefreshManualCompetition then RefreshManualCompetition() end
end

local function CursorItemLink()
    if not GetCursorInfo then return nil end
    local kind, id, link = GetCursorInfo()
    if kind ~= "item" then return nil end
    if link then return link end
    if id and GetItemInfo then return select(2, GetItemInfo(id)) end
end

local function SetManualItem(link)
    if not link then return end
    local bag, slot, count = FindBagItem(link)
    if not bag then Warn("Only unlocked items currently in your bags can be selected."); return end
    local name, _, _, _, _, itemType = GetItemInfo(link)
    if not IsMarketPriceEligible(link, itemType) then
        Warn("Only equipment with an exact required level of 60 can be auctioned.")
        return
    end
    local bound = Core.ScanTooltip(link, nil, { bag = bag, slot = slot })
    if not IsAuctionableBinding(bound) then Warn("That item cannot be auctioned."); return end
    local marketItem = FindMarketItem(EnsureDB(), link, itemType)
    local suggested, _, confidence = ReasonablePrice(marketItem)
    local entry = { bag = bag, slot = slot, count = count, numStacks = 1, available = count,
        link = link, itemID = ItemID(link),
        itemType = itemType, name = name or link, suggested = suggested, confidence = confidence }
    manual.awaitingLink, manual.lastLiveCheck = false, nil
    SetManualSelection(entry, true)
    if manual.warning then manual.warning:SetText("Selected. Check Live for an advisory comparison, or enter a price and post directly.") end
end

local function ClearManualItem()
    manual.awaitingLink, manual.lastLiveCheck, manual.activeKey, manual.entries = false, nil, nil, {}
    manual.liveRows, manual.marketSelection = {}, nil
    RefreshManualActive()
    if RefreshSellGrid then RefreshSellGrid() end
    if manual.warning then manual.warning:SetText("Select one unlocked bag item.") end
end

local function SetShoppingItem(link)
    if not link or not ItemID(link) then return end
    local name, _, _, _, _, itemType = GetItemInfo(link)
    if not IsMarketPriceEligible(link, itemType) then
        Warn("Only equipment with an exact required level of 60 can be bought.")
        return
    end
    shopping.awaitingLink = false
    shopping.active, shopping.activeKey, shopping.results, shopping.selectedResults, shopping.dismissedResults = nil, nil, {}, {}, {}
    shopping.pendingBuy = nil
    shopping.selectedLink, shopping.selectedItemID, shopping.selectedItemType = link, ItemID(link), itemType
    if shopping.itemSlot then
        shopping.itemSlot.icon:SetTexture((GetItemIcon and GetItemIcon(link)) or "Interface\\Icons\\INV_Misc_QuestionMark")
        shopping.itemSlot.count:SetText("")
    end
    if shopping.itemName then shopping.itemName:SetText(name or link) end
    if shopping.itemBox then shopping.itemBox:SetText(name or "") end
    RefreshShoppingResults()
end

local function ClearShoppingItem()
    shopping.awaitingLink, shopping.active, shopping.activeKey, shopping.results, shopping.selectedResults, shopping.dismissedResults = false, nil, nil, {}, {}, {}
    shopping.selectedLink, shopping.selectedItemID, shopping.selectedItemType = nil, nil, nil
    shopping.pendingBuy = nil
    if shopping.itemSlot then
        shopping.itemSlot.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        shopping.itemSlot.count:SetText("")
    end
    if shopping.itemName then shopping.itemName:SetText("No item selected") end
    if shopping.itemBox then shopping.itemBox:SetText("") end
    RefreshShoppingResults()
end

local function CaptureItemLink(link)
    if not link or not ItemID(link) then return end
    if manual.awaitingLink then SetManualItem(link); return true end
    if shopping.awaitingLink or (shopping.itemBox and shopping.itemBox.HasFocus and shopping.itemBox:HasFocus()) then
        SetShoppingItem(link)
        return true
    end
end

if hooksecurefunc and ChatEdit_InsertLink then
    hooksecurefunc("ChatEdit_InsertLink", function(link) CaptureItemLink(link) end)
end
-- Item links clicked in Auction House lists do not always enter ChatEdit on
-- older clients. This captures that path after the user armed a selector.
if hooksecurefunc and SetItemRef then
    hooksecurefunc("SetItemRef", function(link) CaptureItemLink(link) end)
end

local function RefreshManualPrice()
    if not manual.link or posting or scan or marketQuery then Warn("Select an item and wait for other Auction House work."); return end
    local checkedLink, checkedItemID = manual.link, manual.itemID
    local checkedName, checkedItemType = manual.name, manual.itemType
    BeginMarketQuery({ link = checkedLink, itemID = checkedItemID, name = checkedName,
        equipment = IsEquipment(checkedItemType), notice = "manual" }, function(reason, rows)
        if reason then Warn(reason); return end
        local live = { current = rows, history = {} }
        table.sort(live.current, function(a, b) return a.unit < b.unit end)
        UpdateCheckedMarketItem(checkedLink, checkedItemType, live.current)
        RefreshScanFooters()
        -- Always retain the database observation, but do not apply one item's
        -- completed query to a different selection if the user changed rows.
        if manual.link ~= checkedLink then return end
        manual.liveRows = live.current
        manual.marketSelection = manual.liveRows[1]
        if RefreshManualCompetition then RefreshManualCompetition() end
        local unit, _, confidence, why = ReasonablePrice(live)
        if unit then
            manual.lastLiveCheck = GetTime()
            local entry = manual.activeKey and manual.entries[manual.activeKey]
            if entry then entry.suggested, entry.manualPrice = unit, unit end
            manual.priceInput:SetValue(unit * (entry and entry.count or 1))
            manual.warning:SetText(confidence .. " live estimate applied. Manual prices are advisory-checked, not blocked.")
            if RefreshSellGrid then RefreshSellGrid() end
        else
            manual.lastLiveCheck = nil
            manual.warning:SetText("Live-market warning: " .. (why or "insufficient support") .. ". Manual posting is still allowed.")
        end
    end)
end

local function ApplyManualMarketPrice(undercut)
    local entry = manual.activeKey and manual.entries[manual.activeKey]
    local row = manual.marketSelection or (manual.liveRows and manual.liveRows[1])
    if not entry or not row or not row.unit then Warn("Check live competition and select a price first."); return end
    local unit = row.unit
    local matchingOwn = undercut and IsPlayerSeller(row.owner)
    if undercut and not matchingOwn then
        unit = UndercutUnitPrice(unit, UndercutPercent())
    end
    entry.manualPrice = unit
    if manual.warning then
        manual.warning:SetText((matchingOwn and "Your selected listing matched"
            or undercut and "Selected live price undercut" or "Selected live price matched")
            .. ": " .. Money(row.unit) .. " each -> " .. Money(unit) .. " each.")
    end
    RefreshManualActive()
    if RefreshSellGrid then RefreshSellGrid() end
end

local function StartManualPost()
    if posting or scan or marketQuery then Warn("Wait for current Auction House work to finish."); return end
    ScanSellInventory()
    queue = {}
    for _, entry in pairs(manual.entries) do
        local link = GetContainerItemLink(entry.bag, entry.slot)
        local _, available, locked = GetContainerItemInfo(entry.bag, entry.slot)
        local stackSize = math.min(entry.count, tonumber(available) or 0)
        local numStacks = math.max(1, math.min(tonumber(entry.numStacks) or 1,
            math.floor((tonumber(available) or 0) / math.max(1, stackSize))))
        local count = stackSize * numStacks
        local price = math.max(1, math.floor(tonumber(entry.manualPrice) or tonumber(entry.suggested) or 0))
        if link == entry.link and not locked and count > 0 and price > 0 then
            queue[#queue + 1] = { bag = entry.bag, slot = entry.slot, link = entry.link, itemID = entry.itemID,
                itemType = entry.itemType, name = entry.name, count = count,
                stackSize = stackSize, numStacks = numStacks, unitPrice = price,
                manualPrice = price, duration = tonumber(manual.duration) or Setting("duration", 2) }
        end
    end
    table.sort(queue, function(a, b) return a.name < b.name end)
    if #queue == 0 then Warn("Select an auctionable bag item with a reviewed price before posting."); return end
    -- Each item receives its own fresh market query in PostNext before the AH
    -- API is called, so review prices cannot become stale during a bulk post.
    posting = { waiting = false, nextAt = GetTime(), posted = 0, skipped = 0, livePrices = {} }
    UpdateWorkerState(); RefreshWindow()
end

local function CopperCeiling(base, percent)
    base, percent = math.max(0, math.floor(tonumber(base) or 0)), math.max(0, tonumber(percent) or 0)
    local result = math.floor(base * (1 + percent / 100))
    if percent > 0 and result <= base then result = base + 1 end
    return result
end
Auction.CopperCeiling = CopperCeiling

local function ShoppingThreshold(entry)
    local maximum = tonumber(entry.maximum) or 0
    if entry.broad then return maximum > 0 and maximum or nil end
    local reference = tonumber(entry.referencePrice) or 0
    local percent = math.max(0, tonumber(entry.percent) or 0)
    local percentCeiling = reference > 0 and CopperCeiling(reference, percent) or nil
    -- Either limit may be used alone; when both are set, neither can be
    -- exceeded. Limits are per item, so stack sizes remain comparable.
    if maximum > 0 and percentCeiling then return math.min(maximum, percentCeiling) end
    if maximum > 0 then return maximum end
    return percentCeiling
end

local function ShoppingRowKey(row)
    return row and table.concat({ tostring(row.page), tostring(row.index), tostring(row.buyout), tostring(row.count), tostring(row.link) }, ":")
end

RefreshShoppingResults = function()
    if not shopping.resultText then return end
    local entry = shopping.active
    if not entry then shopping.resultText:SetText("No shopping item selected.") else
        local eligible, selected = 0, 0
        for _, row in ipairs(shopping.results) do
            if row.eligible and not (shopping.dismissedResults and shopping.dismissedResults[ShoppingRowKey(row)]) then eligible = eligible + 1 end
        end
        for _ in pairs(shopping.selectedResults or {}) do selected = selected + 1 end
        local reference = entry.referencePrice and Money(entry.referencePrice) .. " each" or "not set"
        shopping.resultText:SetText("Reference: " .. reference .. " | ceiling: " .. (ShoppingThreshold(entry) and Money(ShoppingThreshold(entry)) .. " each" or "none")
            .. " | " .. eligible .. " eligible | " .. selected .. " selected")
    end
    local selectedCount = 0
    for _ in pairs(shopping.selectedResults or {}) do selectedCount = selectedCount + 1 end
    if shopping.buyButton then
        if shopping.pendingBuy then
            shopping.buyButton:SetText("Buy " .. Money(shopping.pendingBuy.buyout))
        else
            shopping.buyButton:SetText(selectedCount > 0 and "Buy Selected" or "Buy Cheapest")
        end
    end
    shopping.eligibleResults = {}
    for _, row in ipairs(shopping.results) do
        if row.eligible and not (shopping.dismissedResults and shopping.dismissedResults[ShoppingRowKey(row)]) then
            table.insert(shopping.eligibleResults, row)
        end
    end
    local offset = shopping.resultScroll and FauxScrollFrame_GetOffset(shopping.resultScroll) or 0
    for index, button in ipairs(shopping.resultRows or {}) do
        local row = shopping.eligibleResults[offset + index]
        button.row = row
        if row then
            local selected = shopping.selectedResults and shopping.selectedResults[ShoppingRowKey(row)]
            button.forceSelected = selected and true or false
            button:SetBackdropBorderColor(selected and BRAND[1] or BORDER[1], selected and BRAND[2] or BORDER[2], selected and BRAND[3] or BORDER[3], 1)
            button.item:SetText(row.link)
            button.unit:SetText(TooltipMoney(row.unit))
            button.quantity:SetText("x" .. row.count)
            button.total:SetText(TooltipMoney(row.buyout))
            button:Show()
        else button.row = nil; button.forceSelected = false; button:Hide() end
    end
    if shopping.resultScroll then
        FauxScrollFrame_Update(shopping.resultScroll, #shopping.eligibleResults, #shopping.resultRows, 21)
        if shopping.scrollThumb and shopping.scrollTrack then
            local rows, visible = #shopping.eligibleResults, #shopping.resultRows
            local maximum = math.max(0, rows - visible)
            local ratio = rows > 0 and math.min(1, visible / rows) or 1
            local travel = 107
            local height = math.max(18, math.floor(travel * ratio))
            local position = maximum > 0 and math.floor((FauxScrollFrame_GetOffset(shopping.resultScroll) / maximum) * (travel - height)) or 0
            shopping.scrollThumb:ClearAllPoints()
            shopping.scrollThumb:SetPoint("TOP", shopping.scrollTrack, "TOP", 0, -20 - position)
            shopping.scrollThumb:SetSize(12, height)
            shopping.scrollThumb:SetShown(rows > visible)
        end
    end
end

local function SavedShoppingKeys()
    local keys = {}
    for key, entry in pairs(EnsureDB().shopping) do
        if type(entry) == "table" and (entry.itemID or entry.name) then table.insert(keys, key) end
    end
    table.sort(keys, function(a, b)
        local left, right = EnsureDB().shopping[a], EnsureDB().shopping[b]
        return tostring(left.name or a) < tostring(right.name or b)
    end)
    return keys
end

local function LoadSavedShoppingEntry(key)
    local keys = SavedShoppingKeys()
    if #keys == 0 then
        shopping.active, shopping.activeKey = nil, nil
        shopping.pendingBuy = nil
        if shopping.savedButton then shopping.savedButton:SetText("Saved: none") end
        RefreshShoppingResults()
        return
    end
    key = key or keys[1]
    local entry = EnsureDB().shopping[key]
    if type(entry) ~= "table" or (not entry.itemID and not entry.name) then return end
    shopping.active, shopping.activeKey, shopping.mode = entry, key, entry.mode or "percent"
    shopping.pendingBuy = nil
    shopping.selectedLink, shopping.selectedItemID, shopping.selectedItemType = entry.link, entry.itemID, entry.itemType
    if shopping.itemSlot then
        shopping.itemSlot.icon:SetTexture((GetItemIcon and GetItemIcon(entry.link)) or "Interface\\Icons\\INV_Misc_QuestionMark")
        shopping.itemSlot.count:SetText("")
    end
    if shopping.itemName then shopping.itemName:SetText(entry.name or key) end
    if shopping.itemBox then shopping.itemBox:SetText(entry.name or "") end
    shopping.maxInput:SetValue(entry.maximum or 0)
    shopping.percentBox:SetText(tostring(entry.percent or Setting("shoppingDefaultPercent", 10)))
    if shopping.modeButton then shopping.modeButton:SetText(shopping.mode == "percent" and "Guard: Lowest + %" or "Guard: Max only") end
    if shopping.savedButton then shopping.savedButton:SetText("Saved: " .. tostring(entry.name or key)) end
    RefreshShoppingResults()
end

local function CycleSavedShopping()
    local keys = SavedShoppingKeys()
    if #keys == 0 then LoadSavedShoppingEntry(); return end
    local selected = 0
    for index, key in ipairs(keys) do if key == shopping.activeKey then selected = index; break end end
    LoadSavedShoppingEntry(keys[selected % #keys + 1])
end

local function ShowSavedShoppingMenu(button)
    local keys = SavedShoppingKeys()
    if not EasyMenu then CycleSavedShopping(); return end
    local menu = { { text = "Saved Searches", isTitle = true, notCheckable = true } }
    if #keys == 0 then
        menu[#menu + 1] = { text = "No saved searches", disabled = true, notCheckable = true }
    else
        for _, key in ipairs(keys) do
            local entry = EnsureDB().shopping[key]
            local selectedKey = key
            menu[#menu + 1] = { text = tostring(entry.name or key),
                checked = key == shopping.activeKey,
                func = function() LoadSavedShoppingEntry(selectedKey) end }
        end
    end
    shopping.savedMenu = shopping.savedMenu or CreateFrame("Frame",
        "AutoEverythingAuctionSavedSearchMenu", UIParent, "UIDropDownMenuTemplate")
    EasyMenu(menu, shopping.savedMenu, button, 0, 0, "MENU")
end

local function DeleteSavedShoppingEntry()
    if not shopping.activeKey then Warn("No saved shopping entry is selected."); return end
    EnsureDB().shopping[shopping.activeKey] = nil
    shopping.results = {}
    LoadSavedShoppingEntry()
    Info("Removed saved shopping entry.")
end

local function SaveShoppingEntry()
    local text = shopping.itemBox and shopping.itemBox:GetText() or ""
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    local selectedLink = shopping.selectedLink
    if selectedLink and text ~= "" then
        local selectedName = GetItemInfo and GetItemInfo(selectedLink)
        if selectedName and string.lower(text) ~= string.lower(selectedName) and not text:find("|Hitem:") then
            selectedLink = nil
        end
    end
    local link = selectedLink or (text and (text:match("(|c%x+|Hitem:[^|]+|h%[[^%]]+%]|h|r)") or text:match("(|Hitem:[^|]+|h%[[^%]]+%]|h)")))
    local typedItemID = tonumber(text:match("^item:(%-?%d+)$") or text:match("^(%-?%d+)$"))
    if not link and typedItemID and GetItemInfo then link = select(2, GetItemInfo(typedItemID)) end
    if not link and text and text ~= "" and not typedItemID and GetItemInfo then link = select(2, GetItemInfo(text)) end
    if not link and typedItemID then
        local market = EnsureDB()
        local cached = market.items[tostring(typedItemID)]
        if not cached then
            for _, item in pairs(market.items) do
                if tonumber(item.itemID) == typedItemID then cached = item; break end
            end
        end
        link = cached and cached.link
    end
    local itemID = (selectedLink and shopping.selectedItemID) or ItemID(link or text) or typedItemID
    local name, itemType
    if link and GetItemInfo then
        local resolvedName, _, _, _, _, resolvedType = GetItemInfo(link)
        name, itemType = resolvedName, resolvedType
    end
    if typedItemID and not name then
        Warn("Item ID " .. typedItemID .. " is not cached yet. Run a market scan, then search again.")
        return
    end
    if not itemID and text == "" then Warn("Enter an item name to search for."); return end
    local previous = shopping.active
    local entry = { link = link, itemID = itemID, name = name or text,
        broad = not itemID,
        itemType = itemType or (selectedLink and shopping.selectedItemType), maximum = shopping.maxInput:GetValue(),
        percent = tonumber(shopping.percentBox:GetText()) or 0 }
    if not IsMarketPriceEligible(entry.link, entry.itemType) then
        Warn("Only equipment with an exact required level of 60 can be bought.")
        return
    end
    if itemID and previous and previous.itemID == itemID then entry.referencePrice = previous.referencePrice end
    shopping.active, shopping.activeKey = entry, itemID and tostring(itemID) or string.lower(entry.name)
    return entry
end

local function PersistShoppingEntry()
    local entry = SaveShoppingEntry()
    if not entry then return end
    EnsureDB().shopping[shopping.activeKey] = entry
    if shopping.savedButton then shopping.savedButton:SetText("Saved: " .. tostring(entry.name)) end
    Info("Saved shopping search for " .. tostring(entry.name) .. ".")
end

local function ScanShopping(updateReference)
    local entry = SaveShoppingEntry()
    if not entry then return end
    if not IsMarketPriceEligible(entry.link, entry.itemType) then
        Warn("Only equipment with an exact required level of 60 can be bought.")
        return
    end
    if scan or posting or marketQuery then return end
    shopping.pendingBuy = nil
    BeginMarketQuery({ link = entry.link, itemID = entry.itemID, name = entry.name,
        equipment = IsEquipment(entry.itemType), broad = entry.broad, notice = "shopping" }, function(reason, rows)
        if reason then Warn(reason); return end
        shopping.dismissedResults = {}
        shopping.submittedRows = {}
        if not entry.broad and entry.link then
            UpdateCheckedMarketItem(entry.link, entry.itemType, rows)
            RefreshScanFooters()
        end
        shopping.results = rows
        -- Shopping order, reference, and Buy Cheapest all use unit price;
        -- a larger stack must not outrank a cheaper item merely by total cost.
        table.sort(shopping.results, function(a, b)
            if a.unit ~= b.unit then return a.unit < b.unit end
            if a.buyout ~= b.buyout then return a.buyout < b.buyout end
            if a.page ~= b.page then return a.page < b.page end
            return a.index < b.index
        end)
        local retained = {}
        for _, row in ipairs(shopping.results) do
            local key = ShoppingRowKey(row)
            if shopping.selectedResults and shopping.selectedResults[key] then retained[key] = true end
        end
        shopping.selectedResults = retained
        if not entry.broad and (updateReference or not entry.referencePrice) then
            entry.referencePrice = shopping.results[1] and shopping.results[1].unit
        end
        local ceiling = ShoppingThreshold(entry)
        for _, row in ipairs(shopping.results) do
            row.eligible = row.buyout > 0 and (not ceiling or row.unit <= ceiling)
        end
        RefreshShoppingResults()
    end)
end

local ConfirmShoppingBuyout

local function FindLiveShoppingRow(wanted)
    if not wanted or shopping.loadedPage ~= wanted.page or not GetNumAuctionItems then return nil end
    local num = GetNumAuctionItems("list")
    num = tonumber(num) or 0
    for index = 1, num do
        local name, _, count, _, _, _, _, _, buyout, _, _, owner, sold = GetAuctionItemInfo("list", index)
        local link = GetAuctionItemLink("list", index)
        count, buyout = tonumber(count) or 0, tonumber(buyout) or 0
        local submitted = shopping.submittedRows and shopping.submittedRows[wanted.page]
        if not IsSoldAuction(sold) and not (submitted and submitted[index])
            and name and link == wanted.link and count == wanted.count and buyout == wanted.buyout
            and (not wanted.owner or owner == wanted.owner)
        then
            return { page = wanted.page, index = index, buyout = buyout, count = count,
                link = link, owner = owner, unit = math.max(1, math.floor(buyout / count)) }
        end
    end
end

local function DismissShoppingRow(row, key)
    key = key or ShoppingRowKey(row)
    shopping.pendingBuy = nil
    shopping.selectedResults = shopping.selectedResults or {}
    shopping.selectedResults[key] = nil
    shopping.dismissedResults = shopping.dismissedResults or {}
    shopping.dismissedResults[key] = true
end

local function PrepareShoppingRow(wanted, key, mayBuy, selected)
    local live = FindLiveShoppingRow(wanted)
    if not live then return false end
    live.key = key
    shopping.pendingBuy = live
    if SetSelectedAuctionItem then SetSelectedAuctionItem("list", live.index) end
    RefreshShoppingResults()
    if mayBuy then
        ConfirmShoppingBuyout()
    else
        Info((selected and "Selected" or "Cheapest") .. " listing is ready at "
            .. Money(live.unit) .. " each (" .. Money(live.buyout) .. " total). Click Buy again.")
    end
    return true
end

local function LoadShoppingPage(wanted, key, selected)
    return BeginMarketQuery({ link = wanted.link, itemID = ItemID(wanted.link),
        name = shopping.active and shopping.active.name,
        equipment = shopping.active and IsEquipment(shopping.active.itemType),
        page = wanted.page, singlePage = true, notice = "shopping" }, function(reason)
        if reason then Warn(reason); return end
        if not PrepareShoppingRow(wanted, key, false, selected) then
            DismissShoppingRow(wanted, key)
            RefreshShoppingResults()
            Warn("That listing is gone and was removed from the scanned results.")
        end
    end)
end

local function BuyNextShopping(mayBuy)
    local entry = shopping.active
    if not entry or marketQuery or scan or posting then return end
    if not IsMarketPriceEligible(entry.link, entry.itemType) then
        Warn("Only equipment with an exact required level of 60 can be bought.")
        return
    end
    for _, row in ipairs(shopping.results or {}) do
        local key = ShoppingRowKey(row)
        if row.eligible and not (shopping.dismissedResults and shopping.dismissedResults[key]) then
            if shopping.loadedPage ~= row.page then LoadShoppingPage(row, key, false); return end
            if PrepareShoppingRow(row, key, mayBuy, false) then return end
            DismissShoppingRow(row, key)
        end
    end
    RefreshShoppingResults()
    Warn("No scanned listing fits this item's price limits. Click Rescan to refresh the market.")
end

local function BuySelectedShopping(mayBuy)
    if marketQuery or scan or posting then Warn("Wait for current Auction House work to finish."); return end
    for _, row in ipairs(shopping.results or {}) do
        local rowKey = ShoppingRowKey(row)
        if shopping.selectedResults and shopping.selectedResults[rowKey] then
            if shopping.loadedPage ~= row.page then LoadShoppingPage(row, rowKey, true); return end
            if PrepareShoppingRow(row, rowKey, mayBuy, true) then return end
            DismissShoppingRow(row, rowKey)
        end
    end
    RefreshShoppingResults()
    Warn("No selected scanned listings remain.")
end

ConfirmShoppingBuyout = function()
    local pending = shopping.pendingBuy
    if not pending then return end
    if scan or posting or marketQuery then Warn("Wait for current Auction House work to finish."); return end
    local name, _, count, _, _, _, _, _, buyout, _, _, _, sold = GetAuctionItemInfo("list", pending.index)
    local link = GetAuctionItemLink("list", pending.index)
    count, buyout = tonumber(count) or 0, tonumber(buyout) or 0
    if IsSoldAuction(sold) or not name or link ~= pending.link or count ~= pending.count or buyout ~= pending.buyout then
        shopping.pendingBuy = nil
        DismissShoppingRow(pending, pending.key)
        RefreshShoppingResults()
        Warn("That listing is gone and was removed from the scanned results.")
        return
    end
    local itemType = GetItemInfo and select(6, GetItemInfo(link))
    if not IsMarketPriceEligible(link, itemType) then
        shopping.pendingBuy = nil
        DismissShoppingRow(pending, pending.key)
        RefreshShoppingResults()
        Warn("Only equipment with an exact required level of 60 can be bought.")
        return
    end
    local ceiling = shopping.active and ShoppingThreshold(shopping.active)
    local unit = count > 0 and math.max(1, math.floor(buyout / count)) or 0
    if buyout <= 0 or (ceiling and unit > ceiling) then
        shopping.pendingBuy = nil
        RefreshShoppingResults()
        Warn("That listing no longer fits the saved price limits.")
        return
    end
    local spendCap = math.max(0, tonumber(Setting("shoppingMaxSpend", 100000)) or 0)
    if spendCap > 0 and shopping.sessionSpent + buyout > spendCap then
        Warn("This purchase would exceed the Auction House session spend cap ("
            .. Money(spendCap) .. ").")
        return
    end
    if GetMoney and buyout > GetMoney() then Warn("You do not have enough money for that buyout."); return end
    if not PlaceAuctionBid or not SetSelectedAuctionItem then
        Warn("The Auction House buyout API is unavailable.")
        return
    end
    SetSelectedAuctionItem("list", pending.index)
    PlaceAuctionBid("list", pending.index, buyout)
    shopping.submittedRows = shopping.submittedRows or {}
    shopping.submittedRows[pending.page] = shopping.submittedRows[pending.page] or {}
    shopping.submittedRows[pending.page][pending.index] = true
    shopping.sessionSpent = shopping.sessionSpent + buyout
    shopping.selectedResults[pending.key] = nil
    shopping.dismissedResults = shopping.dismissedResults or {}
    shopping.dismissedResults[pending.key] = true
    shopping.pendingBuy = nil
    Info("Buyout submitted for " .. Money(buyout) .. ". Session spend: "
        .. Money(shopping.sessionSpent) .. ".")
    RefreshShoppingResults()
end

local function OwnedTimeText(value)
    value = tonumber(value)
    if not value then return "Unknown" end
    if value <= 4 then return ({ "< 30m", "30m-2h", "2h-12h", "> 12h" })[value] or "Unknown" end
    if value < 3600 then return math.max(1, math.floor(value / 60)) .. "m" end
    return math.floor(value / 3600) .. "h"
end

RefreshOwnedAuctions = function()
    if not owned.rows then return end
    local num = 0
    if GetNumAuctionItems then
        local ownedCount = GetNumAuctionItems("owner")
        num = tonumber(ownedCount) or 0
    end
    owned.results = {}
    for index = 1, num do
        local name, _, count, _, _, _, minBid, _, buyout, bidAmount, highestBidder, _, sold =
            GetAuctionItemInfo("owner", index)
        local link = GetAuctionItemLink("owner", index)
        count, buyout = tonumber(count) or 0, tonumber(buyout) or 0
        owned.results[#owned.results + 1] = { index = index, name = name, link = link,
            count = count, buyout = buyout, unit = count > 0 and math.floor(buyout / count) or 0,
            minBid = tonumber(minBid) or 0, bidAmount = tonumber(bidAmount) or 0,
            highestBidder = highestBidder, sold = sold,
            timeLeft = GetAuctionItemTimeLeft and GetAuctionItemTimeLeft("owner", index) }
    end
    table.sort(owned.results, function(a, b)
        if a.name == b.name then return a.unit < b.unit end
        return tostring(a.name) < tostring(b.name)
    end)
    local selectedStillExists
    for _, row in ipairs(owned.results) do
        if owned.selected and row.index == owned.selected.index and row.link == owned.selected.link
            and row.buyout == owned.selected.buyout then selectedStillExists = row end
    end
    owned.selected = selectedStillExists
    local offset = owned.scroll and FauxScrollFrame_GetOffset(owned.scroll) or 0
    for displayIndex, button in ipairs(owned.rows) do
        local row = owned.results[offset + displayIndex]
        button.row = row
        if row then
            local selected = owned.selected == row
            button.forceSelected = selected
            if button.RefreshAuctionStyle then button:RefreshAuctionStyle() end
            button.item:SetText(row.link or row.name or "Unknown item")
            button.quantity:SetText("x" .. row.count)
            button.unit:SetText(row.unit > 0 and TooltipMoney(row.unit) or "Bid only")
            button.total:SetText(row.buyout > 0 and TooltipMoney(row.buyout) or TooltipMoney(row.minBid))
            button.time:SetText(OwnedTimeText(row.timeLeft))
            button:Show()
        else
            button.row, button.forceSelected = nil, false
            button:Hide()
        end
    end
    if owned.scroll then FauxScrollFrame_Update(owned.scroll, #owned.results, #owned.rows, 24) end
    if owned.summary then
        local total = 0
        for _, row in ipairs(owned.results) do total = total + row.buyout end
        owned.summary:SetText(#owned.results .. " active auctions | " .. Money(total) .. " total buyout value")
    end
    if owned.cancelButton then owned.cancelButton:SetText("Cancel Auction") end
end

local function RequestOwnedAuctions()
    if not AuctionFrame or not AuctionFrame:IsShown() then Warn("Open the Auction House first."); return end
    if GetOwnerAuctionItems then GetOwnerAuctionItems() else Warn("The owned-auction API is unavailable.") end
end

local function CancelSelectedAuction()
    local selected = owned.selected
    if not selected then Warn("Select one of your active auctions first."); return end
    local name, _, count, _, _, _, _, _, buyout = GetAuctionItemInfo("owner", selected.index)
    local link = GetAuctionItemLink("owner", selected.index)
    if not name or link ~= selected.link or tonumber(count) ~= selected.count
        or tonumber(buyout) ~= selected.buyout then
        owned.selected = nil
        RefreshOwnedAuctions()
        Warn("That auction changed. Refresh and select it again.")
        return
    end
    if SetSelectedAuctionItem then SetSelectedAuctionItem("owner", selected.index) end
    if CanCancelAuction and not CanCancelAuction(selected.index) then Warn("That auction cannot be cancelled."); return end
    if not CancelAuction then Warn("The auction cancellation API is unavailable."); return end
    local ok, result = pcall(CancelAuction, selected.index)
    if not ok or result == false then
        Warn("The Auction House rejected that cancellation.")
        return
    end
    owned.selected = nil
    Info("Cancellation submitted for " .. (selected.link or selected.name or "auction") .. ".")
end

local function AddScanFooter(page)
    local footer = page:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    footer:SetPoint("BOTTOMRIGHT", -4, 4); footer:SetWidth(560); footer:SetJustifyH("RIGHT")
    footer:SetTextColor(0.55, 0.58, 0.62)
    table.insert(scanFooters, footer)
    return footer
end

local function UpgradeSlotText(equipSlot)
    if equipSlot and _G[equipSlot] then return _G[equipSlot] end
    local text = tostring(equipSlot or "Unknown")
    return text:gsub("^INVTYPE_", ""):gsub("_", " "):lower():gsub("^%l", string.upper)
end

RefreshUpgradeResults = function()
    if not upgrades.rows then return end
    upgrades.filtered = {}
    for _, row in ipairs(upgrades.results or {}) do
        if (not upgrades.typeFilter or row.itemType == upgrades.typeFilter)
            and (not upgrades.subTypeFilter or row.subType == upgrades.subTypeFilter)
            and (not upgrades.slotFilter or row.equipSlot == upgrades.slotFilter)
        then upgrades.filtered[#upgrades.filtered + 1] = row end
    end
    local offset = upgrades.scroll and FauxScrollFrame_GetOffset(upgrades.scroll) or 0
    for index, button in ipairs(upgrades.rows) do
        local row = upgrades.filtered[offset + index]
        button.row = row
        if row then
            button.item:SetText(row.link or row.name)
            button.gain:SetText(row.percent and string.format("+%.1f%%", row.percent)
                or string.format("+%.1f empty", row.gain))
            button.subType:SetText(row.subType or row.itemType or "-")
            button.slot:SetText(UpgradeSlotText(row.equipSlot))
            button.price:SetText(row.unit and TooltipMoney(row.unit) or "-")
            button:Show()
        else button.row = nil; button:Hide() end
    end
    if upgrades.scroll then FauxScrollFrame_Update(upgrades.scroll, #upgrades.filtered, #upgrades.rows, 24) end
    if upgrades.summary and not upgradeAnalysis then
        upgrades.summary:SetText(#upgrades.filtered .. " shown | " .. #(upgrades.results or {})
            .. " upgrades found | highest upgrade first")
    end
    if upgrades.typeButton then upgrades.typeButton:SetText("Type: " .. (upgrades.typeFilter or "All")) end
    if upgrades.subTypeButton then upgrades.subTypeButton:SetText("Subtype: " .. (upgrades.subTypeFilter or "All")) end
    if upgrades.slotButton then upgrades.slotButton:SetText("Slot: " .. (upgrades.slotFilter and UpgradeSlotText(upgrades.slotFilter) or "All")) end
end

local function FinishUpgradeAnalysis()
    if not upgradeAnalysis then return end
    upgrades.results = upgradeAnalysis.results
    table.sort(upgrades.results, function(a, b)
        if a.rank ~= b.rank then return a.rank > b.rank end
        if a.gain ~= b.gain then return a.gain > b.gain end
        return tostring(a.name) < tostring(b.name)
    end)
    upgradeAnalysis = nil
    UpdateWorkerState()
    RefreshUpgradeResults()
end

ProcessUpgradeAnalysis = function()
    if not upgradeAnalysis then return end
    local work = upgradeAnalysis
    local started = debugprofilestop and debugprofilestop() or 0
    local processed = 0
    while work.index <= #work.items and processed < 12 do
        local item = work.items[work.index]
        work.index, processed = work.index + 1, processed + 1
        local score = 0
        for statName, value in pairs(item.stats or {}) do
            score = score + (tonumber(value) or 0) * (tonumber(work.weights[statName]) or 0)
        end
        local ok, isUpgrade, newScore, equippedScore, targetSlot = pcall(
            AutoUpgrade.EvaluateItem, item.link, nil, { itemScore = score })
        if ok and isUpgrade then
            newScore, equippedScore = tonumber(newScore) or score, tonumber(equippedScore) or 0
            local gain = newScore - equippedScore
            local percent = equippedScore > 0 and gain / equippedScore * 100 or nil
            work.results[#work.results + 1] = {
                name = item.name or item.link, link = item.link, itemType = item.itemType,
                subType = item.subType, equipSlot = item.equipSlot, targetSlot = targetSlot,
                score = newScore, equippedScore = equippedScore, gain = gain, percent = percent,
                rank = percent or (100000 + gain), unit = item.current and item.current[1] and item.current[1].unit,
            }
        end
        if debugprofilestop and processed >= 2 and debugprofilestop() - started >= 2.5 then break end
    end
    if upgrades.summary then
        upgrades.summary:SetText("Analyzing saved gear " .. math.min(work.index - 1, #work.items)
            .. "/" .. #work.items .. "...")
    end
    if work.index > #work.items then FinishUpgradeAnalysis() end
end

StartUpgradeAnalysis = function()
    if upgradeAnalysis then return end
    if scan or posting or marketQuery then Warn("Wait for current Auction House work to finish."); return end
    if not AutoUpgrade or not AutoUpgrade.EvaluateItem then
        upgrades.results = {}
        RefreshUpgradeResults()
        if upgrades.summary then upgrades.summary:SetText("Upgrade evaluation is unavailable.") end
        return
    end
    local weights = UpgradeStatWeights()
    if not Core.HasStatWeights or not Core.HasStatWeights(weights) then
        upgrades.results = {}
        RefreshUpgradeResults()
        if upgrades.summary then upgrades.summary:SetText("Configure upgrade stat weights to find upgrades.") end
        return
    end
    local items = {}
    for _, item in pairs(EnsureDB().items or {}) do
        local requiredLevel = tonumber(item.requiredLevel)
        if IsEquipment(item.itemType) and requiredLevel == 60
            and type(item.stats) == "table" and next(item.stats)
            and item.current and item.current[1]
            and (not upgrades.typeFilter or item.itemType == upgrades.typeFilter)
            and (not upgrades.subTypeFilter or item.subType == upgrades.subTypeFilter)
            and (not upgrades.slotFilter or item.equipSlot == upgrades.slotFilter)
        then items[#items + 1] = item end
    end
    upgrades.results = {}
    upgradeAnalysis = { items = items, index = 1, results = {}, weights = weights }
    RefreshUpgradeResults()
    if upgrades.summary then upgrades.summary:SetText("Analyzing saved gear 0/" .. #items .. "...") end
    UpdateWorkerState()
    if #items == 0 then FinishUpgradeAnalysis() end
end

local UPGRADE_EQUIP_SLOTS = {
    "INVTYPE_HEAD", "INVTYPE_NECK", "INVTYPE_SHOULDER", "INVTYPE_BODY", "INVTYPE_CHEST",
    "INVTYPE_ROBE", "INVTYPE_WAIST", "INVTYPE_LEGS", "INVTYPE_FEET", "INVTYPE_WRIST",
    "INVTYPE_HAND", "INVTYPE_FINGER", "INVTYPE_TRINKET", "INVTYPE_CLOAK", "INVTYPE_WEAPON",
    "INVTYPE_WEAPONMAINHAND", "INVTYPE_WEAPONOFFHAND", "INVTYPE_2HWEAPON", "INVTYPE_SHIELD",
    "INVTYPE_HOLDABLE", "INVTYPE_RANGED", "INVTYPE_RANGEDRIGHT", "INVTYPE_THROWN", "INVTYPE_RELIC",
}

local FALLBACK_UPGRADE_SUBTYPES = {
    [ARMOR or "Armor"] = { "Miscellaneous", "Cloth", "Leather", "Mail", "Plate", "Shields",
        "Librams", "Idols", "Totems", "Sigils" },
    [WEAPON or "Weapon"] = { "One-Handed Axes", "Two-Handed Axes", "Bows", "Guns",
        "One-Handed Maces", "Two-Handed Maces", "Polearms", "One-Handed Swords", "Two-Handed Swords",
        "Staves", "Fist Weapons", "Miscellaneous", "Daggers", "Thrown", "Crossbows", "Wands",
        "Fishing Poles" },
}

local function UpgradeFilterValues(kind)
    local values, seen = {}, {}
    local function Add(value)
        if type(value) == "string" and value ~= "" and not seen[value] then
            seen[value] = true
            values[#values + 1] = value
        end
    end
    if kind == "slot" then
        for _, value in ipairs(UPGRADE_EQUIP_SLOTS) do Add(value) end
    elseif kind == "subType" then
        if GetAuctionItemClasses and GetAuctionItemSubClasses then
            local classes = { pcall(GetAuctionItemClasses) }
            if classes[1] then
                table.remove(classes, 1)
                for classIndex, itemType in ipairs(classes) do
                    if IsEquipment(itemType) and (not upgrades.typeFilter or itemType == upgrades.typeFilter) then
                        local subtypes = { pcall(GetAuctionItemSubClasses, classIndex) }
                        if subtypes[1] then
                            table.remove(subtypes, 1)
                            for _, value in ipairs(subtypes) do Add(value) end
                        end
                    end
                end
            end
        end
        for itemType, subtypes in pairs(FALLBACK_UPGRADE_SUBTYPES) do
            if not upgrades.typeFilter or itemType == upgrades.typeFilter then
                for _, value in ipairs(subtypes) do Add(value) end
            end
        end
    end
    -- Preserve custom Ascension categories and slots already observed in the
    -- saved market, even if the live classification API omits them.
    for _, item in pairs(EnsureDB().items or {}) do
        if IsEquipment(item.itemType) and (not upgrades.typeFilter or item.itemType == upgrades.typeFilter) then
            Add(kind == "slot" and item.equipSlot or item.subType)
        end
    end
    table.sort(values, function(a, b)
        local left = kind == "slot" and UpgradeSlotText(a) or tostring(a)
        local right = kind == "slot" and UpgradeSlotText(b) or tostring(b)
        return left < right
    end)
    return values
end

local function ShowUpgradeFilterMenu(button, kind)
    if not EasyMenu then return end
    local values = {}
    if kind == "type" then
        values = { ARMOR or "Armor", WEAPON or "Weapon" }
    else values = UpgradeFilterValues(kind) end
    local menu = { { text = kind == "type" and "Item Type" or (kind == "subType" and "Armor / Weapon Type" or "Equipment Slot"),
        isTitle = true, notCheckable = true } }
    local function Select(value)
        if kind == "type" then
            upgrades.typeFilter, upgrades.subTypeFilter, upgrades.slotFilter = value, nil, nil
        elseif kind == "subType" then upgrades.subTypeFilter = value
        else upgrades.slotFilter = value end
        if upgrades.scroll then upgrades.scroll:SetVerticalScroll(0) end
        if upgradeAnalysis then upgradeAnalysis = nil; UpdateWorkerState() end
        StartUpgradeAnalysis()
    end
    menu[#menu + 1] = { text = "All", notCheckable = true, func = function() Select(nil) end }
    for _, value in ipairs(values) do
        local selectedValue = value
        menu[#menu + 1] = { text = kind == "slot" and UpgradeSlotText(value) or tostring(value),
            notCheckable = true, func = function() Select(selectedValue) end }
    end
    upgrades.filterMenu = upgrades.filterMenu or CreateFrame("Frame", "AutoEverythingAuctionUpgradeFilterMenu",
        UIParent, "UIDropDownMenuTemplate")
    EasyMenu(menu, upgrades.filterMenu, button, 0, 0, "MENU")
end

local function ShowAuctionPage(name)
    currentPage = pageFrames[name] and name or "sell"
    for key, frame in pairs(pageFrames) do if key == currentPage then frame:Show() else frame:Hide() end end
    for key, button in pairs(pageButtons) do
        button.forceHovered, button.forceActive = key == currentPage, key == currentPage
        if button.RefreshAuctionStyle then button:RefreshAuctionStyle() end
    end
    if currentPage == "owned" then RequestOwnedAuctions() end
    if currentPage == "upgrades" then StartUpgradeAnalysis() end
end

RefreshSellGrid = function()
    if not manual.rows then return end
    ScanSellInventory()
    if manual.scrollFrame then
        FauxScrollFrame_Update(manual.scrollFrame, #manual.inventory, #manual.rows, 27)
    end
    local offset = manual.scrollFrame and FauxScrollFrame_GetOffset(manual.scrollFrame) or 0
    for index, row in ipairs(manual.rows) do
        local entry = manual.inventory[offset + index]
        row.entry = entry
        if entry then
            row.icon:SetTexture((GetItemIcon and GetItemIcon(entry.link)) or "Interface\\Icons\\INV_Misc_QuestionMark")
            row.name:SetText(entry.link or entry.name)
            row.available:SetText(tostring(entry.available or 0))
            row.market:SetText(entry.suggested and TooltipMoney(entry.suggested)
                or (entry.confidence == "Suspicious" and "Review" or "No price"))
            local quantity = entry.selected and entry.count * (entry.numStacks or 1) or 0
            local total = quantity * math.max(0, tonumber(entry.manualPrice) or tonumber(entry.suggested) or 0)
            row.value:SetText(total > 0 and TooltipMoney(total) or "-")
            local active = manual.activeKey == ManualKey(entry.bag, entry.slot)
            row.forceSelected = active
            if row.RefreshAuctionStyle then row:RefreshAuctionStyle() end
            row:Show()
        else
            row.entry, row.forceSelected = nil, false
            row:Hide()
        end
    end
    local selected, value, totalQuantity = 0, 0, 0
    for _, entry in pairs(manual.entries) do
        selected = selected + 1
        local quantity = entry.count * (entry.numStacks or 1)
        totalQuantity = totalQuantity + quantity
        value = value + quantity * math.max(0, tonumber(entry.manualPrice) or tonumber(entry.suggested) or 0)
    end
    if manual.summary then
        manual.summary:SetText(selected .. " selected | " .. totalQuantity .. " items | expected " .. Money(value))
    end
end

RefreshManualCompetition = function()
    if not manual.marketRows then return end
    for index, button in ipairs(manual.marketRows) do
        local row = manual.liveRows and manual.liveRows[index]
        button.row = row
        if row then
            local selected = manual.marketSelection == row
            button.forceSelected = selected
            if button.RefreshAuctionStyle then button:RefreshAuctionStyle() end
            button.price:SetText(TooltipMoney(row.unit))
            button.quantity:SetText("x" .. tostring(row.count or 1))
            button:Show()
        else
            button.row, button.forceSelected = nil, false
            button:Hide()
        end
    end
    if manual.marketHint then
        if manual.liveRows and #manual.liveRows > 0 then
            manual.marketHint:SetText("Select a listing to apply your undercut; Match Selected keeps its exact price.")
        else
            manual.marketHint:SetText("Check Live to load competing listings.")
        end
    end
end

local function CreateUpgradePage(upgradePage, contentWidth)
    local upgradeRowWidth = contentWidth - 24
    local upgradeRefresh = Button(upgradePage, "Refresh", 100, "primary")
    upgradeRefresh:SetPoint("TOPLEFT", 4, -8); upgradeRefresh:SetScript("OnClick", StartUpgradeAnalysis)
    local upgradeFilterWidth = math.floor((upgradeRowWidth - 124) / 3)
    upgrades.typeButton = Button(upgradePage, "Type: All", upgradeFilterWidth)
    upgrades.typeButton:SetPoint("LEFT", upgradeRefresh, "RIGHT", 8, 0)
    upgrades.typeButton:SetScript("OnClick", function(self) ShowUpgradeFilterMenu(self, "type") end)
    upgrades.subTypeButton = Button(upgradePage, "Subtype: All", upgradeFilterWidth)
    upgrades.subTypeButton:SetPoint("LEFT", upgrades.typeButton, "RIGHT", 8, 0)
    upgrades.subTypeButton:SetScript("OnClick", function(self) ShowUpgradeFilterMenu(self, "subType") end)
    upgrades.slotButton = Button(upgradePage, "Slot: All", upgradeFilterWidth)
    upgrades.slotButton:SetPoint("LEFT", upgrades.subTypeButton, "RIGHT", 8, 0)
    upgrades.slotButton:SetScript("OnClick", function(self) ShowUpgradeFilterMenu(self, "slot") end)
    AddHelp(upgradeRefresh, "Refresh upgrade ranking", "Re-evaluates saved required-level-60 gear against your currently equipped items and active upgrade weights.")
    AddHelp(upgrades.typeButton, "Armor or weapon", "Limits analysis to all gear, only armor, or only weapons. Non-matching saved items are skipped before upgrade calculations.")
    AddHelp(upgrades.subTypeButton, "Armor or weapon type", "Limits analysis to a subtype, such as Plate, Cloth, Sword, or Staff.")
    AddHelp(upgrades.slotButton, "Equipment slot", "Limits analysis to gear for the selected equipment slot.")
    upgrades.summary = upgradePage:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    upgrades.summary:SetPoint("TOPLEFT", 4, -42); upgrades.summary:SetWidth(upgradeRowWidth)
    upgrades.summary:SetJustifyH("LEFT"); upgrades.summary:SetText("Open this tab to analyze saved gear.")

    local upgradeItemWidth = math.max(150, upgradeRowWidth - 365)
    local upgradeGainX, upgradeTypeX = upgradeItemWidth + 10, upgradeItemWidth + 84
    local upgradeSlotX, upgradePriceX = upgradeItemWidth + 170, upgradeItemWidth + 270
    local upgradeHeaders = { { "Item", 4, upgradeItemWidth }, { "Upgrade", upgradeGainX, 70 },
        { "Type", upgradeTypeX, 82 }, { "Slot", upgradeSlotX, 96 }, { "Each", upgradePriceX, 92 } }
    for _, header in ipairs(upgradeHeaders) do
        local label = upgradePage:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("TOPLEFT", header[2], -63); label:SetWidth(header[3]); label:SetJustifyH("LEFT")
        label:SetText(header[1])
    end
    upgrades.rows = {}
    local function ScrollUpgradeResults(delta)
        local maximum = math.max(0, (#(upgrades.filtered or {}) - #upgrades.rows) * 24)
        upgrades.scroll:SetVerticalScroll(math.max(0,
            math.min(maximum, upgrades.scroll:GetVerticalScroll() - delta * 24)))
        RefreshUpgradeResults()
    end
    for index = 1, 10 do
        local row = Button(upgradePage, "", upgradeRowWidth)
        row:SetPoint("TOPLEFT", 4, -80 - (index - 1) * 24); row:GetFontString():Hide()
        row.item = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.item:SetPoint("LEFT", 6, 0); row.item:SetWidth(upgradeItemWidth); row.item:SetJustifyH("LEFT")
        row.gain = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.gain:SetPoint("LEFT", upgradeGainX - 4, 0); row.gain:SetWidth(74); row.gain:SetJustifyH("LEFT")
        row.subType = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.subType:SetPoint("LEFT", upgradeTypeX - 4, 0); row.subType:SetWidth(86); row.subType:SetJustifyH("LEFT")
        row.slot = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.slot:SetPoint("LEFT", upgradeSlotX - 4, 0); row.slot:SetWidth(100); row.slot:SetJustifyH("LEFT")
        row.price = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.price:SetPoint("LEFT", upgradePriceX - 4, 0); row.price:SetWidth(96); row.price:SetJustifyH("LEFT")
        row:HookScript("OnEnter", function(self)
            if self.row and self.row.link then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetHyperlink(self.row.link); GameTooltip:Show()
            end
        end)
        row:HookScript("OnLeave", function() GameTooltip:Hide() end)
        row:EnableMouseWheel(true)
        row:SetScript("OnMouseWheel", function(_, delta) ScrollUpgradeResults(delta) end)
        upgrades.rows[index] = row
    end
    upgrades.scroll = CreateFrame("ScrollFrame", nil, upgradePage, "FauxScrollFrameTemplate")
    upgrades.scroll:SetPoint("TOPLEFT", upgradeRowWidth + 6, -80); upgrades.scroll:SetSize(18, 240)
    upgrades.scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, 24, RefreshUpgradeResults)
    end)
    upgrades.scroll:EnableMouseWheel(true)
    upgrades.scroll:SetScript("OnMouseWheel", function(_, delta) ScrollUpgradeResults(delta) end)
    local upgradeScrollChildren = { upgrades.scroll:GetChildren() }
    for _, child in ipairs(upgradeScrollChildren) do
        child:Hide(); child:HookScript("OnShow", function(self) self:Hide() end)
    end
    RefreshUpgradeResults()
    AddScanFooter(upgradePage)
end

local function CreateWindow()
    if window then return end
    if not AuctionFrame then return end
    window = CreateFrame("Frame", "AutoEverythingAuctionFrame", AuctionFrame)
    -- ElvUI leaves the stock Auction House title strip visually empty. Use it
    -- for our task navigation while retaining a small inset for the close box.
    window:SetPoint("TOPLEFT", AuctionFrame, "TOPLEFT", 18, -14)
    window:SetPoint("BOTTOMRIGHT", AuctionFrame, "BOTTOMRIGHT", -18, 10)
    window:SetFrameLevel((AuctionFrame:GetFrameLevel() or 0) + 8)
    window:EnableMouse(true); Skin(window); window:Hide()

    local tabs = { { "sell", "Sell" }, { "shopping", "Buy" }, { "queue", "Auto Sell" },
        { "owned", "My Auctions" }, { "upgrades", "Upgrades" }, { "scan", "Market Data" } }
    local contentWidth = math.max(588, (AuctionFrame:GetWidth() or 656) - 68)
    local tabWidth = math.floor((contentWidth - (#tabs - 1) * 6) / #tabs)
    local previous
    for _, spec in ipairs(tabs) do
        local button = Button(window, spec[2], tabWidth)
        if previous then button:SetPoint("LEFT", previous, "RIGHT", 6, 0) else button:SetPoint("TOPLEFT", 16, -12) end
        button:SetScript("OnClick", function() ShowAuctionPage(spec[1]) end)
        AddHelp(button, spec[2], spec[1] == "sell" and "Select a bag item, check its live competition, then post deliberately."
            or spec[1] == "queue" and "Build rule-matched listings, then run a complete targeted live search for each unique item before posting."
            or spec[1] == "shopping" and "Save an item and limits, review matches, then click once per purchase."
            or spec[1] == "upgrades" and "Rank saved required-level-60 auction gear against your equipped items and active upgrade profile."
            or "Collect bounded market observations, including exact equipment variants.")
        pageButtons[spec[1]], previous = button, button
        local page = CreateFrame("Frame", nil, window); page:SetPoint("TOPLEFT", 16, -48); page:SetPoint("BOTTOMRIGHT", -16, 12)
        pageFrames[spec[1]] = page
    end

    local ownedPage = pageFrames.owned
    local ownedRowWidth = contentWidth - 24
    local ownedItemWidth = math.max(220, ownedRowWidth - 332)
    local ownedStackX, ownedUnitX = ownedItemWidth + 10, ownedItemWidth + 64
    local ownedTotalX, ownedTimeX = ownedItemWidth + 154, ownedItemWidth + 264
    local ownedRefresh = Button(ownedPage, "Refresh", 140); ownedRefresh:SetPoint("TOPLEFT", 4, -8)
    ownedRefresh:SetScript("OnClick", RequestOwnedAuctions)
    owned.cancelButton = Button(ownedPage, "Cancel Auction", 140, "danger")
    owned.cancelButton:SetPoint("LEFT", ownedRefresh, "RIGHT", 8, 0)
    owned.cancelButton:SetScript("OnClick", CancelSelectedAuction)
    AddHelp(ownedRefresh, "Refresh your auctions", "Requests the latest owner list from the Auction House.")
    AddHelp(owned.cancelButton, "Cancel selected auction", "Cancellation is submitted only for the highlighted row after its item, quantity, and price are verified again.")
    owned.summary = ownedPage:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    owned.summary:SetPoint("TOPRIGHT", -4, -14); owned.summary:SetWidth(contentWidth - 304); owned.summary:SetJustifyH("RIGHT")
    local ownedHeaders = { { "Item", 4, ownedItemWidth }, { "Stack", ownedStackX, 48 },
        { "Each", ownedUnitX, 84 }, { "Buyout", ownedTotalX, 104 }, { "Left", ownedTimeX, 68 } }
    for _, header in ipairs(ownedHeaders) do
        local label = ownedPage:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("TOPLEFT", header[2], -48); label:SetWidth(header[3]); label:SetJustifyH("LEFT")
        label:SetText(header[1])
    end
    owned.rows = {}
    for index = 1, 11 do
        local row = Button(ownedPage, "", ownedRowWidth)
        row:SetPoint("TOPLEFT", 4, -65 - (index - 1) * 24); row:GetFontString():Hide()
        row.item = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.item:SetPoint("LEFT", 6, 0); row.item:SetWidth(ownedItemWidth); row.item:SetJustifyH("LEFT")
        row.quantity = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.quantity:SetPoint("LEFT", ownedStackX - 4, 0); row.quantity:SetWidth(52); row.quantity:SetJustifyH("LEFT")
        row.unit = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.unit:SetPoint("LEFT", ownedUnitX - 4, 0); row.unit:SetWidth(90); row.unit:SetJustifyH("LEFT")
        row.total = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.total:SetPoint("LEFT", ownedTotalX - 4, 0); row.total:SetWidth(110); row.total:SetJustifyH("LEFT")
        row.time = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.time:SetPoint("LEFT", ownedTimeX - 4, 0); row.time:SetWidth(68); row.time:SetJustifyH("LEFT")
        row:SetScript("OnClick", function(self)
            if not self.row then return end
            owned.selected = self.row
            if SetSelectedAuctionItem then SetSelectedAuctionItem("owner", self.row.index) end
            RefreshOwnedAuctions()
        end)
        row:HookScript("OnEnter", function(self)
            if self.row and self.row.link then GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetHyperlink(self.row.link); GameTooltip:Show() end
        end)
        row:HookScript("OnLeave", function() GameTooltip:Hide() end)
        owned.rows[index] = row
    end
    owned.scroll = CreateFrame("ScrollFrame", nil, ownedPage, "FauxScrollFrameTemplate")
    owned.scroll:SetPoint("TOPLEFT", ownedRowWidth + 6, -65); owned.scroll:SetSize(18, 264)
    owned.scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, 24, RefreshOwnedAuctions)
    end)
    local ownedScrollChildren = { owned.scroll:GetChildren() }
    for _, child in ipairs(ownedScrollChildren) do
        child:Hide()
        child:HookScript("OnShow", function(self) self:Hide() end)
    end
    AddScanFooter(ownedPage)

    local sell = pageFrames.sell
    local sellListWidth = math.floor(contentWidth * 0.58)
    local sellRightX = sellListWidth + 18
    local sellRightWidth = math.max(182, contentWidth - sellRightX)
    local sellHint = sell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sellHint:SetPoint("TOPLEFT", 4, -8); sellHint:SetWidth(contentWidth); sellHint:SetJustifyH("LEFT")
    sellHint:SetText("Sellable bags | select one item to price and post; clicking it again clears it.")
    -- Stack size and stack count are edited below the list, so a separate Post
    -- column is redundant for this single-select workflow. Give that space to
    -- Market and Value so all three coin textures remain inside the row.
    local nameWidth = math.max(80, sellListWidth - 315)
    local nameX, bagX = 4, 31 + nameWidth
    local marketX = bagX + 38
    local valueX = marketX + 94
    local valueWidth = math.max(42, sellListWidth - valueX - 6)
    local sellHeaders = { { "Item", nameX, nameWidth }, { "Bag", bagX, 34 },
        { "Market each", marketX, 90 }, { "Value", valueX, valueWidth } }
    for _, header in ipairs(sellHeaders) do
        local label = sell:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("TOPLEFT", header[2], -29); label:SetWidth(header[3]); label:SetJustifyH("LEFT")
        label:SetText(header[1])
    end
    manual.rows = {}
    local function ScrollSellGrid(delta)
        local scroll = manual.scrollFrame
        if not scroll then return end
        local maximum = math.max(0, (#manual.inventory - #manual.rows) * 27)
        scroll:SetVerticalScroll(math.max(0, math.min(maximum, scroll:GetVerticalScroll() - delta * 27)))
        RefreshSellGrid()
    end
    for index = 1, 7 do
        local row = Button(sell, "", sellListWidth); row:SetSize(sellListWidth, 25)
        row:SetPoint("TOPLEFT", 4, -44 - (index - 1) * 27); row:GetFontString():Hide()
        row.icon = row:CreateTexture(nil, "ARTWORK"); row.icon:SetSize(20, 20); row.icon:SetPoint("LEFT", 3, 0)
        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.name:SetPoint("LEFT", 27, 0); row.name:SetWidth(nameWidth); row.name:SetJustifyH("LEFT")
        row.available = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.available:SetPoint("LEFT", bagX - 4, 0); row.available:SetWidth(34); row.available:SetJustifyH("LEFT")
        row.market = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.market:SetPoint("LEFT", marketX - 4, 0); row.market:SetWidth(92); row.market:SetJustifyH("LEFT")
        row.value = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.value:SetPoint("LEFT", valueX - 4, 0); row.value:SetWidth(valueWidth); row.value:SetHeight(20); row.value:SetJustifyH("RIGHT")
        if row.value.SetWordWrap then row.value:SetWordWrap(false) end
        row:SetScript("OnClick", function(self)
            local entry = self.entry
            if not entry then return end
            SetManualSelection(entry, not entry.selected)
        end)
        row:HookScript("OnEnter", function(self)
            local entry = self.entry
            if not entry then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if GameTooltip.SetBagItem then GameTooltip:SetBagItem(entry.bag, entry.slot)
            elseif GameTooltip.SetHyperlink then GameTooltip:SetHyperlink(entry.link) end
            GameTooltip:Show()
        end)
        row:HookScript("OnLeave", function() GameTooltip:Hide() end)
        row:EnableMouseWheel(true)
        row:SetScript("OnMouseWheel", function(_, delta) ScrollSellGrid(delta) end)
        manual.rows[index] = row
    end
    manual.scrollFrame = CreateFrame("ScrollFrame", nil, sell, "FauxScrollFrameTemplate")
    manual.scrollFrame:SetPoint("TOPLEFT", sellListWidth + 2, -44); manual.scrollFrame:SetSize(18, 189)
    manual.scrollFrame:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, 27, RefreshSellGrid)
    end)
    local sellScrollChildren = { manual.scrollFrame:GetChildren() }
    for _, child in ipairs(sellScrollChildren) do
        child:Hide()
        child:HookScript("OnShow", function(self) self:Hide() end)
    end
    manual.scrollFrame:EnableMouseWheel(true)
    manual.scrollFrame:SetScript("OnMouseWheel", function(_, delta) ScrollSellGrid(delta) end)
    AddHelp(manual.scrollFrame, "Sellable bag items", "Scroll to review unlocked auctionable bag items. Selecting a row replaces the previous selection; stack size and stack count are configured below.")
    local refreshBags = Button(sell, "Refresh Bags", math.floor((sellRightWidth - 8) * 0.6)); refreshBags:SetPoint("TOPLEFT", sellRightX, -28)
    refreshBags:SetScript("OnClick", function() ScanSellInventory(); if RefreshSellGrid then RefreshSellGrid() end end)
    AddHelp(refreshBags, "Refresh sellable bags", "Rebuilds the grid from your unlocked auctionable bag items.")
    local clearManual = Button(sell, "Clear", math.floor((sellRightWidth - 8) * 0.4), "danger"); clearManual:SetPoint("LEFT", refreshBags, "RIGHT", 8, 0); clearManual:SetScript("OnClick", ClearManualItem)
    AddHelp(clearManual, "Clear selected item", "Deselects the current Sell-grid item without changing your bags.")
    manual.marketHint = sell:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    manual.marketHint:SetPoint("TOPLEFT", sellRightX, -60); manual.marketHint:SetWidth(sellRightWidth); manual.marketHint:SetJustifyH("LEFT")
    manual.marketHint:SetText("Check Live to load competing listings.")
    manual.marketRows = {}
    for index = 1, 7 do
        local row = Button(sell, "", sellRightWidth); row:SetSize(sellRightWidth, 21)
        row:SetPoint("TOPLEFT", sellRightX, -76 - (index - 1) * 23); row:GetFontString():Hide()
        row.price = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.price:SetPoint("LEFT", 6, 0); row.price:SetWidth(130); row.price:SetJustifyH("LEFT")
        row.quantity = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.quantity:SetPoint("RIGHT", -6, 0); row.quantity:SetWidth(40); row.quantity:SetJustifyH("RIGHT")
        row:SetScript("OnClick", function(self)
            if self.row then
                manual.marketSelection = self.row
                RefreshManualCompetition()
                ApplyManualMarketPrice(true)
            end
        end)
        row:HookScript("OnEnter", function(self)
            if self.row then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:AddLine("Competing listing", 1, 1, 1)
                GameTooltip:AddDoubleLine("Unit price", TooltipMoney(self.row.unit), 0.8, 0.8, 0.8, 1, 1, 1)
                GameTooltip:AddDoubleLine("Stack", tostring(self.row.count or 1), 0.8, 0.8, 0.8, 1, 1, 1)
                if self.row.owner then GameTooltip:AddDoubleLine("Seller", self.row.owner, 0.8, 0.8, 0.8, 1, 1, 1) end
                GameTooltip:Show()
            end
        end)
        row:HookScript("OnLeave", function() GameTooltip:Hide() end)
        manual.marketRows[index] = row
    end
    local undercutLabel = sell:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    undercutLabel:SetPoint("TOPLEFT", sellRightX, -236); undercutLabel:SetText("Undercut %")
    manual.undercutBox = EditBox(sell, 72, false); manual.undercutBox:SetPoint("TOPLEFT", sellRightX, -253)
    manual.undercutBox:SetText(tostring(UndercutPercent()))
    local function ApplyUndercutPercent()
        local value = tonumber(manual.undercutBox:GetText())
        if not value then value = UndercutPercent() end
        value = math.max(0, math.min(25, math.floor(value * 1000 + 0.5) / 1000))
        SetSetting("undercutPercent", value)
        manual.undercutBox:SetText(tostring(value))
        if manual.marketSelection then ApplyManualMarketPrice(true) end
    end
    manual.undercutBox:HookScript("OnEditFocusLost", ApplyUndercutPercent)
    manual.undercutBox:SetScript("OnEnterPressed", function(self) ApplyUndercutPercent(); self:ClearFocus() end)
    AddHelp(manual.undercutBox, "Live-list undercut percentage",
        "Selecting another seller's listing uses its unit price minus this percentage. Your own selected listing is matched instead. Decimals are allowed; every positive undercut is at least one copper unless the listing is already one copper.")
    local matchPrice = Button(sell, "Match Selected", math.max(94, sellRightWidth - 80)); matchPrice:SetPoint("TOPLEFT", sellRightX + 80, -253)
    matchPrice:SetScript("OnClick", function() ApplyManualMarketPrice(false) end)
    AddHelp(matchPrice, "Match selected competition", "Uses the selected listing's unit price for the highlighted sell item.")
    RefreshManualCompetition()
    local priceLabel = sell:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); priceLabel:SetPoint("TOPLEFT", 4, -236); priceLabel:SetText("Listing buyout (G/S/C)")
    manual.priceInput = MoneyInput(sell); manual.priceInput:SetPoint("TOPLEFT", 4, -253)
    local function HookBuyoutField(field)
        field:HookScript("OnEditFocusLost", ApplyManualBuyout)
        field:SetScript("OnEnterPressed", function(self) ApplyManualBuyout(); self:ClearFocus() end)
    end
    HookBuyoutField(manual.priceInput.gold); HookBuyoutField(manual.priceInput.silver); HookBuyoutField(manual.priceInput.copper)
    local countLabel = sell:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); countLabel:SetPoint("TOPLEFT", 200, -236); countLabel:SetText("Stack size")
    manual.countBox = EditBox(sell, 54, true); manual.countBox:SetPoint("TOPLEFT", 200, -253); manual.countBox:SetText("1")
    manual.countBox:HookScript("OnEditFocusLost", ApplyManualQuantity)
    manual.countBox:SetScript("OnEnterPressed", function(self) ApplyManualQuantity(); self:ClearFocus() end)
    local stack = Button(sell, "Max", 50); stack:SetPoint("LEFT", manual.countBox, "RIGHT", 6, 0)
    stack:SetScript("OnClick", function()
        local e = manual.activeKey and manual.entries[manual.activeKey]
        if e then e.count, e.numStacks = e.available or 1, 1; RefreshManualActive(); RefreshSellGrid() end
    end)
    local stacksLabel = sell:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); stacksLabel:SetPoint("TOPLEFT", 320, -236); stacksLabel:SetText("Stacks")
    manual.stacksBox = EditBox(sell, 54, true); manual.stacksBox:SetPoint("TOPLEFT", 320, -253); manual.stacksBox:SetText("1")
    manual.stacksBox:HookScript("OnEditFocusLost", ApplyManualStacks)
    manual.stacksBox:SetScript("OnEnterPressed", function(self) ApplyManualStacks(); self:ClearFocus() end)
    local duration = Button(sell, "Duration: 24h", 112); manual.duration = 2
    duration:SetScript("OnClick", function(self)
        local menu = {}
        for index, label in ipairs({ "12 hours", "24 hours", "48 hours" }) do
            local durationIndex = index
            menu[#menu + 1] = { text = label, checked = manual.duration == durationIndex, func = function()
                manual.duration = durationIndex; duration:SetText("Duration: " .. ({ "12h", "24h", "48h" })[durationIndex])
            end }
        end
        if EasyMenu then EasyMenu(menu, _G.AutoEverythingAuctionDurationMenu or CreateFrame("Frame", "AutoEverythingAuctionDurationMenu", UIParent, "UIDropDownMenuTemplate"), self, 0, 0, "MENU") end
    end)
    local refreshPrice = Button(sell, "Check Live", 104); refreshPrice:SetPoint("TOPLEFT", 4, -281); refreshPrice:SetScript("OnClick", RefreshManualPrice)
    local manualPost = Button(sell, "Post Selected", 120, "primary"); manualPost:SetPoint("LEFT", refreshPrice, "RIGHT", 8, 0); manualPost:SetScript("OnClick", StartManualPost)
    duration:SetPoint("LEFT", manualPost, "RIGHT", 8, 0)
    local sellMessageWidth = math.max(math.floor(contentWidth * 0.62), contentWidth - 340)
    manual.summary = sell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); manual.summary:SetPoint("BOTTOMLEFT", 4, 23); manual.summary:SetWidth(sellMessageWidth); manual.summary:SetJustifyH("LEFT")
    AddHelp(manual.countBox, "Stack size", "Number of items in each auction. Max uses the full selected bag stack as one auction.")
    AddHelp(manual.stacksBox, "Number of stacks", "How many auctions of this stack size to create. The total cannot exceed the selected bag stack.")
    manual.warning = sell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); manual.warning:SetPoint("BOTTOMLEFT", 4, 6); manual.warning:SetWidth(sellMessageWidth); manual.warning:SetJustifyH("LEFT"); manual.warning:SetText("Manual prices are advisory-checked and never blocked.")
    local sellFooter = AddScanFooter(sell); sellFooter:SetWidth(contentWidth - sellMessageWidth - 16)
    ScanSellInventory()

    local queuePage = pageFrames.queue
    postButton = Button(queuePage, "Build Queue", 150, "primary"); postButton:SetPoint("TOPLEFT", 4, -8)
    postButton:SetScript("OnClick", function()
        if posting then
            StopPosting("Posting stopped.")
        elseif #queue == 0 then
            Auction.BuildQueue()
            if Setting("postingMode", "queue") == "auto" and #queue > 0 then Auction.StartPosting() end
        else
            Auction.StartPosting()
        end
    end)
    modeButton = Button(queuePage, "Mode: Preview Queue", 170); modeButton:SetPoint("LEFT", postButton, "RIGHT", 8, 0)
    modeButton:SetScript("OnClick", function() SetSetting("postingMode", Setting("postingMode", "queue") == "auto" and "queue" or "auto"); RefreshWindow() end)
    local rules = Button(queuePage, "Rules", 90); rules:SetPoint("LEFT", modeButton, "RIGHT", 8, 0)
    rules:SetScript("OnClick", function() window:Hide(); if Core.Settings and Core.Settings.Open then Core.Settings.Open("Auction Rules") end end)
    -- Status belongs to Auto Queue only. Parenting it to the window made the
    -- "Last scan" line overlap the Sell and Shopping item-selection rows.
    statusText = queuePage:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    statusText:SetPoint("BOTTOMLEFT", 4, 4); statusText:SetWidth(math.floor(contentWidth / 2)); statusText:SetJustifyH("LEFT")
    statusText:SetTextColor(0.55, 0.58, 0.62)
    local queueFooter = AddScanFooter(queuePage); queueFooter:SetWidth(math.floor(contentWidth / 2))
    local queueItemWidth = math.max(220, contentWidth - 344)
    local queueStackX, queueEachX = queueItemWidth + 10, queueItemWidth + 84
    local queueTotalX, queueSourceX = queueItemWidth + 176, queueItemWidth + 278
    local queueHeaders = { { "Item", 4, queueItemWidth }, { "Stacks", queueStackX, 68 },
        { "Each", queueEachX, 86 }, { "Total", queueTotalX, 96 }, { "Price", queueSourceX, 64 } }
    for _, header in ipairs(queueHeaders) do
        local label = queuePage:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("TOPLEFT", header[2], -52); label:SetWidth(header[3]); label:SetJustifyH("LEFT")
        label:SetText(header[1])
    end
    for index = 1, 11 do
        local rowIndex = index
        local row = Button(queuePage, "", contentWidth); row:SetSize(contentWidth, 23)
        row:SetPoint("TOPLEFT", 4, -67 - (index - 1) * 25); row:GetFontString():Hide()
        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.name:SetPoint("LEFT", 6, 0); row.name:SetWidth(queueItemWidth); row.name:SetJustifyH("LEFT")
        row.quantity = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.quantity:SetPoint("LEFT", queueStackX - 4, 0); row.quantity:SetWidth(70); row.quantity:SetJustifyH("LEFT")
        row.unit = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.unit:SetPoint("LEFT", queueEachX - 4, 0); row.unit:SetWidth(90); row.unit:SetJustifyH("LEFT")
        row.total = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.total:SetPoint("LEFT", queueTotalX - 4, 0); row.total:SetWidth(102); row.total:SetJustifyH("LEFT")
        row.source = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.source:SetPoint("LEFT", queueSourceX - 4, 0); row.source:SetWidth(64); row.source:SetJustifyH("LEFT")
        row:HookScript("OnEnter", function(self)
            local entry = queue[rowIndex]
            if entry and entry.link then GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetHyperlink(entry.link); GameTooltip:Show() end
        end)
        row:HookScript("OnLeave", function() GameTooltip:Hide() end)
        queueRows[index] = row
    end

    local shop = pageFrames.shopping
    shopping.mode = "percent"
    local shopRowWidth = contentWidth - 24
    local shopItemWidth = math.max(220, shopRowWidth - 278)
    local shopEachX, shopQtyX, shopTotalX = shopItemWidth + 10, shopItemWidth + 106, shopItemWidth + 164
    local searchLabel = shop:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    searchLabel:SetPoint("TOPLEFT", 4, -8); searchLabel:SetText("Search by item name, item ID, or item link")
    shopping.itemBox = EditBox(shop, shopRowWidth, false); shopping.itemBox:SetPoint("TOPLEFT", 4, -25)
    shopping.itemBox:SetAutoFocus(false)
    shopping.itemBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); ScanShopping(true) end)
    AddHelp(shopping.itemBox, "Auction search", "Enter an item name, numeric item ID, or item link. Item IDs resolve through the client cache or your market database.")

    local shopActionWidth = math.floor((shopRowWidth - 40) / 6)
    local searchButton = Button(shop, "Search", shopActionWidth, "primary"); searchButton:SetPoint("TOPLEFT", 4, -61)
    searchButton:SetScript("OnClick", function() ScanShopping(true) end)
    shopping.savedButton = Button(shop, "Saved", shopActionWidth); shopping.savedButton:SetPoint("LEFT", searchButton, "RIGHT", 8, 0)
    shopping.savedButton:SetScript("OnClick", function(self) ShowSavedShoppingMenu(self) end)
    local saveSearch = Button(shop, "Save", shopActionWidth); saveSearch:SetPoint("LEFT", shopping.savedButton, "RIGHT", 8, 0)
    saveSearch:SetScript("OnClick", PersistShoppingEntry)
    local deleteSearch = Button(shop, "Delete", shopActionWidth, "danger"); deleteSearch:SetPoint("LEFT", saveSearch, "RIGHT", 8, 0)
    deleteSearch:SetScript("OnClick", DeleteSavedShoppingEntry)
    AddHelp(shopping.savedButton, "Saved searches", "Opens a menu of saved item and name searches in alphabetical order.")
    AddHelp(saveSearch, "Save current search", "Stores the current item/name and price limits in the Auction database.")
    AddHelp(deleteSearch, "Delete saved search", "Removes the currently loaded saved search.")
    local shopScan = Button(shop, "Rescan", shopActionWidth); shopScan:SetPoint("LEFT", deleteSearch, "RIGHT", 8, 0); shopScan:SetScript("OnClick", function() ScanShopping(false) end)
    local buy = Button(shop, "Buy Cheapest", shopActionWidth, "primary"); buy:SetPoint("LEFT", shopScan, "RIGHT", 8, 0); shopping.buyButton = buy
    buy:SetScript("OnClick", function()
        if shopping.pendingBuy then ConfirmShoppingBuyout()
        else
            local hasSelection = next(shopping.selectedResults or {}) ~= nil
            if hasSelection then BuySelectedShopping(true) else BuyNextShopping(true) end
        end
    end)
    AddHelp(shopScan, "Rescan listings", "Refreshes the eligible-listings table but keeps the current reference price.")
    AddHelp(buy, "Buy from scanned results", "Buys the cheapest remaining scanned listing, or the next selected listing. It walks the current scan without rescanning; changing auction pages may require one extra click after the page loads. Your session spend cap is enforced.")

    local maxLabel = shop:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); maxLabel:SetPoint("TOPLEFT", 4, -99); maxLabel:SetText("Maximum / item (G/S/C, optional)")
    local percentLabel = shop:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); percentLabel:SetPoint("TOPLEFT", 204, -99); percentLabel:SetText("Above reference %")
    shopping.maxInput = MoneyInput(shop); shopping.maxInput:SetPoint("TOPLEFT", 4, -116)
    shopping.percentBox = EditBox(shop, 100, true); shopping.percentBox:SetPoint("TOPLEFT", 204, -116); shopping.percentBox:SetText(tostring(Setting("shoppingDefaultPercent", 10)))
    AddHelp(shopping.maxInput, "Maximum per item", "Optional hard cap for the unit price. Listings above it are hidden.")
    AddHelp(shopping.percentBox, "Percentage limit", "Optional maximum percent above the fixed reference unit price. The default is 10%.")

    shopping.resultText = shop:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); shopping.resultText:SetPoint("TOPLEFT", 4, -151); shopping.resultText:SetWidth(shopRowWidth); shopping.resultText:SetJustifyH("LEFT")
    local headers = { { "Item", 4, shopItemWidth }, { "Each", shopEachX, 90 },
        { "Qty", shopQtyX, 52 }, { "Total", shopTotalX, 108 } }
    for _, header in ipairs(headers) do
        local label = shop:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("TOPLEFT", header[2], -174); label:SetWidth(header[3]); label:SetJustifyH("LEFT"); label:SetText(header[1])
    end
    shopping.resultRows = {}
    for index = 1, 7 do
        local row = Button(shop, "", shopRowWidth)
        row:SetPoint("TOPLEFT", 4, -191 - (index - 1) * 21); row:GetFontString():Hide()
        row.item = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.item:SetPoint("LEFT", 6, 0); row.item:SetWidth(shopItemWidth); row.item:SetJustifyH("LEFT")
        row.unit = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.unit:SetPoint("LEFT", shopEachX - 4, 0); row.unit:SetWidth(96); row.unit:SetJustifyH("LEFT")
        row.quantity = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.quantity:SetPoint("LEFT", shopQtyX - 4, 0); row.quantity:SetWidth(58); row.quantity:SetJustifyH("LEFT")
        row.total = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.total:SetPoint("LEFT", shopTotalX - 4, 0); row.total:SetWidth(108); row.total:SetJustifyH("LEFT")
        row:SetScript("OnClick", function(self)
            if not self.row then return end
            shopping.pendingBuy = nil
            shopping.selectedResults = shopping.selectedResults or {}
            local key = ShoppingRowKey(self.row)
            shopping.selectedResults[key] = not shopping.selectedResults[key] or nil
            RefreshShoppingResults()
        end)
        row:HookScript("OnEnter", function(self)
            if self.row then GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetHyperlink(self.row.link); GameTooltip:Show() end
        end)
        row:HookScript("OnLeave", function() GameTooltip:Hide() end)
        row:EnableMouseWheel(true)
        row:SetScript("OnMouseWheel", function(_, delta)
            local scroll = shopping.resultScroll
            if not scroll then return end
            local maximum = math.max(0, (#(shopping.eligibleResults or {}) - #shopping.resultRows) * 21)
            scroll:SetVerticalScroll(math.max(0, math.min(maximum, scroll:GetVerticalScroll() - delta * 21)))
            RefreshShoppingResults()
        end)
        shopping.resultRows[index] = row
    end
    shopping.resultScroll = CreateFrame("ScrollFrame", nil, shop, "FauxScrollFrameTemplate")
    -- Hide Blizzard's wide chrome. The compact brand scroller is attached
    -- directly to the result table's right edge.
    shopping.resultScroll:SetPoint("TOPLEFT", shopRowWidth + 6, -191); shopping.resultScroll:SetSize(18, 147)
    -- FauxScrollFrameTemplate creates several Blizzard scrollbar children
    -- (bar plus arrow buttons). Hide every one; hiding only the first child
    -- left the stock bar visible beside our replacement on some clients.
    local defaultScrollChildren = { shopping.resultScroll:GetChildren() }
    for _, child in ipairs(defaultScrollChildren) do
        child:Hide()
        child:HookScript("OnShow", function(self) self:Hide() end)
    end
    shopping.resultScroll:SetScript("OnVerticalScroll", function(self, offset) FauxScrollFrame_OnVerticalScroll(self, offset, 21, RefreshShoppingResults) end)
    local function ScrollShoppingResults(delta)
        local scroll = shopping.resultScroll
        local maximum = math.max(0, (#(shopping.eligibleResults or {}) - #shopping.resultRows) * 21)
        scroll:SetVerticalScroll(math.max(0, math.min(maximum, scroll:GetVerticalScroll() - delta * 21)))
        RefreshShoppingResults()
    end
    shopping.resultScroll:EnableMouseWheel(true)
    shopping.resultScroll:SetScript("OnMouseWheel", function(_, delta) ScrollShoppingResults(delta) end)
    shopping.scrollTrack = CreateFrame("Frame", nil, shop); shopping.scrollTrack:SetPoint("TOPLEFT", shopRowWidth + 6, -191); shopping.scrollTrack:SetSize(18, 147); Skin(shopping.scrollTrack)
    shopping.scrollThumb = CreateFrame("Frame", nil, shopping.scrollTrack); Skin(shopping.scrollThumb)
    shopping.scrollThumb:SetBackdropColor(BRAND[1] * 0.22, BRAND[2] * 0.22, BRAND[3] * 0.22, 1)
    shopping.scrollThumb:SetBackdropBorderColor(BRAND[1], BRAND[2], BRAND[3], 0.9)
    -- Button() defaults to 24px high, which made these arrows look like long
    -- stock controls. Keep compact 16px blue arrows inside the full-height
    -- track, matching the result table's bounding area.
    local up = Button(shop, "▲", 18); up:SetSize(16, 16); up:SetPoint("TOP", shopping.scrollTrack, "TOP", 0, -1); up:GetFontString():SetTextColor(BRAND[1], BRAND[2], BRAND[3]); up:SetScript("OnClick", function() ScrollShoppingResults(1) end)
    local down = Button(shop, "▼", 18); down:SetSize(16, 16); down:SetPoint("BOTTOM", shopping.scrollTrack, "BOTTOM", 0, 1); down:GetFontString():SetTextColor(BRAND[1], BRAND[2], BRAND[3]); down:SetScript("OnClick", function() ScrollShoppingResults(-1) end)
    for _, arrow in ipairs({ up, down }) do
        arrow:HookScript("OnEnter", function(self) self:GetFontString():SetTextColor(BRAND[1], BRAND[2], BRAND[3]) end)
        arrow:HookScript("OnLeave", function(self) self:GetFontString():SetTextColor(BRAND[1], BRAND[2], BRAND[3]) end)
    end
    AddHelp(shopping.scrollTrack, "Eligible listings", "Only listings within the current maximum and percentage rules appear. Scroll to review more.")
    RefreshShoppingResults()
    AddScanFooter(shop)

    CreateUpgradePage(pageFrames.upgrades, contentWidth)

    local scanPage = pageFrames.scan
    scanButton = Button(scanPage, "Scan Entire Market", 180, "primary"); scanButton:SetPoint("TOPLEFT", 4, -8); scanButton:SetScript("OnClick", Auction.StartScan)
    AddHelp(scanButton, "Market scan", "Optional full-market snapshot. Exact item searches and Auto Sell also update prices incrementally, avoiding a full scan for normal posting.")
    scanStatusText = scanPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    scanStatusText:SetPoint("LEFT", scanButton, "RIGHT", 16, 0); scanStatusText:SetWidth(contentWidth - 210)
    scanStatusText:SetJustifyH("LEFT"); scanStatusText:SetText("Ready to scan.")
    local snapshotTitle = scanPage:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    snapshotTitle:SetPoint("TOPLEFT", 4, -62); snapshotTitle:SetText("Current market snapshot")
    scanStatsText = scanPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    scanStatsText:SetPoint("TOPLEFT", 4, -88); scanStatsText:SetWidth(contentWidth)
    scanStatsText:SetJustifyH("LEFT"); scanStatsText:SetText("No market data loaded.")
    local capabilityText = scanPage:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    capabilityText:SetPoint("TOPLEFT", 4, -116); capabilityText:SetWidth(contentWidth); capabilityText:SetJustifyH("LEFT")
    local canQuery, canGetAll
    if CanSendAuctionQuery then canQuery, canGetAll = CanSendAuctionQuery("list") end
    capabilityText:SetText("Scan method: " .. (canQuery and canGetAll and "fast server snapshot with paged fallback"
        or "reliable page-by-page scan") .. " | history depth: " .. MAX_HISTORY .. " snapshots")
    local scanHelp = CreateFrame("Frame", nil, scanPage)
    scanHelp:SetPoint("TOPLEFT", 4, -56); scanHelp:SetSize(contentWidth, 82)
    scanHelp:EnableMouse(true)
    AddHelp(scanHelp, "Market database", "Complete full-market or targeted item searches store bounded price history. Required-level-60 gear also stores exact-variant tooltip stats for upgrade searches. Partial browse pages are not used because they may omit cheaper listings.")
    local scanFooter = AddScanFooter(scanPage); scanFooter:SetWidth(contentWidth)

    window:SetScript("OnShow", function() ShowAuctionPage(currentPage); RefreshWindow() end)
end

function Auction.Hide()
    if upgradeAnalysis then upgradeAnalysis = nil; UpdateWorkerState() end
    if window then window:Hide() end
end

function Auction.Open()
    CreateWindow()
    if not window then Warn("Open the Auction House first."); return end
    if AutoEverythingSettingsFrame and AutoEverythingSettingsFrame:IsShown() then
        AutoEverythingSettingsFrame:Hide()
    end
    if AuctionFrameBrowse then AuctionFrameBrowse:Hide() end
    if AuctionFrameBid then AuctionFrameBid:Hide() end
    if AuctionFrameAuctions then AuctionFrameAuctions:Hide() end
    if auctionLauncher and PanelTemplates_SetTab then
        PanelTemplates_SetTab(AuctionFrame, auctionLauncher:GetID())
    end
    window:Show()
    RefreshWindow()
end

local function PositionAuctionButton()
    if not auctionLauncher or not AuctionFrame then return end
    local anchor = AuctionFrameTab3
    for index = 4, tonumber(AuctionFrame.numTabs) or 3 do
        local tab = _G["AuctionFrameTab" .. index]
        if tab and tab ~= auctionLauncher and tab:IsShown() then anchor = tab end
    end
    auctionLauncher:ClearAllPoints()
    if anchor then
        local overlap = (_G.ElvUI and _G.ElvUI[1]) and -15 or -8
        auctionLauncher:SetPoint("LEFT", anchor, "RIGHT", overlap, 0)
    else
        auctionLauncher:SetPoint("BOTTOMLEFT", AuctionFrame, "BOTTOMLEFT", 245, 8)
    end
end

local function AddAuctionButton()
    if not AuctionFrame then return end
    if not auctionLauncher then
        local tabID = (tonumber(AuctionFrame.numTabs) or 3) + 1
        auctionLauncher = CreateFrame("Button", "AuctionFrameTab" .. tabID, AuctionFrame, "AuctionTabTemplate")
        auctionLauncher:SetText("AE Auctions")
        if PanelTemplates_TabResize then PanelTemplates_TabResize(auctionLauncher, 0)
        else auctionLauncher:SetSize(112, 28) end
        auctionLauncher:SetID(tabID)
        AuctionFrame.numTabs = tabID
        if PanelTemplates_SetNumTabs then PanelTemplates_SetNumTabs(AuctionFrame, tabID) end
        auctionLauncher:SetFrameLevel((AuctionFrame:GetFrameLevel() or 0) + 20)
        -- ElvUI skins the three stock tabs before this dynamic tab exists, so
        -- explicitly give it the identical treatment when that skin is active.
        local engine = _G.ElvUI and _G.ElvUI[1]
        local skins = engine and engine.GetModule and engine:GetModule("Skins", true)
        if skins and skins.HandleTab then skins:HandleTab(auctionLauncher) end
        auctionLauncher:SetScript("OnClick", Auction.Open)
        for index = 1, tabID - 1 do
            local blizzardTab = _G["AuctionFrameTab" .. index]
            if blizzardTab and not blizzardTab.aeAuctionHooked then
                blizzardTab.aeAuctionHooked = true
                blizzardTab:HookScript("OnClick", Auction.Hide)
            end
        end
    end
    PositionAuctionButton()
    CreateWindow()
end

events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("AUCTION_HOUSE_SHOW")
events:RegisterEvent("AUCTION_HOUSE_CLOSED")
events:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
events:RegisterEvent("AUCTION_OWNED_LIST_UPDATE")
events:RegisterEvent("AUCTION_MULTISELL_START")
events:RegisterEvent("AUCTION_MULTISELL_UPDATE")
events:RegisterEvent("AUCTION_MULTISELL_FAILURE")
events:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "AUCTION_OWNED_LIST_UPDATE" and RefreshOwnedAuctions then RefreshOwnedAuctions() end
    if event == "AUCTION_ITEM_LIST_UPDATE" and not marketQuery then
        -- A completed buyout can compact the live page and change every row
        -- index. Submitted indices only protect the short interval before this
        -- refresh arrives; afterward rows are matched again by their contents.
        shopping.submittedRows = {}
    end
    if event == "ADDON_LOADED" and arg1 == "AutoEverything" then
        EnsureDB()
    elseif event == "PLAYER_LOGIN" then
        -- Other addons may create their comparison frames during load.
        HookAuctionTooltips()
        if IsAddOnLoaded and not IsAddOnLoaded("AutoEverything_AuctionDB") then
            Warn("The companion market database is disabled; scanned prices will not persist after logout.")
        end
    elseif event == "AUCTION_HOUSE_SHOW" then
        -- Scans always require the explicit Scan Market click. The selected
        -- posting mode only controls what happens after that scan succeeds.
        AddAuctionButton()
    elseif event == "AUCTION_HOUSE_CLOSED" then
        upgradeAnalysis = nil
        if scan then AbortScan("Auction House closed; scan stopped.") end
        if posting then StopPosting("Auction House closed; posting stopped.")
        elseif marketQuery then FinishMarketQuery("Auction House closed.") end
        UpdateWorkerState()
        if window then window:Hide() end
    elseif event == "AUCTION_ITEM_LIST_UPDATE" and scan and scan.waiting then
        scan.responseAt = GetTime()
        if scan.mode == "getall" then
            local num, total = GetNumAuctionItems("list")
            scan.waiting = false
            scan.fastCapture = { index = 1, num = tonumber(num) or 0, total = tonumber(total) or 0 }
        else
            -- Valid page responses advance immediately from the AH event. The
            -- worker only takes over when CapturePage detects incomplete data
            -- and schedules its short settlement retry.
            ReadPage()
        end
    elseif event == "AUCTION_ITEM_LIST_UPDATE" and marketQuery and marketQuery.waiting then
        marketQuery.readyAt = GetTime()
    elseif event == "AUCTION_MULTISELL_FAILURE" and posting then
        StopPosting("The Auction House rejected a listing.")
    elseif event == "AUCTION_MULTISELL_START" and posting and posting.waiting then
        posting.multisellExpected = math.max(1, tonumber(arg1) or posting.multisellExpected or 1)
    elseif event == "AUCTION_MULTISELL_UPDATE" and posting and posting.waiting then
        local created = tonumber(arg1) or 0
        local expected = tonumber(arg2) or posting.multisellExpected or 1
        if created >= expected then
            posting.waiting = false
            posting.posted = posting.posted + expected
            posting.multisellExpected = nil
            posting.nextAt = GetTime() + 0.35
        end
    elseif event == "AUCTION_OWNED_LIST_UPDATE" and posting and posting.waiting
        and not posting.multisellExpected then
        posting.waiting = false
        posting.posted = posting.posted + 1
        posting.nextAt = GetTime() + 0.35
    end
end)
ProcessAuctionWork = function()
    local now = GetTime()
    if scan then
        if scan.mode == "getall" then
            if scan.fastCapture then ProcessGetAllChunk()
            elseif scan.waiting and now - scan.sentAt > 30 then FallBackToPagedScan("Get-all timed out") end
        elseif scan.waiting and scan.readyAt and now >= scan.readyAt then ReadPage()
        elseif scan.waiting and now - scan.sentAt > QUERY_TIMEOUT then
            scan.waiting, scan.readyAt = false, nil
            scan.retries = scan.retries + 1
            if scan.retries > MAX_RETRIES then AbortScan("Scan timed out on page " .. (scan.page + 1) .. ".")
            else scan.nextQuery = now + 0.2 end
        else SendQuery() end
    elseif marketQuery then
        if marketQuery.waiting and marketQuery.readyAt and now >= marketQuery.readyAt then
            ReadMarketQueryPage()
        elseif marketQuery.waiting and now - marketQuery.sentAt > QUERY_TIMEOUT then
            FinishMarketQuery("Live Auction House query timed out.")
        else SendMarketQuery() end
    elseif posting then
        if posting.waiting and now - posting.sentAt > QUERY_TIMEOUT then
            StopPosting("Timed out waiting for the Auction House to accept " .. posting.current.name .. ".")
        elseif not posting.waiting and now >= posting.nextAt then PostNext() end
    elseif upgradeAnalysis then
        ProcessUpgradeAnalysis()
    end
end
