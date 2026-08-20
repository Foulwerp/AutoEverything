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
local notableByZone
local combinedByZone = {}
local worldPins, minimapPins = {}, {}
local worldRouteDots, minimapRouteDots = {}, {}
local minimapVisibleCount = 0
local minimapZoneKey
local highlightedRouteEntityID
local RefreshRouteHighlight
local refreshPending, refreshAt = false, 0
local playerMap = { name = nil, key = nil, x = nil, y = nil }
local buildStats = { activeQuests=0, matchedQuests=0, points=0, servicePoints=0 }
local minimapStatus = "not updated"
local locationDebug = {}
local mapContributions = {}
local mapContributionStats = { rebuilt=0, reused=0 }
local invalidateContributionCache = false
local trackedNPCIDs = {}
local initialBuildComplete = false
local initialBuildThread
local buildCooperate
local questLayerReady = false

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
    fargodeepmine    = "Elwynn Forest",
    coldridgevalley  = "Dun Morogh",
    deathknell       = "Tirisfal Glades",
    valleyoftrials   = "Durotar",
    campnarache      = "Mulgore",
    shadowglen       = "Teldrassil",
    ammenvale        = "Azuremyst Isle",
    sunstriderisle   = "Eversong Woods",
}

-- Ascension exposes several starter areas as standalone zoomed maps. Quest
-- and NPC coordinates still use the surrounding classic zone. These bounds
-- are the starter-area overlay rectangles from the client's bundled
-- WorldMapOverlay data, normalized to the parent map. They let both map and
-- minimap pins use the standalone map when selecting the parent map does not
-- yield a usable player position.
local starterMapTransforms = {
    northshirevalley = {
        parent="Elwynn Forest", left=0.424152, top=0.284431,
        right=0.598802, bottom=0.561377,
    },
    fargodeepmine = {
        parent="Elwynn Forest", left=0.299401, top=0.763473,
        right=0.469062, bottom=0.920659,
    },
    coldridgevalley = {
        parent="Dun Morogh", left=0.189621, top=0.666168,
        right=0.339321, bottom=0.838323,
    },
    deathknell = {
        parent="Tirisfal Glades", left=0.278443, top=0.547904,
        right=0.410180, bottom=0.730539,
    },
    valleyoftrials = {
        parent="Durotar", left=0.394212, top=0.591317,
        right=0.494012, bottom=0.748503,
    },
    campnarache = {
        parent="Mulgore", left=0.339321, top=0.718563,
        right=0.558882, bottom=0.935629,
    },
    shadowglen = {
        parent="Teldrassil", left=0.533932, top=0.306886,
        right=0.658683, bottom=0.494012,
    },
    ammenvale = {
        parent="Azuremyst Isle", left=0.753493, top=0.402695,
        right=0.798403, bottom=0.473054,
    },
    sunstriderisle = {
        parent="Eversong Woods", left=0.225549, top=0.040419,
        right=0.401198, bottom=0.281437,
    },
}

local function NormalizeZone(name)
    name = string.lower(name or "")
    name = string.gsub(name, "^the%s+", "")
    name = string.gsub(name, "[^%w]", "")
    return zoneAliases[name] or name
end

local function ModuleEnabled()
    return AutoCore.GetSetting("quest", "enabled",
        AutoQuestConfig and AutoQuestConfig.enabled) ~= false
end

local function Enabled()
    return ModuleEnabled() and AutoCore.GetSetting("quest", "mapPins",
        AutoQuestConfig and AutoQuestConfig.mapPins) ~= false
end

-- User-adjustable via the Map Pins section of the Quest settings page.
local function Setting(key, fallback)
    local value = tonumber(AutoCore.GetSetting("quest", key,
        AutoQuestConfig and AutoQuestConfig[key]))
    return value or fallback
end

local function WorldPinSize() return Setting("worldPinSize", 10) end
local function MinimapPinSize() return Setting("minimapPinSize", 10) end
local function MinimapPinRadiusPercent() return Setting("minimapPinRadiusPercent", 95) end
local function MaxWorldPins() return Setting("maxWorldPins", 500) end
local function MaxMinimapPins() return Setting("maxMinimapPins", 150) end

-- Pulls the "3/10" style count out of a live quest-log objective line (e.g.
-- "Defias Bandits slain: 3/10") so pin tooltips can show real progress
-- instead of just re-stating the quest's static requirement text.
local function ExtractProgress(text)
    local current, required = Resolver.Progress(text)
    if current and required then return current .. "/" .. required end
end

local function BossNPCsEnabled()
    return AutoCore.GetSetting("quest", "showNotableNPCPins",
        AutoQuestConfig and AutoQuestConfig.showNotableNPCPins) ~= false
end

local function RareNPCsEnabled()
    return AutoCore.GetSetting("quest", "showRareNPCPins",
        AutoQuestConfig and AutoQuestConfig.showRareNPCPins) == true
end

local function NotableNPCsEnabled()
    return BossNPCsEnabled() or RareNPCsEnabled()
end

local function AddLocation(zoneID, zoneName, floor, record, coord, questID, questTitle,
    kind, progress, partyMember, partyClass, targetByZone, targetPointKeys)
    targetByZone = targetByZone or activeByZone
    targetPointKeys = targetPointKeys or activePointKeys
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
    local existing = targetPointKeys[pointKey]
    if existing then
        if partyMember then
            existing.partyMembers = existing.partyMembers or {}
            existing.partyMembers[partyMember] = {
                progress=progress, class=partyClass,
            }
            existing.isParty = true
        end
        return false
    end

    targetByZone[key] = targetByZone[key] or {
        name=zoneName, zoneIDs={}, questIDs={}, points={}, routes={},
    }
    local zone = targetByZone[key]
    local numericZoneID = tonumber(zoneID)
    if numericZoneID then zone.zoneIDs[numericZoneID] = true end
    if questID then zone.questIDs[questID] = true end
    local point = {
        x = x, y = y, floor = tonumber(floor) or 0,
        questID = questID, questTitle = questTitle, kind = kind,
        entityID = record.id, name = record.name,
        item = record.item, progress = progress, isParty=partyMember ~= nil,
        seenAt = record.seenAt, expiresAt = record.expiresAt,
        sightingSource = record.source,
        partyMembers = {},
    }
    if partyMember then
        point.partyMembers[partyMember] = { progress=progress, class=partyClass }
    end
    zone.points[#zone.points + 1] = point
    targetPointKeys[pointKey] = point
    return true
end

local function PathsEnabled()
    return Enabled() and AutoCore.GetSetting("quest", "showPatrolPaths",
        AutoQuestConfig and AutoQuestConfig.showPatrolPaths) ~= false
end

-- NPC pages may expose many sampled positions for an NPC that patrols.
-- Split disconnected samples first so separate static spawns are not joined
-- across a zone, then derive one smooth centerline per connected group with
-- pins only at its endpoint(s).
local PATROL_GROUP_LINK_SQ = 25
local PATROL_ROUTE_MIN_SPAN_SQ = 2.25

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
                        if dx * dx + dy * dy <= PATROL_GROUP_LINK_SQ then
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

local function TreeFarthest(adjacency, startIndex)
    local farthest, farthestDistance = startIndex, 0
    local parent = {}
    local stack = { { index=startIndex, from=0, distance=0 } }
    while #stack > 0 do
        local entry = table.remove(stack)
        parent[entry.index] = entry.from
        if entry.distance > farthestDistance then
            farthest, farthestDistance = entry.index, entry.distance
        end
        for _, edge in ipairs(adjacency[entry.index] or {}) do
            if edge.index ~= entry.from then
                stack[#stack + 1] = {
                    index=edge.index, from=entry.index,
                    distance=entry.distance + edge.distance,
                }
            end
        end
    end
    return farthest, parent
end

-- The database contains dense, unordered samples with small side clusters.
-- Build a minimum spanning tree, keep its longest end-to-end path, then apply
-- a light three-point smoothing pass. This yields one stable patrol centerline
-- without connecting distant branches or drawing every noisy sample.
local function ServiceRoutePath(group)
    local adjacency, connected, nearest, nearestSq = {}, { [1]=true }, {}, {}
    for index = 1, #group do adjacency[index] = {} end
    for index = 2, #group do
        local dx, dy = group[1].x - group[index].x, group[1].y - group[index].y
        nearest[index], nearestSq[index] = 1, dx * dx + dy * dy
    end
    for _ = 2, #group do
        local bestTo, bestDistanceSq
        for index = 1, #group do
            if not connected[index] and (not bestDistanceSq or nearestSq[index] < bestDistanceSq) then
                bestTo, bestDistanceSq = index, nearestSq[index]
            end
        end
        if not bestTo or bestDistanceSq > PATROL_GROUP_LINK_SQ then break end
        local bestFrom, distance = nearest[bestTo], math.sqrt(bestDistanceSq)
        connected[bestTo] = true
        adjacency[bestFrom][#adjacency[bestFrom] + 1] = { index=bestTo, distance=distance }
        adjacency[bestTo][#adjacency[bestTo] + 1] = { index=bestFrom, distance=distance }
        for index, point in ipairs(group) do
            if not connected[index] then
                local dx, dy = group[bestTo].x - point.x, group[bestTo].y - point.y
                local distanceSq = dx * dx + dy * dy
                if distanceSq < nearestSq[index] then
                    nearest[index], nearestSq[index] = bestTo, distanceSq
                end
            end
        end
    end

    local first = TreeFarthest(adjacency, 1)
    local last, parent = TreeFarthest(adjacency, first)
    local reversed, index = {}, last
    while index and index ~= 0 do
        reversed[#reversed + 1] = group[index]
        if index == first then break end
        index = parent[index]
    end
    local path = {}
    for reverseIndex = #reversed, 1, -1 do path[#path + 1] = reversed[reverseIndex] end
    if #path < 3 then return path end

    local smoothed = { path[1] }
    for pathIndex = 2, #path - 1 do
        local previous, point, following = path[pathIndex - 1], path[pathIndex], path[pathIndex + 1]
        smoothed[#smoothed + 1] = {
            x=previous.x * 0.25 + point.x * 0.5 + following.x * 0.25,
            y=previous.y * 0.25 + point.y * 0.5 + following.y * 0.25,
        }
    end
    smoothed[#smoothed + 1] = path[#path]
    return smoothed
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
        local _, _, spanSq = FarthestServicePoints(group)
        if #group >= 3 and spanSq >= PATROL_ROUTE_MIN_SPAN_SQ then
            local path = ServiceRoutePath(group)
            zone.routes[#zone.routes + 1] = {
                points=path,
                floor=tonumber(location.floor) or 0,
                kind=service.kind, entityID=service.id, name=service.name,
            }
            AddServicePoint(zone, service, location, path[1], true)
            AddServicePoint(zone, service, location, path[#path], true)
        elseif #group > 0 then
            AddServicePoint(zone, service, location, RepresentativeServicePoint(group), false)
        end
    end
end

local function AddRarePatrolPoint(zone, npc, location, point, routeEndpoint)
    zone.points[#zone.points + 1] = {
        x=point.x, y=point.y, floor=tonumber(location.floor) or 0,
        kind="rare", entityID=npc.id, name=npc.name,
        routeEndpoint=routeEndpoint and true or nil,
    }
end

local function AddRarePatrolLocation(zone, npc, location)
    for _, group in ipairs(ServiceCoordinateGroups(location.coords)) do
        local _, _, spanSq = FarthestServicePoints(group)
        if #group >= 3 and spanSq >= PATROL_ROUTE_MIN_SPAN_SQ then
            local path = ServiceRoutePath(group)
            local closed = false
            if #path >= 5 then
                local dx = path[1].x - path[#path].x
                local dy = path[1].y - path[#path].y
                closed = dx * dx + dy * dy <= spanSq * 0.16
            end
            if closed then path[#path + 1] = path[1] end
            zone.routes[#zone.routes + 1] = {
                points=path, closed=closed,
                floor=tonumber(location.floor) or 0,
                kind="rare", entityID=npc.id, name=npc.name,
            }
            AddRarePatrolPoint(zone, npc, location, path[1], true)
            if not closed then
                AddRarePatrolPoint(zone, npc, location, path[#path], true)
            end
        elseif #group > 0 then
            AddRarePatrolPoint(zone, npc, location,
                RepresentativeServicePoint(group), false)
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
            if buildCooperate then buildCooperate() end
        end
        if buildCooperate then buildCooperate() end
    end
end

local StarterZoneForKey

local function ZoneForKey(key)
    if not key then return nil end
    local cached = combinedByZone[key]
    if cached then return cached end
    local questZone = activeByZone[key]
    local notableZone = NotableNPCsEnabled() and notableByZone and notableByZone[key]
    local serviceZone = serviceByZone and serviceByZone[key]
    local sources = {}
    if questZone then sources[#sources + 1] = questZone end
    if notableZone then sources[#sources + 1] = notableZone end
    if serviceZone then sources[#sources + 1] = serviceZone end
    if #sources == 0 then return nil end
    if #sources == 1 and sources[1] ~= notableZone then return sources[1] end
    local scanner = AutoQuest.RareScanner
    local zone = {
        name=(questZone and questZone.name) or sources[1].name,
        zoneIDs={}, questIDs=questZone and questZone.questIDs or {}, points={}, routes={},
    }
    for _, source in ipairs(sources) do
        for zoneID in pairs(source.zoneIDs or {}) do zone.zoneIDs[zoneID] = true end
        for _, point in ipairs(source.points or {}) do
            local enabled = source ~= notableZone
                or (point.kind == "rare" and RareNPCsEnabled())
                or (point.kind ~= "rare" and BossNPCsEnabled())
            local defeated = source == notableZone and point.kind == "boss"
                and scanner and scanner.IsBossDefeated
                and scanner.IsBossDefeated(point.entityID)
            if enabled and (source ~= notableZone
                or not trackedNPCIDs[tonumber(point.entityID) or point.entityID])
                and not defeated
            then
                zone.points[#zone.points + 1] = point
            end
        end
        for _, route in ipairs(source.routes or {}) do
            if source ~= notableZone or RareNPCsEnabled() then
                zone.routes[#zone.routes + 1] = route
            end
        end
    end
    combinedByZone[key] = zone
    return zone
end

local function StarterPoint(point, transform)
    local parentX, parentY = (tonumber(point.x) or 0) / 100, (tonumber(point.y) or 0) / 100
    if parentX < transform.left or parentX > transform.right
        or parentY < transform.top or parentY > transform.bottom
    then
        return nil
    end
    local copy = {}
    for key, value in pairs(point) do copy[key] = value end
    copy.x = (parentX - transform.left) / (transform.right - transform.left) * 100
    copy.y = (parentY - transform.top) / (transform.bottom - transform.top) * 100
    return copy
end

StarterZoneForKey = function(key)
    local transform = starterMapTransforms[key]
    if not transform then return nil end
    -- Transform only the active quest layer. Static services and notable NPCs
    -- have their own map identities and must not decide whether quest points
    -- from the parent coordinate frame are available here.
    local parent = activeByZone[NormalizeZone(transform.parent)]
    if not parent then return nil end
    local zone = {
        name=key, zoneIDs={}, questIDs=parent.questIDs or {}, points={}, routes={},
    }
    for _, point in ipairs(parent.points or {}) do
        local transformed = StarterPoint(point, transform)
        if transformed then zone.points[#zone.points + 1] = transformed end
    end
    for _, route in ipairs(parent.routes or {}) do
        local transformedRoute = {}
        for routeKey, value in pairs(route) do
            if routeKey ~= "points" then transformedRoute[routeKey] = value end
        end
        transformedRoute.points = {}
        for _, point in ipairs(route.points or {}) do
            local transformed = StarterPoint(point, transform)
            if transformed then transformedRoute.points[#transformedRoute.points + 1] = transformed end
        end
        if #transformedRoute.points >= 2 then zone.routes[#zone.routes + 1] = transformedRoute end
    end
    if #zone.points == 0 and #zone.routes == 0 then return nil end
    return zone
end

-- Materialize alternate-map quest layers before static pins are built. This
-- makes map identity independent of whether a boss or service layer exists,
-- and avoids relying on a lazy combined-layer lookup during map API events.
local function BuildMappedQuestZones()
    local mapped = {}
    buildStats.mappedQuestPoints = 0
    for key in pairs(starterMapTransforms) do
        local zone = StarterZoneForKey(key)
        if zone then
            mapped[key] = zone
            buildStats.mappedQuestPoints = buildStats.mappedQuestPoints + #(zone.points or {})
        end
    end
    for key, zone in pairs(mapped) do
        local existing = activeByZone[key]
        if not existing then
            activeByZone[key] = zone
        else
            for zoneID in pairs(zone.zoneIDs or {}) do existing.zoneIDs[zoneID] = true end
            for questID in pairs(zone.questIDs or {}) do existing.questIDs[questID] = true end
            for _, point in ipairs(zone.points or {}) do
                existing.points[#existing.points + 1] = point
            end
            for _, route in ipairs(zone.routes or {}) do
                existing.routes[#existing.routes + 1] = route
            end
        end
    end
end

local function HasActiveQuestPoints(key)
    if not key then return false end
    local zone = activeByZone[key]
    return zone and (#(zone.points or {}) > 0 or #(zone.routes or {}) > 0) or false
end

local function ConfirmedMapKind(kind)
    if kind == "kill" then return kind end
    if kind == "interact" then return "object" end
end

-- A unique live tooltip match can supplement missing kill/interact locations.
-- Loot locations remain gated by explicit quest/item source relationships.
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

local function AddQuestObjectiveNPCs(questID, questTitle, objectives, npcIDs, partyMember, partyClass)
    local objective = Resolver.ObjectiveForQuestNPC(objectives)
    local kind = objective and Resolver.RecordKind({}, objective, "map")
    if not objective or not kind then return end

    local _, displayLabel = Resolver.Normalize(objective.text)
    for _, npcID in ipairs(npcIDs or {}) do
        local record = { id=npcID, name=displayLabel ~= "" and displayLabel or questTitle }
        for _, location in ipairs(SpawnStore.Get(npcID) or {}) do
            for _, coord in ipairs(location.coords or {}) do
                if AddLocation(location.zoneID, location.zone, location.floor,
                    record, coord, questID, questTitle, kind,
                    ExtractProgress(objective.text), partyMember, partyClass)
                then
                    buildStats.points = buildStats.points + 1
                end
            end
        end
    end
end

local function AddQuestItemNPCs(questID, questTitle, objectives, sources, partyMember, partyClass)
    for _, source in ipairs(sources or {}) do
        local objective = Resolver.ObjectiveForQuestItem(objectives, source.itemName)
        if objective then
            local _, displayLabel = Resolver.Normalize(objective.text)
            local itemName = source.itemName or displayLabel
            for _, npcID in ipairs(source.npcIDs or {}) do
                local record = {
                    id=npcID, name=SpawnStore.GetName(npcID) or ("NPC " .. npcID),
                    item=itemName ~= "" and itemName or nil,
                }
                for _, location in ipairs(SpawnStore.Get(npcID) or {}) do
                    for _, coord in ipairs(location.coords or {}) do
                        if AddLocation(location.zoneID, location.zone, location.floor,
                            record, coord, questID, questTitle, "loot",
                            ExtractProgress(objective.text), partyMember, partyClass)
                        then
                            buildStats.points = buildStats.points + 1
                        end
                    end
                end
            end
        end
    end
end

local function RemoteObjectives(quest)
    local objectives = {}
    for index, objective in ipairs(quest.objectives or {}) do
        objectives[index] = {
            text=objective.text or "", kind=objective.type or "",
            done=Resolver.ObjectiveIsComplete(objective.text, objective.finished)
                or (objective.current and objective.required and objective.required > 0
                    and objective.current >= objective.required),
            current=objective.current, required=objective.required,
            targetType=objective.targetType, targetID=objective.targetID,
        }
    end
    return objectives
end

local function IndexRemoteQuest(quest, member)
    local questID = tonumber(quest.id) or tonumber(string.match(quest.key or "", "^I(%d+)$"))
    local title = quest.title or "Unknown quest"
    local objectives = RemoteObjectives(quest)
    local resolved = AutoQuest.ResolveQuestEntries(questID, title) or {}
    local relationshipData, relationshipIDs = {}, {}
    local function AddRelationshipID(value)
        value = tonumber(value)
        if not value or relationshipIDs[value] then return end
        relationshipIDs[value] = true
        relationshipData[#relationshipData + 1] = {
            questID=value,
            npcIDs=SpawnStore.GetObjectiveNPCs(value),
            itemSources=SpawnStore.GetQuestItemSources(value),
        }
    end
    AddRelationshipID(questID)
    for _, match in ipairs(resolved) do AddRelationshipID(match.id) end

    local pointsBefore = buildStats.points
    for _, match in ipairs(resolved) do
        local matchQuestID = match.id
        for _, record in ipairs(match.entry.records or {}) do
            local recordType = tonumber(record.type) or 1
            local objective = Resolver.ObjectiveForRecord(objectives, record)
            local kind = Resolver.RecordKind(record, objective, "map")
            if objective and kind and not objective.done then
                local progress = ExtractProgress(objective.text)
                if recordType == 2 or recordType == -1 then
                    for _, coord in ipairs(record.coords or {}) do
                        if AddLocation(record.zoneID, record.zone, record.floor, record, coord,
                            matchQuestID, title, kind, progress, member.name, member.class)
                        then
                            buildStats.points = buildStats.points + 1
                            buildStats.partyPoints = buildStats.partyPoints + 1
                        end
                    end
                else
                    for _, location in ipairs(SpawnStore.Get(tonumber(record.id)) or {}) do
                        for _, coord in ipairs(location.coords or {}) do
                            if AddLocation(location.zoneID, location.zone, location.floor,
                                record, coord, matchQuestID, title, kind, progress,
                                member.name, member.class)
                            then
                                buildStats.points = buildStats.points + 1
                                buildStats.partyPoints = buildStats.partyPoints + 1
                            end
                        end
                    end
                end
            end
        end
    end

    for _, data in ipairs(relationshipData) do
        local before = buildStats.points
        AddQuestObjectiveNPCs(data.questID, title, objectives, data.npcIDs,
            member.name, member.class)
        AddQuestItemNPCs(data.questID, title, objectives, data.itemSources,
            member.name, member.class)
        buildStats.partyPoints = buildStats.partyPoints + (buildStats.points - before)
    end

    -- A stable monster target sent by the remote client can still produce
    -- locations when the quest page relationship is incomplete locally.
    for _, objective in ipairs(objectives) do
        local targetID = tonumber(objective.targetID)
        if not objective.done and objective.targetType == "monster" and targetID then
            local _, display = Resolver.Normalize(objective.text)
            local record = { id=targetID, name=display ~= "" and display or title }
            local kind = Resolver.RecordKind(record, objective, "map")
            for _, location in ipairs(SpawnStore.Get(targetID) or {}) do
                for _, coord in ipairs(location.coords or {}) do
                    if AddLocation(location.zoneID, location.zone, location.floor,
                        record, coord, questID, title, kind or "kill",
                        ExtractProgress(objective.text), member.name, member.class)
                    then
                        buildStats.points = buildStats.points + 1
                        buildStats.partyPoints = buildStats.partyPoints + 1
                    end
                end
            end
        end
    end
    if buildStats.points > pointsBefore then buildStats.partyQuests = buildStats.partyQuests + 1 end
end

local function MapQuestFingerprint(quest, member)
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

local function IndexLocalQuest(quest)
    local title, questID = quest.title, quest.id
    local resolved = AutoQuest.ResolveQuestEntries(questID, title) or {}
    buildStats.activeQuests = buildStats.activeQuests + 1
    if quest.complete then return end
    local objectives = {}
    for _, objective in ipairs(quest.objectives or {}) do
        objectives[#objectives + 1] = {
            text=objective.text, kind=objective.type, done=objective.finished,
        }
    end

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
        local matchQuestID = match.id
        local matchPointsBefore = buildStats.points
        for _, record in ipairs(match.entry.records or {}) do
            local recordType = tonumber(record.type) or 1
            local objective = Resolver.ObjectiveForRecord(objectives, record)
            local kind = Resolver.RecordKind(record, objective, "map")
            if objective and kind and not objective.done then
                local progress = ExtractProgress(objective.text)
                if recordType == 2 or recordType == -1 then
                    for _, coord in ipairs(record.coords or {}) do
                        if AddLocation(record.zoneID, record.zone, record.floor,
                            record, coord, matchQuestID, title, kind, progress)
                        then
                            buildStats.points = buildStats.points + 1
                        end
                    end
                else
                    local id = tonumber(record.id)
                    for _, location in ipairs(id and SpawnStore.Get(id) or {}) do
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
    for _, objective in ipairs(objectives) do
        local objectiveType = string.lower(objective.kind or "")
        if not objective.done and (objectiveType == "monster" or objectiveType == "player") then
            local npcIDs = SpawnStore.FindNPCsByObjectiveText(objective.text, buildCooperate)
            if npcIDs then AddQuestObjectiveNPCs(questID, title, { objective }, npcIDs) end
        end
    end
end

local function BuildMapContribution(quest, member, fingerprint)
    local aggregateZones, aggregateKeys, aggregateStats = activeByZone, activePointKeys, buildStats
    activeByZone, activePointKeys = {}, {}
    buildStats = {
        activeQuests=0, matchedQuests=0, confirmedObjectives=0,
        points=0, servicePoints=0, partyPoints=0, partyQuests=0, matches={},
    }
    if member then
        if not quest.complete then IndexRemoteQuest(quest, member) end
    else
        IndexLocalQuest(quest)
    end
    local contribution = {
        fingerprint=fingerprint, zones=activeByZone, stats=buildStats,
        remote=member ~= nil,
    }
    activeByZone, activePointKeys, buildStats = aggregateZones, aggregateKeys, aggregateStats
    return contribution
end

local function MergeContribution(contribution)
    local stats = contribution.stats or {}
    buildStats.activeQuests = buildStats.activeQuests + (stats.activeQuests or 0)
    buildStats.matchedQuests = buildStats.matchedQuests + (stats.matchedQuests or 0)
    buildStats.partyQuests = buildStats.partyQuests + (stats.partyQuests or 0)
    for _, match in ipairs(stats.matches or {}) do buildStats.matches[#buildStats.matches + 1] = match end
    for _, zone in pairs(contribution.zones or {}) do
        for _, point in ipairs(zone.points or {}) do
            local record = { id=point.entityID, name=point.name, item=point.item }
            local members, addedMember = point.partyMembers or {}, false
            for memberName, progress in pairs(members) do
                AddLocation(nil, zone.name, point.floor, record, {point.x, point.y},
                    point.questID, point.questTitle, point.kind,
                    progress.progress or point.progress, memberName, progress.class)
                addedMember = true
            end
            if not addedMember then
                AddLocation(nil, zone.name, point.floor, record, {point.x, point.y},
                    point.questID, point.questTitle, point.kind, point.progress)
            end
        end
        local mergedZone = activeByZone[NormalizeZone(zone.name)]
        if mergedZone then
            for zoneID in pairs(zone.zoneIDs or {}) do mergedZone.zoneIDs[zoneID] = true end
            for questID in pairs(zone.questIDs or {}) do mergedZone.questIDs[questID] = true end
        end
    end
end

local function AddDiscoveryNPC(npc, kind, targetByZone, targetPointKeys)
    if not npc or type(npc.locations) ~= "table" then return 0 end
    local added = 0
    local record = { id=npc.id, name=npc.name }
    for _, location in ipairs(npc.locations) do
        for _, coord in ipairs(location.coords or {}) do
            if AddLocation(location.zoneID, location.zone, location.floor,
                record, coord, nil, nil, kind, nil, nil, nil,
                targetByZone, targetPointKeys)
            then
                added = added + 1
            end
        end
        if buildCooperate then buildCooperate() end
    end
    return added
end

local function BuildNotableIndex()
    if notableByZone then return end
    notableByZone = {}
    local pointKeys = {}
    for _, metadata in ipairs(SpawnStore.GetNotableNPCs(buildCooperate) or {}) do
        local npc = SpawnStore.GetNPC(metadata.id)
        if metadata.kind == "rare" and RareNPCsEnabled()
            and npc and type(npc.locations) == "table"
        then
            for _, location in ipairs(npc.locations) do
                local key = NormalizeZone(location.zone)
                if key ~= "" then
                    local zone = notableByZone[key]
                    if not zone then
                        zone = { name=location.zone, zoneIDs={}, questIDs={}, points={}, routes={} }
                        notableByZone[key] = zone
                    end
                    local numericZoneID = tonumber(location.zoneID)
                    if numericZoneID then zone.zoneIDs[numericZoneID] = true end
                    AddRarePatrolLocation(zone, npc, location)
                end
                if buildCooperate then buildCooperate() end
            end
        elseif metadata.kind ~= "rare" and BossNPCsEnabled() then
            AddDiscoveryNPC(npc, metadata.kind or "rare", notableByZone, pointKeys)
        end
        if buildCooperate then buildCooperate() end
    end
end

local function AddNPCDiscoveryLocations()
    -- Live sightings and explicit searches are added before the static rare
    -- catalog so they survive the world-map pin cap in crowded zones.
    buildStats.sightingPoints = 0
    local scanner = AutoQuest.RareScanner
    for _, sighting in ipairs(scanner and scanner.GetSightings and scanner.GetSightings() or {}) do
        local pinKind = sighting.kind == "boss" and "bossSighting"
            or sighting.kind == "quest" and "questSighting"
            or sighting.kind == "questLoot" and "questLootSighting"
            or "sighting"
        if AddLocation(sighting.zoneID, sighting.zone, sighting.floor,
            sighting, { sighting.x, sighting.y }, nil, nil, pinKind)
        then
            buildStats.sightingPoints = buildStats.sightingPoints + 1
        end
    end
    buildStats.trackedNPCPoints = 0
    for npcID in pairs(trackedNPCIDs) do
        buildStats.trackedNPCPoints = buildStats.trackedNPCPoints
            + AddDiscoveryNPC(SpawnStore.GetNPC(npcID), "search")
    end
    buildStats.notablePoints = 0
    if NotableNPCsEnabled() then
        BuildNotableIndex()
        for _, zone in pairs(notableByZone or {}) do
            buildStats.notablePoints = buildStats.notablePoints + #(zone.points or {})
        end
    end
end

function QuestMap.RebuildIndex()
    activeByZone = {}
    activePointKeys = {}
    combinedByZone = {}
    questLayerReady = false
    if SpawnStore.AreNotableNPCsReady and not SpawnStore.AreNotableNPCsReady() then
        notableByZone = nil
    end
    buildStats = {
        activeQuests=0, matchedQuests=0, confirmedObjectives=0,
        points=0, servicePoints=0, partyPoints=0, partyQuests=0, matches={}
    }
    if not Enabled() then return end
    local resolverObjectives = Resolver.BuildActive()
    local previous = invalidateContributionCache and {} or mapContributions
    local nextContributions, rebuilt, reused = {}, 0, 0
    invalidateContributionCache = false
    local function Include(sourceKey, quest, member)
        local fingerprint = MapQuestFingerprint(quest, member)
        local contribution = previous[sourceKey]
        if not contribution or contribution.fingerprint ~= fingerprint then
            contribution = BuildMapContribution(quest, member, fingerprint)
            rebuilt = rebuilt + 1
        else
            reused = reused + 1
        end
        nextContributions[sourceKey] = contribution
    end
    for _, quest in ipairs(AutoQuest.QuestState.GetQuests()) do
        Include("local:" .. tostring(quest.key or quest.id or quest.title), quest)
    end
    if AutoCore.GetSetting("quest", "groupQuestSync",
        AutoQuestConfig and AutoQuestConfig.groupQuestSync) == true
        and AutoCore.GetSetting("quest", "showGroupQuestMapPins",
            AutoQuestConfig and AutoQuestConfig.showGroupQuestMapPins) ~= false
    then
        local sync = AutoQuest.GroupSync
        local members = sync and sync.GetMemberQuestData and sync.GetMemberQuestData() or {}
        for memberKey, member in pairs(members) do
            if member.completeSnapshot and not member.stale and member.connected ~= false then
                for key, quest in pairs(member.quests or {}) do
                    Include("remote:" .. tostring(memberKey) .. ":" .. tostring(key), quest, member)
                end
            end
        end
    end
    mapContributions = nextContributions
    mapContributionStats = { rebuilt=rebuilt, reused=reused }
    -- Preserve the old local-first merge behavior so a point shared with a
    -- party member keeps the local player's progress as its primary label.
    for _, contribution in pairs(mapContributions) do
        if not contribution.remote then MergeContribution(contribution) end
    end
    for _, contribution in pairs(mapContributions) do
        if contribution.remote then MergeContribution(contribution) end
    end
    AddConfirmedLocations(resolverObjectives)
    BuildMappedQuestZones()
    -- Active quest locations are usable now. Static service, notable-NPC, and
    -- fallback-name indexes can continue warming without withholding them.
    questLayerReady = true
    BuildServiceIndex()
    for _, zone in pairs(serviceByZone or {}) do
        buildStats.servicePoints = buildStats.servicePoints + #(zone.points or {})
    end
    AddNPCDiscoveryLocations()
    buildStats.points, buildStats.partyPoints = 0, 0
    for _, zone in pairs(activeByZone) do
        buildStats.points = buildStats.points + #(zone.points or {})
        for _, point in ipairs(zone.points or {}) do
            if point.isParty then buildStats.partyPoints = buildStats.partyPoints + 1 end
        end
    end
    if buildCooperate then
        -- Warm both global fallbacks cooperatively even when their individual
        -- pin options are off. Later quest acceptance, NPC lookup, or rare
        -- scanning must never become the first synchronous full-catalog scan.
        SpawnStore.GetNotableNPCs(buildCooperate)
        BuildNotableIndex()
        if SpawnStore.PrepareQuestLookups then
            SpawnStore.PrepareQuestLookups(buildCooperate)
        end
    end
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
    boss = "Interface\\AddOns\\AutoEverything\\Images\\QuestSkull.tga",
    rare = "Interface\\AddOns\\AutoEverything\\Images\\QuestRare.tga",
    search = "Interface\\AddOns\\AutoEverything\\Images\\Interact.tga",
    sighting = "Interface\\AddOns\\AutoEverything\\Images\\QuestRare.tga",
    bossSighting = "Interface\\AddOns\\AutoEverything\\Images\\QuestSkull.tga",
    questSighting = "Interface\\AddOns\\AutoEverything\\Images\\QuestSkull.tga",
    questLootSighting = "Interface\\AddOns\\AutoEverything\\Images\\QuestLootBag.tga",
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
    boss={1,0.18,0.18}, rare={0.75,0.35,1}, search={0.2,0.85,1},
    sighting={1,0.82,0.18}, bossSighting={1,0.35,0.2},
    questSighting={1,0.3,0.3}, questLootSighting={0.35,1,0.45},
    auctioneer={1,0.65,0.2}, banker={1,0.82,0.2}, battlemaster={0.85,0.9,1},
    flightmaster={0.75,0.9,1}, guildmaster={0.35,0.55,1}, innkeeper={0.35,0.7,1},
    talentunlearner={0.75,0.45,1}, tabardvendor={1,0.3,0.25},
    stablemaster={0.8,0.85,0.95}, trainer={1,0.9,0.55}, vendor={1,0.55,0.3},
}
local ROUTE_COLOR = { 0.62, 0.65, 0.68 }
local ROUTE_HIGHLIGHT_COLOR = { 1, 0.82, 0.25 }
local ROUTE_DOT_TEXTURE = AutoCore.UI and AutoCore.UI.Textures
    and AutoCore.UI.Textures.circle or "Interface\\TALENTFRAME\\talentsmasknodecircle"

local headingText = {
    kill = "Kill",
    boss = "Boss",
    rare = "Rare",
    search = "NPC Search",
    sighting = "Recent Rare Sighting",
    bossSighting = "Recent Boss Sighting",
    questSighting = "Recent Quest Target Sighting",
    questLootSighting = "Recent Quest Loot Sighting",
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
    elseif cluster.kind == "boss" then
        return "Boss: " .. name
    elseif cluster.kind == "rare" then
        return "Rare: " .. name
    elseif cluster.kind == "search" then
        return "Find " .. name .. " (NPC " .. tostring(point.entityID or "?") .. ")"
    elseif cluster.kind == "sighting" or cluster.kind == "bossSighting"
        or cluster.kind == "questSighting" or cluster.kind == "questLootSighting"
    then
        return "Recently sighted: " .. name
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

local function ColoredPartyName(name, class)
    local display = string.match(tostring(name or "Unknown"), "^[^-]+") or tostring(name or "Unknown")
    local color = type(RAID_CLASS_COLORS) == "table" and RAID_CLASS_COLORS[class or ""] or nil
    if not color then return display end
    return string.format("|cff%02x%02x%02x%s|r",
        math.floor((color.r or 0.8) * 255 + 0.5),
        math.floor((color.g or 0.8) * 255 + 0.5),
        math.floor((color.b or 0.8) * 255 + 0.5), display)
end

local function ShowPinTooltip(pin)
    local cluster = pin.cluster
    if not cluster then return end
    GameTooltip:SetOwner(pin, "ANCHOR_RIGHT")
    local color = iconColors[cluster.kind] or iconColors.kill
    local partyCluster = false
    for _, point in ipairs(cluster.members or {}) do
        if point.isParty then partyCluster = true; break end
    end
    local heading = headingText[cluster.kind] or "Quest Objective"
    GameTooltip:SetText((partyCluster and "Party " or "") .. heading,
        color[1], color[2], color[3])

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
                if not point.isService and point.questTitle then
                    GameTooltip:AddLine("  " .. point.questTitle, 0.6, 0.65, 0.75)
                end
                if point.seenAt then
                    local age = math.max(0, math.floor((GetTime and GetTime() or 0) - point.seenAt))
                    GameTooltip:AddLine("  Seen " .. age .. " sec ago - "
                        .. tostring(point.sightingSource or "nearby"), 1, 0.82, 0.25)
                end
                local partyNames = {}
                for name in pairs(point.partyMembers or {}) do partyNames[#partyNames + 1] = name end
                table.sort(partyNames, function(a, b) return string.lower(a) < string.lower(b) end)
                for _, name in ipairs(partyNames) do
                    local party = point.partyMembers[name]
                    GameTooltip:AddLine("    " .. ColoredPartyName(name, party.class)
                        .. ": |cffffd200" .. (party.progress or "In progress") .. "|r",
                        0.82, 0.82, 0.82)
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

local function UpdateSightingPulse(pin)
    local pulse = 0.72 + 0.28 * math.abs(math.sin((GetTime and GetTime() or 0) * 3))
    pin.icon:SetAlpha(pulse)
end

local function ConfigurePin(pin, cluster, size)
    if pin.cluster == cluster and pin.configuredSize == size then return end
    pin.cluster = cluster
    pin.configuredSize = size
    pin:SetWidth(size)
    pin:SetHeight(size)
    -- No vertex tint - same natural icon colors as the nameplate badges in
    -- QuestMarkers.lua (white skull, brown bag) rather than recoloring them.
    pin.icon:SetTexture(iconTextures[cluster.kind] or iconTextures.kill)
    pin.icon:SetVertexColor(1, 1, 1, 1)
    if cluster.kind == "sighting" or cluster.kind == "bossSighting"
        or cluster.kind == "questSighting" or cluster.kind == "questLootSighting"
    then
        pin:SetScript("OnUpdate", UpdateSightingPulse)
    else
        pin:SetScript("OnUpdate", nil)
        pin.icon:SetAlpha(1)
    end
    local isParty = false
    for _, point in ipairs(cluster.members or {}) do
        if point.isParty then isParty = true; break end
    end
    if isParty then pin.partyBadge:Show() else pin.partyBadge:Hide() end
end

local function RouteEntityForPin(pin)
    local cluster = pin and pin.cluster
    for _, point in ipairs(cluster and cluster.members or {}) do
        if point.routeEndpoint and point.entityID then
            return tonumber(point.entityID) or point.entityID
        end
    end
end

local function ShowPinDetails(pin)
    highlightedRouteEntityID = RouteEntityForPin(pin)
    if RefreshRouteHighlight then RefreshRouteHighlight(pin) end
    ShowPinTooltip(pin)
end

local function HidePinDetails(pin)
    GameTooltip_Hide()
    if highlightedRouteEntityID ~= nil then
        highlightedRouteEntityID = nil
        if RefreshRouteHighlight then RefreshRouteHighlight(pin) end
    end
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
    pin.partyBadge = pin:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    if AutoCore.UI and AutoCore.UI.ApplyFont then AutoCore.UI.ApplyFont(pin.partyBadge, 10) end
    pin.partyBadge:SetPoint("TOPRIGHT", pin, "TOPRIGHT", 4, 4)
    pin.partyBadge:SetText("+")
    pin.partyBadge:SetTextColor(0.35, 0.75, 1, 1)
    pin.partyBadge:Hide()
    pin:SetScript("OnEnter", ShowPinDetails)
    pin:SetScript("OnLeave", HidePinDetails)
    pin:Hide()
    return pin
end

local function HidePins(pool)
    for _, pin in ipairs(pool) do
        pin:SetScript("OnUpdate", nil)
        pin.icon:SetAlpha(1)
        pin:Hide()
        pin.partyBadge:Hide()
        pin.cluster = nil
    end
end

local function HidePinsAfter(pool, lastVisible)
    for index = lastVisible + 1, #pool do
        local pin = pool[index]
        if pin:IsShown() or pin.cluster then
            pin:SetScript("OnUpdate", nil)
            pin.icon:SetAlpha(1)
            pin:Hide()
            pin.partyBadge:Hide()
            pin.cluster = nil
        end
    end
end

local function HideRouteDots(pool)
    for _, line in ipairs(pool) do line:Hide() end
end

local function RoutePixel(pool, index, parent, anchor, x, y, color, size, alpha)
    local pixel = pool[index]
    if pixel and pixel:GetParent() ~= parent then
        pixel:Hide()
        pixel = nil
    end
    if not pixel then
        -- World-map tiles also use ARTWORK. OVERLAY keeps the route visible
        -- regardless of the order in which the legacy client rebuilds tiles.
        pixel = parent:CreateTexture(nil, "OVERLAY")
        pool[index] = pixel
    end
    pixel:SetWidth(size)
    pixel:SetHeight(size)
    pixel:SetTexture(ROUTE_DOT_TEXTURE)
    pixel:SetVertexColor(color[1], color[2], color[3], alpha)
    pixel:ClearAllPoints()
    pixel:SetPoint("CENTER", parent, anchor, x, y)
    pixel:Show()
end

local function DrawEvenRouteDots(pool, count, limit, parent, anchor,
    points, color, size, alpha, spacing, visible)
    if not points or not points[1] then return count end
    local placed = {}
    local minimumDistanceSq = (spacing * 0.7) * (spacing * 0.7)
    local function AddDot(x, y)
        if count >= limit or (visible and not visible(x, y)) then return end
        for _, point in ipairs(placed) do
            local dx, dy = point.x - x, point.y - y
            if dx * dx + dy * dy < minimumDistanceSq then return end
        end
        placed[#placed + 1] = { x=x, y=y }
        count = count + 1
        RoutePixel(pool, count, parent, anchor, x, y, color, size, alpha)
    end

    AddDot(points[1].x, points[1].y)
    local distanceSinceDot = 0
    for index = 2, #points do
        local first, last = points[index - 1], points[index]
        local dx, dy = last.x - first.x, last.y - first.y
        local length = math.sqrt(dx * dx + dy * dy)
        if length > 0 then
            local offset = spacing - distanceSinceDot
            while offset <= length do
                local progress = offset / length
                AddDot(first.x + dx * progress, first.y + dy * progress)
                if count >= limit then return count end
                offset = offset + spacing
            end
            distanceSinceDot = (distanceSinceDot + length) % spacing
        end
    end
    return count
end

local function DrawWorldRoutes(zone, parent, currentFloor)
    HideRouteDots(worldRouteDots)
    if not PathsEnabled() then return end
    local width, height = parent:GetWidth(), parent:GetHeight()
    local count = 0
    for _, route in ipairs(zone.routes or {}) do
        if route.floor == 0 or currentFloor == 0 or route.floor == currentFloor then
            local highlighted = highlightedRouteEntityID ~= nil
                and tonumber(route.entityID) == tonumber(highlightedRouteEntityID)
            local color = highlighted and ROUTE_HIGHLIGHT_COLOR or ROUTE_COLOR
            local size, alpha = highlighted and 5 or 3, highlighted and 0.9 or 0.45
            local screenPoints = {}
            for _, point in ipairs(route.points or {}) do
                screenPoints[#screenPoints + 1] = {
                    x=point.x * width / 100,
                    y=-point.y * height / 100,
                }
            end
            count = DrawEvenRouteDots(worldRouteDots, count, 1500, parent, "TOPLEFT",
                screenPoints, color, size, alpha, 8)
        end
        if count >= 1500 then break end
    end
end

-- Dungeon maps do not participate in the classic continent/zone selector.
-- Resolve the selected map through every map API shape exposed by supported
-- Ascension builds, including the legacy map-file name returned by
-- GetMapInfo(). Map-file names omit spaces ("WailingCaverns") but normalize
-- to the same keys as the database's display names.
local function CurrentMapName()
    local mapID = GetCurrentMapAreaID and GetCurrentMapAreaID()
    local name = mapID and GetMapName and GetMapName(mapID)
    if not name and mapID and C_Map and C_Map.GetMapInfo then
        local ok, info = pcall(C_Map.GetMapInfo, mapID)
        if ok and type(info) == "table" then name = info.name end
    end
    if not name and GetMapInfo then
        local ok, mapFileName = pcall(GetMapInfo)
        if ok and type(mapFileName) == "string" and mapFileName ~= "" then
            name = mapFileName
        end
    end
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

local function ZoneForMapName(name)
    local key = NormalizeZone(name)
    local zone = ZoneForKey(key)
    -- Legacy dungeon map-file names concatenate a leading article, while
    -- NormalizeZone removes it from display names such as "The Deadmines".
    if not zone and string.sub(key, 1, 3) == "the" then
        key = string.sub(key, 4)
        zone = ZoneForKey(key)
    end
    return zone, key
end

local function MapKey(name)
    local _, key = ZoneForMapName(name)
    return key
end

function QuestMap.UpdateWorldMap()
    HideRouteDots(worldRouteDots)
    if initialBuildThread and not questLayerReady then
        HidePins(worldPins)
        return
    end
    if not Enabled() or not WorldMapFrame or not WorldMapFrame:IsShown() then
        HidePins(worldPins)
        return
    end
    local parent = WorldMapDetailFrame or WorldMapButton
    if not parent or parent:GetWidth() <= 0 or parent:GetHeight() <= 0 then
        HidePins(worldPins)
        return
    end
    local mapName = CurrentMapName()
    local zone = mapName and ZoneForMapName(mapName)
    if not zone then
        HidePins(worldPins)
        return
    end

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
    HidePinsAfter(worldPins, shown)
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
    local zoneName = GetZoneText and GetZoneText()
    local realZoneName = GetRealZoneText and GetRealZoneText()
    local subZoneName = GetSubZoneText and GetSubZoneText()
    local name = zoneName
    if not name or name == "" then name = realZoneName end

    -- GetPlayerMapPosition returns coordinates in the currently selected map,
    -- not necessarily the player's zone. A continent map (and some custom
    -- maps) can return a perfectly valid non-zero position, so checking only
    -- for 0,0 mixes those coordinates with zone-local objective coordinates.
    -- Confirm the selected map first and select the current zone when needed.
    local selectedName = CurrentMapName()
    local x, y = ReadPlayerMapPosition()
    local beforeX, beforeY = x, y
    local setOK, setResult
    local selectedKey = selectedName and MapKey(selectedName)
    local playerZoneKey = name and name ~= "" and MapKey(name)
    local wrongMap = (oldContinent and oldContinent > 0 and oldZone == 0)
        or (name and name ~= "" and selectedName
            and selectedKey ~= playerZoneKey)
    if wrongMap or not x or not y or (x == 0 and y == 0) then
        if SetMapToCurrentZone then setOK, setResult = pcall(SetMapToCurrentZone) end
        x, y = ReadPlayerMapPosition()
        selectedName = CurrentMapName() or selectedName
    end
    if not name or name == "" then name = CurrentMapName() end

    -- Instance display names and legacy map-file names can differ completely
    -- ("Ragefire Chasm" versus "Ragefire"). Static spawn data uses the map
    -- file when the generated area catalog has no dungeon display name, so
    -- prefer that selected-map identity only when it actually has pin data.
    local selectedZone = selectedName and ZoneForMapName(selectedName)
    local displayZone = name and name ~= "" and ZoneForMapName(name)
    if selectedZone and not displayZone then name = selectedName end

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
        mapShown=mapShown and true or false, zoneText=zoneName,
        realZoneText=realZoneName, subZoneText=subZoneName, selectedName=selectedName,
        wrongMap=wrongMap and true or false, beforeX=beforeX,
        beforeY=beforeY, x=x, y=y, setOK=setOK, setResult=setResult,
        probeSelector=probeSelector, probeQuestID=probeQuestID,
        continent=GetCurrentMapContinent and GetCurrentMapContinent(),
        zone=GetCurrentMapZone and GetCurrentMapZone(),
        areaID=GetCurrentMapAreaID and GetCurrentMapAreaID(),
        floor=GetCurrentMapDungeonLevel and GetCurrentMapDungeonLevel() or 0,
    }
    -- Sub-zone remap (see subZoneParents): the player stands in a micro-zone,
    -- but its quest pins are filed under the parent zone's frame. Only bother
    -- when the parent actually has active objective points to show, so the
    -- SetMapZoom cost is paid only when it can produce pins.
    local parentName = name and name ~= "" and subZoneParents[NormalizeZone(name)]
    if not parentName and subZoneName and subZoneName ~= "" then
        parentName = subZoneParents[NormalizeZone(subZoneName)]
    end
    -- Indoor micro-maps such as Fargodeep Mine are not represented in the
    -- objective database: their points use the surrounding zone's coordinate
    -- frame. When the selected map has no records, prefer a current zone name
    -- that does. This also covers custom cave maps without maintaining an
    -- exhaustive subZoneParents list.
    if not parentName and selectedName
        and not HasActiveQuestPoints(NormalizeZone(selectedName))
    then
        local candidates = {}
        if zoneName and zoneName ~= "" then candidates[#candidates + 1] = zoneName end
        if realZoneName and realZoneName ~= "" then candidates[#candidates + 1] = realZoneName end
        for _, candidate in ipairs(candidates) do
            if candidate and candidate ~= ""
                and NormalizeZone(candidate) ~= NormalizeZone(selectedName)
                and HasActiveQuestPoints(NormalizeZone(candidate))
            then
                parentName = candidate
                break
            end
        end
    end
    if parentName and not mapShown and HasActiveQuestPoints(NormalizeZone(parentName)) then
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
        playerMap.zoneID = locationDebug.areaID
        playerMap.floor = locationDebug.floor
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

-- Between full map-context checks, the selected map is already known to be
-- the player's zone. Sampling just its coordinates avoids repeating zone,
-- quest-map, and debug bookkeeping on every animation tick.
local function UpdatePlayerPositionFast()
    if WorldMapFrame and WorldMapFrame:IsShown() then return false end
    local x, y = ReadPlayerMapPosition()
    if not x or not y or (x == 0 and y == 0) then return false end
    playerMap.x, playerMap.y = x, y
    return true
end

-- Ascension exposes the same guarded world-position API used by installed map
-- addons. It fills dimensions for capitals and custom maps that are absent
-- from the conservative static 3.3.5 zone table above.
local function PhysicalZoneSize(zone, key)
    local known = zoneSizes[key]
    if known then return known end
    local function TryArea(areaID)
        if not (areaID and C_WorldMap and C_WorldMap.GetWorldPosition) then return nil end
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
    -- Standalone starter maps have no shipped spawn-area IDs of their own.
    -- Their live selected-map ID is still authoritative for physical size.
    if playerMap.key == key then
        known = TryArea(playerMap.zoneID)
        if known then return known end
    end
    for areaID in pairs(zone and zone.zoneIDs or {}) do
        known = TryArea(areaID)
        if known then return known end
    end
    local transform = starterMapTransforms[key]
    local parentSize = transform and zoneSizes[NormalizeZone(transform.parent)]
    if parentSize then
        known = {
            parentSize[1] * (transform.right - transform.left),
            parentSize[2] * (transform.bottom - transform.top),
        }
        zoneSizes[key] = known
        return known
    end
end

local function DrawMinimapRoutes(zone, size, radius, radiusLimit, mapRadius, facing, rotate)
    HideRouteDots(minimapRouteDots)
    if not PathsEnabled() then return end
    local count = 0
    local scale = mapRadius / radius
    local visibleRadius = radiusLimit * scale
    local visibleRadiusSq = visibleRadius * visibleRadius
    local function Visible(x, y) return x * x + y * y <= visibleRadiusSq end
    local cosFacing, sinFacing = math.cos(facing), math.sin(facing)
    for _, route in ipairs(zone.routes or {}) do
        local highlighted = highlightedRouteEntityID ~= nil
            and tonumber(route.entityID) == tonumber(highlightedRouteEntityID)
        local color = highlighted and ROUTE_HIGHLIGHT_COLOR or ROUTE_COLOR
        local dotSize, alpha = highlighted and 4 or 2.5, highlighted and 0.9 or 0.45
        local screenPoints = {}
        for _, point in ipairs(route.points or {}) do
            local dx = (point.x / 100 - playerMap.x) * size[1]
            local dy = (point.y / 100 - playerMap.y) * size[2]
            if rotate then
                dx, dy = dx * cosFacing - dy * sinFacing,
                    dx * sinFacing + dy * cosFacing
            end
            local x, y = dx * scale, -dy * scale
            screenPoints[#screenPoints + 1] = { x=x, y=y }
        end
        count = DrawEvenRouteDots(minimapRouteDots, count, 600, Minimap, "CENTER",
            screenPoints, color, dotSize, alpha, 8, Visible)
        if count >= 600 then break end
    end
end

RefreshRouteHighlight = function(pin)
    if pin and pin:GetParent() == Minimap then
        local zone = playerMap.key and ZoneForKey(playerMap.key)
        local size = zone and PhysicalZoneSize(zone, playerMap.key)
        if not size then return end
        local radius = MinimapRadius()
        local radiusLimit = radius * (MinimapPinRadiusPercent() / 100)
        local facing = GetPlayerFacing and GetPlayerFacing() or 0
        local rotate = GetCVar and GetCVar("rotateMinimap") == "1"
        local mapRadius = math.min(Minimap:GetWidth(), Minimap:GetHeight()) / 2 - 10
        DrawMinimapRoutes(zone, size, radius, radiusLimit, mapRadius, facing, rotate)
        return
    end

    local parent = WorldMapDetailFrame or WorldMapButton
    local mapName = CurrentMapName()
    local zone = mapName and ZoneForMapName(mapName)
    if parent and zone then
        local currentFloor = GetCurrentMapDungeonLevel and GetCurrentMapDungeonLevel() or 0
        DrawWorldRoutes(zone, parent, currentFloor)
    end
end

local function ClearMinimapPins(status)
    HidePins(minimapPins)
    HideRouteDots(minimapRouteDots)
    minimapVisibleCount = 0
    minimapZoneKey = nil
    minimapStatus = status
end

-- Moving pins only changes their screen offsets. Keep this hot path free of
-- zone scans, sorting, texture changes, and pool teardown so it can run often
-- enough to remain smooth at flight-path speeds.
local function PositionMinimapPins()
    if minimapZoneKey ~= playerMap.key
        or not Minimap or not playerMap.x or not playerMap.y
    then
        return false
    end
    local zone = ZoneForKey(playerMap.key)
    if not zone then return false end
    local size = PhysicalZoneSize(zone, playerMap.key)
    if not size then return false end

    local radius = MinimapRadius()
    local facing = GetPlayerFacing and GetPlayerFacing() or 0
    local rotate = GetCVar and GetCVar("rotateMinimap") == "1"
    local mapRadius = math.min(Minimap:GetWidth(), Minimap:GetHeight()) / 2 - 10
    local scale = mapRadius / radius
    local pinSize = MinimapPinSize()
    local cosFacing, sinFacing
    if rotate then cosFacing, sinFacing = math.cos(facing), math.sin(facing) end
    for index = 1, minimapVisibleCount do
        local pin = minimapPins[index]
        local cluster = pin and pin.cluster
        if cluster then
            local dx = (cluster.x / 100 - playerMap.x) * size[1]
            local dy = (cluster.y / 100 - playerMap.y) * size[2]
            if rotate then
                dx, dy = dx * cosFacing - dy * sinFacing,
                    dx * sinFacing + dy * cosFacing
            end
            local offsetX, offsetY = ClusterOffset(cluster, pinSize)
            pin:ClearAllPoints()
            pin:SetPoint("CENTER", Minimap, "CENTER",
                dx * scale + offsetX, -dy * scale + offsetY)
        end
    end
    return true
end

function QuestMap.UpdateMinimap()
    if initialBuildThread and not questLayerReady then ClearMinimapPins("map data loading"); return end
    if not Enabled() then ClearMinimapPins("disabled"); return end
    if not Minimap then ClearMinimapPins("Minimap frame unavailable"); return end
    if not playerMap.key or not playerMap.x then
        ClearMinimapPins("player map position unavailable")
        return
    end
    local zone = ZoneForKey(playerMap.key)
    if not zone then
        ClearMinimapPins("no map icon records for " .. playerMap.key)
        return
    end
    local size = PhysicalZoneSize(zone, playerMap.key)
    if not size then
        ClearMinimapPins("no physical map dimensions for " .. playerMap.key)
        return
    end

    local radius = MinimapRadius()
    local radiusLimit = radius * (MinimapPinRadiusPercent() / 100)
    local facing = GetPlayerFacing and GetPlayerFacing() or 0
    local rotate = GetCVar and GetCVar("rotateMinimap") == "1"
    local mapRadius = math.min(Minimap:GetWidth(), Minimap:GetHeight()) / 2 - 10
    DrawMinimapRoutes(zone, size, radius, radiusLimit, mapRadius, facing, rotate)
    local candidates = {}
    local currentFloor = GetCurrentMapDungeonLevel and GetCurrentMapDungeonLevel() or 0
    local radiusLimitSq = radiusLimit * radiusLimit
    if not zone.exactPoints then zone.exactPoints = GroupExactPoints(zone.points) end
    for _, cluster in ipairs(zone.exactPoints) do
        if cluster.floor == 0 or currentFloor == 0 or cluster.floor == currentFloor then
            local dx = (cluster.x / 100 - playerMap.x) * size[1]
            local dy = (cluster.y / 100 - playerMap.y) * size[2]
            local distanceSq = dx * dx + dy * dy
        -- Only display locations within minimapPinRadiusPercent of the
        -- minimap's own view radius (Map Pins settings). Distant locations
        -- belong on the world map/route arrow; clamping every spawn to the
        -- rim creates an unreadable pile of icons.
            if distanceSq <= radiusLimitSq then
                candidates[#candidates + 1] = { cluster=cluster, distanceSq=distanceSq }
            end
        end
    end
    table.sort(candidates, function(a,b)
        if a.cluster.isService ~= b.cluster.isService then
            return not a.cluster.isService
        end
        if a.distanceSq ~= b.distanceSq then return a.distanceSq < b.distanceSq end
        if a.cluster.x ~= b.cluster.x then return a.cluster.x < b.cluster.x end
        if a.cluster.y ~= b.cluster.y then return a.cluster.y < b.cluster.y end
        return tostring(a.cluster.kind) < tostring(b.cluster.kind)
    end)

    local pinSize = MinimapPinSize()
    local visibleCount = math.min(#candidates, MaxMinimapPins())
    minimapStatus = tostring(visibleCount) .. " nearby pins shown from " .. tostring(#zone.exactPoints) .. " zone locations"
    for index = 1, visibleCount do
        local candidate = candidates[index]
        local pin = minimapPins[index]
        if not pin then pin = NewPin(Minimap, true); minimapPins[index] = pin end
        ConfigurePin(pin, candidate.cluster, pinSize)
        pin:Show()
    end
    minimapVisibleCount = visibleCount
    minimapZoneKey = playerMap.key
    HidePinsAfter(minimapPins, visibleCount)
    PositionMinimapPins()
end

function QuestMap.SetEnabled(enabled)
    AutoCore.SetSetting("quest", "mapPins", enabled and true or false)
    invalidateContributionCache = true
    QuestMap.RebuildIndex()
    QuestMap.UpdateWorldMap()
    UpdatePlayerLocation()
    QuestMap.UpdateMinimap()
    AutoCore.Info("Quest", "Quest map pins " .. (enabled and "enabled." or "disabled."))
end

function QuestMap.GetPlayerLocation(force)
    UpdatePlayerLocation(force == true)
    if not playerMap.x or not playerMap.y or not playerMap.name then return nil end
    return {
        x=playerMap.x * 100, y=playerMap.y * 100,
        zone=playerMap.name, zoneID=playerMap.zoneID,
        floor=tonumber(playerMap.floor) or 0,
    }
end

function QuestMap.SetNotableNPCsEnabled(enabled)
    AutoCore.SetSetting("quest", "showNotableNPCPins", enabled and true or false)
    notableByZone = nil
    combinedByZone = {}
    QuestMap.RequestRefresh()
    AutoCore.Info("Quest", "Boss icons " .. (enabled and "enabled." or "disabled."))
end

function QuestMap.SetRareNPCsEnabled(enabled)
    AutoCore.SetSetting("quest", "showRareNPCPins", enabled and true or false)
    notableByZone = nil
    combinedByZone = {}
    QuestMap.RequestRefresh()
    AutoCore.Info("Quest", "Known rare icons " .. (enabled and "enabled." or "disabled."))
end

local function TrackResults(results, exactName)
    local tracked, missing = 0, 0
    for _, npc in ipairs(results) do
        if not exactName or string.lower(npc.name or "") == exactName then
            if npc.locations and #npc.locations > 0 then
                trackedNPCIDs[npc.id] = true
                tracked = tracked + 1
            else
                missing = missing + 1
            end
        end
    end
    if tracked > 0 then QuestMap.RequestRefresh() end
    return tracked, missing
end

function QuestMap.TrackNPC(query)
    query = strtrim and strtrim(tostring(query or "")) or tostring(query or "")
    if query == "" then
        AutoCore.Info("Quest", "Usage: /aq npc <name or ID>, /aq npc clear, /aq npc list")
        return false
    end
    local results = SpawnStore.SearchNPCs(query, 12)
    if #results == 0 then
        AutoCore.Warn("Quest", "No NPC matched '" .. query .. "'.")
        return false
    end
    local exactName = not tonumber(query) and string.lower(query) or nil
    local exactCount = 0
    if exactName then
        for _, npc in ipairs(results) do
            if string.lower(npc.name or "") == exactName then exactCount = exactCount + 1 end
        end
    end
    if not tonumber(query) and exactCount == 0 and #results > 1 then
        AutoCore.Info("Quest", "Multiple NPCs matched; use an ID to choose one:")
        for _, npc in ipairs(results) do
            print("  " .. tostring(npc.id) .. " - " .. tostring(npc.name)
                .. ((npc.locations and #npc.locations > 0) and "" or " (no coordinates)"))
        end
        return false
    end
    local tracked, missing = TrackResults(results, exactCount > 0 and exactName or nil)
    if tracked > 0 then
        AutoCore.Info("Quest", "Showing " .. tracked .. " NPC record"
            .. (tracked == 1 and "." or "s."))
    end
    if missing > 0 then
        AutoCore.Warn("Quest", missing .. " matching NPC record"
            .. (missing == 1 and " has" or "s have") .. " no known coordinates.")
    end
    return tracked > 0
end

function QuestMap.ClearTrackedNPCs()
    trackedNPCIDs = {}
    QuestMap.RequestRefresh()
    AutoCore.Info("Quest", "NPC search icons cleared.")
end

function QuestMap.ListTrackedNPCs()
    local ids = {}
    for npcID in pairs(trackedNPCIDs) do ids[#ids + 1] = npcID end
    table.sort(ids)
    if #ids == 0 then AutoCore.Info("Quest", "No NPC searches are active."); return end
    AutoCore.Info("Quest", "Active NPC searches:")
    for _, npcID in ipairs(ids) do
        print("  " .. npcID .. " - " .. tostring(SpawnStore.GetName(npcID) or "Unknown NPC"))
    end
end

function QuestMap.ApplyProfile()
    -- Service locations are otherwise static and intentionally cached. A
    -- profile switch or selector change must rebuild that cache immediately.
    serviceByZone = nil
    notableByZone = nil
    invalidateContributionCache = true
    QuestMap.RebuildIndex()
    QuestMap.UpdateWorldMap()
    UpdatePlayerLocation()
    QuestMap.UpdateMinimap()
end

function QuestMap.RequestRefresh(invalidate)
    if invalidate == true then invalidateContributionCache = true end
    refreshPending, refreshAt = true, 0
end

function QuestMap.IsEnabled() return Enabled() end
function QuestMap.IsInitialBuildComplete()
    return initialBuildComplete or not ModuleEnabled()
end
function QuestMap.IsQuestLayerReady()
    return questLayerReady or initialBuildComplete or not ModuleEnabled()
end

function QuestMap.Debug()
    QuestMap.RebuildIndex()
    UpdatePlayerLocation(true)
    QuestMap.UpdateMinimap()
    local zone = playerMap.key and ZoneForKey(playerMap.key)
    local zonePoints = zone and #zone.points or 0
    print("|cff33ccffMap Pins|r")
    print("  enabled=" .. tostring(Enabled()) .. " dbLoaded="
        .. tostring(AutoQuest.DataStore.HasQuestData()))
    print("  activeQuests=" .. buildStats.activeQuests .. " matchedInDB=" .. buildStats.matchedQuests
        .. " confirmedObjectives=" .. buildStats.confirmedObjectives
        .. " indexedPoints=" .. buildStats.points
        .. " mappedQuestPoints=" .. (buildStats.mappedQuestPoints or 0)
        .. " partyQuests=" .. buildStats.partyQuests
        .. " partyPoints=" .. buildStats.partyPoints
        .. " servicePoints=" .. buildStats.servicePoints
        .. " notablePoints=" .. (buildStats.notablePoints or 0)
        .. " searchedNPCPoints=" .. (buildStats.trackedNPCPoints or 0)
        .. " sightingPoints=" .. (buildStats.sightingPoints or 0))
    print("  quest indexes rebuilt=" .. mapContributionStats.rebuilt
        .. " reused=" .. mapContributionStats.reused)
    for _, match in ipairs(buildStats.matches or {}) do
        print("    matched: " .. tostring(match.title) .. " (id " .. tostring(match.id) .. ") -> "
            .. tostring(match.points) .. " point(s)")
    end
    print("  playerMap=" .. tostring(playerMap.name) .. " key=" .. tostring(playerMap.key)
        .. " position=" .. string.format("%.1f, %.1f", (playerMap.x or 0) * 100, (playerMap.y or 0) * 100))
    print("  currentZonePoints=" .. zonePoints .. " mapSizeKnown=" .. tostring(zoneSizes[playerMap.key or ""] ~= nil))
    print("  minimap=" .. minimapStatus)
    print("  raw zoneText=" .. tostring(locationDebug.zoneText) .. " realZone=" .. tostring(locationDebug.realZoneText)
        .. " subZone=" .. tostring(locationDebug.subZoneText)
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
frame:RegisterEvent("WORLD_MAP_UPDATE")
frame:RegisterEvent("WORLD_MAP_NAME_UPDATE")
frame:SetScript("OnEvent", function(_, event)
    if event == "WORLD_MAP_UPDATE" or event == "WORLD_MAP_NAME_UPDATE" then
        QuestMap.UpdateWorldMap()
    else
        refreshPending, refreshAt = true, GetTime() + 0.5
    end
end)
AutoQuest.QuestState.Subscribe(function(changes)
    if changes.semanticChanged then
        refreshPending = true
        refreshAt = GetTime() + (changes.settled and 0 or Resolver.QUEST_LOG_SETTLE_DELAY)
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
        if initialBuildComplete or not ModuleEnabled() then return end
    elseif frame.pinsWereEnabled == false then
        refreshPending, refreshAt = true, 0
    end
    frame.pinsWereEnabled = true

    if initialBuildThread then
        local ok, message = coroutine.resume(initialBuildThread)
        if not ok then
            initialBuildThread = nil
            buildCooperate = nil
            initialBuildComplete = true
            refreshPending, refreshAt = true, 0
            AutoCore.Warn("Quest", "Map data loading stopped: " .. tostring(message))
        elseif coroutine.status(initialBuildThread) == "dead" then
            initialBuildThread = nil
            buildCooperate = nil
            initialBuildComplete = true
            combinedByZone = {}
            UpdatePlayerLocation()
            QuestMap.UpdateWorldMap()
            QuestMap.UpdateMinimap()
        elseif questLayerReady and not frame.initialQuestPinsPublished then
            -- Publish the active quest layer on the first cooperative pause;
            -- the much larger static layers can finish over later frames.
            frame.initialQuestPinsPublished = true
            frame.initialPositionElapsed = 0
            frame.initialSelectionElapsed = 0
            UpdatePlayerLocation()
            QuestMap.UpdateWorldMap()
            QuestMap.UpdateMinimap()
        end
        if initialBuildThread and questLayerReady and frame.initialQuestPinsPublished then
            -- The player can move while static layers continue warming. Keep
            -- already-published pins anchored to their world coordinates
            -- instead of leaving their screen offsets frozen until completion.
            frame.initialPositionElapsed = (frame.initialPositionElapsed or 0)
                + math.min(elapsed or 0, 0.1)
            frame.initialSelectionElapsed = (frame.initialSelectionElapsed or 0)
                + math.min(elapsed or 0, 0.1)
            if frame.initialSelectionElapsed >= 0.2 then
                frame.initialPositionElapsed, frame.initialSelectionElapsed = 0, 0
                UpdatePlayerLocation()
                QuestMap.UpdateMinimap()
            elseif frame.initialPositionElapsed >= (1 / 30) then
                frame.initialPositionElapsed = 0
                if not UpdatePlayerPositionFast() or not PositionMinimapPins() then
                    UpdatePlayerLocation()
                    QuestMap.UpdateMinimap()
                end
            end
        end
        return
    end

    frame.positionElapsed = (frame.positionElapsed or 0) + math.min(elapsed or 0, 0.1)
    frame.selectionElapsed = (frame.selectionElapsed or 0) + math.min(elapsed or 0, 0.1)
    if refreshPending and GetTime() >= refreshAt then
        refreshPending = false
        if not initialBuildComplete and coroutine and coroutine.create
            and coroutine.resume and coroutine.yield
        then
            questLayerReady = false
            frame.initialQuestPinsPublished = false
            local sliceStarted
            local checkpoints = 0
            buildCooperate = function()
                -- This callback remains reachable while the frame-budgeted
                -- build is suspended. Synchronous rebuilds (for example the
                -- chat debug command) must not yield through WoW's C event
                -- handler, and unrelated coroutines must not yield on behalf
                -- of this build.
                if not coroutine.running or coroutine.running() ~= initialBuildThread then
                    return
                end
                checkpoints = checkpoints + 1
                if debugprofilestop then
                    local now = debugprofilestop()
                    -- Start a fresh clock after every resume. The wall time
                    -- spent suspended between frames is not warmup work and
                    -- must not make the very first checkpoint yield again.
                    if not sliceStarted then
                        sliceStarted = now
                        return
                    end
                    if now - sliceStarted < 2 then return end
                    sliceStarted = nil
                elseif checkpoints < 200 then
                    return
                end
                checkpoints = 0
                coroutine.yield()
            end
            initialBuildThread = coroutine.create(function()
                if Enabled() then
                    QuestMap.RebuildIndex()
                else
                    BuildServiceIndex()
                    BuildNotableIndex()
                    if SpawnStore.PrepareQuestLookups then
                        SpawnStore.PrepareQuestLookups(buildCooperate)
                    end
                end
            end)
        else
            QuestMap.RebuildIndex()
            initialBuildComplete = true
            UpdatePlayerLocation()
            QuestMap.UpdateWorldMap()
            QuestMap.UpdateMinimap()
        end
        frame.positionElapsed, frame.selectionElapsed = 0, 0
    elseif frame.positionElapsed >= (1 / 30) then
        frame.positionElapsed = 0
        if frame.selectionElapsed >= 0.2 then
            frame.selectionElapsed = 0
            UpdatePlayerLocation()
            QuestMap.UpdateMinimap()
        elseif WorldMapFrame and WorldMapFrame:IsShown() then
            PositionMinimapPins()
        elseif not UpdatePlayerPositionFast() or not PositionMinimapPins() then
            UpdatePlayerLocation()
            QuestMap.UpdateMinimap()
        end
    end
end)
