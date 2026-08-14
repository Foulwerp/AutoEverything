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
    if type(GetCreatureIDFromGUID) == "function" then
        local ok, value = pcall(GetCreatureIDFromGUID, guid)
        value = ok and tonumber(value) or nil
        if value and value > 0 then return value end
    end

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
        if title and not isHeader and questComplete ~= 1 and questComplete ~= true then
            local count = GetNumQuestLeaderBoards and GetNumQuestLeaderBoards(logIndex) or 0
            for objectiveIndex = 1, count do
                local raw, objectiveType, done =
                    GetQuestLogLeaderBoard(objectiveIndex, logIndex)
                local label, display = Resolver.Normalize(raw)
                if not done and label ~= "" then
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

function Resolver.Confirm(objectiveKey, npcID, kind)
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
    if confirmation.npcIDs[npcID] then return false end
    confirmation.npcIDs[npcID] = true
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
                local added = Resolver.Confirm(promotable.key, npcID, kind)
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
eventFrame:SetScript("OnEvent", function()
    refreshPending, refreshAt = true, GetTime() + 0.2
end)
eventFrame:SetScript("OnUpdate", function()
    if refreshPending and GetTime() >= refreshAt then
        refreshPending = false
        Resolver.BuildActive()
    end
end)
