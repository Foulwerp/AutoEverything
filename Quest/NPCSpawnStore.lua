----------------------------------------------------------------------
-- NPCSpawnStore.lua
-- =================
-- Lazy access to packed NPC coordinates with legacy database fallback.
----------------------------------------------------------------------
AutoQuest = AutoQuest or {}
AutoQuest.NPCSpawnStore = AutoQuest.NPCSpawnStore or {}
local Store = AutoQuest.NPCSpawnStore

local decoded = {}

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
    return type(AscensionNPCLocationDB) == "table" and AscensionNPCLocationDB[npcID] or nil
end

function Store.ClearCache()
    decoded = {}
end
