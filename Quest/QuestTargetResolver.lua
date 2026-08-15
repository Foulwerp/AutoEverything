----------------------------------------------------------------------
-- QuestTargetResolver.lua
-- =======================
-- Shared live objective identity, evidence, and tooltip confirmation.
----------------------------------------------------------------------
AutoQuest = AutoQuest or {}
AutoQuest.ObjectiveResolver = AutoQuest.ObjectiveResolver or {}
local Resolver = AutoQuest.ObjectiveResolver

local activeObjectives = {}
local activeByKey = {}
local activeByLabel = {}
local refreshPending, refreshAt = false, 0

-- Ascension can fire QUEST_LOG_UPDATE before the objective's finished flag
-- has settled. GroupSync intentionally reads the log after 0.65 seconds; pins
-- and nameplate markers must not take an earlier snapshot and then remain
-- stale until the next unrelated quest update.
Resolver.QUEST_LOG_SETTLE_DELAY = 0.75

local function Trim(value)
    value = string.gsub(value or "", "^%s+", "")
    return string.gsub(value, "%s+$", "")
end

function Resolver.Normalize(text)
    local label = string.gsub(text or "", "|c%x%x%x%x%x%x%x%x", "")
    label = string.gsub(label, "|r", "")
    label = string.gsub(label, "%s*%d+%s*/%s*%d+%s*$", "")
    label = string.gsub(label, "%s*%d+%%%s*$", "")
    label = string.gsub(label, ":%s*$", "")
    label = Trim(label)
    label = string.gsub(label, "%s+", " ")
    return string.lower(label), label
end

function Resolver.KindFromClientType(objectiveType)
    objectiveType = string.lower(objectiveType or "")
    if objectiveType == "monster" or objectiveType == "player" then return "kill" end
    if objectiveType == "item" then return "loot" end
    if objectiveType == "object" or objectiveType == "event" then return "interact" end
    return "neutral"
end

function Resolver.IsComplete(value)
    return value == true or value == 1 or value == "1"
end

-- Custom event/object objectives occasionally update their visible progress
-- before the client flips the finished return value. Treat a final N/N count
-- as complete as well, using the last progress pair on the line so numbers in
-- an objective's name cannot be mistaken for its progress.
function Resolver.ObjectiveIsComplete(text, finished)
    if Resolver.IsComplete(finished) then return true end
    local current, required
    for rawCurrent, rawRequired in string.gmatch(text or "", "(%d+)%s*/%s*(%d+)") do
        current, required = tonumber(rawCurrent), tonumber(rawRequired)
    end
    return current ~= nil and required ~= nil and required > 0 and current >= required
end

local function ObjectiveKey(questID, title, objectiveIndex, label)
    if questID and questID > 0 then
        return table.concat({ "id", questID, objectiveIndex, label }, ":")
    end
    local normalizedTitle = Resolver.Normalize(title)
    return table.concat({ "title", normalizedTitle, objectiveIndex, label }, ":")
end

local function SavedTargets()
    AutoEverythingCharDB = AutoEverythingCharDB or {}
    if type(AutoEverythingCharDB.questTargets) ~= "table" then
        AutoEverythingCharDB.questTargets = {}
    end
    return AutoEverythingCharDB.questTargets
end

local function NPCIDFromGUID(guid)
    if type(guid) ~= "string" then return nil end

    local fields = {}
    for field in string.gmatch(guid, "[^-]+") do fields[#fields + 1] = field end
    if fields[1] == "Creature" or fields[1] == "Vehicle" then
        local value = tonumber(fields[6])
        if value and value > 0 then return value end
    end

    if string.sub(guid, 1, 2) == "0x" and string.len(guid) >= 12 then
        local value = tonumber(string.sub(guid, 7, 12), 16)
        if value and value > 0 then return value end
    end

    -- Ascension's helper can truncate legacy GUID creature IDs (for example,
    -- 0x336 / 822 may be reported as 82). Use it only for an unknown GUID
    -- format after the stable client encodings above have been exhausted.
    if type(GetCreatureIDFromGUID) == "function" then
        local ok, value = pcall(GetCreatureIDFromGUID, guid)
        value = ok and tonumber(value) or nil
        if value and value > 0 then return value end
    end
end

Resolver.NPCIDFromGUID = NPCIDFromGUID

function Resolver.Prune(active)
    local valid = active or activeByKey
    local saved = SavedTargets()
    for key in pairs(saved) do
        if not valid[key] then saved[key] = nil end
    end
end

function Resolver.BuildActive()
    local objectives, byKey, byLabel = {}, {}, {}
    local entries = GetNumQuestLogEntries and GetNumQuestLogEntries() or 0
    for logIndex = 1, entries do
        local title, _, _, _, isHeader, _, questComplete, _, questID =
            GetQuestLogTitle(logIndex)
        if title and not isHeader and not Resolver.IsComplete(questComplete) then
            local count = GetNumQuestLeaderBoards and GetNumQuestLeaderBoards(logIndex) or 0
            for objectiveIndex = 1, count do
                local raw, objectiveType, done =
                    GetQuestLogLeaderBoard(objectiveIndex, logIndex)
                local label, display = Resolver.Normalize(raw)
                if not Resolver.ObjectiveIsComplete(raw, done) and label ~= "" then
                    local numericQuestID = tonumber(questID)
                    local objective = {
                        key = ObjectiveKey(numericQuestID, title, objectiveIndex, label),
                        questID = numericQuestID and numericQuestID > 0 and numericQuestID or nil,
                        questTitle = title,
                        logIndex = logIndex,
                        objectiveIndex = objectiveIndex,
                        rawLabel = raw or "",
                        label = label,
                        displayLabel = display,
                        clientType = string.lower(objectiveType or ""),
                        kind = Resolver.KindFromClientType(objectiveType),
                    }
                    objectives[#objectives + 1] = objective
                    byKey[objective.key] = objective
                    byLabel[label] = byLabel[label] or {}
                    byLabel[label][#byLabel[label] + 1] = objective
                end
            end
        end
    end
    activeObjectives, activeByKey, activeByLabel = objectives, byKey, byLabel
    Resolver.Prune(byKey)
    return objectives, byKey, byLabel
end

function Resolver.GetActive()
    return activeObjectives, activeByKey, activeByLabel
end

function Resolver.GetConfirmations(objectiveKey)
    return SavedTargets()[objectiveKey]
end

function Resolver.Confirm(objectiveKey, npcID, kind, npcName)
    local objective = activeByKey[objectiveKey]
    npcID = tonumber(npcID)
    if not objective or not npcID or npcID <= 0 then return false end
    kind = kind or objective.kind
    if kind == "neutral" then return false end

    local saved = SavedTargets()
    local confirmation = saved[objectiveKey]
    if not confirmation then
        confirmation = { kind = kind, npcIDs = {} }
        saved[objectiveKey] = confirmation
    elseif confirmation.kind ~= kind then
        -- Conflicting evidence is not safe to promote to exact map pins.
        saved[objectiveKey] = nil
        return false
    end
    if type(confirmation.npcIDs) ~= "table" then
        confirmation.npcIDs = {}
    end
    local changed = false
    if not confirmation.npcIDs[npcID] then
        confirmation.npcIDs[npcID] = true
        changed = true
    end
    if type(npcName) == "string" and npcName ~= "" then
        if type(confirmation.npcNames) ~= "table" then confirmation.npcNames = {} end
        if confirmation.npcNames[npcID] ~= npcName then
            confirmation.npcNames[npcID] = npcName
            changed = true
        end
    end
    if not changed then return false end
    if AutoQuest.Markers and AutoQuest.Markers.RequestRefresh then
        AutoQuest.Markers.RequestRefresh()
    end
    if AutoQuest.Map and AutoQuest.Map.RequestRefresh then
        AutoQuest.Map.RequestRefresh()
    end
    return true
end

local scanTooltip

local function ScanTooltip()
    if scanTooltip then return scanTooltip end
    scanTooltip = CreateFrame(
        "GameTooltip", "AEQuestTargetResolverTooltip", nil, "GameTooltipTemplate"
    )
    scanTooltip:SetOwner(WorldFrame, "ANCHOR_NONE")
    return scanTooltip
end

local function SharedKind(matches)
    local kind
    for _, objective in ipairs(matches) do
        if not kind then kind = objective.kind
        elseif kind ~= objective.kind then return "neutral" end
    end
    return kind or "neutral"
end

function Resolver.MatchTooltip(unit)
    if not unit or not UnitExists(unit) or UnitIsPlayer(unit) then return nil end
    if not next(activeByKey) then Resolver.BuildActive() end

    local tooltip = ScanTooltip()
    tooltip:ClearLines()
    tooltip:SetUnit(unit)
    local npcID = NPCIDFromGUID(UnitGUID(unit))
    local immediate = {}
    local promotable
    for lineIndex = 2, tooltip:NumLines() do
        local region = _G["AEQuestTargetResolverTooltipTextLeft" .. lineIndex]
        local raw = region and region:GetText()
        local label = raw and Resolver.Normalize(raw) or ""
        local matches = label ~= "" and activeByLabel[label] or nil
        if matches and #matches > 0 then
            local kind = SharedKind(matches)
            local result = {
                label = label,
                rawLabel = raw,
                kind = kind,
                npcID = npcID,
                ambiguous = #matches ~= 1,
                objectives = matches,
            }
            immediate[#immediate + 1] = result
            if #matches == 1 and npcID and kind ~= "neutral" then
                promotable = matches[1]
                local npcName = type(UnitName) == "function" and UnitName(unit) or nil
                local added = Resolver.Confirm(promotable.key, npcID, kind, npcName)
                local confirmation = Resolver.GetConfirmations(promotable.key)
                result.promoted = added or (
                    confirmation
                    and confirmation.kind == kind
                    and type(confirmation.npcIDs) == "table"
                    and confirmation.npcIDs[npcID]
                ) or false
            end
        end
    end
    if #immediate == 0 then return nil end
    return immediate, promotable
end

function Resolver.RequestRefresh()
    refreshPending, refreshAt = true, 0
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("QUEST_LOG_UPDATE")
eventFrame:RegisterEvent("QUEST_WATCH_UPDATE")
eventFrame:RegisterEvent("UNIT_QUEST_LOG_CHANGED")
eventFrame:RegisterEvent("QUEST_ITEM_UPDATE")
eventFrame:RegisterEvent("QUEST_FINISHED")
eventFrame:RegisterEvent("BAG_UPDATE")
eventFrame:RegisterEvent("ITEM_PUSH")
eventFrame:SetScript("OnEvent", function()
    refreshPending, refreshAt = true, GetTime() + Resolver.QUEST_LOG_SETTLE_DELAY
end)
eventFrame:SetScript("OnUpdate", function()
    if refreshPending and GetTime() >= refreshAt then
        refreshPending = false
        Resolver.BuildActive()
    end
end)
