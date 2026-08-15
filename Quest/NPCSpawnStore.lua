----------------------------------------------------------------------
-- NPCSpawnStore.lua
-- =================
-- Lazy access to the consolidated packed NPC coordinate database.
----------------------------------------------------------------------
AutoQuest = AutoQuest or {}
AutoQuest.NPCSpawnStore = AutoQuest.NPCSpawnStore or {}
local Store = AutoQuest.NPCSpawnStore

local decoded = {}
local decodedQuestNPCs = {}
local decodedQuestItems = {}
local decodedServices

local serviceOrder = {
    "auctioneer", "banker", "battlemaster", "flightmaster", "guildmaster",
    "innkeeper", "talentunlearner", "tabardvendor", "stablemaster", "trainer", "vendor",
}

local function Decode(packed)
    local locations = {}
    for group in string.gmatch(packed or "", "[^|]+") do
        local header, points = string.match(group, "^([^:]+):(.*)$")
        local areaText, floorText
        if header then
            areaText, floorText = string.match(header, "^(%d+),(%d+)$")
        end
        local areaID, floor = tonumber(areaText), tonumber(floorText)
        if areaID and floor and points then
            local location = {
                zoneID = areaID,
                zone = type(AutoQuest.NPCSpawnAreas) == "table"
                    and AutoQuest.NPCSpawnAreas[areaID] or ("Map " .. areaID),
                floor = floor,
                coords = {},
            }
            for point in string.gmatch(points, "[^;]+") do
                local xText, yText = string.match(point, "^([^,]+),([^,]+)$")
                local x, y = tonumber(xText), tonumber(yText)
                if x and y and x >= 0 and x <= 100 and y >= 0 and y <= 100 then
                    location.coords[#location.coords + 1] = { x, y }
                end
            end
            if #location.coords > 0 then locations[#locations + 1] = location end
        end
    end
    return locations
end

function Store.Get(npcID)
    npcID = tonumber(npcID)
    if not npcID then return nil end

    local packed = type(AutoQuest.NPCSpawnPacked) == "table"
        and AutoQuest.NPCSpawnPacked[npcID] or nil
    if type(packed) == "string" then
        if not decoded[npcID] then decoded[npcID] = Decode(packed) end
        return decoded[npcID]
    end
    return nil
end

-- NPC pages expose an "Objective of" quest list. The generator stores the
-- inverse relationship as a compact comma-separated NPC list per quest so an
-- active quest can activate its known spawns without scanning the whole DB.
function Store.GetObjectiveNPCs(questID)
    questID = tonumber(questID)
    if not questID then return nil end
    if decodedQuestNPCs[questID] ~= nil then
        return decodedQuestNPCs[questID] or nil
    end

    local packed = type(AutoQuest.QuestObjectiveNPCs) == "table"
        and AutoQuest.QuestObjectiveNPCs[questID] or nil
    if type(packed) ~= "string" or packed == "" then
        decodedQuestNPCs[questID] = false
        return nil
    end

    local result = {}
    for value in string.gmatch(packed, "[^,]+") do
        local npcID = tonumber(value)
        if npcID and npcID > 0 then result[#result + 1] = npcID end
    end
    decodedQuestNPCs[questID] = result
    return result
end

-- Required item pages expose both the quests that need the item and every NPC
-- in their Dropped-by table. Keep item identity in the packed relationship so
-- mixed-objective quests can match the correct live item objective.
function Store.GetQuestItemSources(questID)
    questID = tonumber(questID)
    if not questID then return nil end
    if decodedQuestItems[questID] ~= nil then
        return decodedQuestItems[questID] or nil
    end

    local packed = type(AutoQuest.QuestItemNPCs) == "table"
        and AutoQuest.QuestItemNPCs[questID] or nil
    if type(packed) ~= "string" or packed == "" then
        decodedQuestItems[questID] = false
        return nil
    end

    local result = {}
    for group in string.gmatch(packed, "[^|]+") do
        local itemText, npcText = string.match(group, "^(%d+):(.*)$")
        local itemID = tonumber(itemText)
        if itemID then
            local source = {
                itemID = itemID,
                itemName = type(AutoQuest.QuestItemNames) == "table"
                    and AutoQuest.QuestItemNames[itemID] or nil,
                npcIDs = {},
            }
            for value in string.gmatch(npcText or "", "[^,]+") do
                local npcID = tonumber(value)
                if npcID and npcID > 0 then source.npcIDs[#source.npcIDs + 1] = npcID end
            end
            if #source.npcIDs > 0 then result[#result + 1] = source end
        end
    end
    decodedQuestItems[questID] = result
    return result
end

function Store.GetServices()
    if decodedServices then return decodedServices end
    decodedServices = {}
    local packedServices = type(AutoQuest.ServiceNPCs) == "table"
        and AutoQuest.ServiceNPCs or {}
    local names = type(AutoQuest.ServiceNPCNames) == "table"
        and AutoQuest.ServiceNPCNames or {}
    for _, kind in ipairs(serviceOrder) do
        local packed = packedServices[kind]
        if type(packed) == "string" then
            for value in string.gmatch(packed, "[^,]+") do
                local npcID = tonumber(value)
                if npcID and npcID > 0 then
                    decodedServices[#decodedServices + 1] = {
                        id = npcID,
                        kind = kind,
                        name = names[npcID],
                    }
                end
            end
        end
    end
    return decodedServices
end

function Store.ClearCache()
    decoded = {}
    decodedQuestNPCs = {}
    decodedQuestItems = {}
    decodedServices = nil
end
