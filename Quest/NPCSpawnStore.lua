----------------------------------------------------------------------
-- NPCSpawnStore.lua
-- =================
-- Lazy access to the consolidated packed NPC coordinate database.
----------------------------------------------------------------------
AutoQuest = AutoQuest or {}
AutoQuest.NPCSpawnStore = AutoQuest.NPCSpawnStore or {}
local Store = AutoQuest.NPCSpawnStore
local DataStore = AutoQuest.DataStore

local decoded = {}
local decodedQuestNPCs = {}
local decodedQuestItems = {}
local decodedServices
local decodedServiceFactions
local observedNames = {}
local npcIDsByName
local npcNamesByID
local metadataByID = {}
local metadataPackStarts
local notableNPCs
local notableNPCsBuilding = false
local observedClassifications = {}

local serviceOrder = {
    "auctioneer", "banker", "battlemaster", "flightmaster", "guildmaster",
    "innkeeper", "talentunlearner", "tabardvendor", "stablemaster", "trainer", "vendor",
}

local function SplitTabs(row)
    local values = {}
    for value in string.gmatch((row or "") .. "\t", "([^\t]*)\t") do
        values[#values + 1] = value
    end
    return values
end

local function MetadataRow(row)
    local values = SplitTabs(row)
    local npcID = tonumber(values[1])
    if not npcID then return nil end
    return {
        id=npcID, name=values[2] ~= "" and values[2] or nil,
        minLevel=tonumber(values[3]), maxLevel=tonumber(values[4]),
        creatureType=tonumber(values[5]), family=tonumber(values[6]),
        classification=tonumber(values[7]) or 0, boss=values[8] == "1",
        hasQuests=values[9] == "1", allianceReaction=tonumber(values[10]),
        hordeReaction=tonumber(values[11]),
    }
end

local function ForEachMetadata(callback, cooperate)
    for _, packed in ipairs(DataStore.GetNPCMetadataPacks()) do
        for row in string.gmatch(packed, "[^\n]+") do
            local metadata = MetadataRow(row)
            if metadata then callback(metadata) end
            if cooperate then cooperate() end
        end
    end
end

-- Metadata is generated in ascending NPC-ID chunks. Index only each chunk's
-- first ID so a one-NPC lookup parses roughly one chunk, not the full file.
local function MetadataPackForID(npcID)
    local packs = DataStore.GetNPCMetadataPacks()
    if not metadataPackStarts then
        metadataPackStarts = {}
        for index, packed in ipairs(packs) do
            metadataPackStarts[index] = tonumber(string.match(packed, "^(%d+)\t"))
        end
    end
    local selected
    for index, firstID in ipairs(metadataPackStarts) do
        if firstID and firstID <= npcID then selected = packs[index] else break end
    end
    return selected
end

local function NotableKind(metadata)
    if not metadata then return nil end
    local observed = observedClassifications[metadata.id]
    if observed == "worldboss" then return "boss" end
    if observed == "rare" or observed == "rareelite" then return "rare" end
    local classification = tonumber(metadata.classification)
    if metadata.boss or classification == 3 then return "boss" end
    if classification == 2 or classification == 4 then return "rare" end
end

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
                zone = DataStore.GetNPCSpawnAreaName(areaID) or ("Map " .. areaID),
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

    local packed = DataStore.GetNPCSpawnPacked(npcID)
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

function Store.RememberClassification(npcID, classification)
    npcID = tonumber(npcID)
    if not npcID or type(classification) ~= "string" or classification == "" then return false end
    if observedClassifications[npcID] == classification then return false end
    observedClassifications[npcID] = classification
    notableNPCs = nil
    return classification == "worldboss" or classification == "rare"
        or classification == "rareelite"
end

function Store.GetMetadata(npcID)
    npcID = tonumber(npcID)
    if not npcID then return nil end
    if metadataByID[npcID] ~= nil then return metadataByID[npcID] or nil end
    local generated = DataStore.GetNPCRecord(npcID)
    if generated then
        local metadata = {
            id=npcID, name=generated.name, minLevel=generated.minLevel,
            maxLevel=generated.maxLevel, creatureType=generated.creatureType,
            family=generated.family, classification=generated.classification,
            boss=generated.boss == true or generated.boss == 1,
            hasQuests=generated.hasQuests == true or generated.hasQuests == 1,
        }
        metadataByID[npcID] = metadata
        return metadata
    end
    local found
    local packed = MetadataPackForID(npcID)
    for row in string.gmatch(packed or "", "[^\n]+") do
        local metadata = MetadataRow(row)
        if metadata and metadata.id == npcID then found = metadata; break end
        if metadata and metadata.id > npcID then break end
    end
    metadataByID[npcID] = found or false
    return found
end

function Store.GetNotableNPCs(cooperate)
    if notableNPCs then return notableNPCs end
    if notableNPCsBuilding then return nil end
    notableNPCsBuilding = true
    local result = {}
    local seen = {}
    local function Add(metadata)
        local kind = NotableKind(metadata)
        if kind and not seen[metadata.id] then
            seen[metadata.id] = true
            metadata.kind = kind
            result[#result + 1] = metadata
            metadataByID[metadata.id] = metadata
        end
    end
    ForEachMetadata(Add, cooperate)
    for npcID in pairs(observedClassifications) do
        Add(Store.GetMetadata(npcID) or { id=npcID, name=Store.GetName(npcID) })
    end
    notableNPCs = result
    notableNPCsBuilding = false
    return notableNPCs
end

function Store.AreNotableNPCsReady()
    return notableNPCs ~= nil
end

local function BuildNPCNameIndex(cooperate)
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

    for _, packed in ipairs(DataStore.GetNPCNamePacks()) do
        for row in string.gmatch(packed, "[^\n]+") do
            local npcText, name = string.match(row, "^(%d+)=(.*)$")
            Add(npcText, name)
            if cooperate then cooperate() end
        end
    end
    DataStore.ForEachQuest(function(_, entry)
        for _, record in ipairs(entry.records or {}) do
            if tonumber(record.type) ~= 2 and tonumber(record.type) ~= -1 then
                Add(record.id, record.name)
            end
        end
        if cooperate then cooperate() end
    end)
    for _, packedIDs in pairs(DataStore.GetServicesPacked()) do
        for value in string.gmatch(type(packedIDs) == "string" and packedIDs or "", "[^,]+") do
            local npcID = tonumber(value)
            if npcID then Add(npcID, DataStore.GetServiceName(npcID)) end
            if cooperate then cooperate() end
        end
    end
end

function Store.PrepareQuestLookups(cooperate)
    if not npcIDsByName then BuildNPCNameIndex(cooperate) end
end

function Store.GetName(npcID)
    npcID = tonumber(npcID)
    if not npcID then return nil end
    if observedNames[npcID] then return observedNames[npcID] end
    if npcNamesByID and npcNamesByID[npcID] then return npcNamesByID[npcID] end
    local metadata = Store.GetMetadata(npcID)
    if metadata and metadata.name then return metadata.name end
    -- Generated metadata normally supplies every NPC name. Keep the broader
    -- quest-record fallback for unusual legacy data, but do not build that
    -- global index for ordinary one-ID lookups.
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
    local metadata = Store.GetMetadata(npcID) or {}
    return {
        id = npcID,
        name = metadata.name or Store.GetName(npcID) or ("NPC " .. npcID),
        locations = locations,
        kind = NotableKind(metadata), metadata = metadata,
    }
end

function Store.SearchNPCs(query, maximum)
    query = strtrim and strtrim(tostring(query or "")) or tostring(query or "")
    maximum = math.max(1, math.min(tonumber(maximum) or 20, 50))
    if query == "" then return {} end
    local numericID = tonumber(query)
    if numericID then
        local metadata = Store.GetMetadata(numericID)
        local npc = Store.GetNPC(numericID)
        if metadata or npc then
            return { npc or {
                id=numericID, name=metadata and metadata.name or ("NPC " .. numericID),
                locations={}, kind=NotableKind(metadata), metadata=metadata,
            } }
        end
        return {}
    end

    if not npcIDsByName then BuildNPCNameIndex() end
    local needle, exact, partial = string.lower(query), {}, {}
    for _, npcID in ipairs(npcIDsByName[needle] or {}) do
        exact[#exact + 1] = {
            id=npcID, name=npcNamesByID[npcID] or query,
        }
    end
    for name, npcIDs in pairs(npcIDsByName) do
        if name ~= needle and #partial < maximum
            and string.find(name, needle, 1, true)
        then
            for _, npcID in ipairs(npcIDs) do
                partial[#partial + 1] = {
                    id=npcID, name=npcNamesByID[npcID] or name,
                }
                if #partial >= maximum then break end
            end
        end
    end
    local results, seen = {}, {}
    local function Add(metadata)
        if #results >= maximum or seen[metadata.id] then return end
        seen[metadata.id] = true
        local fullMetadata = Store.GetMetadata(metadata.id) or metadata
        local npc = Store.GetNPC(metadata.id)
        results[#results + 1] = npc or {
            id=metadata.id, name=fullMetadata.name or ("NPC " .. metadata.id),
            locations={}, kind=NotableKind(fullMetadata), metadata=fullMetadata,
        }
    end
    table.sort(exact, function(a, b) return a.id < b.id end)
    table.sort(partial, function(a, b)
        if a.name == b.name then return a.id < b.id end
        return string.lower(a.name or "") < string.lower(b.name or "")
    end)
    for _, metadata in ipairs(exact) do Add(metadata) end
    for _, metadata in ipairs(partial) do Add(metadata) end
    return results
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
function Store.FindNPCsByObjectiveText(text, cooperate)
    if type(text) ~= "string" or text == "" then return nil end
    if not npcIDsByName then BuildNPCNameIndex(cooperate) end
    local label = string.lower(text)
    local best, bestLength
    for name, npcIDs in pairs(npcIDsByName) do
        if string.find(label, name, 1, true)
            and (not bestLength or string.len(name) > bestLength)
        then
            best, bestLength = npcIDs, string.len(name)
        end
        if cooperate then cooperate() end
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

    local packed = DataStore.GetQuestObjectiveNPCPacked(questID)
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

    local packed = DataStore.GetQuestItemNPCPacked(questID)
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
                itemName = DataStore.GetItemName(itemID),
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
    local packedServices = DataStore.GetServicesPacked()
    if not decodedServiceFactions then
        decodedServiceFactions = {}
        local packedFactions = DataStore.GetServiceFactionsPacked()
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
                        name = DataStore.GetServiceName(npcID),
                        faction = decodedServiceFactions[npcID],
                    }
                end
            end
        end
    end
    return decodedServices
end

function Store.ClearCache()
    if DataStore.ClearCache then DataStore.ClearCache() end
    decoded = {}
    decodedQuestNPCs = {}
    decodedQuestItems = {}
    decodedServices = nil
    decodedServiceFactions = nil
    observedNames = {}
    metadataByID = {}
    metadataPackStarts = nil
    notableNPCs = nil
    notableNPCsBuilding = false
    npcIDsByName = nil
    npcNamesByID = nil
end
