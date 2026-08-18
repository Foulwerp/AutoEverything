----------------------------------------------------------------------
-- AutoLoot.lua
-- ============
-- Fast-loots selected corpse items the instant the loot window opens. An
-- AutoLoot rule is an allow-list entry: matching items are taken and unmatched
-- items stay on the corpse. Money and currency are always taken. Rules reuse
-- the shared matcher, so the same conditions (quality, itemID, type, name, bind
-- status, ...) available to AutoJunk/AutoSell work here too.
--
-- The module can manage Blizzard's auto-loot CVars so the loot window opens and
-- this allow-list remains authoritative. WoW 3.3.5a compatible.
----------------------------------------------------------------------

local addonName = "AutoEverything"
local config = AutoLootConfig or {}

AutoLoot = AutoLoot or {}
local AL = AutoLoot

-- Placeholder until ApplyProfile() points this at the character's profile
-- section once saved variables are available.
AL.db = {}

local eventFrame = CreateFrame("Frame")
local managedBlizzardAutoLoot = false
local managedAutoLootKey = false

local function ApplyDefaults()
    if AL.db.enabled == nil then
        AL.db.enabled = config.enabled == true
    end
    if AL.db.fasterLooting == nil then
        AL.db.fasterLooting = config.fasterLooting == true
    end
    if AL.db.disableBlizzardAutoLoot == nil then
        AL.db.disableBlizzardAutoLoot = config.disableBlizzardAutoLoot == true
    end
    if AL.db.disableAutoLootKey == nil then
        AL.db.disableAutoLootKey = config.disableAutoLootKey == true
    end
    if AL.db.disableOnShift == nil then
        AL.db.disableOnShift = config.disableOnShift ~= false
    end
end

local function MigrateLeaveBehindRules()
    if AL.db.ruleSemanticsVersion == 2 then return end
    -- Old rules meant "leave this item behind", which cannot be safely
    -- reinterpreted as an allow-list. Preserve them for recovery/export, then
    -- start the new list empty rather than accidentally looting protected gear.
    if type(AL.db.rules) == "table" and #AL.db.rules > 0 then
        AL.db.legacyLeaveBehindRules = AutoCore.DeepCopy(AL.db.rules)
        AL.db.legacyDisabledLeaveBehindRules = AutoCore.DeepCopy(AL.db.disabledProfileRules or {})
        print("|cffffcc00AutoLoot:|r Saved the old leave-behind rules and started a new items-to-loot list.")
    end
    AL.db.rules = {}
    AL.db.disabledProfileRules = {}
    AL.db.ruleSemanticsVersion = 2
end

function AL.ApplyCVars()
    if not SetCVar then return end
    if AL.db.disableBlizzardAutoLoot then
        pcall(SetCVar, "autoLootDefault", "0")
        managedBlizzardAutoLoot = true
    elseif managedBlizzardAutoLoot then
        pcall(SetCVar, "autoLootDefault", "1")
        managedBlizzardAutoLoot = false
    end
    if AL.db.disableAutoLootKey then
        pcall(SetCVar, "autoLootKey", "NONE")
        managedAutoLootKey = true
    elseif managedAutoLootKey then
        pcall(SetCVar, "autoLootKey", "SHIFT")
        managedAutoLootKey = false
    end
end

function AL.ApplyProfile()
    if AutoCore and AutoCore.GetProfileSection then
        AL.db = AutoCore.GetProfileSection("loot", true)
    end
    ApplyDefaults()
    MigrateLeaveBehindRules()
    AL.ApplyCVars()
end

local activeConfig = nil
local function GetActiveConfig()
    if not activeConfig then
        -- Runtime toggles are read directly from AL.db; request fasterLooting
        -- alongside the merged rule list for callers that inspect the config.
        activeConfig = AutoCore.BuildActiveConfig(config, { "fasterLooting" })
    end
    return activeConfig
end

function AL.ClearConfigCache()
    activeConfig = nil
end

local function RuleMatches(rule, data, boundStatus, usable, playerLevel)
    -- Invalid exceptions fail closed, matching AutoJunk/AutoSell: a malformed
    -- rule must never cause an item to be looted by accident.
    for _, exception in ipairs(rule.exceptions or {}) do
        local matched, why = AutoCore.EntryMatchDebug(exception, data, boundStatus, usable, playerLevel)
        local unsupported = AutoCore.GetUnsupportedEntryFields(exception)
        if matched or #unsupported > 0 or why == "entry has no supported filter fields" then return false end
    end
    local unsupported = AutoCore.GetUnsupportedEntryFields(rule)
    return #unsupported == 0 and AutoCore.EntryMatches(rule, data, boundStatus, usable, playerLevel)
end

-- True when any active allow-list rule says to loot this item.
local function ShouldLoot(link)
    if not link then return false end
    local cfg = GetActiveConfig()
    if not cfg or #(cfg.rules or {}) == 0 then return false end
    local data = AutoCore.GetItemData(link)
    if not data then return false end
    local playerLevel = UnitLevel("player")
    -- Loot slots have no bag location; scan the link alone for bind/usable.
    local boundStatus, usable = AutoCore.ScanTooltip(link)
    for _, rule in ipairs(cfg.rules) do
        if RuleMatches(rule, data, boundStatus, usable, playerLevel) then return true end
    end
    return false
end

function AL.Process()
    -- enabled/fasterLooting/printMessages are read from the live profile
    -- section (AL.db) so a settings toggle takes effect immediately; only the
    -- rule list is taken from the cached active config (its edits notify).
    if not AL.db.enabled or AL.db.fasterLooting == false then return end
    if AL.db.disableOnShift and IsShiftKeyDown and IsShiftKeyDown() then return end

    local numItems = GetNumLootItems and GetNumLootItems() or 0
    if numItems == 0 then return end

    local skipped = 0
    -- Loot from the last slot down: looting a slot shifts the ones after it.
    for i = numItems, 1, -1 do
        local slotType = (GetLootSlotType and GetLootSlotType(i)) or LOOT_SLOT_ITEM
        if slotType ~= LOOT_SLOT_ITEM then
            -- Money and currency slots have no item link; always take them.
            pcall(LootSlot, i)
        else
            local link = GetLootSlotLink and GetLootSlotLink(i) or nil
            if ShouldLoot(link) then
                pcall(LootSlot, i)
            else
                skipped = skipped + 1
            end
        end
    end

    if skipped > 0 and AL.db.printMessages then
        print("|cff00ff00AutoLoot:|r Left " .. skipped .. " unmatched item(s) on the corpse.")
    end
end

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("LOOT_OPENED")
eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if (...) ~= addonName then return end
        AL.ApplyProfile()
        self:UnregisterEvent("ADDON_LOADED")
        AutoCore.Debug("Loot", "Saved state loaded.")
    elseif event == "LOOT_OPENED" then
        AL.Process()
    end
end)

SLASH_AUTOLOOT1 = "/autoloot"
SLASH_AUTOLOOT2 = "/al"
SlashCmdList["AUTOLOOT"] = function(msg)
    msg = string.lower(strtrim(msg or ""))

    if msg == "on" then
        AL.db.enabled = true
        AutoCore.NotifyProfileChanged("loot")
        print("|cff00ff00AutoLoot:|r Enabled.")
    elseif msg == "off" then
        AL.db.enabled = false
        AutoCore.NotifyProfileChanged("loot")
        print("|cff00ff00AutoLoot:|r Disabled.")
    elseif msg == "faster" then
        AL.db.fasterLooting = not (AL.db.fasterLooting ~= false)
        AutoCore.NotifyProfileChanged("loot")
        print("|cff00ff00AutoLoot:|r Faster looting " .. (AL.db.fasterLooting and "enabled." or "disabled."))
    elseif msg == "debug" then
        local cfg = GetActiveConfig()
        print("|cff00ff00AutoLoot Debug:|r enabled=" .. tostring(AL.db.enabled)
            .. ", fasterLooting=" .. tostring(cfg and cfg.fasterLooting ~= false)
            .. ", activeRules=" .. tostring(#((cfg and cfg.rules) or {}))
            .. ", lootOpen=" .. tostring((GetNumLootItems and GetNumLootItems() or 0) > 0))
        if GetNumLootItems and GetNumLootItems() > 0 then
            for i = 1, GetNumLootItems() do
                local slotType = (GetLootSlotType and GetLootSlotType(i)) or LOOT_SLOT_ITEM
                if slotType == LOOT_SLOT_ITEM then
                    local link = GetLootSlotLink and GetLootSlotLink(i) or nil
                    print("  Slot " .. i .. ": " .. tostring(link)
                        .. (ShouldLoot(link) and " |cff40ff40(loot)|r" or " |cffff4040(not listed)|r"))
                else
                    print("  Slot " .. i .. ": money/currency |cff40ff40(loot)|r")
                end
            end
        end
    else
        local cfg = GetActiveConfig()
        print("|cff00ff00AutoLoot:|r " .. (AL.db.enabled and "Enabled" or "Disabled")
            .. "; faster looting " .. ((cfg and cfg.fasterLooting ~= false) and "on" or "off")
            .. "; " .. #((cfg and cfg.rules) or {}) .. " items-to-loot rule(s).")
        print("  /autoloot on|off  - Enable or disable automatic looting")
        print("  /autoloot faster  - Toggle instant looting")
        print("  /autoloot debug   - Show what would be looted or skipped right now")
    end
end
