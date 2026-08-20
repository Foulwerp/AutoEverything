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
local questContributions = {}
local contributionStats = { rebuilt=0, reused=0 }
local IndexQuestTargets

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

local function QuestTooltipsRequested()
    return AutoCore.GetSetting("quest", "showGroupQuestTooltips",
        AutoQuestConfig and AutoQuestConfig.showGroupQuestTooltips) ~= false
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
    questContributions = {}
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
        current, required = Resolver.Progress(objective.text)
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

local function ObjectiveStatus(objectives, record)
    local objective = Resolver.ObjectiveForRecord(objectives, record)
    local done, remaining = ParseProgress(objective)
    return done, remaining, objective
end

local function QuestFingerprint(quest, member)
    local fields = {
        tostring(quest.id or ""), tostring(quest.title or ""),
        quest.complete and "1" or "0",
        member and tostring(member.name or "") or "",
        member and tostring(member.class or "") or "",
        member and member.completeSnapshot and "1" or "0",
        member and member.stale and "1" or "0",
        member and member.connected == false and "0" or "1",
    }
    for index, objective in ipairs(quest.objectives or {}) do
        fields[#fields + 1] = table.concat({
            tostring(index), tostring(objective.text or ""),
            tostring(objective.type or objective.kind or ""),
            (objective.finished or objective.done) and "1" or "0",
            tostring(objective.current or ""), tostring(objective.required or ""),
            tostring(objective.targetType or ""), tostring(objective.targetID or ""),
        }, "\30")
    end
    return table.concat(fields, "\31")
end

local function LocalObjectives(quest)
    local objectives = {}
    for objectiveIndex, objective in ipairs(quest.objectives or {}) do
        objectives[objectiveIndex] = {
            text=objective.text, kind=objective.type, done=objective.finished,
            current=objective.current, required=objective.required,
        }
    end
    return objectives
end

local function RemoteObjectives(quest)
    local objectives = {}
    for index, objective in ipairs(quest.objectives or {}) do
        objectives[index] = {
            text = objective.text or "", kind = objective.type or "",
            done = Resolver.ObjectiveIsComplete(objective.text, objective.finished)
                or (objective.current and objective.required
                    and objective.required > 0 and objective.current >= objective.required),
            current = objective.current, required = objective.required,
            targetType = objective.targetType, targetID = objective.targetID,
        }
    end
    return objectives
end

local function BuildQuestContribution(quest, member, sourceKey, fingerprint)
    local aggregateNPC, aggregateName = activeByNPC, activeByName
    activeByNPC, activeByName = {}, {}
    if not quest.complete then
        local objectives = member and RemoteObjectives(quest) or LocalObjectives(quest)
        local questID = tonumber(quest.id)
            or tonumber(string.match(quest.key or sourceKey or "", "I(%d+)$"))
        local memberName, memberClass
        if member then
            memberName, memberClass = member.name, member.class
        elseif QuestTooltipsRequested() then
            memberName = UnitName and UnitName("player") or nil
            if UnitClass then _, memberClass = UnitClass("player") end
        end
        IndexQuestTargets(quest.title, questID, objectives,
            memberName, memberClass)
    end
    local contribution = {
        fingerprint=fingerprint, byNPC=activeByNPC, byName=activeByName,
    }
    activeByNPC, activeByName = aggregateNPC, aggregateName
    return contribution
end

local function MergeMatch(index, key, source)
    local target = index[key]
    if not target then
        target = {
            kill=false, loot=false, quests={}, items={}, localProgress={},
            members={}, memberSteps={},
        }
        index[key] = target
    end
    target.kill = target.kill or source.kill
    target.loot = target.loot or source.loot
    target.talk = target.talk or source.talk
    target.killRemaining = math.max(target.killRemaining or 0, source.killRemaining or 0)
    target.lootRemaining = math.max(target.lootRemaining or 0, source.lootRemaining or 0)
    for title in pairs(source.quests or {}) do target.quests[title] = true end
    for item in pairs(source.items or {}) do target.items[item] = true end
    for _, kind in ipairs({ "kill", "loot", "talk" }) do
        local value = source.localProgress and source.localProgress[kind]
        if value == true then target.localProgress[kind] = target.localProgress[kind] or true
        elseif value then
            target.localProgress[kind] = math.max(
                tonumber(target.localProgress[kind]) or 0, value)
        end
    end
    for name, progress in pairs(source.members or {}) do
        local merged = target.members[name] or {}
        target.members[name] = merged
        merged.class = progress.class or merged.class
        if progress.kill == true then merged.kill = merged.kill or true
        elseif progress.kill then merged.kill = math.max(tonumber(merged.kill) or 0, progress.kill) end
        if progress.loot == true then merged.loot = merged.loot or true
        elseif progress.loot then merged.loot = math.max(tonumber(merged.loot) or 0, progress.loot) end
        if progress.talk == true then merged.talk = merged.talk or true
        elseif progress.talk then merged.talk = math.max(tonumber(merged.talk) or 0, progress.talk) end
    end
    for name, steps in pairs(source.memberSteps or {}) do
        local merged = target.memberSteps[name]
        if not merged then merged = { seen={} }; target.memberSteps[name] = merged end
        for _, step in ipairs(steps) do
            local stepKey = table.concat({
                step.questTitle or "", step.kind or "", step.text or "",
            }, "\31")
            if not merged.seen[stepKey] then
                merged.seen[stepKey] = true
                merged[#merged + 1] = step
            end
        end
    end
end

local function AddMatch(index, key, kind, questTitle, itemName, remaining,
    memberName, objective, memberClass)
    if key == nil or key == "" then return end
    local match = index[key]
    if not match then
        match = {
            kill=false, loot=false, quests={}, items={}, localProgress={},
            members={}, memberSteps={},
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
        if memberClass and memberClass ~= "" then progress.class = memberClass end
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
    else
        local progress = match.localProgress
        if remaining and remaining > 0 then
            progress[kind] = math.max(tonumber(progress[kind]) or 0, remaining)
        elseif progress[kind] == nil then
            progress[kind] = true
        end
    end
end

IndexQuestTargets = function(title, questID, objectives, memberName, memberClass)
    local resolved = AutoQuest.ResolveQuestEntries(questID, title)
    for _, match in ipairs(resolved) do
        for _, record in ipairs(match.entry.records or {}) do
            local done, remaining, objective = ObjectiveStatus(objectives, record)
            local kind = Resolver.RecordKind(record, objective, "marker")
            if objective and kind and not done then
                AddMatch(activeByNPC, tonumber(record.id), kind, title, record.item,
                    remaining, memberName, objective, memberClass)
                AddMatch(activeByName, string.lower(record.name or ""), kind, title,
                    record.item, remaining, memberName, objective, memberClass)
            end
        end
    end

    for _, objective in ipairs(objectives or {}) do
        local targetID = tonumber(objective.targetID)
        if memberName and not objective.done and objective.targetType == "monster" and targetID then
            local _, display = Resolver.Normalize(objective.text)
            local done, remaining = ParseProgress(objective)
            if not done then
                AddMatch(activeByNPC, targetID, Resolver.RecordKind({}, objective, "marker") or "kill",
                    title, nil, remaining, memberName, objective, memberClass)
                if display ~= "" then
                    AddMatch(activeByName, string.lower(display), Resolver.RecordKind({}, objective, "marker") or "kill",
                        title, nil, remaining, memberName, objective, memberClass)
                end
            end
        end
    end

    if SpawnStore then
        for _, objective in ipairs(objectives or {}) do
            local objectiveType = string.lower(objective.kind or "")
            if not objective.done
                and (objectiveType == "monster" or objectiveType == "player")
            then
                local done, remaining = ParseProgress(objective)
                local kind = Resolver.RecordKind({}, objective, "marker") or "kill"
                for _, npcID in ipairs(SpawnStore.FindNPCsByObjectiveText(objective.text) or {}) do
                    AddMatch(activeByNPC, npcID, kind, title, nil,
                        remaining, memberName, objective, memberClass)
                end
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

    local npcObjective = Resolver.ObjectiveForQuestNPC(objectives)
    local npcDone, npcRemaining = ParseProgress(npcObjective)
    local npcKind = Resolver.RecordKind({}, npcObjective, "marker")
    for _, relationshipQuestID in ipairs(relationshipQuestIDs) do
        if npcObjective and npcKind and not npcDone then
            for _, npcID in ipairs(SpawnStore.GetObjectiveNPCs(relationshipQuestID) or {}) do
                AddMatch(activeByNPC, tonumber(npcID), npcKind, title, nil,
                    npcRemaining, memberName, npcObjective, memberClass)
            end
        end

        for _, source in ipairs(SpawnStore.GetQuestItemSources(relationshipQuestID) or {}) do
            local itemObjective = Resolver.ObjectiveForQuestItem(objectives, source.itemName)
            local itemDone, itemRemaining = ParseProgress(itemObjective)
            if itemObjective and not itemDone then
                for _, npcID in ipairs(source.npcIDs or {}) do
                    AddMatch(
                        activeByNPC, tonumber(npcID), "loot", title,
                        source.itemName, itemRemaining, memberName, itemObjective, memberClass
                    )
                end
            end
        end
    end
end

local function SameContributionKeys(left, right)
    for key in pairs(left) do if not right[key] then return false end end
    for key in pairs(right) do if not left[key] then return false end end
    return true
end

function Markers.RebuildIndex()
    activeByNPC, activeByName = {}, {}
    if not Enabled() and not QuestTooltipsRequested() then return end
    Resolver.BuildActive()
    local previous, nextContributions = questContributions, {}
    local rebuilt, reused = 0, 0
    local function Include(sourceKey, quest, member)
        local fingerprint = QuestFingerprint(quest, member)
        local contribution = previous[sourceKey]
        if not contribution or contribution.fingerprint ~= fingerprint then
            contribution = BuildQuestContribution(quest, member, sourceKey, fingerprint)
            rebuilt = rebuilt + 1
        else
            reused = reused + 1
        end
        nextContributions[sourceKey] = contribution
    end
    for _, quest in ipairs(AutoQuest.QuestState.GetQuests()) do
        Include("local:" .. tostring(quest.key or quest.id or quest.title), quest)
    end

    -- Complete synchronized snapshots participate even when the local player
    -- does not have the quest. Each member/quest pair owns one contribution,
    -- so departure or completion removes only that pair from the aggregate.
    local sync = AutoQuest.GroupSync
    local members = sync and sync.GetMemberQuestData and sync.GetMemberQuestData() or {}
    for memberKey, member in pairs(members) do
        if member.completeSnapshot and not member.stale and member.connected ~= false then
            for key, quest in pairs(member.quests or {}) do
                Include("remote:" .. tostring(memberKey) .. ":" .. tostring(key), quest, member)
            end
        end
    end
    questContributions = nextContributions
    contributionStats = { rebuilt=rebuilt, reused=reused }
    if rebuilt > 0 or not SameContributionKeys(previous, nextContributions) then
        liveMatchCache = {}
    end
    for _, contribution in pairs(questContributions) do
        for key, match in pairs(contribution.byNPC) do MergeMatch(activeByNPC, key, match) end
        for key, match in pairs(contribution.byName) do MergeMatch(activeByName, key, match) end
    end
end

----------------------------------------------------------------------
-- After database matching, the shared resolver scans live unit tooltips only
-- when an unmatched kill unit or interact verification needs live evidence.
-- It also persists a unique objective/NPC confirmation for map use;
-- ambiguous duplicate labels remain immediate nameplate evidence only. Loot
-- sources always require the quest/item relationship database because other
-- addons may add unrelated item-objective lines to a unit tooltip.
----------------------------------------------------------------------
-- Returns remaining count and whether it was a percentage (e.g. an escort
-- quest's "62% complete"). Percentage objectives don't map to a kill/loot
-- count, so callers skip them rather than badge them with a wrong number.
local function ParseTooltipProgress(text)
    local current, required = Resolver.Progress(text)
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
        elseif result.kind == "kill" then
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
    if UnitIsUnit and UnitIsUnit(unit, "pet") then return nil end
    local npcID = NPCIDFromGUID(UnitGUID(unit))
    local name = UnitName(unit)
    if npcID then SpawnStore.RememberName(npcID, name) end
    local learnedNotable = npcID and UnitClassification
        and SpawnStore.RememberClassification(npcID, UnitClassification(unit))
    if learnedNotable then
        if AutoQuest.Map and AutoQuest.Map.RequestRefresh then AutoQuest.Map.RequestRefresh() end
        if Markers.RequestRefresh then Markers.RequestRefresh() end
    end
    local match = npcID and activeByNPC[npcID]
    if not match and not npcID then
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
            quests = match.quests, items = match.items,
            localProgress = match.localProgress, members = match.members,
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
    if UnitIsUnit and UnitIsUnit(unit, "pet") then return {} end
    if not QuestTooltipsRequested() then return {} end
    if not next(activeByNPC) and not next(activeByName) then Markers.RebuildIndex() end
    local match = MatchUnit(unit)
    local rows = {}
    for name, steps in pairs(match and match.memberSteps or {}) do
        local progress = match.members and match.members[name]
        local row = { name = name, class=progress and progress.class, steps = {} }
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
    marker:Hide()

    plate.AutoEverythingQuestMarker = marker
    return marker
end

local function ResetMarker(marker)
    marker.kill:Hide(); marker.kill.count:Hide()
    marker.loot:Hide(); marker.loot.count:Hide()
    marker.talk:Hide(); marker.talk.count:Hide()
end

local function ShowProgressCounts(icon, match, kind)
    local values = {}
    local localValue = match.localProgress and match.localProgress[kind]
    if type(localValue) == "number" and localValue > 0 then
        values[#values + 1] = "|cffffffff" .. localValue .. "|r"
    end

    local names = {}
    for name in pairs(match.members or {}) do names[#names + 1] = name end
    table.sort(names, function(a, b) return string.lower(a) < string.lower(b) end)
    for _, name in ipairs(names) do
        local value = match.members[name] and match.members[name][kind]
        if type(value) == "number" and value > 0 then
            values[#values + 1] = "|cff40ff40" .. value .. "|r"
        end
    end

    -- Live tooltip evidence has no source ownership, so retain the ordinary
    -- white count when no indexed local or synchronized progress is available.
    local fallback = match[kind .. "Remaining"]
    if #values == 0 and fallback and fallback > 0 then
        values[1] = "|cffffffff" .. fallback .. "|r"
    end
    if #values > 0 then
        icon.count:SetText(table.concat(values, " "))
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

    if not Enabled() or not UnitExists(unit) or UnitIsPlayer(unit)
        or (UnitIsUnit and UnitIsUnit(unit, "pet"))
    then
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
    if match.kill then ShowProgressCounts(marker.kill, match, "kill") end
    if match.loot then ShowProgressCounts(marker.loot, match, "loot") end
    if match.talk then ShowProgressCounts(marker.talk, match, "talk") end
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
    questContributions = {}
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
    print("  quest indexes rebuilt=" .. contributionStats.rebuilt
        .. " reused=" .. contributionStats.reused)
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
eventFrame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
eventFrame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
eventFrame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
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
    elseif event == "PLAYER_TARGET_CHANGED" or event == "UPDATE_MOUSEOVER_UNIT" then
        local observedUnit = event == "PLAYER_TARGET_CHANGED" and "target" or "mouseover"
        if UnitExists(observedUnit) and not UnitIsPlayer(observedUnit) then
            local npcID = NPCIDFromGUID(UnitGUID(observedUnit))
            SpawnStore.RememberName(npcID, UnitName(observedUnit))
            local learnedNotable = UnitClassification
                and SpawnStore.RememberClassification(npcID, UnitClassification(observedUnit))
            if learnedNotable and AutoQuest.Map and AutoQuest.Map.RequestRefresh then
                AutoQuest.Map.RequestRefresh(true)
            end
        end
    else
        refreshPending, refreshAt = true,
            GetTime() + (Resolver.QUEST_LOG_SETTLE_DELAY or 0.75)
    end
end)
AutoQuest.QuestState.Subscribe(function(changes)
    if changes.semanticChanged then
        refreshPending = true
        refreshAt = GetTime()
            + (changes.settled and 0 or (Resolver.QUEST_LOG_SETTLE_DELAY or 0.75))
    end
end)
eventFrame:SetScript("OnUpdate", function(_, elapsed)
    local visualEnabled = Enabled()
    local indexEnabled = visualEnabled or QuestTooltipsRequested()
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
    if refreshPending and GetTime() >= refreshAt then
        if AutoQuest.Map and AutoQuest.Map.IsQuestLayerReady
            and not AutoQuest.Map.IsQuestLayerReady()
        then
            return
        end
        refreshPending = false
        Markers.RebuildIndex()
        if visualEnabled then RefreshVisible() end
    end
end)
