----------------------------------------------------------------------
-- QuestDataStore.lua
-- ==================
-- Stable read-only access to generated quest data. Future generated files
-- populate AutoQuestData; the legacy consolidated globals remain supported
-- while the database builder transitions to the split schema. Lua 5.1.
----------------------------------------------------------------------

AutoQuest = AutoQuest or {}
AutoQuest.DataStore = AutoQuest.DataStore or {}
local Store = AutoQuest.DataStore

local questEntriesByTitle

local function Data()
    return type(AutoQuestData) == "table" and AutoQuestData or {}
end

local function Table(primary, legacy)
    local value = Data()[primary]
    if type(value) == "table" then return value end
    return type(legacy) == "table" and legacy or nil
end

local function Quests()
    return Table("quests", AscensionQuestLocationDB) or {}
end

function Store.GetSchemaVersion()
    return tonumber(Data().schemaVersion) or 0
end

function Store.HasQuestData()
    return next(Quests()) ~= nil
end

function Store.GetQuest(questID)
    return Quests()[tonumber(questID)]
end

function Store.ForEachQuest(callback)
    if type(callback) ~= "function" then return end
    for questID, quest in pairs(Quests()) do callback(tonumber(questID) or questID, quest) end
end

local function BuildQuestTitleIndex()
    questEntriesByTitle = {}
    Store.ForEachQuest(function(questID, quest)
        local title = type(quest) == "table" and quest.title
        if type(title) == "string" and title ~= "" then
            local bucket = questEntriesByTitle[title]
            if not bucket then bucket = {}; questEntriesByTitle[title] = bucket end
            bucket[#bucket + 1] = { id = questID, entry = quest }
        end
    end)
end

-- Returns the existing consumer contract: { { id=questID, entry=record } }.
-- IDs are authoritative; title matching is only a 3.3.5 compatibility path.
function Store.ResolveQuestEntries(questID, title)
    questID = tonumber(questID)
    local quest = questID and Store.GetQuest(questID)
    if quest then return { { id = questID, entry = quest } } end
    if type(title) ~= "string" or title == "" then return {} end
    local generatedIndex = Table("questIDsByTitle", nil)
    local generatedIDs = generatedIndex and generatedIndex[title]
    if generatedIDs then
        local matches = {}
        local function Add(value)
            local id = tonumber(value)
            local entry = id and Store.GetQuest(id)
            if entry then matches[#matches + 1] = { id = id, entry = entry } end
        end
        if type(generatedIDs) == "string" then
            for value in string.gmatch(generatedIDs, "[^,]+") do Add(value) end
        elseif type(generatedIDs) == "table" then
            for _, value in ipairs(generatedIDs) do Add(value) end
        end
        return matches
    end
    if not questEntriesByTitle then BuildQuestTitleIndex() end
    return questEntriesByTitle[title] or {}
end

function Store.GetQuestItemIDsByTitle(title)
    local index = Table("questItemsByTitle", QuestByTitle)
    local result = index and index[title]
    return type(result) == "table" and result or nil
end

function Store.GetNPCSpawnPacked(npcID)
    local packed = Table("npcSpawnPacked", AutoQuest.NPCSpawnPacked)
    local value = packed and packed[tonumber(npcID)]
    if type(value) == "string" then return value end
    local npc = Store.GetNPCRecord(npcID)
    return npc and type(npc.spawns) == "string" and npc.spawns or nil
end

function Store.GetNPCRecord(npcID)
    local npcs = Table("npcs", nil)
    local value = npcs and npcs[tonumber(npcID)]
    return type(value) == "table" and value or nil
end

function Store.GetNPCSpawnAreaName(areaID)
    local areas = Table("npcSpawnAreas", AutoQuest.NPCSpawnAreas)
    return areas and areas[tonumber(areaID)] or nil
end

function Store.GetNPCNamePacks()
    return Table("npcNamePacked", AutoQuest.NPCSpawnNamePacked) or {}
end

function Store.GetQuestObjectiveNPCPacked(questID)
    local index = Table("questObjectiveNPCs", AutoQuest.QuestObjectiveNPCs)
    return index and index[tonumber(questID)] or nil
end

function Store.GetQuestItemNPCPacked(questID)
    local index = Table("questItemNPCs", AutoQuest.QuestItemNPCs)
    return index and index[tonumber(questID)] or nil
end

function Store.GetItemName(itemID)
    local names = Table("itemNames", AutoQuest.QuestItemNames)
    local name = names and names[tonumber(itemID)]
    if name then return name end
    local items = Table("items", nil)
    local item = items and items[tonumber(itemID)]
    return type(item) == "table" and item.name or nil
end

function Store.GetServicesPacked()
    return Table("services", AutoQuest.ServiceNPCs) or {}
end

function Store.GetServiceName(npcID)
    local names = Table("serviceNames", AutoQuest.ServiceNPCNames)
    local name = names and names[tonumber(npcID)]
    if name then return name end
    local npc = Store.GetNPCRecord(npcID)
    return npc and npc.name or nil
end

function Store.GetServiceFactionsPacked()
    return Table("serviceFactions", AutoQuest.ServiceNPCFactions) or {}
end

function Store.ClearCache()
    questEntriesByTitle = nil
end
