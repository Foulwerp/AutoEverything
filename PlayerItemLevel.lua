----------------------------------------------------------------------
-- PlayerItemLevel.lua - average equipped item level in unit tooltips.
--
-- Ascension backports several generations of Blizzard item-level APIs, but
-- their behavior is not documented consistently. Prefer the client's unit
-- value because it includes Ascension-specific effective item levels, then
-- calculate from equipped links as a guarded fallback.
----------------------------------------------------------------------

local Core = AutoCore
if not Core then return end

local SLOT_IDS = { 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18 }
local BASE_SLOT_COUNT = 15
local CACHE_SECONDS = 300
local INSPECT_DELAY = 1
local cache = {}
local pendingUnit, pendingGUID, pendingReady, pendingExpires
local roleUnit, roleGUID, roleAt
local nextInspectAt = 0
local elapsedSincePoll = 0
local inspectionConsumerUntil = 0

Core.PlayerInspection = Core.PlayerInspection or {}
local Inspection = Core.PlayerInspection

local ROLE_STATS = {
    Strength = 1, Agility = 1, Stamina = 1, Intellect = 1, Spirit = 1,
    ["Critical Strike Rating"] = 1, ["Hit Rating"] = 1, ["Haste Rating"] = 1,
    ["Weapon DPS"] = 1, ["Ranged DPS"] = 1, ["Attack Power"] = 1,
    ["Ranged Attack Power"] = 1, ["Spell Power"] = 1, ["Spell Damage"] = 1,
    ["Healing Power"] = 1, ["Armor Penetration Rating"] = 1,
    ["Spell Penetration"] = 1, ["Expertise Rating"] = 1, Armor = 1,
    ["Defense Rating"] = 1, ["Dodge Rating"] = 1, ["Parry Rating"] = 1,
    ["Block Rating"] = 1, ["Block Value"] = 1, ["Shield Block"] = 1,
}

local function Enabled()
    return Core.GetSetting("core", "showPlayerItemLevel",
        (AutoCoreConfig or {}).showPlayerItemLevel ~= false) ~= false
end

local function PositiveNumber(value)
    value = tonumber(value)
    if value and value > 0 then return value end
    return nil
end

local function NativeItemLevel(unit)
    local isPlayer = unit == "player" or (UnitIsUnit and UnitIsUnit(unit, "player"))
    if UnitAverageItemLevel then
        local ok, value = pcall(UnitAverageItemLevel, unit)
        value = ok and PositiveNumber(value) or nil
        if value then return value end
    end
    if isPlayer and GetAverageItemLevel then
        -- Blizzard returns overall and equipped averages in that order on
        -- clients that expose both. Prefer the equipped (second) result.
        local ok, average, equipped = pcall(GetAverageItemLevel)
        if ok then
            local value = PositiveNumber(equipped) or PositiveNumber(average)
            if value then return value end
        end
    end
    if isPlayer and C_Player and C_Player.GetAverageItemLevel then
        local ok, value = pcall(C_Player.GetAverageItemLevel, C_Player)
        value = ok and PositiveNumber(value) or nil
        if value then return value end
    end
    return nil
end

local function CalculatedEquippedItemLevel(unit)
    if not unit or not UnitExists(unit) then return nil end

    local total = 0
    local slotCount = BASE_SLOT_COUNT
    for _, slotID in ipairs(SLOT_IDS) do
        local link = GetInventoryItemLink(unit, slotID)
        if link then
            local itemLevel = select(4, GetItemInfo(link))
            if not itemLevel then return nil end
            total = total + itemLevel
            -- The 15 armor/main-hand slots always count. Off-hand and ranged
            -- count only when occupied, matching C_Player:GetAverageItemLevel.
            if slotID == 17 or slotID == 18 then slotCount = slotCount + 1 end
        end
    end

    if total <= 0 then return nil end
    return total / slotCount
end

local function EquippedItemLevel(unit)
    if not unit or not UnitExists(unit) then return nil end
    return NativeItemLevel(unit) or CalculatedEquippedItemLevel(unit)
end

local function AddStats(total, source)
    for stat, value in pairs(source or {}) do
        if type(value) == "number" then total[stat] = (total[stat] or 0) + value end
    end
end

local function InferGearRole(unit)
    if not unit or not UnitExists(unit) then return nil end
    local stats, itemCount, hasShield = {}, 0, false
    for _, slotID in ipairs(SLOT_IDS) do
        local link = GetInventoryItemLink(unit, slotID)
        if link then
            if not GetItemInfo(link) then return nil end
            itemCount = itemCount + 1
            AddStats(stats, Core.GetItemStats(link, ROLE_STATS, nil))
            if slotID == 17 and select(7, GetItemInfo(link)) == "Shields" then hasShield = true end
        end
    end
    if itemCount < 4 then return nil end

    local defensive = (stats["Defense Rating"] or 0) * 4
        + (stats["Dodge Rating"] or 0) * 3
        + (stats["Parry Rating"] or 0) * 3
        + (stats["Block Rating"] or 0) * 3
        + (stats["Block Value"] or 0) * 0.15
        + (stats["Shield Block"] or 0) * 3
        + (hasShield and 80 or 0)
    local caster = (stats["Spell Power"] or 0)
        + (stats["Spell Damage"] or 0)
        + (stats.Intellect or 0) * 1.4
        + (stats.Spirit or 0) * 0.5
        + (stats["Spell Penetration"] or 0) * 0.5
    local healer = (stats["Healing Power"] or 0) * 1.2
        + (stats["Spell Power"] or 0) * 0.8
        + (stats.Intellect or 0) * 1.2
        + (stats.Spirit or 0)
    local physical = (stats["Attack Power"] or 0) * 0.5
        + (stats["Ranged Attack Power"] or 0) * 0.45
        + (stats.Strength or 0) * 2
        + (stats.Agility or 0) * 1.5
        + (stats["Weapon DPS"] or 0) * 4
        + (stats["Ranged DPS"] or 0) * 4
        + (stats["Expertise Rating"] or 0) * 1.5
        + (stats["Armor Penetration Rating"] or 0)
    if defensive <= 0 and caster <= 0 and healer <= 0 and physical <= 0
        and (stats.Stamina or 0) <= 0 then
        return nil, stats
    end

    -- Generic hit/crit exists on both physical and spell gear, so it is not
    -- used as a primary signal. Defensive ratings and shields win decisively;
    -- healing is only chosen when explicit healing power is present.
    local role
    if defensive >= 40 and defensive >= math.max(caster, physical) * 0.30 then
        role = "tank"
    elseif (stats["Healing Power"] or 0) > 0 and healer > math.max(caster, physical) * 1.10 then
        role = "healer"
    elseif caster > physical then
        role = "caster"
    else
        role = "melee"
    end
    return role, stats, { tank = defensive, caster = caster, healer = healer, melee = physical }
end

local function TooltipUnitGUID(tooltip)
    if not tooltip or not tooltip.GetUnit then return nil end
    local _, unit = tooltip:GetUnit()
    if not unit or not UnitExists(unit) or not UnitIsPlayer(unit) then return nil end
    return UnitGUID(unit), unit
end

local function SetTooltipValue(tooltip, guid, value)
    if not tooltip or tooltip.__aeItemLevelGUID ~= guid then return end
    local line = tooltip.__aeItemLevelLine
    local right = line and _G[tooltip:GetName() .. "TextRight" .. line]
    if right then
        right:SetText(value)
        tooltip:Show()
    end
end

local function StoreItemLevel(guid, value)
    if not guid or not value then return end
    local entry = cache[guid] or {}
    entry.value = value
    entry.time = GetTime()
    cache[guid] = entry
    SetTooltipValue(GameTooltip, guid, string.format("%.2f", value))
end

local function StoreRole(guid, role, stats, scores)
    if not guid then return end
    local entry = cache[guid]
    if not entry then return end
    local previousRole = entry.role
    entry.role, entry.stats, entry.scores = role, stats, scores
    if previousRole ~= role and AutoBuff and AutoBuff.OnInspectionUpdated then AutoBuff.OnInspectionUpdated(guid, role) end
end

local inspectFrame = CreateFrame("Frame")
inspectFrame:RegisterEvent("INSPECT_TALENT_READY")
inspectFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
inspectFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_EQUIPMENT_CHANGED" then
        local guid = UnitGUID("player")
        if guid then cache[guid] = nil end
        if AutoBuff and AutoBuff.OnInspectionUpdated then AutoBuff.OnInspectionUpdated(guid, nil) end
        return
    end
    if pendingGUID then pendingReady = true end
end)

local function BeginInspect(unit, guid)
    if not NotifyInspect or not CanInspect or not CanInspect(unit, false) then return false end
    NotifyInspect(unit)
    pendingUnit, pendingGUID, pendingReady = unit, guid, false
    pendingExpires = GetTime() + 3
    nextInspectAt = GetTime() + INSPECT_DELAY
    inspectionConsumerUntil = GetTime() + 6
    return true
end

local function FreshEntry(guid)
    local entry = guid and cache[guid]
    if entry and GetTime() - entry.time <= CACHE_SECONDS then return entry end
    return nil
end

function Inspection.GetItemLevel(unit)
    return EquippedItemLevel(unit)
end

function Inspection.Get(unit)
    if not unit or not UnitExists(unit) then return nil end
    local guid = UnitGUID(unit)
    if UnitIsUnit and UnitIsUnit(unit, "player") then
        local value = EquippedItemLevel(unit)
        local role, stats, scores = InferGearRole(unit)
        if value then
            StoreItemLevel(guid, value)
            StoreRole(guid, role, stats, scores)
        end
    end
    return FreshEntry(guid)
end

function Inspection.Request(unit)
    local entry = Inspection.Get(unit)
    if entry and entry.role then return entry end
    if entry and GetTime() - entry.time <= 2 then return entry end
    local guid = unit and UnitGUID(unit)
    if guid and not pendingGUID and GetTime() >= nextInspectAt then BeginInspect(unit, guid) end
    return nil
end

inspectFrame:SetScript("OnUpdate", function(_, elapsed)
    if not Enabled() and GetTime() > inspectionConsumerUntil then
        pendingUnit, pendingGUID, pendingReady, pendingExpires = nil, nil, nil, nil
        return
    end

    elapsedSincePoll = elapsedSincePoll + elapsed
    if elapsedSincePoll < 0.1 then return end
    elapsedSincePoll = 0

    local tooltipGUID, tooltipUnit = TooltipUnitGUID(GameTooltip)
    if roleGUID and roleAt and GetTime() >= roleAt then
        if roleUnit and UnitExists(roleUnit) and UnitGUID(roleUnit) == roleGUID then
            local role, stats, scores = InferGearRole(roleUnit)
            StoreRole(roleGUID, role, stats, scores)
        end
        roleUnit, roleGUID, roleAt = nil, nil, nil
    end

    if pendingGUID and pendingExpires and GetTime() >= pendingExpires then
        pendingUnit, pendingGUID, pendingReady, pendingExpires = nil, nil, nil, nil
    elseif pendingGUID and pendingReady then
        if pendingUnit and UnitExists(pendingUnit) and UnitGUID(pendingUnit) == pendingGUID then
            local value = EquippedItemLevel(pendingUnit)
            if value then
                -- Publish the inexpensive item-level result first. Role
                -- inference scans every equipped-item tooltip and can wait a
                -- frame without making the visible player tooltip feel slow.
                StoreItemLevel(pendingGUID, value)
                roleUnit, roleGUID, roleAt = pendingUnit, pendingGUID, GetTime() + 0.01
                pendingUnit, pendingGUID, pendingReady, pendingExpires = nil, nil, nil, nil
            end
        else
            pendingUnit, pendingGUID, pendingReady, pendingExpires = nil, nil, nil, nil
        end
    end

    if tooltipGUID and tooltipGUID ~= UnitGUID("player") and not pendingGUID
        and GetTime() >= nextInspectAt
    then
        local entry = FreshEntry(tooltipGUID)
        if not entry then
            BeginInspect(tooltipUnit, tooltipGUID)
        end
    end
end)

GameTooltip:HookScript("OnTooltipSetUnit", function(self)
    if not Enabled() or self.__aeAddingItemLevel then return end
    local guid, unit = TooltipUnitGUID(self)
    if not guid then return end

    local value
    if UnitIsUnit(unit, "player") then
        value = EquippedItemLevel("player")
        if value then
            local role, stats, scores = InferGearRole("player")
            StoreItemLevel(guid, value)
            StoreRole(guid, role, stats, scores)
        end
    else
        local entry = FreshEntry(guid)
        if entry then value = entry.value end
    end

    local canRequest = value or (CanInspect and CanInspect(unit, false))
    if not canRequest then return end

    self.__aeAddingItemLevel = true
    self:AddDoubleLine("Equipped Item Level", value and string.format("%.2f", value) or "Inspecting...",
        0.35, 0.85, 1, 1, 1, 1)
    self.__aeItemLevelLine = self:NumLines()
    self.__aeItemLevelGUID = guid
    self.__aeAddingItemLevel = nil
    self:Show()

    if not value and not pendingGUID and GetTime() >= nextInspectAt then
        BeginInspect(unit, guid)
    end
end)

GameTooltip:HookScript("OnTooltipCleared", function(self)
    self.__aeItemLevelLine = nil
    self.__aeItemLevelGUID = nil
    self.__aeAddingItemLevel = nil
end)
