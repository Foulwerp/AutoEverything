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
local npcNamesByPrefix
local shortNPCNames
local objectiveNPCMatchCache = {}
local metadataByID = {}
local metadataPackStarts
local notableNPCs
local notableNPCsBuilding = false
local observedClassifications = {}
local areaMapNames = {}

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

-- The generated area-name catalog is intentionally compact and some classic
-- dungeon AreaTable IDs are absent from it. Ascension's guarded world-map API
-- can still resolve those IDs to the same map-file key returned by
-- GetMapInfo(), which keeps static dungeon bosses out of anonymous "Map N"
-- buckets without maintaining a manual instance list.
local function SpawnAreaName(areaID)
    local generated = DataStore.GetNPCSpawnAreaName(areaID)
    if areaMapNames[areaID] ~= nil then return areaMapNames[areaID] or nil end
    local name
    if C_WorldMap and type(C_WorldMap.GetMapFileByAreaID) == "function" then
        local ok, value = pcall(C_WorldMap.GetMapFileByAreaID, areaID)
        if ok and type(value) == "string" and value ~= "" then name = value end
    end
    -- Prefer the client's exact map-file key when available. Generated names
    -- keep every known shipped dungeon usable on clients lacking this API.
    if not name then name = generated end
    areaMapNames[areaID] = name or false
    return name
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
                zone = SpawnAreaName(areaID) or ("Map " .. areaID),
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

local function GeneratedNotableMetadata(npcID)
    npcID = tonumber(npcID)
    if not npcID then return nil end
    local packed = DataStore.GetRareNPCPacked(npcID)
    if type(packed) ~= "string" then return nil end
    local kind, name = string.match(packed, "^([^\t]+)\t(.*)$")
    if kind ~= "r" and kind ~= "b" then return nil end
    local metadata = metadataByID[npcID] or {
        id=npcID,
        name=name ~= "" and name or nil,
        classification=kind == "r" and 2 or 3,
        boss=kind == "b",
    }
    metadata.kind = kind == "r" and "rare" or "boss"
    metadataByID[npcID] = metadata
    return metadata
end

function Store.GetRareMetadata(npcID)
    local metadata = GeneratedNotableMetadata(npcID)
    return metadata and metadata.kind == "rare" and metadata or nil
end

function Store.GetRareNPCsForZone(zoneID)
    local packed = DataStore.GetRareNPCsByZonePacked(zoneID)
    if type(packed) ~= "string" then return {} end
    local result = {}
    for value in string.gmatch(packed, "[^,]+") do
        local metadata = GeneratedNotableMetadata(tonumber(value))
        if metadata and metadata.kind == "rare" then result[#result + 1] = metadata end
    end
    return result
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
    local generatedRecords = DataStore.GetRareNPCRecords()
    if next(generatedRecords) ~= nil then
        for npcID in pairs(generatedRecords) do
            Add(GeneratedNotableMetadata(npcID))
            if cooperate then cooperate() end
        end
    else
        -- Legacy/test databases may predate the compact catalog. Installed
        -- builds always take the branch above and never scan all metadata.
        ForEachMetadata(Add, cooperate)
    end
    for npcID in pairs(observedClassifications) do
        Add(Store.GetMetadata(npcID) or { id=npcID, name=Store.GetName(npcID) })
    end
    table.sort(result, function(left, right) return left.id < right.id end)
    -- Do not cache an empty legacy result: old embedded test/data shims may
    -- populate their metadata table after this file has loaded.
    if #result > 0 or next(generatedRecords) ~= nil then
        notableNPCs = result
    else
        notableNPCs = nil
    end
    notableNPCsBuilding = false
    return result
end

function Store.AreNotableNPCsReady()
    return notableNPCs ~= nil
end

local function BuildNPCNameIndex(cooperate)
    npcIDsByName = {}
    npcNamesByID = {}
    npcNamesByPrefix = {}
    shortNPCNames = {}
    objectiveNPCMatchCache = {}
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
            if string.len(key) < 3 then
                shortNPCNames[#shortNPCNames + 1] = key
            else
                local prefix = string.sub(key, 1, 3)
                local names = npcNamesByPrefix[prefix]
                if not names then names = {}; npcNamesByPrefix[prefix] = names end
                names[#names + 1] = key
            end
        end
        if not seen[key][npcID] then
            seen[key][npcID] = true
            bucket[#bucket + 1] = npcID
        end
        if not npcNamesByID[npcID] then npcNamesByID[npcID] = name end
    end

    local packedNameCount = 0
    for _, packed in ipairs(DataStore.GetNPCNamePacks()) do
        for row in string.gmatch(packed, "[^\n]+") do
            local npcText, name = string.match(row, "^(%d+)=(.*)$")
            Add(npcText, name)
            packedNameCount = packedNameCount + 1
            if cooperate then cooperate() end
        end
    end
    if packedNameCount == 0 then
        -- Compatibility for older databases that carry names only in their
        -- metadata packs. Installed builds use the dedicated name index.
        ForEachMetadata(function(metadata) Add(metadata.id, metadata.name) end, cooperate)
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
-- the generated quest data. Prefer the longest matching names so specific
-- creatures win over shorter names, while combined objectives can return all
-- equally specific targets (for example, two named kobold types).
function Store.FindNPCsByObjectiveText(text, cooperate)
    if type(text) ~= "string" or text == "" then return nil end
    if not npcIDsByName then BuildNPCNameIndex(cooperate) end
    local label = string.lower(text)
    local cached = objectiveNPCMatchCache[label]
    if cached ~= nil then return cached or nil end
    local best, bestSeen, bestLength
    local candidateNames, candidateSeen = {}, {}
    local function AddCandidate(name)
        if not candidateSeen[name] then
            candidateSeen[name] = true
            candidateNames[#candidateNames + 1] = name
        end
    end
    for _, name in ipairs(shortNPCNames or {}) do AddCandidate(name) end
    for index = 1, math.max(0, string.len(label) - 2) do
        local names = npcNamesByPrefix and npcNamesByPrefix[string.sub(label, index, index + 2)]
        for _, name in ipairs(names or {}) do AddCandidate(name) end
    end
    for _, name in ipairs(candidateNames) do
        local npcIDs = npcIDsByName[name]
        if string.find(label, name, 1, true) then
            local length = string.len(name)
            if not bestLength or length > bestLength then
                best, bestSeen, bestLength = {}, {}, length
            end
            if length == bestLength then
                for _, npcID in ipairs(npcIDs) do
                    if not bestSeen[npcID] then
                        bestSeen[npcID] = true
                        best[#best + 1] = npcID
                    end
                end
            end
        end
        if cooperate then cooperate() end
    end
    if best then table.sort(best) end
    objectiveNPCMatchCache[label] = best or false
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
    npcNamesByPrefix = nil
    shortNPCNames = nil
    objectiveNPCMatchCache = {}
end
