----------------------------------------------------------------------
-- QuestMarkers.lua
-- ================
-- Quest objective markers for Ascension nameplates. Players can use these
-- independent badges or hand nameplate quest display back to ElvUI.
----------------------------------------------------------------------
AutoQuest = AutoQuest or {}
AutoQuest.Markers = AutoQuest.Markers or {}
local Markers = AutoQuest.Markers
local Resolver = AutoQuest.ObjectiveResolver
local SpawnStore = AutoQuest.NPCSpawnStore

local activeByNPC, activeByName = {}, {}
-- [guid] = match table or false ("scanned, no match"). Cleared on every
-- RebuildIndex so a live rescan only happens when the quest log actually
-- changes, not on every 0.25s visible-nameplate refresh tick.
local liveMatchCache = {}
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

local function GroupTooltipsRequested()
    local sync = AutoQuest.GroupSync
    local members = sync and sync.GetMemberQuestData and sync.GetMemberQuestData()
    return AutoCore.GetSetting("quest", "groupQuestSync",
            AutoQuestConfig and AutoQuestConfig.groupQuestSync) == true
        and AutoCore.GetSetting("quest", "showGroupQuestTooltips",
            AutoQuestConfig and AutoQuestConfig.showGroupQuestTooltips) ~= false
        and type(members) == "table" and next(members) ~= nil
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

----------------------------------------------------------------------
-- NPC and objective indexing
----------------------------------------------------------------------
local NPCIDFromGUID = Resolver.NPCIDFromGUID

local function ParseProgress(objective)
    if not objective then return false, nil end
    local current, required = objective.current, objective.required
    if not current or not required then
        current, required = string.match(objective.text or "", "(%d+)%s*/%s*(%d+)")
    end
    local remaining
    if current and required then
        remaining = math.max(tonumber(required) - tonumber(current), 0)
    end
    local complete = Resolver.ObjectiveIsComplete(objective.text, objective.done)
        or (tonumber(current) and tonumber(required) and tonumber(required) > 0
            and tonumber(current) >= tonumber(required))
    return complete, remaining
end

-- Use direct database facts where available, then the client-reported type of
-- the exact live objective. Unknown types are deliberately not guessed.
local function RecordKind(record, objective)
    -- Mapped events are coordinate-only objectives and never belong on unit
    -- nameplates, even when their numeric event ID happens to match an NPC ID.
    if tonumber(record.type) == -1 then return nil end
    if tonumber(record.type) == 2 then return "talk" end
    if record.item then return "loot" end

    local objectiveType = objective and string.lower(objective.kind or "") or ""
    if objectiveType == "monster" or objectiveType == "player" then return "kill" end
    if objectiveType == "item" then return "loot" end
    if objectiveType == "object" or objectiveType == "event" then return "talk" end
    return nil
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

-- NPC-page relationships identify the quest but not its objective slot. Match
-- them to the same safe live objective selection used by map pins: prefer an
-- unfinished monster objective, or accept the only unfinished objective.
local function ObjectiveForQuestNPC(objectives)
    local unfinished, monster = {}, nil
    for _, objective in ipairs(objectives or {}) do
        if not objective.done then
            unfinished[#unfinished + 1] = objective
            local objectiveType = string.lower(objective.kind or "")
            if not monster and (objectiveType == "monster" or objectiveType == "player") then
                monster = objective
            end
        end
    end
    if monster then return monster end
    if #unfinished == 1 then return unfinished[1] end
end

local function ObjectiveForQuestItem(objectives, itemName)
    local needle = Resolver.Normalize(itemName)
    local itemObjectives = {}
    for _, objective in ipairs(objectives or {}) do
        if not objective.done and string.lower(objective.kind or "") == "item" then
            itemObjectives[#itemObjectives + 1] = objective
            local normalized = Resolver.Normalize(objective.text)
            if needle ~= "" and string.find(normalized, needle, 1, true) then
                return objective
            end
        end
    end
    if #itemObjectives == 1 then return itemObjectives[1] end
end

local function AddMatch(index, key, kind, questTitle, itemName, remaining, memberName, objective)
    if key == nil or key == "" then return end
    local match = index[key]
    if not match then
        match = {
            kill=false, loot=false, quests={}, items={}, members={}, memberSteps={},
        }
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
    if memberName and memberName ~= "" then
        local progress = match.members[memberName]
        if not progress then progress = {}; match.members[memberName] = progress end
        if remaining and remaining > 0 then
            progress[kind] = math.max(progress[kind] or 0, remaining)
        elseif progress[kind] == nil then
            progress[kind] = true
        end
        if objective then
            local steps = match.memberSteps[memberName]
            if not steps then steps = { seen = {} }; match.memberSteps[memberName] = steps end
            local text = objective.text or questTitle or "Quest objective"
            if objective.current and objective.required
                and not string.find(text, "%d+%s*/%s*%d+")
            then
                text = text .. ": " .. objective.current .. "/" .. objective.required
            end
            local stepKey = table.concat({ questTitle or "", kind or "", text }, "\31")
            if not steps.seen[stepKey] then
                steps.seen[stepKey] = true
                steps[#steps + 1] = {
                    questTitle = questTitle,
                    text = text,
                    kind = kind,
                    remaining = remaining,
                }
            end
        end
    end
end

local function IndexQuestTargets(title, questID, objectives, memberName)
    local resolved = AutoQuest.ResolveQuestEntries(questID, title)
    for _, match in ipairs(resolved) do
        for _, record in ipairs(match.entry.records or {}) do
            local done, remaining, objective = ObjectiveStatus(objectives, record)
            local kind = RecordKind(record, objective)
            if objective and kind and not done then
                AddMatch(activeByNPC, tonumber(record.id), kind, title, record.item,
                    remaining, memberName, objective)
                AddMatch(activeByName, string.lower(record.name or ""), kind, title,
                    record.item, remaining, memberName, objective)
            end
        end
    end

    if not SpawnStore then return end
    local relationshipQuestIDs, seenQuestIDs = {}, {}
    local function AddRelationshipQuestID(value)
        value = tonumber(value)
        if value and not seenQuestIDs[value] then
            seenQuestIDs[value] = true
            relationshipQuestIDs[#relationshipQuestIDs + 1] = value
        end
    end
    AddRelationshipQuestID(questID)
    for _, match in ipairs(resolved) do AddRelationshipQuestID(match.id) end

    local npcObjective = ObjectiveForQuestNPC(objectives)
    local npcDone, npcRemaining = ParseProgress(npcObjective)
    local npcKind = RecordKind({}, npcObjective)
    for _, relationshipQuestID in ipairs(relationshipQuestIDs) do
        if npcObjective and npcKind and not npcDone then
            for _, npcID in ipairs(SpawnStore.GetObjectiveNPCs(relationshipQuestID) or {}) do
                AddMatch(activeByNPC, tonumber(npcID), npcKind, title, nil,
                    npcRemaining, memberName, npcObjective)
            end
        end

        for _, source in ipairs(SpawnStore.GetQuestItemSources(relationshipQuestID) or {}) do
            local itemObjective = ObjectiveForQuestItem(objectives, source.itemName)
            local itemDone, itemRemaining = ParseProgress(itemObjective)
            if itemObjective and not itemDone then
                for _, npcID in ipairs(source.npcIDs or {}) do
                    AddMatch(
                        activeByNPC, tonumber(npcID), "loot", title,
                        source.itemName, itemRemaining, memberName, itemObjective
                    )
                end
            end
        end
    end
end

function Markers.RebuildIndex()
    activeByNPC, activeByName = {}, {}
    liveMatchCache = {}
    if not Enabled() and not GroupTooltipsRequested() then return end
    Resolver.BuildActive()

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
                    text=text or "", kind=objectiveType,
                    done=Resolver.ObjectiveIsComplete(text, done),
                }
            end
        end
        if title and not isHeader and not Resolver.IsComplete(complete) then
            IndexQuestTargets(title, questID, objectives)
        end
    end

    -- A synchronized member's objectives must participate even when the
    -- local player does not have that quest. Only consume complete snapshots
    -- so a multi-message refresh never flashes partial or misleading badges.
    local sync = AutoQuest.GroupSync
    local members = sync and sync.GetMemberQuestData and sync.GetMemberQuestData() or {}
    for _, member in pairs(members) do
        if member.completeSnapshot then
            for key, quest in pairs(member.quests or {}) do
                if not quest.complete then
                    local objectives = {}
                    for index, objective in ipairs(quest.objectives or {}) do
                        objectives[index] = {
                            text = objective.text or "",
                            kind = objective.type or "",
                            done = Resolver.ObjectiveIsComplete(objective.text, objective.finished)
                                or (objective.current and objective.required
                                    and objective.required > 0
                                    and objective.current >= objective.required),
                            current = objective.current,
                            required = objective.required,
                        }
                    end
                    local remoteQuestID = tonumber(string.match(key or "", "^I(%d+)$"))
                    IndexQuestTargets(quest.title, remoteQuestID, objectives, member.name)
                end
            end
        end
    end

end

----------------------------------------------------------------------
-- After database matching, the shared resolver scans live unit tooltips only
-- when an unmatched unit or loot/interact verification needs live evidence.
-- It also persists a unique objective/NPC confirmation for map use;
-- ambiguous duplicate labels remain immediate nameplate evidence only.
----------------------------------------------------------------------
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
    local results = Resolver.MatchTooltip(unit)
    if not results then return nil end
    local match
    for _, result in ipairs(results) do
        if result.kind == "interact" then
            match = EnsureMatch(match)
            match.talk = true
        elseif result.kind == "kill" or result.kind == "loot" then
            local remaining, isPercent = ParseTooltipProgress(result.rawLabel)
            if not isPercent and (remaining == nil or remaining > 0) then
                match = EnsureMatch(match)
                match[result.kind] = true
                if remaining then
                    local countKey = result.kind .. "Remaining"
                    match[countKey] = math.max(match[countKey] or 0, remaining)
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
    local needsLiveEvidence = not match or match.talk
    local cached = needsLiveEvidence and guid and liveMatchCache[guid] or nil
    if needsLiveEvidence and cached == nil then
        cached = ScanUnitForQuestMatch(unit) or false
        if guid then liveMatchCache[guid] = cached end
    end
    local tooltipMatch = needsLiveEvidence and cached or nil

    if match then
        -- Active quest records and item-source relationships identify exact
        -- kill/loot NPCs, matching the evidence already used by map pins.
        -- Interaction associations remain broader and still require the
        -- unit's live quest tooltip to confirm them.
        match = {
            kill = match.kill,
            loot = match.loot,
            talk = match.talk and tooltipMatch and tooltipMatch.talk or false,
            killRemaining = match.killRemaining,
            lootRemaining = match.lootRemaining
                or (tooltipMatch and tooltipMatch.lootRemaining),
            quests = match.quests, items = match.items, members = match.members,
            memberSteps = match.memberSteps,
        }
        if not match.kill and not match.loot and not match.talk then match = nil end
    else
        match = tooltipMatch
    end
    return match, npcID
end

function Markers.GetGroupTooltipRows(unit)
    if not unit or not UnitExists(unit) or UnitIsPlayer(unit) then return {} end
    if not GroupTooltipsRequested() then return {} end
    if not next(activeByNPC) and not next(activeByName) then Markers.RebuildIndex() end
    local match = MatchUnit(unit)
    local rows = {}
    for name, steps in pairs(match and match.memberSteps or {}) do
        local row = { name = name, steps = {} }
        for _, step in ipairs(steps) do row.steps[#row.steps + 1] = step end
        table.sort(row.steps, function(a, b)
            if (a.questTitle or "") ~= (b.questTitle or "") then
                return (a.questTitle or "") < (b.questTitle or "")
            end
            return (a.text or "") < (b.text or "")
        end)
        if #row.steps > 0 then rows[#rows + 1] = row end
    end
    table.sort(rows, function(a, b) return string.lower(a.name) < string.lower(b.name) end)
    return rows
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
    marker:SetWidth(300)
    marker:SetHeight(70)
    marker:SetPoint("LEFT", plate.unitFrame or plate, "RIGHT", -30, 0)
    marker:SetFrameStrata("HIGH")
    marker:SetFrameLevel(100)
    marker:EnableMouse(false)

    -- Same icons/colors as the QuestMap world/minimap pins for consistency.
    marker.kill = NewBadge(marker, "Interface\\AddOns\\AutoEverything\\Images\\QuestSkull.tga", 30)
    marker.loot = NewBadge(marker, "Interface\\AddOns\\AutoEverything\\Images\\QuestLootBag.tga", 30)
    -- "Speak with" objectives, using Blizzard's own chat bubble artwork.
    -- Comes only from live tooltip evidence, never an inferred database kind.
    marker.talk = NewBadge(marker, "Interface\\WorldMap\\ChatBubble_64.PNG", 30)
    marker.groupText = marker:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    if AutoCore.UI and AutoCore.UI.ApplyFont then AutoCore.UI.ApplyFont(marker.groupText, 10) end
    marker.groupText:SetWidth(190)
    marker.groupText:SetJustifyH("LEFT")
    marker.groupText:SetTextColor(1, 0.82, 0.2, 1)
    marker.groupText:Hide()
    marker:Hide()

    plate.AutoEverythingQuestMarker = marker
    return marker
end

local function ResetMarker(marker)
    marker.kill:Hide(); marker.kill.count:Hide()
    marker.loot:Hide(); marker.loot.count:Hide()
    marker.talk:Hide(); marker.talk.count:Hide()
    marker.groupText:Hide(); marker.groupText:SetText("")
end

local function ShowCount(icon, value)
    if value and value > 0 then
        icon.count:SetText(value)
        icon.count:Show()
    end
end

local function GroupProgressLines(match)
    local rows = {}
    for name, progress in pairs(match.members or {}) do
        local parts = {}
        for _, kind in ipairs({ "kill", "loot", "talk" }) do
            local value = progress[kind]
            if value and (kind ~= "talk" or match.talk) then
                if type(value) == "number" then
                    parts[#parts + 1] = kind .. " " .. value
                else
                    parts[#parts + 1] = kind
                end
            end
        end
        if #parts == 1 then
            local amount = string.match(parts[1], "(%d+)$")
            rows[#rows + 1] = {
                name = name,
                text = amount and (amount .. " left") or parts[1],
            }
        elseif #parts > 1 then
            rows[#rows + 1] = { name = name, text = table.concat(parts, ", ") }
        end
    end
    table.sort(rows, function(a, b) return string.lower(a.name) < string.lower(b.name) end)

    local lines = {}
    local visible = math.min(#rows, 5)
    for index = 1, visible do
        lines[#lines + 1] = rows[index].name .. ": " .. rows[index].text
    end
    if #rows > visible then lines[#lines + 1] = "+" .. (#rows - visible) .. " more" end
    return lines
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
    local groupLines = GroupProgressLines(match)
    if #groupLines > 0 then
        marker.groupText:ClearAllPoints()
        marker.groupText:SetPoint("LEFT", marker, "LEFT", (#icons * 34) + 2, 0)
        marker.groupText:SetText(table.concat(groupLines, "\n"))
        marker.groupText:Show()
    end
    marker:Show()
end

local function FindPlate(unit)
    if C_NamePlate and C_NamePlate.GetNamePlateForUnit then
        return C_NamePlate.GetNamePlateForUnit(unit)
    end
end

-- Nameplate add events are not replayed for plates that were already visible
-- when this addon loaded or the UI reloaded. Ascension exposes the same
-- nameplate unit tokens used by its bundled nameplate addons, so discover any
-- missed plates during the existing bounded refresh instead of leaving the
-- marker list empty until each unit's plate is recreated.
local function DiscoverVisible()
    for index = 1, 40 do
        local unit = "nameplate" .. index
        if UnitGUID(unit) then
            local plate = FindPlate(unit)
            if plate and plate:IsShown() then visibleUnits[unit] = plate end
        end
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
    DiscoverVisible()
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

function Markers.RequestRefresh()
    refreshPending, refreshAt = true, 0
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
        else source = "live tooltip evidence" end
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
eventFrame:RegisterEvent("QUEST_WATCH_UPDATE")
eventFrame:RegisterEvent("UNIT_QUEST_LOG_CHANGED")
eventFrame:RegisterEvent("QUEST_ITEM_UPDATE")
eventFrame:RegisterEvent("QUEST_FINISHED")
eventFrame:RegisterEvent("BAG_UPDATE")
eventFrame:RegisterEvent("ITEM_PUSH")
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
        refreshPending, refreshAt = true,
            GetTime() + (Resolver.QUEST_LOG_SETTLE_DELAY or 0.75)
    end
end)
eventFrame:SetScript("OnUpdate", function(_, elapsed)
    local visualEnabled = Enabled()
    local indexEnabled = visualEnabled or GroupTooltipsRequested()
    if not visualEnabled then
        if eventFrame.markersWereEnabled ~= false then
            for _, plate in pairs(visibleUnits) do
                if plate.AutoEverythingQuestMarker then plate.AutoEverythingQuestMarker:Hide() end
            end
            eventFrame.markersWereEnabled = false
        end
    elseif eventFrame.markersWereEnabled == false then
        refreshPending, refreshAt = true, 0
    end
    if visualEnabled then eventFrame.markersWereEnabled = true end
    if not indexEnabled then return end
    eventFrame.elapsed = (eventFrame.elapsed or 0) + math.min(elapsed or 0, 0.1)
    if refreshPending and GetTime() >= refreshAt then
        refreshPending = false
        Markers.RebuildIndex()
        if visualEnabled then RefreshVisible() end
        eventFrame.elapsed = 0
    elseif visualEnabled and eventFrame.elapsed >= 0.25 then
        eventFrame.elapsed = 0
        RefreshVisible()
    end
end)
