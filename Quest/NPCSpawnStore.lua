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
local decodedServiceFactions
local observedNames = {}
local npcIDsByName
local npcNamesByID

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

-- The 3.3.5 API cannot resolve an arbitrary creature ID to a display name.
-- Remember names from visible units so relationship-only loot pins can replace
-- fallback labels such as "NPC 1245" with the creature's real name.
function Store.RememberName(npcID, name)
    npcID = tonumber(npcID)
    if not npcID or type(name) ~= "string" or name == "" then return false end
    if observedNames[npcID] == name then return false end
    observedNames[npcID] = name
    return true
end

local function BuildNPCNameIndex()
    npcIDsByName = {}
    npcNamesByID = {}
    local seen = {}
    local function Add(npcID, name)
        npcID = tonumber(npcID)
        if not npcID or type(name) ~= "string" or name == "" then return end
        local key = string.lower(name)
        local bucket = npcIDsByName[key]
        if not bucket then
            bucket = {}
            npcIDsByName[key] = bucket
            seen[key] = {}
        end
        if not seen[key][npcID] then
            seen[key][npcID] = true
            bucket[#bucket + 1] = npcID
        end
        if not npcNamesByID[npcID] then npcNamesByID[npcID] = name end
    end

    for _, packed in ipairs(AutoQuest.NPCSpawnNamePacked or {}) do
        for row in string.gmatch(packed, "[^\n]+") do
            local npcText, name = string.match(row, "^(%d+)=(.*)$")
            Add(npcText, name)
        end
    end
    for _, entry in pairs(AscensionQuestLocationDB or {}) do
        for _, record in ipairs(entry.records or {}) do
            if tonumber(record.type) ~= 2 and tonumber(record.type) ~= -1 then
                Add(record.id, record.name)
            end
        end
    end
    for npcID, name in pairs(AutoQuest.ServiceNPCNames or {}) do Add(npcID, name) end
end

function Store.GetName(npcID)
    npcID = tonumber(npcID)
    if not npcID then return nil end
    if observedNames[npcID] then return observedNames[npcID] end
    if not npcNamesByID then BuildNPCNameIndex() end
    return npcNamesByID[npcID]
end

-- Unified NPC spawn record used by map pins, diagnostics, and manual lookup.
-- Locations are decoded lazily and share the canonical packed coordinate data.
function Store.GetNPC(npcID)
    npcID = tonumber(npcID)
    if not npcID then return nil end
    local locations = Store.Get(npcID)
    if type(locations) ~= "table" then return nil end
    return {
        id = npcID,
        name = Store.GetName(npcID) or ("NPC " .. npcID),
        locations = locations,
    }
end

function Store.FindNPCsByName(name)
    if type(name) ~= "string" or name == "" then return nil end
    if not npcIDsByName then BuildNPCNameIndex() end
    return npcIDsByName[string.lower(name)]
end

-- Recover monster IDs for quests missing from the public quest catalog by
-- matching their live objective label against NPC names already present in
-- the generated quest data. Prefer the longest name so a specific creature
-- wins over a shorter name contained inside it.
function Store.FindNPCsByObjectiveText(text)
    if type(text) ~= "string" or text == "" then return nil end
    if not npcIDsByName then BuildNPCNameIndex() end
    local label = string.lower(text)
    local best, bestLength
    for name, npcIDs in pairs(npcIDsByName) do
        if string.find(label, name, 1, true)
            and (not bestLength or string.len(name) > bestLength)
        then
            best, bestLength = npcIDs, string.len(name)
        end
    end
    return best
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
    if not decodedServiceFactions then
        decodedServiceFactions = {}
        local packedFactions = type(AutoQuest.ServiceNPCFactions) == "table"
            and AutoQuest.ServiceNPCFactions or {}
        for _, faction in ipairs({ "Alliance", "Horde", "Both", "Neither" }) do
            for value in string.gmatch(packedFactions[faction] or "", "[^,]+") do
                local npcID = tonumber(value)
                if npcID and npcID > 0 then decodedServiceFactions[npcID] = faction end
            end
        end
    end
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
                        faction = decodedServiceFactions[npcID],
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
    decodedServiceFactions = nil
    observedNames = {}
    npcIDsByName = nil
    npcNamesByID = nil
end
