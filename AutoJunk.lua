----------------------------------------------------------------------
-- AutoJunk.lua
-- ============
-- Deletes items selected by profile-owned filter rules, either immediately or
-- only as needed to maintain free normal-bag space. A configurable quality
-- ceiling provides an independent destructive safety limit. Candidates are
-- ordered by total vendor value, and only this module's DELETE_ITEM popup is
-- confirmed.
----------------------------------------------------------------------

local addonName = "AutoEverything"
local config = AutoJunkConfig or {}

AutoJunk = AutoJunk or {}
local AJ = AutoJunk

-- Placeholder until ApplyProfile() points this at the character's
-- profile section once saved variables are available.
AJ.db = {}

local eventFrame = CreateFrame("Frame")
local elapsedSinceSchedule = nil
local pendingDelete = nil
local popupAttempts = 0

local function ApplyDefaults()
    if AJ.db.enabled == nil then
        AJ.db.enabled = config.enabled == true
    end
    if AJ.db.targetFreeSlots == nil then
        AJ.db.targetFreeSlots = tonumber(config.targetFreeSlots) or 3
    end
end

function AJ.ApplyProfile()
    if AutoCore and AutoCore.GetProfileSection then
        AJ.db = AutoCore.GetProfileSection("junk", true)
    end
    ApplyDefaults()
end

local activeConfig = nil
local function GetActiveConfig()
    if not activeConfig then
        -- AutoJunkConfig has no neverSell-style list; pass a key that will
        -- never be present so Core.BuildActiveConfig's "never" comes back
        -- empty. "deleteMode" is AutoJunk-specific and not part of the
        -- shared shape, so it's requested as an extra passthrough key.
        activeConfig = AutoCore.BuildActiveConfig(config, "neverDelete", { "deleteMode" })
        activeConfig.deleteMode = activeConfig.deleteMode or "target"
        activeConfig.maxQuality = activeConfig.maxQuality or 0
    end
    return activeConfig
end

function AJ.ClearConfigCache()
    activeConfig = nil
end

local function GetTargetFreeSlots()
    local target = math.floor(tonumber(AJ.db.targetFreeSlots) or 3)
    if target < 0 then target = 0 end
    return target
end

local function GetNormalBagFreeSlots()
    local freeSlots = 0
    for bag = 0, 4 do
        local free, bagType = GetContainerNumFreeSlots(bag)
        -- A zero bag family is a normal bag. Specialty-bag space cannot hold
        -- arbitrary loot, so it must not make the inventory look less full.
        if bagType == 0 or bagType == nil then
            freeSlots = freeSlots + (free or 0)
        end
    end
    return freeSlots
end

local function FindDeletePopup()
    for i = 1, (STATICPOPUP_NUMDIALOGS or 4) do
        local popup = _G["StaticPopup" .. i]
        if popup and popup:IsShown() and popup.which == "DELETE_ITEM" then
            return popup
        end
    end
    return nil
end

local function Schedule(delay)
    delay = delay or 0.25
    if elapsedSinceSchedule == nil or delay < elapsedSinceSchedule then
        elapsedSinceSchedule = delay
    end
end

-- Unlike Schedule(), this always resets the wait to the full delay. Used for
-- the BAG_UPDATE/MERCHANT_CLOSED debounce so a burst of events (e.g. looting
-- several items at once) keeps pushing the process-run back until the bag
-- state has settled, instead of firing partway through the burst.
local function Debounce(delay)
    delay = delay or 0.25
    elapsedSinceSchedule = delay
end

-- Called by Core after a settings/profile change so AutoJunk does not have to
-- wait for an unrelated BAG_UPDATE before noticing its new state.
function AJ.RefreshAfterSettingsChange()
    Schedule(0)
end

local function RuleMatches(rule, data, boundStatus, usable, playerLevel)
    -- Invalid exceptions fail closed: a malformed intended protection must
    -- never broaden a destructive junk rule.
    for _, exception in ipairs(rule.exceptions or {}) do
        local matched, why = AutoCore.EntryMatchDebug(exception, data, boundStatus, usable, playerLevel)
        local unsupported = AutoCore.GetUnsupportedEntryFields(exception)
        if matched or #unsupported > 0 or why == "entry has no supported filter fields" then return false end
    end
    local unsupported = AutoCore.GetUnsupportedEntryFields(rule)
    return #unsupported == 0 and AutoCore.EntryMatches(rule, data, boundStatus, usable, playerLevel)
end

local function FindCheapestJunk()
    local cfg = GetActiveConfig()
    local candidates = {}
    local order = 0
    local playerLevel = UnitLevel("player")

    for bag = 0, 4 do
        for slot = 1, GetContainerNumSlots(bag) do
            local texture, count, locked, quality, readable, lootable, link = GetContainerItemInfo(bag, slot)
            if texture and link and not locked
                and quality ~= nil and quality <= (cfg.maxQuality or 0)
            then
                local data = AutoCore.GetItemData(link, { bag = bag, slot = slot })
                if data and not AutoCore.IsActiveQuestItem(data.id) then
                    local guid = GetContainerItemGUID and GetContainerItemGUID(bag, slot) or nil
                    local boundStatus, usable = AutoCore.ScanTooltip(link, guid, { bag = bag, slot = slot })
                    local matched = false
                    for _, rule in ipairs(cfg.rules or {}) do
                        if RuleMatches(rule, data, boundStatus, usable, playerLevel) then matched = true; break end
                    end
                    if matched then
                        order = order + 1
                        count = count or 1
                        local vendorPrice = data.vendorPrice or 0
                        table.insert(candidates, {
                            bag = bag, slot = slot, link = link,
                            name = data.name or link, count = count,
                            totalValue = vendorPrice * count, order = order,
                        })
                    end
                end
            end
        end
    end

    table.sort(candidates, function(a, b)
        if a.totalValue == b.totalValue then return a.order < b.order end
        return a.totalValue < b.totalValue
    end)
    return candidates[1]
end

local function FinishPendingDelete()
    local popup = FindDeletePopup()
    if popup then
        local confirmButton = _G[popup:GetName() .. "Button1"]
        if confirmButton and confirmButton:IsEnabled() then
            confirmButton:Click()
            if pendingDelete and AutoCore.SessionAdd then AutoCore.SessionAdd("junk", pendingDelete.count or 1) end
            if AutoCore.GetSetting("junk", "printMessages", config.printMessages) ~= false and pendingDelete then
                print("|cff00ff00AutoJunk:|r Deleted " .. pendingDelete.name .. " x" .. pendingDelete.count
                    .. " (vendor value " .. GetCoinTextureString(pendingDelete.totalValue) .. ").")
            end
            pendingDelete = nil
            popupAttempts = 0
            Schedule(0.25)
            return
        end
    end

    -- Poor items may be deleted immediately without a confirmation popup.
    if not CursorHasItem() then
        if pendingDelete and AutoCore.SessionAdd then AutoCore.SessionAdd("junk", pendingDelete.count or 1) end
        if AutoCore.GetSetting("junk", "printMessages", config.printMessages) ~= false and pendingDelete then
            print("|cff00ff00AutoJunk:|r Deleted " .. pendingDelete.name .. " x" .. pendingDelete.count
                .. " (vendor value " .. GetCoinTextureString(pendingDelete.totalValue) .. ").")
        end
        pendingDelete = nil
        popupAttempts = 0
        Schedule(0.25)
        return
    end

    popupAttempts = popupAttempts + 1
    if popupAttempts >= 10 then
        if pendingDelete and CursorHasItem() then
            PickupContainerItem(pendingDelete.bag, pendingDelete.slot)
        end
        AutoCore.Warn("Junk", "Could not confirm the item deletion; the item was returned to its bag slot.")
        pendingDelete = nil
        popupAttempts = 0
        return
    end
    Schedule(0.1)
end

function AJ.Process()
    if pendingDelete then
        FinishPendingDelete()
        return
    end

    local cfg = GetActiveConfig()
    if not AJ.db.enabled or not cfg or not cfg.enabled then return end
    if cfg.deleteMode ~= "immediate" and GetNormalBagFreeSlots() >= GetTargetFreeSlots() then return end
    if CursorHasItem() then return end

    -- Let AutoSell turn junk into money while a vendor is open instead of
    -- destroying it to satisfy the same free-slot target.
    if MerchantFrame and MerchantFrame:IsShown() then return end

    AutoCore.RebuildQuestItems()
    local candidate = FindCheapestJunk()
    if not candidate then return end

    if GetContainerItemLink(candidate.bag, candidate.slot) ~= candidate.link then
        Schedule(0.25)
        return
    end

    local pickedUp = pcall(PickupContainerItem, candidate.bag, candidate.slot)
    if not pickedUp or not CursorHasItem() then
        if CursorHasItem() then ClearCursor() end
        Schedule(0.25); return
    end

    pendingDelete = candidate
    popupAttempts = 0
    local deleted = pcall(DeleteCursorItem)
    if not deleted then
        AutoCore.Warn("Junk", "DeleteCursorItem failed unexpectedly.")
        if CursorHasItem() then pcall(PickupContainerItem, candidate.bag, candidate.slot) end
        pendingDelete = nil
        return
    end
    Schedule(0)
end

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("BAG_UPDATE")
eventFrame:RegisterEvent("MERCHANT_CLOSED")
eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if (...) ~= addonName then return end
        AJ.ApplyProfile()
        self:UnregisterEvent("ADDON_LOADED")
        AutoCore.Debug("Junk", "Saved state loaded.")
    else
        Debounce(0.35)
    end
end)

eventFrame:SetScript("OnUpdate", function(_, elapsed)
    if elapsedSinceSchedule == nil then return end
    elapsedSinceSchedule = elapsedSinceSchedule - elapsed
    if elapsedSinceSchedule <= 0 then
        elapsedSinceSchedule = nil
        AJ.Process()
    end
end)

SLASH_AUTOJUNK1 = "/autojunk"
SLASH_AUTOJUNK2 = "/aj"
SlashCmdList["AUTOJUNK"] = function(msg)
    msg = string.lower(strtrim(msg or ""))
    local slots = msg:match("^slots%s+(%d+)$")

    if msg == "on" then
        AJ.db.enabled = true
        AutoCore.NotifyProfileChanged("junk")
        print("|cff00ff00AutoJunk:|r Enabled; maintaining " .. GetTargetFreeSlots() .. " free slot(s).")
        Schedule(0)
    elseif msg == "off" then
        AJ.db.enabled = false
        AutoCore.NotifyProfileChanged("junk")
        print("|cff00ff00AutoJunk:|r Disabled.")
    elseif slots then
        AJ.db.targetFreeSlots = tonumber(slots)
        AutoCore.NotifyProfileChanged("junk")
        print("|cff00ff00AutoJunk:|r Free-slot target set to " .. GetTargetFreeSlots() .. ".")
        Schedule(0)
    elseif msg == "run" then
        AJ.Process()
    elseif msg == "debug" then
        local freeSlots = GetNormalBagFreeSlots()
        local candidate = FindCheapestJunk()
        print("|cff00ff00AutoJunk Debug:|r enabled=" .. tostring(AJ.db.enabled)
            .. ", freeSlots=" .. tostring(freeSlots)
            .. ", target=" .. tostring(GetTargetFreeSlots())
            .. ", merchantOpen=" .. tostring(MerchantFrame and MerchantFrame:IsShown() or false)
            .. ", cursorBusy=" .. tostring(CursorHasItem() and true or false))
        if candidate then
            print("  Candidate: " .. tostring(candidate.link) .. " x" .. tostring(candidate.count)
                .. " in bag " .. tostring(candidate.bag) .. ", slot " .. tostring(candidate.slot))
        else
            print("  Candidate: none (no unlocked, non-quest item matches the enabled rules and quality ceiling)")
        end
        local cfg = GetActiveConfig()
        print("  Mode=" .. tostring(cfg.deleteMode) .. ", maxQuality=" .. tostring(cfg.maxQuality)
            .. ", activeRules=" .. tostring(#(cfg.rules or {})))
        if cfg.deleteMode ~= "immediate" and freeSlots >= GetTargetFreeSlots() then
            print("  No deletion needed: the configured free-slot target is already satisfied.")
        elseif MerchantFrame and MerchantFrame:IsShown() then
            print("  Paused while a merchant is open so junk can be sold instead of destroyed.")
        end
    else
        local cfg = GetActiveConfig()
        local behavior = cfg.deleteMode == "immediate"
            and "deleting matching items immediately"
            or ("maintaining " .. GetTargetFreeSlots() .. " free slot(s)")
        print("|cff00ff00AutoJunk:|r " .. (AJ.db.enabled and "Enabled" or "Disabled")
            .. "; " .. behavior .. "; " .. #(cfg.rules or {}) .. " active rule(s).")
        print("  /autojunk on|off     - Enable or disable automatic junk deletion")
        print("  /autojunk slots <N>  - Set the number of free slots to maintain")
        print("  /autojunk run        - Check bag space now")
        print("  /autojunk debug      - Explain why an item is or is not being deleted")
    end
end
