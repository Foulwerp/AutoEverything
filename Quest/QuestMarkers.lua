----------------------------------------------------------------------
-- QuestMarkers.lua
-- ================
-- Quest objective markers for Ascension nameplates. Players can use these
-- independent badges or hand nameplate quest display back to ElvUI.
----------------------------------------------------------------------
AutoQuest = AutoQuest or {}
AutoQuest.Markers = AutoQuest.Markers or {}
local Markers = AutoQuest.Markers

local activeByNPC, activeByName = {}, {}
-- [lowercased objective text] = Blizzard's objectiveType ("monster", "item",
-- "object", ...) for every objective of every logged quest. Rebuilt
-- alongside activeByNPC/activeByName; feeds the live tooltip-scan fallback
-- below with ground-truth classification instead of keyword guessing.
local objectiveTextIndex = {}
-- Runtime-only confirmations keyed by normalized live objective text, then NPC
-- id. These are deliberately not SavedVariables: the bundled Ascension data
-- supplies locations; the tooltip merely selects which database NPC record is
-- authoritative for the currently active objective.
local confirmedTargets = {}
-- [guid] = match table or false ("scanned, no match"). Cleared on every
-- RebuildIndex so a live rescan only happens when the quest log actually
-- changes, not on every 0.25s visible-nameplate refresh tick.
local fallbackMatchCache = {}
local visibleUnits = {}
local refreshPending, refreshAt = false, 0

local function MarkersRequested()
    local moduleEnabled = AutoCore.GetSetting("quest", "enabled",
        AutoQuestConfig and AutoQuestConfig.enabled) ~= false
    return moduleEnabled and AutoCore.GetSetting("quest", "nameplateMarkers",
        AutoQuestConfig and AutoQuestConfig.nameplateMarkers) ~= false
end

local function WantsElvUI()
    return AutoCore.GetSetting("quest", "useElvUIQuestMarkers",
        AutoQuestConfig and AutoQuestConfig.useElvUIQuestMarkers) == true
end

local function ElvUIEngine()
    local engine = _G.ElvUI and _G.ElvUI[1]
    if not engine or not engine.db or not engine.GetModule then return nil end
    local units = engine.db.nameplates and engine.db.nameplates.units
    if not units then return nil end
    return engine, units
end

local function Enabled()
    return MarkersRequested() and not (WantsElvUI() and ElvUIEngine())
end

-- Mirrors the useful one-line command that previously had to be run by hand.
-- Only the two NPC quest-icon switches are touched; all other ElvUI nameplate
-- settings remain under the player's control.
local function ApplyElvUIProvider()
    local engine, units = ElvUIEngine()
    if not engine then return false end

    local useElvUI = MarkersRequested() and WantsElvUI()
    local changed = false
    for _, unitType in ipairs({ "ENEMY_NPC", "FRIENDLY_NPC" }) do
        local questIcon = units[unitType] and units[unitType].questIcon
        if questIcon and questIcon.enable ~= useElvUI then
            questIcon.enable = useElvUI
            changed = true
        end
    end

    if changed then
        local ok, nameplates = pcall(engine.GetModule, engine, "NamePlates")
        if ok and nameplates and nameplates.ConfigureAll then
            pcall(nameplates.ConfigureAll, nameplates)
        end
    end
    return true
end

function Markers.ApplyProfile()
    ApplyElvUIProvider()
    Markers.RebuildIndex()
    refreshPending, refreshAt = true, 0
end

-- Strips the trailing "0/3" or "62%" count off an objective line, leaving
-- just the stable label ("Red Linen Bandana"). The live count on a specific
-- unit's tooltip can already be ahead of whatever was true when the index
-- below was last rebuilt (e.g. you looted one since the last QUEST_LOG_UPDATE),
-- so matching on the full line including the count is unreliable - the label
-- alone is what stays constant.
local function ObjectiveLabel(text)
    local label = string.gsub(text or "", "|c%x%x%x%x%x%x%x%x", "")
    label = string.gsub(label, "|r", "")
    label = string.gsub(label, "%s*%d+%s*/%s*%d+%s*$", "")
    label = string.gsub(label, "%s*%d+%%%s*$", "")
    label = string.gsub(label, ":%s*$", "")
    label = string.gsub(label, "^%s+", "")
    label = string.gsub(label, "%s+$", "")
    label = string.gsub(label, "%s+", " ")
    return string.lower(label)
end

----------------------------------------------------------------------
-- NPC and objective indexing
----------------------------------------------------------------------
local function NPCIDFromGUID(guid)
    if type(guid) ~= "string" then return nil end

    -- Prefer the Ascension-provided decoder. It understands both stock and
    -- Ascension custom creature GUID layouts.
    if type(GetCreatureIDFromGUID) == "function" then
        local ok, value = pcall(GetCreatureIDFromGUID, guid)
        value = ok and tonumber(value) or nil
        if value and value > 0 then return value end
    end

    -- Modern textual GUID fallback: Creature-0-...-NPCID-spawnUID.
    local fields = {}
    for field in string.gmatch(guid, "[^-]+") do fields[#fields + 1] = field end
    if fields[1] == "Creature" or fields[1] == "Vehicle" then
        local value = tonumber(fields[6])
        if value and value > 0 then return value end
    end

    -- Ascension's hexadecimal WotLK GUID: 0xF130EEEEEE...
    if string.sub(guid, 1, 2) == "0x" and string.len(guid) >= 12 then
        local value = tonumber(string.sub(guid, 7, 12), 16)
        if value and value > 0 then return value end
    end
end

local function ParseProgress(objective)
    if not objective then return false, nil end
    local current, required = string.match(objective.text or "", "(%d+)%s*/%s*(%d+)")
    local remaining
    if current and required then
        remaining = math.max(tonumber(required) - tonumber(current), 0)
    end
    return objective.done and true or false, remaining
end

-- Use direct database facts where available, then the client-reported type of
-- the exact live objective. Unknown types are deliberately not guessed.
local function RecordKind(record, objective)
    if tonumber(record.type) == 2 then return "talk" end
    if record.item then return "loot" end

    local objectiveType = objective and string.lower(objective.kind or "") or ""
    if objectiveType == "monster" or objectiveType == "player" then return "kill" end
    if objectiveType == "item" then return "loot" end
    if objectiveType == "object" or objectiveType == "event" then return "talk" end
    return nil
end

local function ConfirmTarget(unit, text, kind)
    local npcID = NPCIDFromGUID and NPCIDFromGUID(UnitGUID(unit))
    local label = ObjectiveLabel(text)
    if not npcID or label == "" or not kind then return end

    local target = confirmedTargets[label]
    if not target then
        target = { kind = kind, npcs = {} }
        confirmedTargets[label] = target
    elseif target.kind ~= kind then
        -- Conflicting live classifications are not safe enough for map pins.
        target.kind = nil
        return
    end
    if target.npcs[npcID] then return end

    target.npcs[npcID] = true
    if AutoQuest.Map and AutoQuest.Map.RequestRefresh then
        AutoQuest.Map.RequestRefresh()
    end
end

-- Tie every scraped record to a live objective before it can create a badge.
local function ObjectiveForRecord(objectives, record)
    local needle = string.lower(record.item or record.name or "")
    if needle ~= "" then
        for _, objective in ipairs(objectives) do
            if string.find(string.lower(objective.text or ""), needle, 1, true) then
                return objective
            end
        end
    end

    -- Ascension Mapper indexes are zero-based. Do not accept a database record
    -- that cannot be tied to a real live objective; stale/cross-referenced
    -- records are otherwise indistinguishable from valid targets.
    local index = tonumber(record.objective)
    return index and objectives[index + 1] or nil
end

local function ObjectiveStatus(objectives, record)
    local objective = ObjectiveForRecord(objectives, record)
    local done, remaining = ParseProgress(objective)
    return done, remaining, objective
end

local function AddMatch(index, key, kind, questTitle, itemName, remaining)
    if key == nil or key == "" then return end
    local match = index[key]
    if not match then
        match = { kill=false, loot=false, quests={}, items={} }
        index[key] = match
    end
    match[kind] = true
    match.quests[questTitle] = true
    if itemName then match.items[itemName] = true end
    if remaining and remaining > 0 then
        local countKey = kind .. "Remaining"
        -- One kill can progress multiple objectives; show how many kills are
        -- needed before all matching objectives are finished.
        match[countKey] = math.max(match[countKey] or 0, remaining)
    end
end

function Markers.RebuildIndex()
    activeByNPC, activeByName = {}, {}
    objectiveTextIndex = {}
    fallbackMatchCache = {}
    if not Enabled() then return end

    local entries = GetNumQuestLogEntries and GetNumQuestLogEntries() or 0
    for logIndex = 1, entries do
        local title, _, _, _, isHeader, _, complete, _, questID = GetQuestLogTitle(logIndex)
        local objectives
        if title and not isHeader then
            objectives = {}
            local count = GetNumQuestLeaderBoards(logIndex) or 0
            for objectiveIndex = 1, count do
                local text, objectiveType, done = GetQuestLogLeaderBoard(objectiveIndex, logIndex)
                objectives[objectiveIndex] = {
                    text=text or "", kind=objectiveType, done=done and true or false,
                }
                -- Indexed by every active quest's live objective label, not
                -- just quests the database happens to know about. This is
                -- what the live tooltip-scan fallback below matches against
                -- to get Blizzard's own item-vs-monster classification
                -- instead of guessing from keywords.
                if text and text ~= "" then
                    local label = ObjectiveLabel(text)
                    if label ~= "" then
                        objectiveTextIndex[label] = {
                            kind = string.lower(objectiveType or ""),
                            done = done and true or false,
                        }
                    end
                end
            end
        end
        -- Resolve by questID, falling back to title (the client may not return
        -- a questID at all on 3.3.5). See AutoQuest.ResolveQuestEntries.
        local resolved = (title and not isHeader) and AutoQuest.ResolveQuestEntries(questID, title) or {}
        if title and not isHeader and #resolved > 0 and complete ~= 1 and complete ~= true then
            for _, match in ipairs(resolved) do
                for _, record in ipairs(match.entry.records or {}) do
                    local done, remaining, objective = ObjectiveStatus(objectives, record)
                    local kind = RecordKind(record, objective)
                    if objective and kind and not done then
                        AddMatch(activeByNPC, tonumber(record.id), kind, title, record.item, remaining)
                        AddMatch(activeByName, string.lower(record.name or ""), kind, title, record.item, remaining)
                    end
                end
            end
        end
    end

    -- Completion, abandonment, and objective replacement all remove the live
    -- label from this index. Drop its session confirmation immediately.
    for label, target in pairs(confirmedTargets) do
        local objective = objectiveTextIndex[label]
        if not objective or objective.done or objective.kind == ""
            or (target.kind == "kill" and objective.kind ~= "monster" and objective.kind ~= "player")
            or (target.kind == "loot" and objective.kind ~= "item")
        then
            confirmedTargets[label] = nil
        end
    end
end

----------------------------------------------------------------------
-- Live unit-tooltip fallback, the same approach nameplate quest-icon addons
-- use. The scraped database can miss an NPC - still-incomplete scrape,
-- an ID/name mismatch, a custom Ascension mob - but Blizzard's own unit
-- tooltip already prints objective lines ("Defias Bandits slain: 3/10")
-- for any unit that counts toward one of the player's active quests. This
-- reads that tooltip directly when the database lookup above comes up
-- empty. It only tells us "this unit matters right now", not a location,
-- so it complements the database rather than replacing it.
----------------------------------------------------------------------
local scanTooltip = CreateFrame("GameTooltip", "AutoEverythingQuestMarkerTooltip", nil, "GameTooltipTemplate")
scanTooltip:SetOwner(WorldFrame, "ANCHOR_NONE")

-- Returns remaining count and whether it was a percentage (e.g. an escort
-- quest's "62% complete"). Percentage objectives don't map to a kill/loot
-- count, so callers skip them rather than badge them with a wrong number.
local function ParseTooltipProgress(text)
    local current, required = string.match(text, "(%d+)%s*/%s*(%d+)")
    if current and required then
        return math.max(tonumber(required) - tonumber(current), 0), false
    end
    local percent = tonumber(string.match(text, "(%d+)%%"))
    if percent then
        return math.max(100 - percent, 0), true
    end
    return nil
end

local function EnsureMatch(match)
    return match or { kill = false, loot = false, talk = false }
end

local function ScanUnitForQuestMatch(unit)
    if not next(objectiveTextIndex) then return nil end
    if not UnitExists(unit) or UnitIsPlayer(unit) then return nil end

    scanTooltip:ClearLines()
    scanTooltip:SetUnit(unit)

    local match
    -- Line 1 is the unit's own name; quest info can appear on any line after
    -- that.
    for i = 2, scanTooltip:NumLines() do
        local region = _G["AutoEverythingQuestMarkerTooltipTextLeft" .. i]
        local text = region and region:GetText()
        if text and text ~= "" then
            local objective = objectiveTextIndex[ObjectiveLabel(text)]
            local objectiveKind = objective and objective.kind
            if objective and not objective.done
                and (objectiveKind == "object" or objectiveKind == "event")
            then
                -- Interaction objectives may be plain flags with no count.
                match = EnsureMatch(match)
                match.talk = true
                ConfirmTarget(unit, text, "talk")
            elseif objective and not objective.done
                and (objectiveKind == "monster" or objectiveKind == "player" or objectiveKind == "item")
            then
                local remaining, isPercent = ParseTooltipProgress(text)
                -- remaining == 0 means this specific objective is already
                -- satisfied (e.g. "3/3"); skip badging it so the icon drops
                -- off once nothing is left to do, while any other quest's
                -- still-active objective on the same unit (a later line in
                -- this same loop) keeps showing normally.
                if remaining and remaining > 0 and not isPercent then
                    -- Only exact active-objective matches are accepted. In
                    -- particular, a generic numbered tooltip line must never
                    -- fall through to a loot badge.
                    local kind = objectiveKind == "item" and "loot" or "kill"
                    if kind == "kill" or kind == "loot" then
                        match = EnsureMatch(match)
                        match[kind] = true
                        ConfirmTarget(unit, text, kind)
                        local countKey = kind .. "Remaining"
                        match[countKey] = math.max(match[countKey] or 0, remaining)
                    end
                end
            end
        end
    end
    return match
end

local function MatchUnit(unit)
    local npcID = NPCIDFromGUID(UnitGUID(unit))
    local match = npcID and activeByNPC[npcID]
    if not match then
        local name = UnitName(unit)
        match = name and activeByName[string.lower(name)]
    end
    local guid = UnitGUID(unit)
    local cached = guid and fallbackMatchCache[guid]
    if cached == nil then
        cached = ScanUnitForQuestMatch(unit) or false
        if guid then fallbackMatchCache[guid] = cached end
    end
    local tooltipMatch = cached or nil

    if match then
        -- Scraped loot-source and interaction associations can be broader than
        -- the live server's actual targets. Require the unit's own quest
        -- tooltip to confirm those badges. Kill requirements remain safe to
        -- resolve by exact NPC id/name from the active quest record.
        match = {
            kill = match.kill,
            loot = match.loot and tooltipMatch and tooltipMatch.loot or false,
            talk = match.talk and tooltipMatch and tooltipMatch.talk or false,
            killRemaining = match.killRemaining,
            lootRemaining = tooltipMatch and tooltipMatch.lootRemaining,
            quests = match.quests, items = match.items,
        }
        if not match.kill and not match.loot and not match.talk then match = nil end
    else
        match = tooltipMatch
    end
    return match, npcID
end


function Markers.IsTargetConfirmed(npcID, objectiveText, kind)
    local target = confirmedTargets[ObjectiveLabel(objectiveText)]
    return target and target.kind == kind
        and target.npcs[tonumber(npcID)] == true or false
end

----------------------------------------------------------------------
-- Independent marker frames
----------------------------------------------------------------------
local function NewBadge(parent, texture, size)
    local icon = parent:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(texture)
    icon:SetWidth(size)
    icon:SetHeight(size)
    icon:Hide()

    local count = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    if AutoCore.UI and AutoCore.UI.ApplyFont then AutoCore.UI.ApplyFont(count, 10) end
    count:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 4, -3)
    count:SetTextColor(1, 1, 1, 1)
    count:Hide()
    icon.count = count
    return icon
end

local function GetMarker(plate)
    if plate.AutoEverythingQuestMarker then return plate.AutoEverythingQuestMarker end

    -- UIParent avoids clipping and frame-level conflicts from any nameplate
    -- replacement addon. The marker remains anchored to the moving plate.
    local marker = CreateFrame("Frame", nil, UIParent)
    marker:SetWidth(166)
    marker:SetHeight(30)
    marker:SetPoint("LEFT", plate.unitFrame or plate, "RIGHT", -30, 0)
    marker:SetFrameStrata("HIGH")
    marker:SetFrameLevel(100)
    marker:EnableMouse(false)

    -- Same icons/colors as the QuestMap world/minimap pins for consistency.
    marker.kill = NewBadge(marker, "Interface\\AddOns\\AutoEverything\\Media\\Icons\\QuestSkull.tga", 30)
    marker.loot = NewBadge(marker, "Interface\\AddOns\\AutoEverything\\Media\\Icons\\QuestLootBag.tga", 30)
    -- "Speak with" objectives, using Blizzard's own chat bubble artwork.
    -- Comes only from the live tooltip-scan fallback, never the database.
    marker.talk = NewBadge(marker, "Interface\\WorldMap\\ChatBubble_64.PNG", 30)
    marker:Hide()

    plate.AutoEverythingQuestMarker = marker
    return marker
end

local function ResetMarker(marker)
    marker.kill:Hide(); marker.kill.count:Hide()
    marker.loot:Hide(); marker.loot.count:Hide()
    marker.talk:Hide(); marker.talk.count:Hide()
end

local function ShowCount(icon, value)
    if value and value > 0 then
        icon.count:SetText(value)
        icon.count:Show()
    end
end

local function UpdateUnit(unit, plate)
    if not plate then return end
    local marker = GetMarker(plate)
    ResetMarker(marker)

    -- /run AutoQuest.Markers.TestIcons() forces all badges for five seconds.
    if marker.testUntil and GetTime() < marker.testUntil then
        local testIcons = { marker.kill, marker.loot, marker.talk }
        for index, icon in ipairs(testIcons) do
            icon:ClearAllPoints()
            icon:SetPoint("LEFT", marker, "LEFT", (index - 1) * 34, 0)
            icon:Show()
        end
        marker:Show()
        return
    end

    if not Enabled() or not UnitExists(unit) or UnitIsPlayer(unit) then
        marker:Hide()
        return
    end

    local match = MatchUnit(unit)
    if not match then marker:Hide(); return end

    local icons = {}
    if match.kill then icons[#icons + 1] = marker.kill end
    if match.loot then icons[#icons + 1] = marker.loot end
    if match.talk then icons[#icons + 1] = marker.talk end

    for index, icon in ipairs(icons) do
        icon:ClearAllPoints()
        icon:SetPoint("LEFT", marker, "LEFT", (index - 1) * 34, 0)
        icon:Show()
    end
    if match.kill then ShowCount(marker.kill, match.killRemaining) end
    if match.loot then ShowCount(marker.loot, match.lootRemaining) end
    marker:Show()
end

local function FindPlate(unit)
    if C_NamePlate and C_NamePlate.GetNamePlateForUnit then
        return C_NamePlate.GetNamePlateForUnit(unit)
    end
end

function Markers.TestIcons()
    local unit = UnitExists("target") and "target" or (UnitExists("mouseover") and "mouseover")
    if not unit then
        print("|cffffcc00Quest:|r Target or mouse over a nameplate first.")
        return
    end
    local plate = FindPlate(unit)
    if not plate then
        print("|cffffcc00Quest:|r No nameplate was found for " .. tostring(UnitName(unit)) .. ".")
        return
    end
    visibleUnits[unit] = plate
    local marker = GetMarker(plate)
    marker.testUntil = GetTime() + 5
    UpdateUnit(unit, plate)
    print("|cff00ff00Quest:|r Showing kill, loot, and talk test icons for 5 seconds.")
end

local function RefreshVisible()
    for unit, plate in pairs(visibleUnits) do
        if UnitExists(unit) and plate:IsShown() then
            UpdateUnit(unit, plate)
        else
            local marker = plate.AutoEverythingQuestMarker
            if marker then marker:Hide() end
            visibleUnits[unit] = nil
        end
    end
end

function Markers.SetEnabled(enabled)
    AutoCore.SetSetting("quest", "nameplateMarkers", enabled and true or false)
    ApplyElvUIProvider()
    Markers.RebuildIndex()
    RefreshVisible()
    AutoCore.Info("Quest", "Quest nameplate markers " .. (enabled and "enabled." or "disabled."))
end

function Markers.IsEnabled() return Enabled() end

function Markers.Debug()
    Markers.RebuildIndex()
    local unit = UnitExists("target") and "target" or (UnitExists("mouseover") and "mouseover")
    print("|cff33ccffQuest Nameplate|r")
    if not unit then print("  Target or mouse over an objective NPC first."); return end

    local plate = FindPlate(unit)
    if plate then
        visibleUnits[unit] = plate
        UpdateUnit(unit, plate)
    end
    local match, npcID = MatchUnit(unit)
    local marker = plate and plate.AutoEverythingQuestMarker
    local source = "none"
    if match then
        local name = UnitName(unit)
        if npcID and activeByNPC[npcID] == match then source = "database (npcID)"
        elseif name and activeByName[string.lower(name)] == match then source = "database (name)"
        else source = "live tooltip scan (fallback)" end
    end
    print("  unit=" .. unit .. " name=" .. tostring(UnitName(unit))
        .. " player=" .. tostring(UnitIsPlayer(unit)))
    print("  guid=" .. tostring(UnitGUID(unit)) .. " npcID=" .. tostring(npcID)
        .. " matched=" .. tostring(match ~= nil) .. " source=" .. source)
    if match then
        print("  kill=" .. tostring(match.kill) .. " remaining=" .. tostring(match.killRemaining)
            .. " loot=" .. tostring(match.loot) .. " remaining=" .. tostring(match.lootRemaining)
            .. " talk=" .. tostring(match.talk))
    end
    print("  plate=" .. tostring(plate ~= nil) .. " plateShown=" .. tostring(plate and plate:IsShown())
        .. " marker=" .. tostring(marker ~= nil) .. " markerShown=" .. tostring(marker and marker:IsShown()))
end

----------------------------------------------------------------------
-- Events
----------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("QUEST_LOG_UPDATE")
eventFrame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
eventFrame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
eventFrame:SetScript("OnEvent", function(_, event, unit)
    if event == "PLAYER_ENTERING_WORLD" then
        ApplyElvUIProvider()
        refreshPending, refreshAt = true, GetTime() + 0.35
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        local plate = FindPlate(unit)
        if plate then visibleUnits[unit] = plate; UpdateUnit(unit, plate) end
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        local plate = visibleUnits[unit]
        if plate and plate.AutoEverythingQuestMarker then plate.AutoEverythingQuestMarker:Hide() end
        visibleUnits[unit] = nil
    else
        refreshPending, refreshAt = true, GetTime() + 0.35
    end
end)
eventFrame:SetScript("OnUpdate", function(_, elapsed)
    local enabled = Enabled()
    if not enabled then
        if eventFrame.markersWereEnabled ~= false then
            for _, plate in pairs(visibleUnits) do
                if plate.AutoEverythingQuestMarker then plate.AutoEverythingQuestMarker:Hide() end
            end
            eventFrame.markersWereEnabled = false
        end
        return
    elseif eventFrame.markersWereEnabled == false then
        refreshPending, refreshAt = true, 0
    end
    eventFrame.markersWereEnabled = true
    eventFrame.elapsed = (eventFrame.elapsed or 0) + math.min(elapsed or 0, 0.1)
    if refreshPending and GetTime() >= refreshAt then
        refreshPending = false
        Markers.RebuildIndex()
        RefreshVisible()
        eventFrame.elapsed = 0
    elseif eventFrame.elapsed >= 0.25 then
        eventFrame.elapsed = 0
        RefreshVisible()
    end
end)
