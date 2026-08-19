----------------------------------------------------------------------
-- QuestState.lua
-- ==============
-- Canonical live quest-log snapshot shared by every quest consumer.
-- Records returned by this module are read-only by convention. WoW 3.3.5a /
-- Lua 5.1.
----------------------------------------------------------------------

AutoQuest = AutoQuest or {}
AutoQuest.QuestState = AutoQuest.QuestState or {}
local State = AutoQuest.QuestState

local quests = {}
local questsByKey = {}
local questsByID = {}
local questsByTitle = {}
local questsByLogIndex = {}
local revision = 0
local signature = ""
local initialized = false
local refreshing = false

local function PlainText(value)
    value = string.gsub(value or "", "|c%x%x%x%x%x%x%x%x", "")
    return string.gsub(value, "|r", "")
end

local function Progress(text)
    local current, required
    for rawCurrent, rawRequired in string.gmatch(PlainText(text), "(%d+)%s*/%s*(%d+)") do
        current, required = tonumber(rawCurrent), tonumber(rawRequired)
    end
    return current, required
end

local function IsComplete(value)
    return value == true or value == 1 or value == "1"
end

local function TitleHash(title)
    local hash = 5381
    for index = 1, string.len(title or "") do
        hash = math.fmod((hash * 33) + string.byte(title, index), 4294967296)
    end
    return string.format("T%08x", hash)
end

function State.QuestKey(questID, title)
    questID = tonumber(questID)
    if questID and questID > 0 then return "I" .. tostring(questID) end
    return TitleHash(title or "")
end

local function BuildSnapshot()
    local ordered, byKey, byID, byTitle, byLogIndex = {}, {}, {}, {}, {}
    local parts = {}
    local entryCount = GetNumQuestLogEntries and (GetNumQuestLogEntries() or 0) or 0

    for logIndex = 1, entryCount do
        local title, level, questTag, suggestedGroup, isHeader, isCollapsed,
            rawComplete, rawDaily, questID = GetQuestLogTitle(logIndex)
        if title and not isHeader then
            local numericID = tonumber(questID)
            if numericID and numericID <= 0 then numericID = nil end
            local quest = {
                key = State.QuestKey(numericID, title),
                id = numericID,
                title = title,
                level = tonumber(level) or 0,
                tag = questTag,
                suggestedGroup = tonumber(suggestedGroup) or 0,
                collapsed = IsComplete(isCollapsed),
                complete = IsComplete(rawComplete),
                isDaily = IsComplete(rawDaily),
                rawComplete = rawComplete,
                rawDaily = rawDaily,
                logIndex = logIndex,
                objectives = {},
            }

            local objectiveCount = GetNumQuestLeaderBoards
                and (GetNumQuestLeaderBoards(logIndex) or 0) or 0
            for objectiveIndex = 1, objectiveCount do
                local text, objectiveType, rawFinished =
                    GetQuestLogLeaderBoard(objectiveIndex, logIndex)
                local current, required = Progress(text)
                local finished = IsComplete(rawFinished)
                    or (current ~= nil and required ~= nil and required > 0 and current >= required)
                quest.objectives[objectiveIndex] = {
                    index = objectiveIndex,
                    text = text or "",
                    type = objectiveType or "",
                    finished = finished,
                    rawFinished = rawFinished,
                    current = current,
                    required = required,
                }
            end
            quest.objectiveCount = #quest.objectives

            ordered[#ordered + 1] = quest
            byKey[quest.key] = quest
            if numericID then byID[numericID] = quest end
            byTitle[title] = byTitle[title] or {}
            byTitle[title][#byTitle[title] + 1] = quest
            byLogIndex[logIndex] = quest

            parts[#parts + 1] = table.concat({
                quest.key, title, quest.complete and "1" or "0", tostring(objectiveCount),
            }, "\30")
            for _, objective in ipairs(quest.objectives) do
                parts[#parts + 1] = table.concat({
                    objective.text, objective.type, objective.finished and "1" or "0",
                }, "\30")
            end
        end
    end

    return ordered, byKey, byID, byTitle, byLogIndex, table.concat(parts, "\31")
end

function State.Refresh()
    if refreshing then return false end
    refreshing = true
    local ordered, byKey, byID, byTitle, byLogIndex, nextSignature = BuildSnapshot()
    quests, questsByKey, questsByID = ordered, byKey, byID
    questsByTitle, questsByLogIndex = byTitle, byLogIndex
    local changed = not initialized or nextSignature ~= signature
    signature = nextSignature
    initialized = true
    if changed then revision = revision + 1 end
    refreshing = false
    return changed
end

local function EnsureInitialized()
    if not initialized then State.Refresh() end
end

function State.GetQuests()
    EnsureInitialized()
    return quests
end

function State.GetByKey(key)
    EnsureInitialized()
    return questsByKey[key]
end

function State.GetByID(questID)
    EnsureInitialized()
    return questsByID[tonumber(questID)]
end

function State.GetByTitle(title)
    EnsureInitialized()
    return questsByTitle[title] or {}
end

function State.GetByLogIndex(logIndex)
    EnsureInitialized()
    return questsByLogIndex[tonumber(logIndex)]
end

function State.GetRevision()
    EnsureInitialized()
    return revision
end

function State.GetSignature()
    EnsureInitialized()
    return signature
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("QUEST_LOG_UPDATE")
eventFrame:RegisterEvent("QUEST_WATCH_UPDATE")
eventFrame:RegisterEvent("UNIT_QUEST_LOG_CHANGED")
eventFrame:RegisterEvent("QUEST_ACCEPTED")
eventFrame:RegisterEvent("QUEST_FINISHED")
eventFrame:SetScript("OnEvent", function(_, event, addonName)
    if event ~= "ADDON_LOADED" or addonName == "AutoEverything" then
        State.Refresh()
    end
end)
