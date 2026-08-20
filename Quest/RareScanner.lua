----------------------------------------------------------------------
-- RareScanner.lua
-- ===============
-- Nearby rare detection and short-lived map sightings. WoW 3.3.5a cannot
-- query remote spawn state, so every sighting comes from a live unit token,
-- combat-log GUID, or a newly populated creature-cache entry.
----------------------------------------------------------------------
AutoQuest = AutoQuest or {}
AutoQuest.RareScanner = AutoQuest.RareScanner or {}
local Scanner = AutoQuest.RareScanner
local Resolver = AutoQuest.ObjectiveResolver
local SpawnStore = AutoQuest.NPCSpawnStore

local SIGHTING_SECONDS = 300
local ALERT_COOLDOWN = 90
local CACHE_BATCH = 2
local CACHE_INTERVAL = 0.25
local UNIT_SCAN_INTERVAL = 0.50

local sightings = {}
local lastAlerts = {}
local cacheKnown = {}
local cacheCandidates = {}
local cacheCandidateIndex = 1
local cacheBaseline = true
local cacheZoneKey
local cacheTooltip
local toast

local function Now()
    return GetTime and GetTime() or 0
end

local function Setting(key, fallback)
    local configured = AutoQuestConfig and AutoQuestConfig[key]
    if configured == nil then configured = fallback end
    return AutoCore.GetSetting("quest", key, configured)
end

local function Enabled()
    return Setting("enabled", true) ~= false
        and Setting("rareScannerEnabled", true) ~= false
end

local function NormalizeZone(name)
    name = string.lower(name or "")
    name = string.gsub(name, "^the%s+", "")
    return string.gsub(name, "[^%w]", "")
end

local function IsRareMetadata(metadata)
    local classification = metadata and tonumber(metadata.classification)
    return classification == 2 or classification == 4
end

local function IsRareClassification(classification)
    return classification == "rare" or classification == "rareelite"
end

local function RareMetadataForID(npcID)
    if SpawnStore.GetRareMetadata then return SpawnStore.GetRareMetadata(npcID) end
    -- Compatibility for older embedded data-store shims.
    for _, metadata in ipairs(SpawnStore.GetNotableNPCs() or {}) do
        if tonumber(metadata.id) == tonumber(npcID) and metadata.kind == "rare" then
            return metadata
        end
    end
end

local function RequestMapRefresh()
    if AutoQuest.Map and AutoQuest.Map.RequestRefresh then
        AutoQuest.Map.RequestRefresh()
    end
end

local function CreateToast()
    if toast or not UIParent or not CreateFrame then return toast end
    local UI = AutoCore.UI
    toast = CreateFrame("Frame", nil, UIParent)
    toast:SetSize(390, 76)
    toast:SetPoint("TOP", UIParent, "TOP", 0, -112)
    toast:SetFrameStrata("DIALOG")
    toast:SetFrameLevel(80)
    toast:EnableMouse(false)
    if UI and UI.Backdrop then
        UI.Backdrop(toast, UI.Colors.surfaceRaised, 0.98)
        toast:SetBackdropBorderColor(UI.Unpack(UI.Colors.brand))
    end

    toast.icon = toast:CreateTexture(nil, "ARTWORK")
    toast.icon:SetTexture("Interface\\AddOns\\AutoEverything\\Images\\QuestScout.tga")
    toast.icon:SetSize(42, 42)
    toast.icon:SetPoint("LEFT", toast, "LEFT", 16, 0)

    toast.title = toast:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    toast.title:SetPoint("TOPLEFT", toast.icon, "TOPRIGHT", 14, 0)
    toast.title:SetPoint("RIGHT", toast, "RIGHT", -14, 0)
    toast.title:SetJustifyH("LEFT")
    toast.title:SetText("Rare creature sighted")

    toast.detail = toast:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    toast.detail:SetPoint("TOPLEFT", toast.title, "BOTTOMLEFT", 0, -7)
    toast.detail:SetPoint("RIGHT", toast, "RIGHT", -14, 0)
    toast.detail:SetJustifyH("LEFT")
    if UI and UI.ApplyFont then
        UI.ApplyFont(toast.title, 15)
        UI.ApplyFont(toast.detail, 12)
        toast.title:SetTextColor(UI.Unpack(UI.Colors.text))
        toast.detail:SetTextColor(UI.Unpack(UI.Colors.textMuted))
    end
    toast:Hide()
    toast:SetScript("OnUpdate", function(self)
        local remaining = (self.hideAt or 0) - Now()
        if remaining <= 0 then
            self:Hide()
        elseif remaining < 1 then
            self:SetAlpha(remaining)
        else
            self:SetAlpha(1)
        end
    end)
    return toast
end

local function ShowAlert(sighting)
    local frame = CreateToast()
    local level = tonumber(sighting.level)
    local levelText = level and level > 0 and ("Level " .. level .. " - ") or ""
    local zoneText = sighting.zone and sighting.zone ~= "" and sighting.zone or "Current area"
    if frame then
        frame.detail:SetText((sighting.name or ("NPC " .. sighting.id)) .. "\n"
            .. levelText .. zoneText .. " - " .. (sighting.source or "nearby"))
        frame:SetAlpha(1)
        frame.hideAt = Now() + 6
        frame:Show()
    end
    AutoCore.Warn("Quest", "Rare sighted: " .. tostring(sighting.name or ("NPC " .. sighting.id))
        .. " in " .. zoneText .. ".")
    if Setting("rareScannerSound", false) == true and PlaySound then
        pcall(PlaySound, "RaidWarning")
    end
end

local function CaptureLocation()
    if AutoQuest.Map and AutoQuest.Map.GetPlayerLocation then
        local location = AutoQuest.Map.GetPlayerLocation(true)
        if location and location.x and location.y then return location end
    end
    local x, y = GetPlayerMapPosition and GetPlayerMapPosition("player")
    if not x or not y or (x == 0 and y == 0) then return nil end
    return {
        x=x * 100, y=y * 100,
        zone=(GetZoneText and GetZoneText()) or (GetRealZoneText and GetRealZoneText()),
        zoneID=GetCurrentMapAreaID and GetCurrentMapAreaID() or nil,
        floor=GetCurrentMapDungeonLevel and GetCurrentMapDungeonLevel() or 0,
    }
end

local function PruneSightings(silent)
    local now, changed = Now(), false
    for npcID, sighting in pairs(sightings) do
        if (sighting.expiresAt or 0) <= now then
            sightings[npcID] = nil
            changed = true
        end
    end
    if changed and not silent then RequestMapRefresh() end
    return changed
end

function Scanner.ObserveNPC(npcID, name, guid, level, source, dead)
    npcID = tonumber(npcID)
    if not Enabled() or not npcID or dead == true then return false end
    local now = Now()
    local existing = sightings[npcID]
    local location = existing or CaptureLocation() or {}
    local sighting = existing or { id=npcID }
    sighting.name = name or sighting.name or ("NPC " .. npcID)
    sighting.guid = guid or sighting.guid
    sighting.level = level or sighting.level
    sighting.source = source or sighting.source or "nearby"
    sighting.seenAt = existing and sighting.seenAt or now
    sighting.lastSeen = now
    sighting.expiresAt = now + SIGHTING_SECONDS
    sighting.x = location.x or sighting.x
    sighting.y = location.y or sighting.y
    sighting.zone = location.zone or sighting.zone
    sighting.zoneID = location.zoneID or sighting.zoneID
    sighting.floor = tonumber(location.floor or sighting.floor) or 0
    sightings[npcID] = sighting

    local canAlert = not existing and (not lastAlerts[npcID]
        or now - lastAlerts[npcID] >= ALERT_COOLDOWN)
    if canAlert then
        lastAlerts[npcID] = now
        ShowAlert(sighting)
    end
    if not existing then RequestMapRefresh() end
    return not existing, sighting
end

function Scanner.ObserveUnit(unit, source)
    if not Enabled() or not UnitExists or not UnitExists(unit) then return false end
    if UnitIsPlayer and UnitIsPlayer(unit) then return false end
    if UnitPlayerControlled and UnitPlayerControlled(unit) then return false end
    if UnitIsVisible and not UnitIsVisible(unit) then return false end
    -- Classification alone is not proof of a real encounter. Ascension also
    -- assigns boss classifications to decorative and story NPCs. Neutral
    -- attackable creatures still pass UnitCanAttack; friendly actors do not.
    if UnitCanAttack and not UnitCanAttack("player", unit) then return false end
    local classification = UnitClassification and UnitClassification(unit)
    if not IsRareClassification(classification) then return false end
    local guid = UnitGUID and UnitGUID(unit)
    local npcID = Resolver and Resolver.NPCIDFromGUID and Resolver.NPCIDFromGUID(guid)
    if not npcID then return false end
    SpawnStore.RememberName(npcID, UnitName and UnitName(unit))
    SpawnStore.RememberClassification(npcID, classification)
    return Scanner.ObserveNPC(npcID, UnitName and UnitName(unit), guid,
        UnitLevel and UnitLevel(unit), source or unit,
        UnitIsDead and UnitIsDead(unit) or false)
end

function Scanner.MarkDead(guid, npcID)
    npcID = tonumber(npcID) or (Resolver and Resolver.NPCIDFromGUID
        and Resolver.NPCIDFromGUID(guid))
    if not npcID or not sightings[npcID] then return false end
    sightings[npcID] = nil
    RequestMapRefresh()
    return true
end

function Scanner.HandleCombatLog(...)
    if not Enabled() then return end
    local args = { ... }
    if #args == 0 and CombatLogGetCurrentEventInfo then
        args = { CombatLogGetCurrentEventInfo() }
    end
    local subevent = args[2]
    local modernLayout = type(args[3]) == "boolean"
    local sourceIndex = modernLayout and 4 or 3
    local destIndex = sourceIndex + (modernLayout and 4 or 3)
    local sourceGUID, sourceName = args[sourceIndex], args[sourceIndex + 1]
    local destGUID, destName = args[destIndex], args[destIndex + 1]
    if subevent == "UNIT_DIED" or subevent == "PARTY_KILL" then
        Scanner.MarkDead(destGUID)
        return
    end
    local function ObserveGUID(guid, name)
        local npcID = Resolver and Resolver.NPCIDFromGUID and Resolver.NPCIDFromGUID(guid)
        local metadata = npcID and RareMetadataForID(npcID)
        if npcID and metadata and IsRareMetadata(metadata) then
            Scanner.ObserveNPC(npcID, name or metadata.name, guid, nil, "combat log", false)
        end
    end
    ObserveGUID(sourceGUID, sourceName)
    ObserveGUID(destGUID, destName)
end

function Scanner.GetSightings()
    PruneSightings(true)
    local result = {}
    for _, sighting in pairs(sightings) do
        if sighting.x and sighting.y and sighting.zone then
            result[#result + 1] = sighting
        end
    end
    table.sort(result, function(a, b) return (a.seenAt or 0) > (b.seenAt or 0) end)
    return result
end

function Scanner.ClearSightings(quiet)
    sightings = {}
    RequestMapRefresh()
    if not quiet then AutoCore.Info("Quest", "Recent rare sightings cleared.") end
end

local function CacheTooltip()
    if cacheTooltip or not CreateFrame then return cacheTooltip end
    cacheTooltip = CreateFrame("GameTooltip", "AutoEverythingRareScanTooltip",
        UIParent, "GameTooltipTemplate")
    return cacheTooltip
end

local function IsCreatureCached(npcID)
    local tooltip = CacheTooltip()
    if not tooltip or not tooltip.SetHyperlink then return false end
    tooltip:Hide()
    if tooltip.ClearLines then tooltip:ClearLines() end
    tooltip:SetOwner(WorldFrame or UIParent, "ANCHOR_NONE")
    local ok = pcall(tooltip.SetHyperlink, tooltip,
        string.format("unit:0xF530%06X000000", npcID))
    local shown = ok and tooltip:IsShown()
    tooltip:Hide()
    return shown and true or false
end

local function RebuildCacheCandidates()
    if AutoQuest.Map and AutoQuest.Map.IsInitialBuildComplete
        and not AutoQuest.Map.IsInitialBuildComplete()
    then
        return
    end
    local playerLocation = AutoQuest.Map and AutoQuest.Map.GetPlayerLocation
        and AutoQuest.Map.GetPlayerLocation(false) or nil
    local zone = playerLocation and playerLocation.zone
        or (GetZoneText and GetZoneText()) or (GetRealZoneText and GetRealZoneText()) or ""
    local zoneID = playerLocation and playerLocation.zoneID
        or (GetCurrentMapAreaID and GetCurrentMapAreaID() or nil)
    local zoneKey = NormalizeZone(zone) .. ":" .. tostring(zoneID or "")
    if zoneKey == cacheZoneKey then return end
    cacheZoneKey = zoneKey
    cacheCandidates, cacheCandidateIndex, cacheBaseline = {}, 1, true
    if tonumber(zoneID) and tonumber(zoneID) > 0 and SpawnStore.GetRareNPCsForZone then
        cacheCandidates = SpawnStore.GetRareNPCsForZone(zoneID)
    else
        -- Legacy clients normally expose an area ID. If one does not, keep a
        -- bounded fallback over the compact rare catalog rather than walking
        -- the universal NPC metadata database.
        for _, metadata in ipairs(SpawnStore.GetNotableNPCs() or {}) do
            if metadata.kind == "rare" then
                for _, location in ipairs(SpawnStore.Get(metadata.id) or {}) do
                    if NormalizeZone(location.zone) == NormalizeZone(zone) then
                        cacheCandidates[#cacheCandidates + 1] = metadata
                        break
                    end
                end
            end
        end
    end
end

local function ScanCreatureCache()
    if Setting("rareScannerCache", true) == false then return end
    RebuildCacheCandidates()
    if #cacheCandidates == 0 then return end
    for _ = 1, CACHE_BATCH do
        local metadata = cacheCandidates[cacheCandidateIndex]
        if not metadata then
            cacheCandidateIndex = 1
            cacheBaseline = false
            metadata = cacheCandidates[cacheCandidateIndex]
        end
        if not metadata then return end
        local cached = IsCreatureCached(metadata.id)
        if cached and not cacheKnown[metadata.id] then
            cacheKnown[metadata.id] = true
            if not cacheBaseline then
                Scanner.ObserveNPC(metadata.id, metadata.name, nil, nil, "NPC cache", false)
            end
        end
        cacheCandidateIndex = cacheCandidateIndex + 1
    end
end

local function ScanRelatedTargets()
    Scanner.ObserveUnit("targettarget", "target of target")
    Scanner.ObserveUnit("focus", "focus")
    for index = 1, 4 do
        Scanner.ObserveUnit("party" .. index .. "target", "party target")
    end
end

function Scanner.ApplyProfile()
    if not Enabled() then
        if toast then toast:Hide() end
        Scanner.ClearSightings(true)
    end
end

function Scanner.SetEnabled(enabled)
    AutoCore.SetSetting("quest", "rareScannerEnabled", enabled and true or false)
    AutoCore.Info("Quest", "Rare sighting alerts " .. (enabled and "enabled." or "disabled."))
end

function Scanner.SetSound(enabled)
    AutoCore.SetSetting("quest", "rareScannerSound", enabled and true or false)
    AutoCore.Info("Quest", "Rare alert sound " .. (enabled and "enabled." or "disabled."))
end

function Scanner.SetCacheEnabled(enabled)
    AutoCore.SetSetting("quest", "rareScannerCache", enabled and true or false)
    AutoCore.Info("Quest", "Rare creature-cache scanning " .. (enabled and "enabled." or "disabled."))
end

function Scanner.Debug()
    local count = 0
    for _ in pairs(sightings) do count = count + 1 end
    print("|cff33ccffRare Scanner|r")
    print("  enabled=" .. tostring(Enabled())
        .. " sound=" .. tostring(Setting("rareScannerSound", false) == true)
        .. " cache=" .. tostring(Setting("rareScannerCache", true) ~= false))
    print("  activeSightings=" .. count .. " cacheCandidates=" .. #cacheCandidates
        .. " baseline=" .. tostring(cacheBaseline) .. " zone=" .. tostring(cacheZoneKey))
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
frame:SetScript("OnEvent", function(_, event, unit, ...)
    if event == "NAME_PLATE_UNIT_ADDED" then
        Scanner.ObserveUnit(unit, "nameplate")
    elseif event == "PLAYER_TARGET_CHANGED" then
        Scanner.ObserveUnit("target", "target")
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        Scanner.ObserveUnit("mouseover", "mouseover")
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        Scanner.HandleCombatLog(unit, ...)
    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        cacheZoneKey = nil
        RebuildCacheCandidates()
    end
end)
frame:SetScript("OnUpdate", function(self, elapsed)
    if not Enabled() then return end
    self.unitElapsed = (self.unitElapsed or 0) + math.min(elapsed or 0, 0.1)
    self.cacheElapsed = (self.cacheElapsed or 0) + math.min(elapsed or 0, 0.1)
    self.pruneElapsed = (self.pruneElapsed or 0) + math.min(elapsed or 0, 0.1)
    if self.unitElapsed >= UNIT_SCAN_INTERVAL then
        self.unitElapsed = 0
        ScanRelatedTargets()
    end
    if self.cacheElapsed >= CACHE_INTERVAL then
        self.cacheElapsed = 0
        ScanCreatureCache()
    end
    if self.pruneElapsed >= 1 then
        self.pruneElapsed = 0
        PruneSightings(false)
    end
end)
