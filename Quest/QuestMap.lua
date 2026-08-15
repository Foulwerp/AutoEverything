----------------------------------------------------------------------
-- QuestMap.lua
-- ============
-- Quest objective and service NPC locations on the world map and minimap.
----------------------------------------------------------------------
AutoQuest = AutoQuest or {}
AutoQuest.Map = AutoQuest.Map or {}
local QuestMap = AutoQuest.Map
local Resolver = AutoQuest.ObjectiveResolver
local SpawnStore = AutoQuest.NPCSpawnStore

local activeByZone = {}
local activePointKeys = {}
local serviceByZone
local combinedByZone = {}
local worldPins, minimapPins = {}, {}
local worldRouteDots, minimapRouteDots = {}, {}
local refreshPending, refreshAt = false, 0
local playerMap = { name = nil, key = nil, x = nil, y = nil }
local buildStats = { activeQuests=0, matchedQuests=0, points=0, servicePoints=0 }
local minimapStatus = "not updated"
local locationDebug = {}

local defaultServiceKinds = {
    "auctioneer", "banker", "battlemaster", "flightmaster", "guildmaster",
    "innkeeper", "talentunlearner", "tabardvendor", "stablemaster", "trainer", "vendor",
}

local function ServiceKindEnabled(kind)
    local fallback = AutoQuestConfig and AutoQuestConfig.mapServiceIconTypes
        or defaultServiceKinds
    local selected = AutoCore.GetSetting("quest", "mapServiceIconTypes", fallback)
    if type(selected) == "string" then return selected == kind end
    if type(selected) ~= "table" then return true end
    for _, value in ipairs(selected) do
        if value == kind then return true end
    end
    return false
end

-- Physical dimensions are needed to translate normalized zone coordinates to
-- minimap yards. Unknown/custom maps still receive world-map pins.
local zoneSizes = {
    ["durotar"]={5288,3524}, ["mulgore"]={5136,3425}, ["barrens"]={10132,6755},
    ["teldrassil"]={5091,3394}, ["darkshore"]={6549,4367}, ["ashenvale"]={5766,3843},
    ["thousandneedles"]={4400,2934}, ["stonetalonmountains"]={4882,3255},
    ["desolace"]={4234,2997}, ["feralas"]={6949,4634}, ["dustwallowmarsh"]={5251,3500},
    ["tanaris"]={6900,4600}, ["azshara"]={5070,3381}, ["felwood"]={5749,3833},
    ["ungorocrater"]={3700,2467}, ["moonglade"]={2308,1539}, ["silithus"]={3482,2323},
    ["winterspring"]={7100,4733}, ["azuremystisle"]={4070,2715}, ["bloodmystisle"]={3262,2175},
    ["alteracmountains"]={2799,1866}, ["arathihighlands"]={3600,2400}, ["badlands"]={2487,1658},
    ["blastedlands"]={3350,2234}, ["tirisfalglades"]={4518,3013}, ["silverpineforest"]={4200,2800},
    ["westernplaguelands"]={4300,2866}, ["easternplaguelands"]={4031,2688},
    ["hillsbradfoothills"]={3200,2133}, ["hinterlands"]={3850,2566}, ["dunmorogh"]={4924,3283},
    ["searinggorge"]={2232,1487}, ["burningsteppes"]={2929,1952}, ["elwynnforest"]={3470,2315},
    ["deadwindpass"]={2500,1667}, ["duskwood"]={2700,1800}, ["lochmodan"]={2759,1840},
    ["redridgemountains"]={2171,1447}, ["stranglethornvale"]={6380,4254},
    ["swampofsorrows"]={2294,1530}, ["westfall"]={3500,2333}, ["wetlands"]={4136,2757},
    ["eversongwoods"]={4925,3283}, ["ghostlands"]={3300,2200},
    ["hellfirepeninsula"]={5164,3443}, ["zangarmarsh"]={5028,3351},
    ["shadowmoonvalley"]={5500,3667}, ["bladesedgemountains"]={5425,3617},
    ["nagrand"]={5525,3682}, ["terokkarforest"]={5400,3601}, ["netherstorm"]={5574,3717},
    ["boreantundra"]={5764,3843}, ["dragonblight"]={5608,3740}, ["grizzlyhills"]={5250,3500},
    ["howlingfjord"]={6046,4030}, ["icecrown"]={6270,4182}, ["sholazarbasin"]={4357,2904},
    ["stormpeaks"]={7111,4741}, ["zuldrak"]={4993,3329}, ["wintergrasp"]={2975,1983},
    ["crystalsongforest"]={2722,1815},
}

local zoneAliases = {
    elwynn = "elwynnforest",
    barrens = "barrens",
    thebarrens = "barrens",
    hinterlands = "hinterlands",
    thehinterlands = "hinterlands",
}

-- Starting/instanced sub-zones that sit inside a larger parent zone's map.
-- Quests done here have their objective coordinates filed under the PARENT
-- zone's map frame (that is how the source data is scraped), while the client
-- reports the player as standing in the sub-zone - which has its own tiny map,
-- a different coordinate system, and no zoneSizes entry. Reading the player's
-- position in the parent frame instead lets the normal minimap math place
-- these pins while the player is still inside the sub-zone. Keys are already
-- NormalizeZone()-form; values are parent zone display names, matched against
-- GetMapZones() to select the parent map.
local subZoneParents = {
    northshirevalley = "Elwynn Forest",
    coldridgevalley  = "Dun Morogh",
    deathknell       = "Tirisfal Glades",
    valleyoftrials   = "Durotar",
    campnarache      = "Mulgore",
    shadowglen       = "Teldrassil",
    ammenvale        = "Azuremyst Isle",
    sunstriderisle   = "Eversong Woods",
}

local function NormalizeZone(name)
    name = string.lower(name or "")
    name = string.gsub(name, "^the%s+", "")
    name = string.gsub(name, "[^%w]", "")
    return zoneAliases[name] or name
end

local function Enabled()
    local moduleEnabled = AutoCore.GetSetting("quest", "enabled",
        AutoQuestConfig and AutoQuestConfig.enabled) ~= false
    return moduleEnabled and AutoCore.GetSetting("quest", "mapPins",
        AutoQuestConfig and AutoQuestConfig.mapPins) ~= false
end

-- User-adjustable via the Map Pins section of the Quest settings page.
local function Setting(key, fallback)
    local value = tonumber(AutoCore.GetSetting("quest", key,
        AutoQuestConfig and AutoQuestConfig[key]))
    return value or fallback
end

local function WorldPinSize() return Setting("worldPinSize", 24) end
local function MinimapPinSize() return Setting("minimapPinSize", 16) end
local function MinimapPinRadiusPercent() return Setting("minimapPinRadiusPercent", 95) end
local function MaxWorldPins() return Setting("maxWorldPins", 500) end
local function MaxMinimapPins() return Setting("maxMinimapPins", 150) end

-- Use direct database facts where available, then the client-reported type of
-- the exact live objective. Unknown types are deliberately not guessed.
local function RecordKind(record, objective)
    if tonumber(record.type) == -1 then return "scout" end
    if tonumber(record.type) == 2 then return "object" end
    if record.item then return "loot" end

    local objectiveType = objective and string.lower(objective.kind or "") or ""
    if objectiveType == "monster" or objectiveType == "player" then return "kill" end
    if objectiveType == "item" then return "loot" end
    if objectiveType == "object" or objectiveType == "event" then return "object" end
    return nil
end

-- Tie every scraped record to a live objective before it can create a pin.
local function ObjectiveForRecord(objectives, record)
    local needle = string.lower(record.item or record.name or "")
    if needle ~= "" then
        for _, objective in ipairs(objectives) do
            if string.find(string.lower(objective.text or ""), needle, 1, true) then
                return objective
            end
        end
    end

    local index = tonumber(record.objective)
    return index and objectives[index + 1] or nil
end

-- Pulls the "3/10" style count out of a live quest-log objective line (e.g.
-- "Defias Bandits slain: 3/10") so pin tooltips can show real progress
-- instead of just re-stating the quest's static requirement text.
local function ExtractProgress(text)
    return text and string.match(text, "%d+%s*/%s*%d+")
end

local function AddLocation(zoneID, zoneName, floor, record, coord, questID, questTitle, kind, progress)
    local key = NormalizeZone(zoneName)
    local x, y = tonumber(coord[1]), tonumber(coord[2])
    if key == "" or not x or not y then return false end

    -- The same NPC can be a kill/loot objective for more than one active
    -- quest at once, or appear at the same coordinate for two different
    -- objectives of the same quest. Keep only one point per quest/entity.
    local pointKey = table.concat({
        key, tostring(tonumber(floor) or 0), kind, tostring(questID or ""),
        tostring(record.id or ""), tostring(record.item or ""),
        string.format("%.3f", x), string.format("%.3f", y),
    }, ":")
    if activePointKeys[pointKey] then return false end
    activePointKeys[pointKey] = true

    activeByZone[key] = activeByZone[key] or { name = zoneName, zoneIDs = {}, questIDs = {}, points = {} }
    local zone = activeByZone[key]
    local numericZoneID = tonumber(zoneID)
    if numericZoneID then zone.zoneIDs[numericZoneID] = true end
    if questID then zone.questIDs[questID] = true end
    zone.points[#zone.points + 1] = {
        x = x, y = y, floor = tonumber(floor) or 0,
        questID = questID, questTitle = questTitle, kind = kind,
        entityID = record.id, name = record.name,
        item = record.item, progress = progress,
    }
    return true
end

-- Service pages may expose many sampled positions for an NPC that patrols.
-- Split disconnected samples first so separate static spawns are not joined
-- across a zone, then reduce each connected group to either one stationary
-- pin or the two farthest patrol endpoints plus a route segment.
local SERVICE_GROUP_LINK_SQ = 25
local SERVICE_ROUTE_MIN_SPAN_SQ = 2.25

local function ServiceCoordinateGroups(coords)
    local points = {}
    for _, coord in ipairs(coords or {}) do
        local x, y = tonumber(coord[1]), tonumber(coord[2])
        if x and y then points[#points + 1] = { x=x, y=y } end
    end

    local groups, assigned = {}, {}
    for startIndex = 1, #points do
        if not assigned[startIndex] then
            local group, queue = {}, { startIndex }
            assigned[startIndex] = true
            local queueIndex = 1
            while queueIndex <= #queue do
                local pointIndex = queue[queueIndex]
                queueIndex = queueIndex + 1
                local point = points[pointIndex]
                group[#group + 1] = point
                for candidateIndex = 1, #points do
                    if not assigned[candidateIndex] then
                        local candidate = points[candidateIndex]
                        local dx, dy = point.x - candidate.x, point.y - candidate.y
                        if dx * dx + dy * dy <= SERVICE_GROUP_LINK_SQ then
                            assigned[candidateIndex] = true
                            queue[#queue + 1] = candidateIndex
                        end
                    end
                end
            end
            groups[#groups + 1] = group
        end
    end
    return groups
end

local function FarthestServicePoints(group)
    local first, last, farthestSq = group[1], group[1], 0
    for left = 1, #group do
        for right = left + 1, #group do
            local dx = group[left].x - group[right].x
            local dy = group[left].y - group[right].y
            local distanceSq = dx * dx + dy * dy
            if distanceSq > farthestSq then
                first, last, farthestSq = group[left], group[right], distanceSq
            end
        end
    end
    return first, last, farthestSq
end

local function RepresentativeServicePoint(group)
    local centerX, centerY = 0, 0
    for _, point in ipairs(group) do
        centerX, centerY = centerX + point.x, centerY + point.y
    end
    centerX, centerY = centerX / #group, centerY / #group
    local best, bestDistanceSq
    for _, point in ipairs(group) do
        local dx, dy = point.x - centerX, point.y - centerY
        local distanceSq = dx * dx + dy * dy
        if not bestDistanceSq or distanceSq < bestDistanceSq then
            best, bestDistanceSq = point, distanceSq
        end
    end
    return best
end

local function AddServicePoint(zone, service, location, point, routeEndpoint)
    zone.points[#zone.points + 1] = {
        x=point.x, y=point.y, floor=tonumber(location.floor) or 0,
        kind=service.kind, entityID=service.id,
        name=service.name, isService=true,
        routeEndpoint=routeEndpoint and true or nil,
    }
end

local function AddServiceLocation(zone, service, location)
    for _, group in ipairs(ServiceCoordinateGroups(location.coords)) do
        local first, last, spanSq = FarthestServicePoints(group)
        if #group >= 3 and spanSq >= SERVICE_ROUTE_MIN_SPAN_SQ then
            zone.routes[#zone.routes + 1] = {
                x1=first.x, y1=first.y, x2=last.x, y2=last.y,
                floor=tonumber(location.floor) or 0,
                kind=service.kind, entityID=service.id, name=service.name,
            }
            AddServicePoint(zone, service, location, first, true)
            AddServicePoint(zone, service, location, last, true)
        elseif #group > 0 then
            AddServicePoint(zone, service, location, RepresentativeServicePoint(group), false)
        end
    end
end

local function BuildServiceIndex()
    if serviceByZone then return end
    serviceByZone = {}
    local playerFaction = UnitFactionGroup and UnitFactionGroup("player") or nil
    for _, service in ipairs(SpawnStore.GetServices() or {}) do
        local available = service.faction == nil or service.faction == "Both"
            or service.faction == playerFaction
        if service.faction == "Neither" then available = false end
        if not ServiceKindEnabled(service.kind) then available = false end
        for _, location in ipairs(available and SpawnStore.Get(service.id) or {}) do
            local key = NormalizeZone(location.zone)
            if key ~= "" then
                local zone = serviceByZone[key]
                if not zone then
                    zone = { name=location.zone, zoneIDs={}, questIDs={}, points={}, routes={} }
                    serviceByZone[key] = zone
                end
                local numericZoneID = tonumber(location.zoneID)
                if numericZoneID then zone.zoneIDs[numericZoneID] = true end
                AddServiceLocation(zone, service, location)
            end
        end
    end
end

local function ZoneForKey(key)
    if not key then return nil end
    local cached = combinedByZone[key]
    if cached then return cached end
    local questZone, serviceZone = activeByZone[key], serviceByZone and serviceByZone[key]
    if not questZone then return serviceZone end
    if not serviceZone then return questZone end
    local zone = {
        name=questZone.name or serviceZone.name,
        zoneIDs={}, questIDs=questZone.questIDs, points={}, routes={},
    }
    for zoneID in pairs(serviceZone.zoneIDs or {}) do zone.zoneIDs[zoneID] = true end
    for zoneID in pairs(questZone.zoneIDs or {}) do zone.zoneIDs[zoneID] = true end
    for _, point in ipairs(questZone.points or {}) do zone.points[#zone.points + 1] = point end
    -- Active quest objectives always receive world-map pins before the static
    -- service catalog if the user's pin cap is reached in a crowded city.
    for _, point in ipairs(serviceZone.points or {}) do zone.points[#zone.points + 1] = point end
    for _, route in ipairs(serviceZone.routes or {}) do zone.routes[#zone.routes + 1] = route end
    combinedByZone[key] = zone
    return zone
end

local function ConfirmedMapKind(kind)
    if kind == "kill" or kind == "loot" then return kind end
    if kind == "interact" then return "object" end
end

-- A unique live tooltip match is stronger evidence than a scraped item-source
-- association. Once the resolver has confirmed the objective/NPC pair, use
-- that NPC's known spawn list even when the quest page itself has no points.
local function AddConfirmedLocations(objectives)
    for _, objective in ipairs(objectives or {}) do
        local confirmation = Resolver.GetConfirmations(objective.key)
        local kind = confirmation and ConfirmedMapKind(confirmation.kind)
        if kind and type(confirmation.npcIDs) == "table" then
            local objectiveAdded = false
            for rawNPCID in pairs(confirmation.npcIDs) do
                local npcID = tonumber(rawNPCID)
                local locations = npcID and SpawnStore.Get(npcID)
                if type(locations) == "table" then
                    local npcName = type(confirmation.npcNames) == "table"
                        and confirmation.npcNames[rawNPCID] or nil
                    local record = {
                        id = npcID,
                        name = npcName or objective.displayLabel,
                        item = kind == "loot" and objective.displayLabel or nil,
                    }
                    for _, location in ipairs(locations) do
                        for _, coord in ipairs(location.coords or {}) do
                            if AddLocation(
                                location.zoneID, location.zone, location.floor,
                                record, coord, objective.questID, objective.questTitle,
                                kind, ExtractProgress(objective.rawLabel)
                            ) then
                                buildStats.points = buildStats.points + 1
                                objectiveAdded = true
                            end
                        end
                    end
                end
            end
            if objectiveAdded then
                buildStats.confirmedObjectives = buildStats.confirmedObjectives + 1
            end
        end
    end
end

-- An NPC page's "Objective of" relationship identifies the quest but not its
-- objective slot. Prefer an unfinished monster objective, then a sole
-- unfinished objective. Mixed ambiguous quests remain on the mapper/tooltip
-- paths instead of receiving a guessed pin type.
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

local function AddQuestObjectiveNPCs(questID, questTitle, objectives, npcIDs)
    local objective = ObjectiveForQuestNPC(objectives)
    local kind = objective and RecordKind({}, objective)
    if not objective or not kind then return end

    local _, displayLabel = Resolver.Normalize(objective.text)
    for _, npcID in ipairs(npcIDs or {}) do
        local record = { id=npcID, name=displayLabel ~= "" and displayLabel or questTitle }
        for _, location in ipairs(SpawnStore.Get(npcID) or {}) do
            for _, coord in ipairs(location.coords or {}) do
                if AddLocation(location.zoneID, location.zone, location.floor,
                    record, coord, questID, questTitle, kind,
                    ExtractProgress(objective.text))
                then
                    buildStats.points = buildStats.points + 1
                end
            end
        end
    end
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

local function AddQuestItemNPCs(questID, questTitle, objectives, sources)
    for _, source in ipairs(sources or {}) do
        local objective = ObjectiveForQuestItem(objectives, source.itemName)
        if objective then
            local _, displayLabel = Resolver.Normalize(objective.text)
            local itemName = source.itemName or displayLabel
            for _, npcID in ipairs(source.npcIDs or {}) do
                local record = {
                    id=npcID, name="NPC " .. npcID,
                    item=itemName ~= "" and itemName or nil,
                }
                for _, location in ipairs(SpawnStore.Get(npcID) or {}) do
                    for _, coord in ipairs(location.coords or {}) do
                        if AddLocation(location.zoneID, location.zone, location.floor,
                            record, coord, questID, questTitle, "loot",
                            ExtractProgress(objective.text))
                        then
                            buildStats.points = buildStats.points + 1
                        end
                    end
                end
            end
        end
    end
end

function QuestMap.RebuildIndex()
    activeByZone = {}
    activePointKeys = {}
    combinedByZone = {}
    buildStats = {
        activeQuests=0, matchedQuests=0, confirmedObjectives=0,
        points=0, servicePoints=0, matches={}
    }
    if not Enabled() then return end
    BuildServiceIndex()
    for _, zone in pairs(serviceByZone or {}) do
        buildStats.servicePoints = buildStats.servicePoints + #(zone.points or {})
    end
    local resolverObjectives = Resolver.BuildActive()

    local entries = GetNumQuestLogEntries and GetNumQuestLogEntries() or 0
    for logIndex = 1, entries do
        local title, _, _, _, isHeader, _, complete, _, questID = GetQuestLogTitle(logIndex)
        -- Resolve by questID, falling back to title (the client may not return
        -- a questID at all on 3.3.5). See AutoQuest.ResolveQuestEntries.
        local resolved = (title and not isHeader) and AutoQuest.ResolveQuestEntries(questID, title) or {}
        if title and not isHeader then buildStats.activeQuests = buildStats.activeQuests + 1 end
        if title and not isHeader and not Resolver.IsComplete(complete) then
            local objectives = {}
            local count = GetNumQuestLeaderBoards(logIndex) or 0
            for objectiveIndex = 1, count do
                local text, objectiveType, done = GetQuestLogLeaderBoard(objectiveIndex, logIndex)
                objectives[#objectives + 1] = {
                    text=text or "", kind=objectiveType,
                    done=Resolver.ObjectiveIsComplete(text, done),
                }
            end

            -- Relationship tables are keyed by database quest ID. The client
            -- may omit that ID, so query the exact ID first and then any IDs
            -- resolved from the database title index.
            local relationshipData, relationshipIDs = {}, {}
            local function AddRelationshipID(value)
                value = tonumber(value)
                if not value or relationshipIDs[value] then return end
                relationshipIDs[value] = true
                relationshipData[#relationshipData + 1] = {
                    questID = value,
                    npcIDs = SpawnStore.GetObjectiveNPCs(value),
                    itemSources = SpawnStore.GetQuestItemSources(value),
                }
            end
            AddRelationshipID(questID)
            for _, match in ipairs(resolved) do AddRelationshipID(match.id) end

            local hasRelationshipData = false
            for _, data in ipairs(relationshipData) do
                if type(data.npcIDs) == "table" or type(data.itemSources) == "table" then
                    hasRelationshipData = true
                    break
                end
            end
            if #resolved > 0 or hasRelationshipData then
                buildStats.matchedQuests = buildStats.matchedQuests + 1
            end

            for _, match in ipairs(resolved) do
                -- Use the resolved id (not the raw questID, which may be nil)
                -- so pin dedupe and per-zone bookkeeping stay correct.
                local matchQuestID = match.id
                local matchPointsBefore = buildStats.points
                for _, record in ipairs(match.entry.records or {}) do
                    local recordType = tonumber(record.type) or 1
                    local objective = ObjectiveForRecord(objectives, record)
                    local kind = RecordKind(record, objective)
                    -- The quest database is keyed by the same quest ID exposed
                    -- by the client. Its source requirements therefore become
                    -- useful immediately while that exact quest and objective
                    -- are active; live tooltip evidence is processed only
                    -- after all database relationships have been considered.
                    if objective and kind and not objective.done then
                        local progress = ExtractProgress(objective.text)
                        if recordType == 2 or recordType == -1 then
                            -- Game objects and mapped events aren't
                            -- cross-referenced like NPCs - their coords are
                            -- inline on the record itself. Every coordinate is
                            -- a real distinct spot - one pin each.
                            for _, coord in ipairs(record.coords or {}) do
                                if AddLocation(record.zoneID, record.zone, record.floor,
                                    record, coord, matchQuestID, title, kind, progress)
                                then
                                    buildStats.points = buildStats.points + 1
                                end
                            end
                        else
                            local id = tonumber(record.id)
                            local locations = id and SpawnStore.Get(id)
                            for _, location in ipairs(locations or {}) do
                                -- Every coordinate here is a real distinct spawn
                                -- point - one pin each, not just the first few.
                                for _, coord in ipairs(location.coords or {}) do
                                    if AddLocation(location.zoneID, location.zone, location.floor,
                                        record, coord, matchQuestID, title, kind, progress)
                                    then
                                        buildStats.points = buildStats.points + 1
                                    end
                                end
                            end
                        end
                    end
                end
                buildStats.matches[#buildStats.matches + 1] = {
                    id = matchQuestID, title = title,
                    points = buildStats.points - matchPointsBefore,
                }
            end
            for _, data in ipairs(relationshipData) do
                AddQuestObjectiveNPCs(data.questID, title, objectives, data.npcIDs)
                AddQuestItemNPCs(data.questID, title, objectives, data.itemSources)
            end
        end
    end
    AddConfirmedLocations(resolverObjectives)
end

-- Every exposed quest-objective coordinate gets its own pin. Service patrols
-- have already been reduced to endpoints above. Records are merged only when
-- they share the exact same coordinate and pin type.
local function GroupExactPoints(points)
    local groups, byCoordinate, serviceCoordinates = {}, {}, {}
    for _, point in ipairs(points or {}) do
        local key = tostring(point.floor) .. ":" .. point.kind .. ":"
            .. string.format("%.3f:%.3f", point.x, point.y)
        local group = byCoordinate[key]
        if group then
            group.members[#group.members + 1] = point
        else
            group = {
                x=point.x, y=point.y, kind=point.kind, floor=point.floor,
                isService=point.isService and true or false, members={point},
            }
            byCoordinate[key] = group
            groups[#groups + 1] = group
            if group.isService then
                local serviceKey = tostring(point.floor) .. ":"
                    .. string.format("%.3f:%.3f", point.x, point.y)
                serviceCoordinates[serviceKey] = serviceCoordinates[serviceKey] or {}
                serviceCoordinates[serviceKey][#serviceCoordinates[serviceKey] + 1] = group
            end
        end
    end
    for _, matches in pairs(serviceCoordinates) do
        if #matches > 1 then
            for index, group in ipairs(matches) do
                group.overlapIndex, group.overlapCount = index, #matches
            end
        end
    end
    return groups
end

-- Quest starters and turn-ins remain out of scope; the client already marks
-- those when in range. Static service NPC types use their own familiar icons.
local iconTextures = {
    kill = "Interface\\AddOns\\AutoEverything\\Images\\QuestSkull.tga",
    loot = "Interface\\AddOns\\AutoEverything\\Images\\QuestLootBag.tga",
    object = "Interface\\AddOns\\AutoEverything\\Images\\Interact.tga",
    scout = "Interface\\AddOns\\AutoEverything\\Images\\QuestScout.tga",
    auctioneer = "Interface\\AddOns\\AutoEverything\\Images\\ServiceAuctioneer.tga",
    banker = "Interface\\AddOns\\AutoEverything\\Images\\ServiceBanker.tga",
    battlemaster = "Interface\\AddOns\\AutoEverything\\Images\\ServiceBattlemaster.tga",
    flightmaster = "Interface\\AddOns\\AutoEverything\\Images\\ServiceFlightMaster.tga",
    guildmaster = "Interface\\AddOns\\AutoEverything\\Images\\ServiceGuildMaster.tga",
    innkeeper = "Interface\\AddOns\\AutoEverything\\Images\\ServiceInnkeeper.tga",
    talentunlearner = "Interface\\AddOns\\AutoEverything\\Images\\ServiceTalentUnlearner.tga",
    tabardvendor = "Interface\\AddOns\\AutoEverything\\Images\\ServiceTabardVendor.tga",
    stablemaster = "Interface\\AddOns\\AutoEverything\\Images\\ServiceStableMaster.tga",
    trainer = "Interface\\AddOns\\AutoEverything\\Images\\ServiceTrainer.tga",
    vendor = "Interface\\AddOns\\AutoEverything\\Images\\ServiceVendor.tga",
}

local iconColors = {
    kill={1,0.3,0.3}, loot={0.35,1,0.45}, object={0.45,0.8,1}, scout={1,0.75,0.25},
    auctioneer={1,0.65,0.2}, banker={1,0.82,0.2}, battlemaster={0.85,0.9,1},
    flightmaster={0.75,0.9,1}, guildmaster={0.35,0.55,1}, innkeeper={0.35,0.7,1},
    talentunlearner={0.75,0.45,1}, tabardvendor={1,0.3,0.25},
    stablemaster={0.8,0.85,0.95}, trainer={1,0.9,0.55}, vendor={1,0.55,0.3},
}

local headingText = {
    kill = "Kill",
    loot = "Item",
    object = "Interact",
    scout = "Scout",
    auctioneer = "Auctioneer",
    banker = "Banker",
    battlemaster = "Battlemaster",
    flightmaster = "Flight Master",
    guildmaster = "Guild Master",
    innkeeper = "Innkeeper",
    talentunlearner = "Talent Unlearner",
    tabardvendor = "Tabard Vendor",
    stablemaster = "Stable Master",
    trainer = "Trainer",
    vendor = "Vendor",
}

-- Phrases a single objective as a short sentence ("Kill Defias Bandit",
-- "Loot Red Bandana from Defias Bandit") instead of stacking raw name/title
-- fields, so the tooltip reads like a to-do list rather than a data dump.
local function DescribeObjective(cluster, point)
    local name = point.name or point.questTitle or "Unknown"
    if point.isService then
        return name
    elseif cluster.kind == "loot" then
        return point.item and ("Loot " .. point.item .. " from " .. name) or ("Loot from " .. name)
    elseif cluster.kind == "object" then
        return "Use " .. name
    elseif cluster.kind == "scout" then
        return name
    else
        return "Kill " .. name
    end
end

local function ShowPinTooltip(pin)
    local cluster = pin.cluster
    if not cluster then return end
    GameTooltip:SetOwner(pin, "ANCHOR_RIGHT")
    local color = iconColors[cluster.kind] or iconColors.kill
    GameTooltip:SetText(headingText[cluster.kind] or "Quest Objective", color[1], color[2], color[3])

    local shown, lineCount, hiddenCount = {}, 0, 0
    for _, point in ipairs(cluster.members) do
        local key = tostring(point.questID) .. ":" .. tostring(point.entityID) .. ":" .. tostring(point.kind)
        if not shown[key] then
            shown[key] = true
            if lineCount < 12 then
                lineCount = lineCount + 1
                local description = DescribeObjective(cluster, point)
                if point.progress then description = description .. "  |cffffd200(" .. point.progress .. ")|r" end
                GameTooltip:AddLine(description, 1, 1, 1)
                if not point.isService then
                    GameTooltip:AddLine("  " .. point.questTitle, 0.6, 0.65, 0.75)
                end
            else
                hiddenCount = hiddenCount + 1
            end
        end
    end
    if hiddenCount > 0 then GameTooltip:AddLine("+" .. hiddenCount .. " more", 0.7, 0.7, 0.7) end
    if #cluster.members > 1 then
        GameTooltip:AddLine(" ")
        local suffix = cluster.isService and " services here" or " objectives here"
        GameTooltip:AddLine(#cluster.members .. suffix, 0.6, 0.6, 0.6)
    end
    GameTooltip:AddLine(string.format("%.1f, %.1f", cluster.x, cluster.y), 0.55, 0.75, 1)
    GameTooltip:Show()
end

local function ConfigurePin(pin, cluster, size)
    pin.cluster = cluster
    pin:SetWidth(size)
    pin:SetHeight(size)
    -- No vertex tint - same natural icon colors as the nameplate badges in
    -- QuestMarkers.lua (white skull, brown bag) rather than recoloring them.
    pin.icon:SetTexture(iconTextures[cluster.kind] or iconTextures.kill)
    pin.icon:SetVertexColor(1, 1, 1, 1)
end

local function ClusterOffset(cluster, size)
    if not cluster.overlapCount or cluster.overlapCount <= 1 then return 0, 0 end
    local angle = (cluster.overlapIndex - 1) * (2 * math.pi / cluster.overlapCount)
    local radius = size * 0.45
    return math.cos(angle) * radius, math.sin(angle) * radius
end

local function NewPin(parent, minimap)
    local pin = CreateFrame("Button", nil, parent)
    pin:SetFrameStrata(minimap and "MEDIUM" or "HIGH")
    pin:SetFrameLevel((parent:GetFrameLevel() or 1) + 20)
    pin:EnableMouse(true)
    pin.icon = pin:CreateTexture(nil, "ARTWORK")
    pin.icon:SetAllPoints(pin)
    pin:SetScript("OnEnter", ShowPinTooltip)
    pin:SetScript("OnLeave", GameTooltip_Hide)
    pin:Hide()
    return pin
end

local function HidePins(pool)
    for _, pin in ipairs(pool) do pin:Hide(); pin.cluster = nil end
end

local function HideRouteDots(pool)
    for _, dot in ipairs(pool) do dot:Hide() end
end

local function RouteDot(pool, index, parent, anchor, x, y, color, size)
    local dot = pool[index]
    if dot and dot:GetParent() ~= parent then
        dot:Hide()
        dot = nil
    end
    if not dot then
        dot = parent:CreateTexture(nil, "ARTWORK")
        pool[index] = dot
    end
    dot:SetWidth(size)
    dot:SetHeight(size)
    dot:SetTexture(color[1], color[2], color[3], 0.72)
    dot:ClearAllPoints()
    dot:SetPoint("CENTER", parent, anchor, x, y)
    dot:Show()
end

local function DrawRouteSegment(pool, count, limit, parent, anchor,
    x1, y1, x2, y2, color, spacing, dotSize, visible)
    local dx, dy = x2 - x1, y2 - y1
    local length = math.sqrt(dx * dx + dy * dy)
    local steps = math.max(1, math.ceil(length / spacing))
    for step = 1, steps - 1 do
        if count >= limit then break end
        local progress = step / steps
        local x, y = x1 + dx * progress, y1 + dy * progress
        if not visible or visible(x, y) then
            count = count + 1
            RouteDot(pool, count, parent, anchor, x, y, color, dotSize)
        end
    end
    return count
end

local function DrawWorldRoutes(zone, parent, currentFloor)
    HideRouteDots(worldRouteDots)
    local width, height = parent:GetWidth(), parent:GetHeight()
    local count = 0
    for _, route in ipairs(zone.routes or {}) do
        if route.floor == 0 or currentFloor == 0 or route.floor == currentFloor then
            local color = iconColors[route.kind] or iconColors.scout
            count = DrawRouteSegment(worldRouteDots, count, 1500, parent, "TOPLEFT",
                route.x1 * width / 100, -route.y1 * height / 100,
                route.x2 * width / 100, -route.y2 * height / 100,
                color, 3, 2.5)
        end
        if count >= 1500 then break end
    end
end

local function CurrentMapName()
    local mapID = GetCurrentMapAreaID and GetCurrentMapAreaID()
    local name = mapID and GetMapName and GetMapName(mapID)
    -- Some Ascension builds expose GetMapName but return nil for area IDs.
    -- Derive the viewed zone from the classic continent/zone selector instead.
    if not name and GetCurrentMapContinent and GetCurrentMapZone and GetMapZones then
        local continent, zoneIndex = GetCurrentMapContinent(), GetCurrentMapZone()
        if continent and continent > 0 and zoneIndex and zoneIndex > 0 then
            local names = { GetMapZones(continent) }
            name = names[zoneIndex]
        end
    end
    if not name and (not WorldMapFrame or not WorldMapFrame:IsShown()) then
        name = (GetZoneText and GetZoneText()) or (GetRealZoneText and GetRealZoneText())
    end
    return name, mapID
end

function QuestMap.UpdateWorldMap()
    HidePins(worldPins)
    HideRouteDots(worldRouteDots)
    if not Enabled() or not WorldMapFrame or not WorldMapFrame:IsShown() then return end
    local parent = WorldMapDetailFrame or WorldMapButton
    if not parent or parent:GetWidth() <= 0 or parent:GetHeight() <= 0 then return end
    local mapName = CurrentMapName()
    local zone = mapName and ZoneForKey(NormalizeZone(mapName))
    if not zone then return end

    local currentFloor = GetCurrentMapDungeonLevel and GetCurrentMapDungeonLevel() or 0
    local shown = 0
    local maxPins = MaxWorldPins()
    local pinSize = WorldPinSize()
    DrawWorldRoutes(zone, parent, currentFloor)
    if not zone.exactPoints then zone.exactPoints = GroupExactPoints(zone.points) end
    for _, cluster in ipairs(zone.exactPoints) do
        if shown >= maxPins then break end
        if cluster.floor == 0 or currentFloor == 0 or cluster.floor == currentFloor then
            shown = shown + 1
            local pin = worldPins[shown]
            if not pin then pin = NewPin(parent, false); worldPins[shown] = pin end
            pin:SetParent(parent)
            ConfigurePin(pin, cluster, pinSize)
            pin:ClearAllPoints()
            local offsetX, offsetY = ClusterOffset(cluster, pinSize)
            pin:SetPoint("CENTER", parent, "TOPLEFT",
                cluster.x * parent:GetWidth() / 100 + offsetX,
                -cluster.y * parent:GetHeight() / 100 + offsetY)
            pin:Show()
        end
    end
end

local function ReadPlayerMapPosition()
    if GetPlayerMapPosition then return GetPlayerMapPosition("player") end
end

-- Select the parent zone's map (only when it is not already selected, so this
-- costs a SetMapZoom only on zone transitions, not every ticker pass) and read
-- the player's position in that frame. Returns nil when the parent map cannot
-- be selected or the client reports no position there.
local function ReadParentZonePosition(parentName)
    if not (GetMapZones and GetCurrentMapContinent and ReadPlayerMapPosition) then return nil end
    local parentKey = NormalizeZone(parentName)
    local current = CurrentMapName()
    if not current or NormalizeZone(current) ~= parentKey then
        if not SetMapZoom then return nil end
        local continent = GetCurrentMapContinent()
        if not continent or continent <= 0 then return nil end
        local names = { GetMapZones(continent) }
        local index
        for i, zoneName in ipairs(names) do
            if NormalizeZone(zoneName) == parentKey then index = i; break end
        end
        if not index or not pcall(SetMapZoom, continent, index) then return nil end
    end
    local x, y = ReadPlayerMapPosition()
    if x and y and (x > 0 or y > 0) then return x, y end
    return nil
end

local function UpdatePlayerLocation(force)
    local mapShown = WorldMapFrame and WorldMapFrame:IsShown()
    if mapShown and playerMap.x and not force then return end

    local oldContinent = GetCurrentMapContinent and GetCurrentMapContinent()
    local oldZone = GetCurrentMapZone and GetCurrentMapZone()
    local oldFloor = GetCurrentMapDungeonLevel and GetCurrentMapDungeonLevel()
    local name = GetZoneText and GetZoneText()
    if not name or name == "" then name = GetRealZoneText and GetRealZoneText() end

    -- GetPlayerMapPosition returns coordinates in the currently selected map,
    -- not necessarily the player's zone. A continent map (and some custom
    -- maps) can return a perfectly valid non-zero position, so checking only
    -- for 0,0 mixes those coordinates with zone-local objective coordinates.
    -- Confirm the selected map first and select the current zone when needed.
    local selectedName = CurrentMapName()
    local x, y = ReadPlayerMapPosition()
    local beforeX, beforeY = x, y
    local setOK, setResult
    local wrongMap = (oldContinent and oldContinent > 0 and oldZone == 0)
        or (name and name ~= "" and selectedName
            and NormalizeZone(selectedName) ~= NormalizeZone(name))
    if wrongMap or not x or not y or (x == 0 and y == 0) then
        if SetMapToCurrentZone then setOK, setResult = pcall(SetMapToCurrentZone) end
        x, y = ReadPlayerMapPosition()
    end
    if not name or name == "" then name = CurrentMapName() end

    local probeSelector, probeQuestID
    -- Ascension can leave GetPlayerMapPosition at 0,0 after selecting the
    -- current zone. Selecting a known active quest's destination map forces
    -- the correct zone canvas to initialize on affected client builds.
    if (not x or not y or (x == 0 and y == 0)) and name and SetMapByID
        and GetQuestWorldMapAreaID
    then
        local currentZone = ZoneForKey(NormalizeZone(name))
        for questID in pairs(currentZone and currentZone.questIDs or {}) do
            local ok, selector = pcall(GetQuestWorldMapAreaID, questID)
            if ok and type(selector) == "number" and selector > 0 then
                local setSelectorOK, result = pcall(SetMapByID, selector)
                local probeX, probeY = ReadPlayerMapPosition()
                if setSelectorOK and result ~= false and probeX and probeY
                    and (probeX > 0 or probeY > 0)
                then
                    x, y, probeSelector, probeQuestID = probeX, probeY, selector, questID
                    break
                end
            end
        end
    end

    locationDebug = {
        mapShown=mapShown and true or false, zoneText=GetZoneText and GetZoneText(),
        realZoneText=GetRealZoneText and GetRealZoneText(), selectedName=selectedName,
        wrongMap=wrongMap and true or false, beforeX=beforeX,
        beforeY=beforeY, x=x, y=y, setOK=setOK, setResult=setResult,
        probeSelector=probeSelector, probeQuestID=probeQuestID,
        continent=GetCurrentMapContinent and GetCurrentMapContinent(),
        zone=GetCurrentMapZone and GetCurrentMapZone(),
        areaID=GetCurrentMapAreaID and GetCurrentMapAreaID(),
    }
    -- Sub-zone remap (see subZoneParents): the player stands in a micro-zone,
    -- but its quest pins are filed under the parent zone's frame. Only bother
    -- when the parent actually has active objective points to show, so the
    -- SetMapZoom cost is paid only when it can produce pins.
    local parentName = name and name ~= "" and subZoneParents[NormalizeZone(name)]
    if parentName and not mapShown and ZoneForKey(NormalizeZone(parentName)) then
        local px, py = ReadParentZonePosition(parentName)
        if px and py then
            name, x, y = parentName, px, py
            locationDebug.subZoneParent = parentName
        end
    end

    if name and name ~= "" then
        local key = NormalizeZone(name)
        -- Never combine a newly entered zone with coordinates retained from
        -- the previous one while the map API is still initializing.
        if playerMap.key and playerMap.key ~= key then
            playerMap.x, playerMap.y = nil, nil
        end
        playerMap.name, playerMap.key = name, key
    end
    if x and y and (x > 0 or y > 0) then playerMap.x, playerMap.y = x, y end

    -- A forced diagnostic may run with the world map open. Restore the map the
    -- player was viewing after briefly selecting their current zone.
    if mapShown and oldContinent and oldZone and SetMapZoom then
        pcall(SetMapZoom, oldContinent, oldZone)
        if oldFloor and SetDungeonMapLevel then pcall(SetDungeonMapLevel, oldFloor) end
    end
end

local function MinimapRadius()
    if Minimap and Minimap.GetViewRadius then
        local ok, radius = pcall(Minimap.GetViewRadius, Minimap)
        if ok and type(radius) == "number" then return radius end
    end
    return 200
end

-- Ascension exposes the same guarded world-position API used by installed map
-- addons. It fills dimensions for capitals and custom maps that are absent
-- from the conservative static 3.3.5 zone table above.
local function PhysicalZoneSize(zone, key)
    local known = zoneSizes[key]
    if known then return known end
    if not (C_WorldMap and C_WorldMap.GetWorldPosition) then return nil end
    for areaID in pairs(zone and zone.zoneIDs or {}) do
        local okStart, x1, y1 = pcall(C_WorldMap.GetWorldPosition, areaID, 0, 0)
        local okEnd, x2, y2 = pcall(C_WorldMap.GetWorldPosition, areaID, 1, 1)
        if okStart and okEnd and type(x1) == "number" and type(y1) == "number"
            and type(x2) == "number" and type(y2) == "number"
        then
            local width, height = math.abs(x1 - x2), math.abs(y1 - y2)
            if width > 0 and height > 0 then
                known = { width, height }
                zoneSizes[key] = known
                return known
            end
        end
    end
end

local function DrawMinimapRoutes(zone, size, radius, radiusLimit, mapRadius, facing, rotate)
    HideRouteDots(minimapRouteDots)
    local count = 0
    local scale = mapRadius / radius
    local visibleRadius = radiusLimit * scale
    local visibleRadiusSq = visibleRadius * visibleRadius
    local function OnMinimap(x, y) return x * x + y * y <= visibleRadiusSq end
    local cosFacing, sinFacing = math.cos(facing), math.sin(facing)
    for _, route in ipairs(zone.routes or {}) do
        local dx1 = (route.x1 / 100 - playerMap.x) * size[1]
        local dy1 = (route.y1 / 100 - playerMap.y) * size[2]
        local dx2 = (route.x2 / 100 - playerMap.x) * size[1]
        local dy2 = (route.y2 / 100 - playerMap.y) * size[2]
        if rotate then
            dx1, dy1 = dx1 * cosFacing - dy1 * sinFacing,
                dx1 * sinFacing + dy1 * cosFacing
            dx2, dy2 = dx2 * cosFacing - dy2 * sinFacing,
                dx2 * sinFacing + dy2 * cosFacing
        end
        local color = iconColors[route.kind] or iconColors.scout
        count = DrawRouteSegment(minimapRouteDots, count, 600, Minimap, "CENTER",
            dx1 * scale, -dy1 * scale, dx2 * scale, -dy2 * scale,
            color, 3, 2.5, OnMinimap)
        if count >= 600 then break end
    end
end

function QuestMap.UpdateMinimap()
    HidePins(minimapPins)
    HideRouteDots(minimapRouteDots)
    if not Enabled() then minimapStatus = "disabled"; return end
    if not Minimap then minimapStatus = "Minimap frame unavailable"; return end
    if not playerMap.key or not playerMap.x then minimapStatus = "player map position unavailable"; return end
    local zone = ZoneForKey(playerMap.key)
    if not zone then minimapStatus = "no map icon records for " .. playerMap.key; return end
    local size = PhysicalZoneSize(zone, playerMap.key)
    if not size then minimapStatus = "no physical map dimensions for " .. playerMap.key; return end

    local radius = MinimapRadius()
    local radiusLimit = radius * (MinimapPinRadiusPercent() / 100)
    local facing = GetPlayerFacing and GetPlayerFacing() or 0
    local rotate = GetCVar and GetCVar("rotateMinimap") == "1"
    local mapRadius = math.min(Minimap:GetWidth(), Minimap:GetHeight()) / 2 - 10
    DrawMinimapRoutes(zone, size, radius, radiusLimit, mapRadius, facing, rotate)
    local candidates = {}
    if not zone.exactPoints then zone.exactPoints = GroupExactPoints(zone.points) end
    for _, cluster in ipairs(zone.exactPoints) do
        local dx = (cluster.x / 100 - playerMap.x) * size[1]
        local dy = (cluster.y / 100 - playerMap.y) * size[2]
        local distance = math.sqrt(dx * dx + dy * dy)
        -- Only display locations within minimapPinRadiusPercent of the
        -- minimap's own view radius (Map Pins settings). Distant locations
        -- belong on the world map/route arrow; clamping every spawn to the
        -- rim creates an unreadable pile of icons.
        if distance <= radiusLimit then
            candidates[#candidates + 1] = { cluster=cluster, dx=dx, dy=dy, distance=distance }
        end
    end
    table.sort(candidates, function(a,b)
        if a.cluster.isService ~= b.cluster.isService then
            return not a.cluster.isService
        end
        return a.distance < b.distance
    end)

    local pinSize = MinimapPinSize()
    local visibleCount = math.min(#candidates, MaxMinimapPins())
    minimapStatus = tostring(visibleCount) .. " nearby pins shown from " .. tostring(#zone.exactPoints) .. " zone locations"
    for index = 1, visibleCount do
        local candidate = candidates[index]
        local dx, dy = candidate.dx, candidate.dy
        if rotate then
            local cosFacing, sinFacing = math.cos(facing), math.sin(facing)
            dx, dy = dx * cosFacing - dy * sinFacing,
                dx * sinFacing + dy * cosFacing
        end
        local scale = mapRadius / radius
        local sx, sy = dx * scale, -dy * scale
        local offsetX, offsetY = ClusterOffset(candidate.cluster, pinSize)
        sx, sy = sx + offsetX, sy + offsetY
        local pin = minimapPins[index]
        if not pin then pin = NewPin(Minimap, true); minimapPins[index] = pin end
        ConfigurePin(pin, candidate.cluster, pinSize)
        pin:ClearAllPoints()
        pin:SetPoint("CENTER", Minimap, "CENTER", sx, sy)
        pin:Show()
    end
end

function QuestMap.SetEnabled(enabled)
    AutoCore.SetSetting("quest", "mapPins", enabled and true or false)
    QuestMap.RebuildIndex()
    QuestMap.UpdateWorldMap()
    UpdatePlayerLocation()
    QuestMap.UpdateMinimap()
    AutoCore.Info("Quest", "Quest map pins " .. (enabled and "enabled." or "disabled."))
end

function QuestMap.ApplyProfile()
    -- Service locations are otherwise static and intentionally cached. A
    -- profile switch or selector change must rebuild that cache immediately.
    serviceByZone = nil
    QuestMap.RebuildIndex()
    QuestMap.UpdateWorldMap()
    UpdatePlayerLocation()
    QuestMap.UpdateMinimap()
end

function QuestMap.RequestRefresh()
    refreshPending, refreshAt = true, 0
end

function QuestMap.IsEnabled() return Enabled() end

function QuestMap.Debug()
    QuestMap.RebuildIndex()
    UpdatePlayerLocation(true)
    QuestMap.UpdateMinimap()
    local zone = playerMap.key and ZoneForKey(playerMap.key)
    local zonePoints = zone and #zone.points or 0
    print("|cff33ccffMap Pins|r")
    print("  enabled=" .. tostring(Enabled()) .. " dbLoaded=" .. tostring(type(AscensionQuestLocationDB) == "table"))
    print("  activeQuests=" .. buildStats.activeQuests .. " matchedInDB=" .. buildStats.matchedQuests
        .. " confirmedObjectives=" .. buildStats.confirmedObjectives
        .. " indexedPoints=" .. buildStats.points
        .. " servicePoints=" .. buildStats.servicePoints)
    for _, match in ipairs(buildStats.matches or {}) do
        print("    matched: " .. tostring(match.title) .. " (id " .. tostring(match.id) .. ") -> "
            .. tostring(match.points) .. " point(s)")
    end
    print("  playerMap=" .. tostring(playerMap.name) .. " key=" .. tostring(playerMap.key)
        .. " position=" .. string.format("%.1f, %.1f", (playerMap.x or 0) * 100, (playerMap.y or 0) * 100))
    print("  currentZonePoints=" .. zonePoints .. " mapSizeKnown=" .. tostring(zoneSizes[playerMap.key or ""] ~= nil))
    print("  minimap=" .. minimapStatus)
    print("  raw zoneText=" .. tostring(locationDebug.zoneText) .. " realZone=" .. tostring(locationDebug.realZoneText)
        .. " selectedMap=" .. tostring(locationDebug.selectedName)
        .. " wrongMap=" .. tostring(locationDebug.wrongMap)
        .. " mapShown=" .. tostring(locationDebug.mapShown)
        .. " subZoneParent=" .. tostring(locationDebug.subZoneParent))
    print("  raw before=" .. tostring(locationDebug.beforeX) .. "," .. tostring(locationDebug.beforeY)
        .. " after=" .. tostring(locationDebug.x) .. "," .. tostring(locationDebug.y)
        .. " setMapOK=" .. tostring(locationDebug.setOK))
    print("  raw continent=" .. tostring(locationDebug.continent) .. " zone=" .. tostring(locationDebug.zone)
        .. " areaID=" .. tostring(locationDebug.areaID) .. " probeSelector=" .. tostring(locationDebug.probeSelector)
        .. " probeQuest=" .. tostring(locationDebug.probeQuestID))
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:RegisterEvent("QUEST_LOG_UPDATE")
frame:RegisterEvent("QUEST_WATCH_UPDATE")
frame:RegisterEvent("UNIT_QUEST_LOG_CHANGED")
frame:RegisterEvent("QUEST_ITEM_UPDATE")
frame:RegisterEvent("QUEST_FINISHED")
frame:RegisterEvent("BAG_UPDATE")
frame:RegisterEvent("ITEM_PUSH")
frame:RegisterEvent("WORLD_MAP_UPDATE")
frame:RegisterEvent("WORLD_MAP_NAME_UPDATE")
frame:SetScript("OnEvent", function(_, event)
    if event == "WORLD_MAP_UPDATE" or event == "WORLD_MAP_NAME_UPDATE" then
        QuestMap.UpdateWorldMap()
    else
        local delay = 0.5
        if event == "QUEST_LOG_UPDATE" or event == "QUEST_WATCH_UPDATE"
            or event == "UNIT_QUEST_LOG_CHANGED"
            or event == "QUEST_ITEM_UPDATE" or event == "QUEST_FINISHED"
            or event == "BAG_UPDATE" or event == "ITEM_PUSH"
        then
            delay = Resolver.QUEST_LOG_SETTLE_DELAY
        end
        refreshPending, refreshAt = true, GetTime() + delay
    end
end)
frame:SetScript("OnUpdate", function(_, elapsed)
    local enabled = Enabled()
    if not enabled then
        if frame.pinsWereEnabled ~= false then
            HidePins(worldPins)
            HidePins(minimapPins)
            HideRouteDots(worldRouteDots)
            HideRouteDots(minimapRouteDots)
            frame.pinsWereEnabled = false
        end
        return
    elseif frame.pinsWereEnabled == false then
        refreshPending, refreshAt = true, 0
    end
    frame.pinsWereEnabled = true
    frame.elapsed = (frame.elapsed or 0) + math.min(elapsed or 0, 0.1)
    if refreshPending and GetTime() >= refreshAt then
        refreshPending = false
        QuestMap.RebuildIndex()
        UpdatePlayerLocation()
        QuestMap.UpdateWorldMap()
        QuestMap.UpdateMinimap()
    elseif frame.elapsed >= 0.12 then
        frame.elapsed = 0
        UpdatePlayerLocation()
        QuestMap.UpdateMinimap()
    end
end)
