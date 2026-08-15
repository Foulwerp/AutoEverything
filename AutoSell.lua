----------------------------------------------------------------------
-- AutoSell.lua
-- ============
-- AutoSell module for the combined addon. Uses AutoCore (Core.lua)
-- for all shared logic (tooltip scanning, filter matching, config
-- profile resolution, quest protection, appearance learning).
--
-- Scans bags when a merchant is open and sells items matching the
-- rules in AutoSellConfig.lua.
----------------------------------------------------------------------

local addonName = "AutoEverything"

-- Namespace
AutoSell = AutoSell or {}
local AS = AutoSell

-- Saved variables (per character)
AS.db = {}

-- Default settings if not present (fallback; corrected at ADDON_LOADED)
if AS.db.enabled == nil then
    AS.db.enabled = false
end

----------------------------------------------------------------------
-- Per-character config resolution (delegated to Core)
-- AutoSellConfig.lua defines commonRules (everyone) + neverSell
-- (everyone) + a "characters" table keyed by "Name-Realm" + a
-- "default" profile for characters not listed. Core.BuildActiveConfig
-- merges those into one flat table. Cached between actions and invalidated
-- immediately whenever the active profile or relevant settings change.
----------------------------------------------------------------------
local activeConfig = nil
local upgradeConfigCache = nil

local function GetActiveConfig()
    if not activeConfig then
        activeConfig = AutoCore.BuildActiveConfig(AutoSellConfig, "neverSell")
    end
    return activeConfig
end

function AS.ClearConfigCache()
    activeConfig = nil
    upgradeConfigCache = nil
end

function AS.ApplyProfile()
    if AutoCore and AutoCore.GetProfileSection then
        AS.db = AutoCore.GetProfileSection("sell", true)
    end
    if AS.db.enabled == nil then AS.db.enabled = (AutoSellConfig or {}).enabled == true end
end

----------------------------------------------------------------------
-- Upgrade config resolution. AutoSell's isUpgrade filter intentionally uses
-- the same active character profile and scoring rules as AutoUpgrade.
----------------------------------------------------------------------
local function GetUpgradeConfig()
    if not upgradeConfigCache then
        local config = AutoUpgradeConfig
        local profile = config and (AutoCore.GetProfile(config) or config.default or {}) or {}
        local function Resolve(key, fallback)
            if profile[key] ~= nil then return profile[key] end
            if config and config[key] ~= nil then return config[key] end
            return fallback
        end
        local mainHandTypes = Resolve("mainHandTypes", {})
        local offHandTypes = Resolve("offHandTypes", {})
        local rangedTypes = Resolve("rangedTypes", {})
        upgradeConfigCache = {
            weights = Resolve("weights", {}),
            threshold = Resolve("upgradeThreshold", 0),
            armorTypes = Resolve("armorTypes", {}),
            mainHandTypes = mainHandTypes,
            offHandTypes = offHandTypes,
            rangedTypes = rangedTypes,
            canOffHandWithTwoHand = AutoCore.InferCanOffHandWithTwoHand(mainHandTypes, offHandTypes),
        }
    end
    return upgradeConfigCache
end

-- Build one matcher per bag item. Upgrade scoring is lazy and cached because
-- several rules/exceptions may ask the same question for that item.
local function CreateItemMatcher(data, boundStatus, usable, playerLevel, location, debug)
    local isUpgradeResult, isUpgradeComputed, upgradeDebugInfo

    local function GetIsUpgrade()
        if not isUpgradeComputed then
            isUpgradeComputed = true
            upgradeDebugInfo = debug and {} or nil
            local cfg = GetUpgradeConfig()
            if not AutoCore.HasStatWeights(cfg.weights) then
                isUpgradeResult = nil
                if upgradeDebugInfo then
                    upgradeDebugInfo.reason = "upgrade status is unknown because no non-zero stat weights are configured"
                end
            else
                isUpgradeResult = AutoCore.IsUpgrade(
                    location and location.link, cfg.weights, cfg.threshold, nil,
                    {
                        armorTypes = cfg.armorTypes,
                        mainHandTypes = cfg.mainHandTypes,
                        offHandTypes = cfg.offHandTypes,
                        rangedTypes = cfg.rangedTypes,
                        canOffHandWithTwoHand = cfg.canOffHandWithTwoHand,
                        usable = usable,
                        bag = location and location.bag,
                        slot = location and location.slot,
                    },
                    upgradeDebugInfo
                )
            end
        end
        return isUpgradeResult, upgradeDebugInfo
    end

    return function(entry)
        local matched, why = AutoCore.EntryMatchDebug(entry, data, boundStatus, usable, playerLevel)
        local unsupported = AutoCore.GetUnsupportedEntryFields(entry, { isUpgrade = true })

        -- Core's matcher deliberately rejects entries without static fields.
        -- A consumer that evaluates isUpgrade may safely accept an entry whose
        -- only condition is isUpgrade, provided it has no unknown keys.
        if not matched and why == "entry has no supported filter fields"
            and entry.isUpgrade ~= nil and #unsupported == 0
        then
            matched, why = true, nil
        end

        -- Unknown fields make a destructive sell rule invalid rather than
        -- allowing a misspelling to broaden what it can sell.
        if #unsupported > 0 then
            matched = false
            why = "entry has unsupported field(s): " .. table.concat(unsupported, ", ")
        end

        if matched and entry.isUpgrade ~= nil then
            local upgrade, info = GetIsUpgrade()
            if upgrade == nil then
                matched = false
                why = (info and info.reason) or "upgrade status is unknown"
            elseif upgrade ~= entry.isUpgrade then
                matched = false
                why = entry.isUpgrade
                    and "item is not an upgrade (this entry requires isUpgrade=true)"
                    or "item IS an upgrade (this entry requires isUpgrade=false)"
                if info and info.reason then why = why .. ": " .. info.reason end
            end
        end
        return matched, why, unsupported
    end
end

-- Event frame
local eventFrame = CreateFrame("Frame")
local sellTimerFrame = CreateFrame("Frame")
local sellState = nil

----------------------------------------------------------------------
-- Helper: Check if an item matches any rule (with exceptions)
-- Returns true if it should be sold
----------------------------------------------------------------------
local function MatchesRules(data, boundStatus, usable, playerLevel, location)
    local config = GetActiveConfig()
    if not config or not config.rules then
        return false
    end

    local MatchEntry = CreateItemMatcher(data, boundStatus, usable, playerLevel, location, false)
    for _, rule in ipairs(config.rules) do
        -- Check exceptions first - if any exception matches, skip this rule
        local exceptionMatch = false
        if rule.exceptions then
            for _, exc in ipairs(rule.exceptions) do
                local matched, why, unsupported = MatchEntry(exc)
                -- A malformed or unevaluable exception blocks its parent
                -- sell rule. Failing closed is safer than silently ignoring
                -- an exception that was intended to protect an item.
                local upgradeUnknown = exc.isUpgrade ~= nil
                    and not AutoCore.HasStatWeights(GetUpgradeConfig().weights)
                if matched or #unsupported > 0
                    or why == "entry has no supported filter fields"
                    or upgradeUnknown
                then
                    exceptionMatch = true
                    break
                end
            end
        end
        if exceptionMatch then
            -- This rule is skipped due to exception
        else
            -- Check if the rule itself matches
            if MatchEntry(rule) then
                return true
            end
        end
    end

    return false
end

----------------------------------------------------------------------
-- Helper: Check if an item is in the neverSell list
-- Returns true if it should NEVER be sold
----------------------------------------------------------------------
local function InNeverSell(data, boundStatus, usable, playerLevel)
    local config = GetActiveConfig()
    if not config or not config.never then
        return false
    end

    for _, entry in ipairs(config.never) do
        if AutoCore.EntryMatches(entry, data, boundStatus, usable, playerLevel) then
            return true
        end
    end

    return false
end

----------------------------------------------------------------------
-- Helper: Should this item be sold?
----------------------------------------------------------------------
local function ShouldSell(data, boundStatus, usable, playerLevel, location)
    local config = GetActiveConfig()
    -- Never sell active quest items (shared Core protection)
    if AutoCore.IsActiveQuestItem(data.id) then
        return false
    end
    -- Keep the strongest pure-PvP/Bloodforged piece found for each slot.
    if AutoUpgrade and AutoUpgrade.IsBestPvPSetItem
        and AutoUpgrade.IsBestPvPSetItem(location and location.link, location)
    then
        return false
    end
    -- Preserve the strongest bag candidates for each enabled weapon role.
    -- This lets a future one-hand/off-hand pair develop while a stronger
    -- two-hander is currently equipped.
    if (not config or config.protectWeaponBench ~= false)
        and AutoUpgrade and AutoUpgrade.IsWeaponBenchItem
        and AutoUpgrade.IsWeaponBenchItem(location and location.link, location)
    then
        return false
    end
    -- Never sell items with no vendor price
    if not data.vendorPrice or data.vendorPrice <= 0 then
        return false
    end

    -- Global safety ceiling. Rules can be broad or mistyped; never allow
    -- them to sell above the explicitly configured quality tier.
    if config and config.maxQuality ~= nil
        and (data.quality == nil or data.quality > config.maxQuality)
    then
        return false
    end

    -- Never sell if in neverSell list
    if InNeverSell(data, boundStatus, usable, playerLevel) then
        return false
    end

    -- Sell if matches any rule
    return MatchesRules(data, boundStatus, usable, playerLevel, location)
end

----------------------------------------------------------------------
-- Auto-repair: repair all items when a merchant is open.
-- Uses the config's autoRepair settings:
--   enabled      : whether to auto-repair at all
--   useGuildBank : try guild bank funds first, then personal gold
--   printMessages: print result messages to chat
-- Returns true if a repair was performed.
----------------------------------------------------------------------
function AS.RepairItems()
    local cfg = GetActiveConfig()
    if not cfg or not cfg.autoRepair or not cfg.autoRepair.enabled then
        return false
    end

    if not CanMerchantRepair() then
        return false
    end

    local repairAllCost, canRepair = GetRepairAllCost()
    if not canRepair or not repairAllCost or repairAllCost == 0 then
        return false
    end

    local printMsg = cfg.autoRepair.printMessages
    local prefixGood = "|cff00ff00AutoSell:|r "
    local prefix = "|cff00ff00AutoSell:|r "

    -- Try guild bank funds first (if enabled)
    if cfg.autoRepair.useGuildBank and IsInGuild() and CanGuildBankRepair() then
        local withdrawLimit = GetGuildBankWithdrawMoney()
        local guildBankMoney = GetGuildBankMoney()
        local guildFunds
        if withdrawLimit == -1 then
            -- -1 means no withdraw limit (e.g. guild leader) - full bank balance available
            guildFunds = guildBankMoney
        else
            guildFunds = math.min(withdrawLimit, guildBankMoney)
        end

        if guildFunds >= repairAllCost then
            RepairAllItems(1)
            if AutoCore.SessionAdd then AutoCore.SessionAdd("repairCopper", repairAllCost) end
            if printMsg then
                DEFAULT_CHAT_FRAME:AddMessage(prefixGood .. "Repaired using guild bank funds (" .. GetCoinTextureString(repairAllCost) .. ")")
            end
            return true
        end
    end

    -- Fall back to personal gold
    if GetMoney() >= repairAllCost then
        RepairAllItems()
        if AutoCore.SessionAdd then AutoCore.SessionAdd("repairCopper", repairAllCost) end
        if printMsg then
            DEFAULT_CHAT_FRAME:AddMessage(prefixGood .. "Repaired using your own gold (" .. GetCoinTextureString(repairAllCost) .. ")")
        end
        return true
    else
        if printMsg then
            DEFAULT_CHAT_FRAME:AddMessage(prefix .. "Can't afford repairs (need " .. GetCoinTextureString(repairAllCost) .. ") and guild bank couldn't cover it either.")
        end
        return false
    end
end

----------------------------------------------------------------------
-- Merchant sell queue
-- Sell a whole quality tier at once, wait for the merchant to update, then
-- verify the tier before moving on. This preserves lowest-quality-first
-- buyback ordering without paying one server round trip per stack.
----------------------------------------------------------------------
local function FinishSellQueue(cancelled)
    local state = sellState
    if not state then return end
    sellState = nil
    sellTimerFrame:SetScript("OnUpdate", nil)

    if state.soldCount > 0 then
        if AutoCore.SessionAdd then
            AutoCore.SessionAdd("sold", state.soldCount)
            AutoCore.SessionAdd("soldCopper", state.soldValue)
        end
        if not state.cfg or state.cfg.printMessages ~= false then
            print("|cff00ff00AutoSell:|r Sold " .. state.soldCount .. " item(s) for "
                .. GetCoinTextureString(state.soldValue) .. ".")
        end
    end
    if state.failedStacks > 0 then
        AutoCore.Warn("Sell", state.failedStacks .. " stack(s) could not be sold after the final retry.")
    end
    if cancelled and (state.waiting or state.groupIndex <= #state.groups or #state.retryItems > 0) then
        AutoCore.Warn("Sell", "The remaining merchant sell queue was cancelled.")
    elseif state.onComplete then
        state.onComplete()
    end
end

local function SellBatch(items)
    local state = sellState
    if not state then return end

    local attempted = {}
    local now = GetTime()
    -- Enter the waiting state before UseContainerItem: some clients dispatch
    -- MERCHANT_UPDATE during the call rather than on a later frame.
    state.waiting = true
    state.updateSeen = false
    state.lastUpdateAt = nil
    state.waitDeadline = now + 1.0

    for _, item in ipairs(items) do
        local texture, count, locked, quality, readable, lootable, link = GetContainerItemInfo(item.bag, item.slot)
        if texture and link == item.link and not locked then
            if state.cfg and state.cfg.learnVanity and not item.learnAttempted then
                local guid = GetContainerItemGUID and GetContainerItemGUID(item.bag, item.slot) or nil
                AutoCore.LearnAppearance(item.id, guid)
                item.learnAttempted = true
            end
            item.beforeCount = count or item.count or 1
            table.insert(attempted, item)
            -- pcall so one unexpected error doesn't abort the rest of the
            -- batch loop, leaving later items in this pass never attempted.
            local ok = pcall(UseContainerItem, item.bag, item.slot)
            if not ok then
                AutoCore.Warn("Sell", "UseContainerItem failed for " .. tostring(item.link) .. "; will retry next pass.")
            end
        else
            -- A locked candidate gets one last chance after all quality tiers
            -- have had their fast batch. If a final-retry slot disappeared,
            -- the original asynchronous sale completed after verification.
            if state.finalRetry then
                if link ~= item.link then
                    local lateSoldCount = item.count or item.beforeCount or 1
                    state.soldCount = state.soldCount + lateSoldCount
                    state.soldValue = state.soldValue + item.price * lateSoldCount
                else
                    state.failedStacks = state.failedStacks + 1
                end
            else
                table.insert(state.retryItems, item)
            end
        end
    end

    state.pendingBatch = attempted
    -- No sale was issued (normally all slots were briefly locked), so there
    -- is no update to await.
    if #attempted == 0 then
        state.waiting = false
    end
end

local function VerifyBatch()
    local state = sellState
    if not state then return end

    for _, item in ipairs(state.pendingBatch or {}) do
        local _, afterCount, _, _, _, _, afterLink = GetContainerItemInfo(item.bag, item.slot)
        local beforeCount = item.beforeCount or item.count or 1
        local soldCount = 0
        if afterLink ~= item.link then
            soldCount = beforeCount
        elseif afterCount and afterCount < beforeCount then
            soldCount = beforeCount - afterCount
        end

        if soldCount > 0 then
            state.soldCount = state.soldCount + soldCount
            state.soldValue = state.soldValue + item.price * soldCount
        end
        if afterLink == item.link and (not afterCount or afterCount > 0) then
            item.count = afterCount or beforeCount
            if state.finalRetry then
                state.failedStacks = state.failedStacks + 1
            else
                table.insert(state.retryItems, item)
            end
        end
    end

    state.pendingBatch = nil
    state.waiting = false
end

local function ProcessSellQueue()
    local state = sellState
    if not state then return end
    if not AS.db.enabled or not (MerchantFrame and MerchantFrame:IsShown()) then
        FinishSellQueue(true)
        return
    end

    local now = GetTime()
    if state.waiting then
        -- Debounce rapid MERCHANT_UPDATE events so the whole batch has time
        -- to settle. The deadline is a fallback for servers that omit it.
        if (state.updateSeen and now >= state.lastUpdateAt + 0.10) or now >= state.waitDeadline then
            VerifyBatch()
        else
            return
        end
    end

    if state.groupIndex <= #state.groups then
        local group = state.groups[state.groupIndex]
        state.groupIndex = state.groupIndex + 1
        SellBatch(group)
        return
    end

    if not state.finalRetry and #state.retryItems > 0 then
        local remaining = state.retryItems
        state.retryItems = {}
        state.finalRetry = true
        SellBatch(remaining)
        return
    end

    FinishSellQueue(false)
end

----------------------------------------------------------------------
-- Main: Scan bags and sell matching items
-- dryRun = true will only print what would be sold, not actually sell.
-- onComplete runs after a non-dry queue finishes (used for auto-repair).
----------------------------------------------------------------------
function AS.ScanAndSell(dryRun, onComplete)
    -- Keep quest protection fresh right before processing (in case a
    -- quest item was just picked up and QUEST_LOG_UPDATE hasn't fired).
    AutoCore.RebuildQuestItems()

    local playerLevel = UnitLevel("player")
    local candidates = {}
    local cfg = GetActiveConfig()
    local scanOrder = 0

    -- First collect every matching stack without modifying the bags. Selling
    -- during this pass would lock us into bag order and could put a valuable
    -- item into the merchant buyback list before lower-quality trash.
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local texture, count, locked, quality, readable, lootable, link = GetContainerItemInfo(bag, slot)
            if texture and link and not locked then
                local data = AutoCore.GetItemData(link, { bag = bag, slot = slot })
                if data then
                    -- Get the item GUID for C_Item.IsBound (used on
                    -- Ascension/retail; ignored on 3.3.5 where the API
                    -- doesn't exist and tooltip scanning is the fallback)
                    local guid = GetContainerItemGUID and GetContainerItemGUID(bag, slot) or nil
                    local boundStatus, usable = AutoCore.ScanTooltip(link, guid, { bag = bag, slot = slot })
                    if ShouldSell(data, boundStatus, usable, playerLevel, { link = link, bag = bag, slot = slot }) then
                        scanOrder = scanOrder + 1
                        table.insert(candidates, {
                            bag = bag,
                            slot = slot,
                            link = link,
                            id = data.id,
                            name = data.name,
                            count = count,
                            quality = data.quality,
                            price = data.vendorPrice,
                            order = scanOrder,
                        })
                    end
                end
            end
        end
    end

    -- Poor first, then Common, Uncommon, Rare, etc. Explicitly break ties
    -- with original bag order because Lua's table.sort is not stable.
    table.sort(candidates, function(a, b)
        local qualityA = a.quality or math.huge
        local qualityB = b.quality or math.huge
        if qualityA == qualityB then
            return a.order < b.order
        end
        return qualityA < qualityB
    end)

    if dryRun then
        if #candidates == 0 then
            print("|cff00ff00AutoSell:|r No items would be sold.")
        else
            local wouldSellCount = 0
            local wouldSellValue = 0
            for _, item in ipairs(candidates) do
                wouldSellCount = wouldSellCount + item.count
                wouldSellValue = wouldSellValue + (item.price * item.count)
            end
            print("|cff00ff00AutoSell:|r Would sell " .. wouldSellCount .. " item(s) in " .. #candidates
                .. " stack(s) for " .. GetCoinTextureString(wouldSellValue) .. " (lowest quality first):")
            for _, item in ipairs(candidates) do
                print("  - " .. item.name .. " x" .. item.count .. " (" .. GetCoinTextureString(item.price * item.count) .. ")")
            end
        end
    else
        if sellState then
            AutoCore.Warn("Sell", "A merchant sell queue is already running.")
            return false
        end
        local groups = {}
        local lastQuality = nil
        for _, item in ipairs(candidates) do
            local quality = item.quality or math.huge
            if quality ~= lastQuality then
                table.insert(groups, {})
                lastQuality = quality
            end
            table.insert(groups[#groups], item)
        end
        sellState = {
            groups = groups,
            groupIndex = 1,
            retryItems = {},
            pendingBatch = nil,
            waiting = false,
            finalRetry = false,
            soldCount = 0,
            soldValue = 0,
            failedStacks = 0,
            cfg = cfg,
            onComplete = onComplete,
        }
        sellTimerFrame:SetScript("OnUpdate", ProcessSellQueue)
        ProcessSellQueue()
        return true
    end
end

----------------------------------------------------------------------
-- Event handling
----------------------------------------------------------------------
local function GetActivationMode()
    return AutoCore.GetSetting("sell", "activationMode", (AutoSellConfig or {}).activationMode or "automatic")
end

local function RunConfiguredMerchantActions()
    local activeCfg = GetActiveConfig()
    if not (AS.db.enabled and activeCfg and activeCfg.enabled) then return end
    AS.ScanAndSell(false, function()
        if MerchantFrame and MerchantFrame:IsShown() then AS.RepairItems() end
    end)
end

local merchantActionButton
if MerchantFrame then
    merchantActionButton = CreateFrame("Button", nil, MerchantFrame, "UIPanelButtonTemplate")
    merchantActionButton:SetSize(110, 22)
    merchantActionButton:SetPoint("BOTTOMRIGHT", MerchantFrame, "BOTTOMRIGHT", -34, 28)
    merchantActionButton:SetText("Sell & Repair")
    merchantActionButton:SetScript("OnClick", RunConfiguredMerchantActions)
    merchantActionButton:Hide()
end

local shiftWasDown = false
eventFrame:SetScript("OnUpdate", function()
    local shown = MerchantFrame and MerchantFrame:IsShown()
    local mode = GetActivationMode()
    if merchantActionButton then
        if shown and mode == "manual" and AS.db.enabled then merchantActionButton:Show()
        else merchantActionButton:Hide() end
    end
    if not shown or mode ~= "shift" or not AS.db.enabled then
        shiftWasDown = false
        return
    end
    local shiftDown = IsShiftKeyDown and IsShiftKeyDown()
    if shiftDown and not shiftWasDown then RunConfiguredMerchantActions() end
    shiftWasDown = shiftDown == true
end)

eventFrame:RegisterEvent("MERCHANT_SHOW")
eventFrame:RegisterEvent("MERCHANT_UPDATE")
eventFrame:RegisterEvent("MERCHANT_CLOSED")
eventFrame:RegisterEvent("ADDON_LOADED")

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name == addonName then
            AS.db = AutoCore.GetProfileSection("sell", true)
            if AS.db.enabled == nil then
                AS.db.enabled = (AutoSellConfig or {}).enabled == true
            end
            -- Confirm the saved state was loaded so the user knows the
            -- on/off toggle persists across reloads/logouts.
            AutoCore.Debug("Sell", "Saved state loaded.")
        end
    elseif event == "MERCHANT_UPDATE" then
        if sellState and sellState.waiting then
            sellState.updateSeen = true
            sellState.lastUpdateAt = GetTime()
        end
    elseif event == "MERCHANT_SHOW" then
        if GetActivationMode() == "automatic" then RunConfiguredMerchantActions() end
    elseif event == "MERCHANT_CLOSED" then
        if sellState then FinishSellQueue(true) end
    end
end)

----------------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------------
SLASH_AUTOSELL1 = "/autosell"
SLASH_AUTOSELL2 = "/as"

SlashCmdList["AUTOSELL"] = function(msg)
    msg = string.lower(strtrim(msg or ""))

    if msg == "on" then
        AS.db.enabled = true
        AutoCore.NotifyProfileChanged("sell")
        print("|cff00ff00AutoSell:|r Auto-sell enabled (saved - will persist on reload).")
    elseif msg == "off" then
        AS.db.enabled = false
        AutoCore.NotifyProfileChanged("sell")
        print("|cff00ff00AutoSell:|r Auto-sell disabled (saved - will persist on reload).")
    elseif msg == "sell" then
        if MerchantFrame and MerchantFrame:IsShown() then
            AS.ScanAndSell(false)
        else
            print("|cff00ff00AutoSell:|r You need to open a merchant first.")
        end
    elseif msg == "repair" then
        if MerchantFrame and MerchantFrame:IsShown() then
            AS.RepairItems()
        else
            print("|cff00ff00AutoSell:|r You need to open a merchant first.")
        end
    elseif msg == "test" then
        if MerchantFrame and MerchantFrame:IsShown() then
            AS.ScanAndSell(true)
        else
            print("|cff00ff00AutoSell:|r You need to open a merchant first.")
        end
    elseif msg == "whoami" then
        local cfg = GetActiveConfig()
        if not cfg then
            print("|cff00ff00AutoSell:|r AutoSellConfig not loaded.")
        else
            print("|cff00ff00AutoSell:|r Character key: " .. cfg.charKey)
            print("  Active rules: " .. #cfg.rules .. " (active profile order)")
            print("  Never-sell entries: " .. #cfg.never)
            print("  Maximum sell quality: " .. tostring(cfg.maxQuality ~= nil and cfg.maxQuality or "none"))
            print("  Protect weapon candidates: " .. tostring(cfg.protectWeaponBench ~= false))
            print("  Sale messages: " .. tostring(cfg.printMessages ~= false))
        end
    elseif msg == "debug" then
        -- Debug: scan EVERY item in bags and show the FULL decision
        -- path: every neverSell entry and every rule, with the exact
        -- reason each one matched or failed.
        local playerLevel = UnitLevel("player")
        local config = GetActiveConfig()
        local itemCount = 0
        local soldCount = 0
        local keptCount = 0

        for bag = 0, 4 do
            for slot = 1, GetContainerNumSlots(bag) do
                local texture, count, locked, quality, readable, lootable, link = GetContainerItemInfo(bag, slot)
                if texture and link and not locked then
                    local data = AutoCore.GetItemData(link, { bag = bag, slot = slot })
                    if data then
                        itemCount = itemCount + 1
                        local guid = GetContainerItemGUID and GetContainerItemGUID(bag, slot) or nil
                        local boundStatus, usable = AutoCore.ScanTooltip(link, guid, { bag = bag, slot = slot })

                        print("|cff00ff00AutoSell Debug:|r " .. data.name .. " x" .. count)
                        print("  itemType=" .. tostring(data.itemType) .. " subType=" .. tostring(data.subType) .. " quality=" .. tostring(data.quality))
                        -- Show both the raw GetItemInfo reqLevel and the
                        -- tooltip reqLevel (they can differ on Ascension
                        -- for scaled items; the tooltip is authoritative).
                        local rawReq = select(5, GetItemInfo(link))
                        local tooltipReq = AutoCore.GetTooltipReqLevel(link)
                        print("  reqLevel(GetItemInfo)=" .. tostring(rawReq) .. " reqLevel(tooltip)=" .. tostring(tooltipReq) .. " (using " .. tostring(data.reqLevel) .. ")")
                        print("  vendorPrice=" .. tostring(data.vendorPrice) .. " equipSlot=" .. tostring(data.equipSlot))
                        print("  bound=" .. tostring(boundStatus) .. " usable=" .. tostring(usable))

                        local shouldSell = false
                        local verdict = nil

                        -- 1. Active quest item?
                        if AutoCore.IsActiveQuestItem(data.id) then
                            verdict = "ACTIVE QUEST ITEM - protected (won't sell)"
                        -- 2. Best PvP set item?
                        elseif AutoUpgrade and AutoUpgrade.IsBestPvPSetItem
                            and AutoUpgrade.IsBestPvPSetItem(link, { link = link, bag = bag, slot = slot })
                        then
                            verdict = "BEST PVP SET - protected for its equipment slot"
                        -- 3. Strategic weapon bench item?
                        elseif (not config or config.protectWeaponBench ~= false)
                            and AutoUpgrade and AutoUpgrade.IsWeaponBenchItem
                            and AutoUpgrade.IsWeaponBenchItem(link, { link = link, bag = bag, slot = slot })
                        then
                            verdict = "WEAPON BENCH CANDIDATE - protected for a future weapon set"
                        -- 4. No vendor price?
                        elseif not data.vendorPrice or data.vendorPrice <= 0 then
                            verdict = "no vendor price (can't be sold)"
                        -- 5. No config loaded?
                        elseif not config then
                            verdict = "AutoSellConfig not loaded"
                        -- 6. Above the global safety ceiling?
                        elseif config.maxQuality ~= nil
                            and (data.quality == nil or data.quality > config.maxQuality)
                        then
                            verdict = "quality " .. tostring(data.quality)
                                .. " is above maxQuality " .. tostring(config.maxQuality) .. " - protected"
                        else
                            local MatchEntry = CreateItemMatcher(
                                data, boundStatus, usable, playerLevel,
                                { link = link, bag = bag, slot = slot }, true
                            )
                            local function PrintUnsupported(label, entry, extraSupported)
                                local unknown = AutoCore.GetUnsupportedEntryFields(entry, extraSupported)
                                if #unknown > 0 then
                                    print("  |cffffcc00WARNING:|r " .. label .. " has unsupported field(s): " .. table.concat(unknown, ", "))
                                end
                            end

                            -- 7. neverSell entries (print EVERY one)
                            local neverHit = false
                            if config.never then
                                for i, entry in ipairs(config.never) do
                                    local m, why = AutoCore.EntryMatchDebug(entry, data, boundStatus, usable, playerLevel)
                                    PrintUnsupported("neverSell " .. i, entry)
                                    local status
                                    if m then
                                        status = "MATCH"
                                        neverHit = true
                                    else
                                        status = "no (" .. (why or "?") .. ")"
                                    end
                                    print(string.format("  neverSell %d %s: %s", i, AutoCore.FormatEntry(entry), status))
                                end
                            end
                            if neverHit then
                                verdict = "in neverSell list - protected"
                            else
                                -- 8. Rules (print EVERY one)
                                local matchedRule = nil
                                if config.rules then
                                    for i, rule in ipairs(config.rules) do
                                        local exceptionMatch = false
                                        if rule.exceptions then
                                            for exceptionIndex, exc in ipairs(rule.exceptions) do
                                                local m, why, unsupported = MatchEntry(exc)
                                                if #unsupported > 0 then
                                                    print("  |cffffcc00WARNING:|r Rule " .. i .. " exception " .. exceptionIndex
                                                        .. " has unsupported field(s): " .. table.concat(unsupported, ", "))
                                                end
                                                if m then
                                                    exceptionMatch = true
                                                    break
                                                end
                                            end
                                        end
                                        local status
                                        if exceptionMatch then
                                            status = "SKIPPED (exception matched)"
                                        else
                                            local m, why, unsupported = MatchEntry(rule)
                                            if #unsupported > 0 then
                                                print("  |cffffcc00WARNING:|r Rule " .. i .. " has unsupported field(s): "
                                                    .. table.concat(unsupported, ", "))
                                            end
                                            if m then
                                                status = "MATCH"
                                                if not matchedRule then
                                                    matchedRule = rule
                                                end
                                            else
                                                status = "no (" .. (why or "?") .. ")"
                                            end
                                        end
                                        print(string.format("  Rule %d %s: %s", i, AutoCore.FormatEntry(rule), status))
                                    end
                                end
                                if matchedRule then
                                    shouldSell = true
                                    verdict = "MATCHES rule " .. AutoCore.FormatEntry(matchedRule)
                                else
                                    verdict = "kept - no rule matched (see rule lines above)"
                                end
                            end
                        end

                        if shouldSell then
                            soldCount = soldCount + 1
                            print("  => |cff00ff00SOLD|r (" .. (verdict or "no reason") .. ")")
                        else
                            keptCount = keptCount + 1
                            print("  => |cffff0000KEPT|r (" .. (verdict or "no reason") .. ")")
                        end
                    end
                end
            end
        end

        print("|cff00ff00AutoSell Debug:|r Scanned " .. itemCount .. " item(s): " .. soldCount .. " would sell, " .. keptCount .. " kept.")
        if itemCount == 0 then
            print("|cff00ff00AutoSell:|r No items found in bags.")
        end
    else
        if AS.db.enabled then
            print("|cff00ff00AutoSell:|r Auto-sell enabled.")
        else
            print("|cff00ff00AutoSell:|r Auto-sell disabled.")
        end
        print("|cff00ff00AutoSell:|r Commands:")
        print("  /autosell on    - Enable auto-sell")
        print("  /autosell off   - Disable auto-sell")
        print("  /autosell sell  - Sell matching items now (merchant open)")
        print("  /autosell repair - Repair all items now (merchant open)")
        print("  /autosell test   - Dry run: show what would be sold")
        print("  /autosell whoami - Show which config profile this character is using")
        print("  /autosell debug  - Debug: scan all bag items, show WHY each is sold/kept")
    end
end
