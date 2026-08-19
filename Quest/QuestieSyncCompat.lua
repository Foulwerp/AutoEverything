----------------------------------------------------------------------
-- QuestieSyncCompat.lua
-- =====================
-- Bounded compatibility adapter for Questie-X comms protocol v5. It decodes
-- Questie's 1short serializer and AceComm framing without requiring Questie
-- to be installed locally, then hands canonical records to GroupSync.
--
-- Protocol behavior is compatible with Questie-X (MIT, Xurkon, 2026); this
-- implementation is intentionally limited to party quest-progress packets.
-- WoW 3.3.5a / Lua 5.1.
----------------------------------------------------------------------

AutoQuest = AutoQuest or {}
AutoQuest.QuestieSyncCompat = AutoQuest.QuestieSyncCompat or {}
local Compat = AutoQuest.QuestieSyncCompat
local Sync = AutoQuest.GroupSync
local DataStore = AutoQuest.DataStore
local QuestState = AutoQuest.QuestState

local PREFIX = "questie"
local PROTOCOL_VERSION = 5
local MAX_WIRE_BYTES = 65536
local MAX_OBJECTS = 8192
local MAX_DEPTH = 64
local MAX_FRAGMENTS = 512
local MAX_PACKETS_PER_WINDOW = 240
local PACKET_WINDOW = 10
local SNAPSHOT_SETTLE = 4
local ACE_FIRST, ACE_NEXT, ACE_LAST, ACE_ESCAPE = 1, 2, 3, 4

local fragments = {}
local snapshots = {}
local rates = {}

local function LocalQuestieOwnsWire()
    return type(Questie) == "table" and type(QuestieLoader) == "table"
end

local function SafeInteger(value, minimum, maximum)
    local number = tonumber(value)
    if not number or number ~= math.floor(number) then return nil end
    if minimum and number < minimum then return nil end
    if maximum and number > maximum then return nil end
    return number
end

local function Reader(data)
    return { data=data, position=1, hashes={}, objects=0 }
end

local function RawByte(reader)
    if reader.position > string.len(reader.data) then error("truncated packet") end
    local value = string.byte(reader.data, reader.position)
    reader.position = reader.position + 1
    return value
end

local function ReadByte(reader)
    local value = RawByte(reader)
    if value == 238 then return 0 end
    if value == 237 then
        local escaped = RawByte(reader)
        if escaped == 1 then return 237 end
        if escaped == 2 then return 238 end
        error("invalid byte escape")
    end
    return value
end

local function ReadUnsigned(reader, count)
    local value = 0
    for _ = 1, count do value = value * 256 + ReadByte(reader) end
    return value
end

local function ReadString(reader, length)
    if length < 0 or length > MAX_WIRE_BYTES then error("invalid string length") end
    local bytes = {}
    for index = 1, length do bytes[index] = string.char(ReadByte(reader)) end
    return table.concat(bytes)
end

local function Hash(value)
    local hash = 5381
    for index = 1, string.len(value) do
        hash = (31 * hash + string.byte(value, index)) % 4294967296
    end
    return hash
end

local function Remember(reader, value)
    if type(value) ~= "string" or value == "" then return end
    local hash = Hash(value)
    if reader.hashes[hash] == nil then reader.hashes[hash] = value end
end

local ReadObject

local function ReadEntries(reader, count, depth, array)
    if count < 0 or count > MAX_OBJECTS then error("too many entries") end
    local result = {}
    for index = 1, count do
        local key = array and index or ReadObject(reader, depth + 1)
        Remember(reader, key)
        local value = ReadObject(reader, depth + 1)
        Remember(reader, value)
        if key ~= nil then result[key] = value end
    end
    return result
end

ReadObject = function(reader, depth)
    if depth > MAX_DEPTH then error("packet nesting is too deep") end
    reader.objects = reader.objects + 1
    if reader.objects > MAX_OBJECTS then error("packet has too many objects") end
    local kind = ReadByte(reader)
    if kind > 31 then return kind - 32 end
    if kind == 1 then return nil end
    if kind == 2 then return ReadUnsigned(reader, 4) end
    if kind == 3 then return -ReadUnsigned(reader, 4) end
    if kind == 4 then return ReadUnsigned(reader, 8) end
    if kind == 5 then return -ReadUnsigned(reader, 8) end
    if kind == 7 then return ReadString(reader, ReadByte(reader)) end
    if kind == 8 then return ReadString(reader, ReadUnsigned(reader, 2)) end
    if kind == 9 then return reader.hashes[ReadUnsigned(reader, 4)] end
    if kind == 10 then return ReadEntries(reader, ReadByte(reader), depth, false) end
    if kind == 11 then return ReadEntries(reader, ReadUnsigned(reader, 2), depth, false) end
    if kind == 12 then return ReadByte(reader) end
    if kind == 13 then return -ReadByte(reader) end
    if kind == 14 then return ReadUnsigned(reader, 2) end
    if kind == 15 then return -ReadUnsigned(reader, 2) end
    if kind == 16 then return false end
    if kind == 17 then return true end
    if kind == 20 then return ReadEntries(reader, ReadByte(reader), depth, true) end
    if kind == 21 then return ReadEntries(reader, ReadUnsigned(reader, 2), depth, true) end
    if kind == 22 then return ReadEntries(reader, ReadUnsigned(reader, 4), depth, true) end
    error("unsupported serialized type " .. tostring(kind))
end

function Compat.Deserialize(message)
    if type(message) ~= "string" or string.len(message) == 0
        or string.len(message) > MAX_WIRE_BYTES
    then
        return nil
    end
    local reader = Reader(message)
    local ok, key, packet = pcall(function()
        return ReadObject(reader, 0), ReadObject(reader, 0)
    end)
    if not ok or key ~= 1 or type(packet) ~= "table" then return nil end
    return packet
end

local function EncodedByte(output, value)
    value = SafeInteger(value, 0, 255)
    if not value then error("byte out of range") end
    if value == 0 then output[#output + 1] = string.char(238)
    elseif value == 237 then output[#output + 1] = string.char(237, 1)
    elseif value == 238 then output[#output + 1] = string.char(237, 2)
    else output[#output + 1] = string.char(value) end
end

local function WriteUnsigned(output, value, count)
    local bytes = {}
    for index = count, 1, -1 do
        bytes[index] = value % 256
        value = math.floor(value / 256)
    end
    for index = 1, count do EncodedByte(output, bytes[index]) end
end

local WriteObject

local function IsArray(value)
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return false, 0 end
        if key > count then count = key end
    end
    for index = 1, count do if value[index] == nil then return false, 0 end end
    return true, count
end

local function WriteString(output, value)
    local length = string.len(value)
    if length <= 254 then
        EncodedByte(output, 7)
        EncodedByte(output, length)
    elseif length <= 65535 then
        EncodedByte(output, 8)
        WriteUnsigned(output, length, 2)
    else
        error("string too long")
    end
    for index = 1, length do EncodedByte(output, string.byte(value, index)) end
end

WriteObject = function(output, value, depth)
    if depth > MAX_DEPTH then error("table nesting is too deep") end
    local valueType = type(value)
    if valueType == "number" then
        local number = SafeInteger(value, -2147483647, 4294967295)
        if not number then error("unsupported number") end
        local negative = number < 0
        if negative then number = -number end
        if not negative and number < 222 then EncodedByte(output, 32 + number)
        elseif number < 255 then EncodedByte(output, negative and 13 or 12); EncodedByte(output, number)
        elseif number < 65530 then EncodedByte(output, negative and 15 or 14); WriteUnsigned(output, number, 2)
        else EncodedByte(output, negative and 3 or 2); WriteUnsigned(output, number, 4) end
    elseif valueType == "string" then
        WriteString(output, value)
    elseif valueType == "boolean" then
        EncodedByte(output, value and 17 or 16)
    elseif valueType == "table" then
        local array, count = IsArray(value)
        if not array then
            count = 0
            for key, entry in pairs(value) do
                if key ~= nil and entry ~= nil and entry ~= false then count = count + 1 end
            end
        end
        if count > 65530 then error("table too large") end
        EncodedByte(output, array and (count <= 254 and 20 or 21)
            or (count <= 254 and 10 or 11))
        if count <= 254 then EncodedByte(output, count) else WriteUnsigned(output, count, 2) end
        if array then
            for index = 1, count do WriteObject(output, value[index], depth + 1) end
        else
            for key, entry in pairs(value) do
                if key ~= nil and entry ~= nil and entry ~= false then
                    WriteObject(output, key, depth + 1)
                    WriteObject(output, entry, depth + 1)
                end
            end
        end
    else
        error("unsupported value type")
    end
end

function Compat.Serialize(packet)
    if type(packet) ~= "table" then return nil end
    local output = {}
    local ok = pcall(function()
        WriteObject(output, 1, 0)
        WriteObject(output, packet, 0)
    end)
    if not ok then return nil end
    local message = table.concat(output)
    return string.len(message) <= MAX_WIRE_BYTES and message or nil
end

local function QueueSerialized(packet, channel, target, priority, coalesceKey)
    local message = Compat.Serialize(packet)
    if not message then return false end
    if string.len(message) <= 240 then
        return Sync.QueueCompatMessage(PREFIX, message, channel, target, priority, coalesceKey)
    end
    local position, part, messages = 1, 0, {}
    while position <= string.len(message) do
        part = part + 1
        if part > MAX_FRAGMENTS then return false end
        local last = math.min(position + 238, string.len(message))
        local control = position == 1 and ACE_FIRST
            or (last == string.len(message) and ACE_LAST or ACE_NEXT)
        messages[#messages + 1] = string.char(control)
            .. string.sub(message, position, last)
        position = last + 1
    end
    return Sync.QueueCompatBatch(PREFIX, messages, channel, target)
end

local function BasePacket(messageID)
    return { ver="0.0.0", msgVer=PROTOCOL_VERSION, msgId=messageID }
end

local function ObjectiveType(value)
    value = string.lower(tostring(value or ""))
    if value == "m" or value == "monster" then return "monster" end
    if value == "i" or value == "item" then return "item" end
    if value == "o" or value == "object" then return "object" end
    if value == "e" or value == "event" then return "event" end
    if value == "p" or value == "player" then return "player" end
    return ""
end

local function ObjectiveLabel(questID, index, objectiveID)
    local quest = DataStore.GetQuest(questID)
    local fallback
    for _, record in ipairs(quest and quest.records or {}) do
        local recordIndex = tonumber(record.objective)
        if tonumber(record.id) == tonumber(objectiveID) then
            return record.item or record.name
        end
        if recordIndex ~= nil and recordIndex + 1 == index and not fallback then
            fallback = record.item or record.name
        end
    end
    return fallback or ("Objective " .. tostring(index))
end

local function CanonicalQuest(raw)
    local questID = SafeInteger(raw and raw.id, 1, 20000000)
    if not questID then return nil end
    local databaseQuest = DataStore.GetQuest(questID)
    local title = databaseQuest and databaseQuest.title or ("Quest " .. questID)
    local quest = {
        key=QuestState.QuestKey(questID, title), id=questID, title=title,
        complete=false, objectives={},
    }
    local allDone, count = true, 0
    for index = 1, 20 do
        local source = raw.objectives and raw.objectives[index]
        if source then
            count = count + 1
            local current = SafeInteger(source.ful or source.fulfilled, 0, 100000000)
            local required = SafeInteger(source.req or source.required, 0, 100000000)
            local finished = source.fin == true or source.finished == true
                or current and required and required > 0 and current >= required
            local objectiveID = SafeInteger(source.id, 0, 20000000)
            local objectiveType = ObjectiveType(source.typ or source.type)
            local label = ObjectiveLabel(questID, index, objectiveID)
            local text = label
            if current and required then text = text .. ": " .. current .. "/" .. required end
            quest.objectives[index] = {
                text=text, finished=finished and true or false, type=objectiveType,
                current=current, required=required, targetType=objectiveType,
                targetID=objectiveID and objectiveID > 0 and objectiveID or nil,
            }
            if not finished then allDone = false end
        end
    end
    quest.objectiveCount = count
    quest.complete = count > 0 and allDone
    return quest
end

local function WireQuest(quest)
    local questID = SafeInteger(quest and quest.id, 1, 20000000)
    if not questID then return nil end
    local result = { id=questID, objectives={} }
    for index, objective in ipairs(quest.objectives or {}) do
        local targetID = SafeInteger(objective.targetID, 0, 20000000) or 0
        local current = SafeInteger(objective.current, 0, 100000000) or 0
        local required = SafeInteger(objective.required, 0, 100000000) or 0
        result.objectives[index] = {
            id=targetID, typ=string.sub(objective.type or "", 1, 1),
            fin=objective.finished and true or nil, ful=current, req=required,
        }
    end
    return result
end

local function TranslateV2(raw, offset, withClass)
    local questID = SafeInteger(raw and raw[offset], 1, 20000000)
    local count = SafeInteger(raw and raw[offset + 1], 0, 20)
    if not questID or not count then return nil, offset end
    local class = withClass and raw[offset + 2] or nil
    offset = offset + (withClass and 3 or 2)
    local quest = { id=questID, objectives={} }
    for index = 1, count do
        local objectiveID = raw[offset]
        local typeByte = SafeInteger(raw[offset + 1], 0, 255)
        quest.objectives[index] = {
            id=objectiveID, typ=typeByte and string.char(typeByte) or "",
            ful=raw[offset + 2], req=raw[offset + 3],
        }
        offset = offset + 4
    end
    return CanonicalQuest(quest), offset, class
end

local function ApplyQuest(sender, raw)
    local quest = CanonicalQuest(raw)
    return quest and Sync.ApplyExternalQuest(sender, quest)
end

local function MergeSnapshot(sender, rawQuests, memberClass)
    local pending = snapshots[sender]
    if not pending then pending = { quests={} }; snapshots[sender] = pending end
    pending.finishAt = GetTime() + SNAPSHOT_SETTLE
    pending.class = memberClass or pending.class
    for _, raw in pairs(rawQuests or {}) do
        local quest = CanonicalQuest(raw)
        if quest then pending.quests[quest.key] = quest end
    end
end

local function ProcessPacket(packet, channel, sender)
    if type(packet) ~= "table" or math.floor(tonumber(packet.msgVer) or -1) ~= PROTOCOL_VERSION then
        return
    end
    local messageID = SafeInteger(packet.msgId, 1, 14)
    if messageID == 1 then
        ApplyQuest(sender, packet.quest)
    elseif messageID == 2 then
        Sync.RemoveExternalQuest(sender, packet.id)
    elseif messageID == 10 then
        MergeSnapshot(sender, packet.rawQuestList)
    elseif messageID == 11 then
        Compat.QueueSnapshot(sender)
    elseif messageID == 12 and type(packet[1]) == "table" then
        local raw, offset, quests = packet[1], 2, {}
        local count = SafeInteger(raw[1], 0, 75) or 0
        for _ = 1, count do
            local quest
            quest, offset = TranslateV2(raw, offset, false)
            if quest then quests[quest.key] = quest end
        end
        local pending = snapshots[sender] or { quests={} }
        snapshots[sender] = pending
        pending.finishAt = GetTime() + SNAPSHOT_SETTLE
        for key, quest in pairs(quests) do pending.quests[key] = quest end
    elseif messageID == 13 and type(packet[1]) == "table" then
        local quest, _, classIndex = TranslateV2(packet[1], 1, true)
        if quest then Sync.ApplyExternalQuest(sender, quest) end
        if classIndex then -- Class is attached when a later snapshot commits.
            local pending = snapshots[sender]
            if pending then pending.classIndex = classIndex end
        end
    elseif messageID == 14 and type(packet[1]) == "table" then
        local quest = TranslateV2(packet[1], 1, false)
        if quest then Sync.ApplyExternalQuest(sender, quest) end
    end
end

local function AcceptRate(sender)
    local now = GetTime()
    local rate = rates[sender]
    if not rate or now - rate.started >= PACKET_WINDOW then
        rate = { started=now, count=0 }
        rates[sender] = rate
    end
    rate.count = rate.count + 1
    return rate.count <= MAX_PACKETS_PER_WINDOW
end

function Compat.Receive(message, channel, sender)
    if not Sync.CanAcceptExternal(sender, channel) or type(message) ~= "string"
        or string.len(message) == 0 or string.len(message) > 255
        or not AcceptRate(sender)
    then
        return
    end
    local control = string.byte(message, 1)
    local key = tostring(channel) .. "\31" .. tostring(sender)
    if control == ACE_FIRST then
        fragments[key] = {
            data={string.sub(message, 2)}, bytes=string.len(message) - 1,
            count=1, updated=GetTime(),
        }
        return
    elseif control == ACE_NEXT or control == ACE_LAST then
        local pending = fragments[key]
        if not pending then return end
        local part = string.sub(message, 2)
        pending.count = pending.count + 1
        pending.bytes = pending.bytes + string.len(part)
        pending.updated = GetTime()
        if pending.count > MAX_FRAGMENTS or pending.bytes > MAX_WIRE_BYTES then
            fragments[key] = nil
            return
        end
        pending.data[#pending.data + 1] = part
        if control ~= ACE_LAST then return end
        fragments[key] = nil
        message = table.concat(pending.data)
    elseif control == ACE_ESCAPE then
        message = string.sub(message, 2)
    elseif control and control >= 1 and control <= 9 then
        return
    end
    local packet = Compat.Deserialize(message)
    if packet then ProcessPacket(packet, channel, sender) end
end

function Compat.OnUpdate(now)
    for key, pending in pairs(fragments) do
        if now - (pending.updated or 0) > 30 then fragments[key] = nil end
    end
    for sender, pending in pairs(snapshots) do
        if now >= (pending.finishAt or now) then
            snapshots[sender] = nil
            Sync.ApplyExternalSnapshot(sender, pending.quests, pending.class)
        end
    end
end

function Compat.QueueRequest(channel)
    if LocalQuestieOwnsWire() then return false end
    if not channel then return false end
    return QueueSerialized(BasePacket(11), channel, nil, "urgent", "questie-request")
end

function Compat.QueueSnapshot(target)
    if LocalQuestieOwnsWire() then return false end
    if not target then return false end
    local queued = false
    for _, quest in pairs(Sync.GetLocalQuestData() or {}) do
        local wire = WireQuest(quest)
        if wire then
            local packet = BasePacket(10)
            packet.rawQuestList = { [wire.id] = wire }
            if QueueSerialized(packet, "WHISPER", target, "bulk") then queued = true end
        end
    end
    return queued
end

function Compat.QueueDelta(before, after)
    if LocalQuestieOwnsWire() then return end
    local channel = Sync.GetGroupChannel()
    if not channel then return end
    for key, quest in pairs(before or {}) do
        if not after[key] and quest.id then
            local packet = BasePacket(2)
            packet.id = quest.id
            QueueSerialized(packet, channel, nil, "urgent", "questie-remove:" .. quest.id)
        end
    end
    for key, quest in pairs(after or {}) do
        local previous = before and before[key]
        local changed = not previous or previous.complete ~= quest.complete
            or #previous.objectives ~= #quest.objectives
        if not changed then
            for index, objective in ipairs(quest.objectives or {}) do
                local old = previous.objectives[index]
                if not old or old.finished ~= objective.finished
                    or old.current ~= objective.current or old.required ~= objective.required
                then
                    changed = true
                    break
                end
            end
        end
        local wire = changed and WireQuest(quest)
        if wire then
            local packet = BasePacket(1)
            packet.quest = wire
            QueueSerialized(packet, channel, nil, "urgent", "questie-update:" .. wire.id)
        end
    end
end
