----------------------------------------------------------------------
-- GroupSync.lua
-- =============
-- AutoQuest extension for invisible party/raid quest synchronization.
--
-- Full snapshots are whispered only in response to a group request. Normal
-- PARTY/RAID traffic contains debounced deltas, so hovering an item, NPC, or
-- corpse is cache-only and never generates network traffic. WoW 3.3.5a / Lua 5.1.
----------------------------------------------------------------------

AutoQuest = AutoQuest or {}
local AQ = AutoQuest
local SpawnStore = AQ.NPCSpawnStore
local QuestState = AQ.QuestState

AQ.GroupSync = AQ.GroupSync or {}
local Sync = AQ.GroupSync

local PREFIX = "AEQ2"
local VERSION = "3"
local CAPABILITIES = "ids,seq,stale,class,contig,heart,digest"
local VALID_KINDS = { R=true, B=true, E=true, X=true, Q=true, O=true, H=true }
local SEP = "\31"
local SEND_INTERVAL = 0.12
local UPDATE_DELAY = 0.65
local ROSTER_SETTLE_DELAY = 0.75
local MAX_QUEUE = 1000
local MAX_PAYLOAD_BYTES = 240
local MAX_REMOTE_QUESTS = 75
local MAX_REMOTE_OBJECTIVES = 600
local MAX_MESSAGES_PER_WINDOW = 180
local MESSAGE_WINDOW = 10
local RETRY_INTERVAL = 5
local HEARTBEAT_INTERVAL = 5
local LOCAL_POLL_INTERVAL = 1
local PARTY_AUDIT_INTERVAL = 300
local RAID_AUDIT_INTERVAL = 600
local STALE_GRACE = 30
local EXPIRE_GRACE = 300

local localQuests = {}
local memberQuests = {}
local itemQuestKeys = {}
local outgoing = { urgent = {}, bulk = {}, snapshotBarriers = {} }
local outgoingKeys = {}
local outgoingOrder = 0
local baselineReady = false
local updateAt = nil
local rosterCleanupAt = nil
local acceptedSharedTitle = nil
local acceptedSharedUntil = 0
local pendingShares = {}
local lastRequestAt = 0
local lastResyncAt = {}
local lastSnapshotAt = {}
local pendingSnapshotTargets = {}
local requestPending = false
local nextAuditAt = 0
local snapshotSerial = 0
local compatBatchSerial = 0
local profileSyncActive = false
local rewardQuestTitle = nil
local pendingTurnIns = {}
local rewardHooked = false
local localSequence = 0
local nextHeartbeatAt = 0
local nextLocalPollAt = 0
local sessionID = tostring(time and time() or 0) .. "-" .. tostring(math.random(100000, 999999))

local driver = CreateFrame("Frame")

local function Setting(key, fallback)
    if AutoCore and AutoCore.GetSetting then
        local value = AutoCore.GetSetting("quest", key, nil)
        if value ~= nil then return value end
    end
    local value = AutoQuestConfig and AutoQuestConfig[key]
    if value == nil then value = fallback end
    return value
end

local function RaidCount()
    return GetNumRaidMembers and (GetNumRaidMembers() or 0) or 0
end

local function PartyCount()
    return GetNumPartyMembers and (GetNumPartyMembers() or 0) or 0
end

local function GroupChannel()
    if RaidCount() > 0 then
        if Setting("groupQuestSyncRaid", false) then return "RAID" end
        return nil
    end
    if PartyCount() > 0 then return "PARTY" end
    return nil
end

local function SyncActive()
    return Setting("groupQuestSync", false) == true and GroupChannel() ~= nil
end

local function NormalizeName(name)
    if not name then return nil end
    return string.lower(tostring(name))
end

local function ShortName(name)
    name = NormalizeName(name)
    return name and (string.match(name, "^[^-]+") or name) or nil
end

local function UnitFullName(unit)
    if not UnitName then return nil end
    local name, realm = UnitName(unit)
    if name and realm and realm ~= "" then return name .. "-" .. realm end
    return name
end

local function CurrentRoster()
    local roster, units = {}, {}
    local function Add(unit)
        local name = UnitFullName(unit)
        if name then
            local key = NormalizeName(name)
            roster[key], units[key] = name, unit
        end
    end
    Add("player")

    if RaidCount() > 0 then
        for index = 1, RaidCount() do
            Add("raid" .. index)
        end
    else
        for index = 1, PartyCount() do
            Add("party" .. index)
        end
    end
    return roster, units
end

local function IsRosterMember(name)
    local roster = CurrentRoster()
    local normalized = NormalizeName(name)
    if roster[normalized] then return true end
    local short = ShortName(name)
    local matches = 0
    for rosterName in pairs(roster) do
        if ShortName(rosterName) == short then matches = matches + 1 end
    end
    return matches == 1
end

local function RosterKey(name)
    local roster = CurrentRoster()
    local normalized = NormalizeName(name)
    if roster[normalized] then return normalized end
    local short, match = ShortName(name), nil
    for rosterName in pairs(roster) do
        if ShortName(rosterName) == short then
            if match then return nil end
            match = rosterName
        end
    end
    return match
end

local function MatchingRosterKey(roster, name)
    local normalized = NormalizeName(name)
    if roster[normalized] then return normalized end
    local short, match = ShortName(name), nil
    for rosterName in pairs(roster) do
        if ShortName(rosterName) == short then
            if match then return nil end
            match = rosterName
        end
    end
    return match
end

local function CleanField(value, maximum)
    local text = tostring(value or "")
    text = string.gsub(text, SEP, " ")
    text = string.gsub(text, "[\r\n]", " ")
    if maximum and string.len(text) > maximum then
        text = string.sub(text, 1, maximum)
    end
    return text
end

local function Split(message)
    local fields = {}
    for field in string.gmatch((message or "") .. SEP, "(.-)" .. SEP) do
        table.insert(fields, field)
    end
    return fields
end

local function HasCapability(member, capability)
    local capabilities = member and member.capabilities or ""
    return string.find("," .. capabilities .. ",", "," .. capability .. ",", 1, true) ~= nil
end

local function QuestKey(questID, title)
    return QuestState.QuestKey(questID, title)
end

local function PlayerClass()
    if not UnitClass then return "" end
    local _, class = UnitClass("player")
    return CleanField(class or "", 16)
end

local function SafeInteger(value, minimum, maximum)
    local number = tonumber(value)
    if not number or number ~= math.floor(number) then return nil end
    if minimum and number < minimum then return nil end
    if maximum and number > maximum then return nil end
    return number
end

local function SafeDigest(value)
    value = string.lower(tostring(value or ""))
    if string.len(value) == 8 and not string.find(value, "[^0-9a-f]") then return value end
    return nil
end

local function HashText(hash, value)
    value = tostring(value or "")
    for index = 1, string.len(value) do
        hash = math.fmod((hash * 33) + string.byte(value, index), 4294967296)
    end
    return math.fmod((hash * 33) + 31, 4294967296)
end

local function QuestDigest(quests)
    local keys = {}
    for key in pairs(quests or {}) do keys[#keys + 1] = tostring(key) end
    table.sort(keys)
    local hash = 5381
    for _, key in ipairs(keys) do
        local quest = quests[key] or {}
        hash = HashText(hash, key)
        hash = HashText(hash, quest.id or "")
        hash = HashText(hash, CleanField(quest.title, 80))
        hash = HashText(hash, quest.complete and "1" or "0")
        hash = HashText(hash, #(quest.objectives or {}))
        for index, objective in ipairs(quest.objectives or {}) do
            hash = HashText(hash, index)
            hash = HashText(hash, objective.finished and "1" or "0")
            hash = HashText(hash, CleanField(objective.type, 12))
            hash = HashText(hash, CleanField(objective.targetType, 8))
            hash = HashText(hash, objective.targetID or "")
            hash = HashText(hash, objective.current or "")
            hash = HashText(hash, objective.required or "")
            hash = HashText(hash, CleanField(objective.text, 100))
        end
    end
    return string.format("%08x", hash)
end

local function NextSequence()
    localSequence = localSequence + 1
    if localSequence > 2147483647 then localSequence = 1 end
    return localSequence
end

local function ObjectiveTarget(questID, title, objectiveIndex, objectiveText, objectiveType)
    local normalized = AQ.ObjectiveResolver and AQ.ObjectiveResolver.Normalize
        and AQ.ObjectiveResolver.Normalize(objectiveText) or string.lower(objectiveText or "")
    local resolved = AQ.ResolveQuestEntries and AQ.ResolveQuestEntries(questID, title) or {}
    local fallbackType = string.lower(objectiveType or "")

    local function TargetFromRecord(match, record)
        if record.item and SpawnStore and SpawnStore.GetQuestItemSources then
            for _, source in ipairs(SpawnStore.GetQuestItemSources(match.id) or {}) do
                local itemName = string.lower(source.itemName or "")
                if itemName ~= "" and string.find(normalized, itemName, 1, true) then
                    return "item", tonumber(source.itemID)
                end
            end
        end
        local recordType = tonumber(record.type)
        local targetID = tonumber(record.id)
        if targetID and targetID > 0 then
            if recordType == 2 then return "object", targetID end
            if recordType == -1 then return "event", targetID end
            return "monster", targetID
        end
    end

    -- Indexed records identify exact objective slots. Resolve all of them
    -- before considering legacy name-only records, since a short target name
    -- can be contained in another objective's name.
    for _, match in ipairs(resolved) do
        for _, record in ipairs(match.entry and match.entry.records or {}) do
            local recordIndex = tonumber(record.objective)
            if recordIndex ~= nil and recordIndex + 1 == objectiveIndex then
                local targetType, targetID = TargetFromRecord(match, record)
                if targetType then return targetType, targetID end
            end
        end
    end

    for _, match in ipairs(resolved) do
        for _, record in ipairs(match.entry and match.entry.records or {}) do
            if tonumber(record.objective) == nil then
                local recordName = string.lower(record.item or record.name or "")
                if recordName ~= "" and string.find(normalized, recordName, 1, true) then
                    local targetType, targetID = TargetFromRecord(match, record)
                    if targetType then return targetType, targetID end
                end
            end
        end
    end

    if fallbackType == "item" and SpawnStore and SpawnStore.GetQuestItemSources then
        for _, match in ipairs(resolved) do
            for _, source in ipairs(SpawnStore.GetQuestItemSources(match.id) or {}) do
                local itemName = string.lower(source.itemName or "")
                if itemName ~= "" and string.find(normalized, itemName, 1, true) then
                    return "item", tonumber(source.itemID)
                end
            end
        end
    end
    return "", nil
end

local function BuildLocalState()
    local quests = {}
    local items = {}
    QuestState.Refresh()

    for _, cachedQuest in ipairs(QuestState.GetQuests()) do
        local title, questID = cachedQuest.title, cachedQuest.id
        local key = QuestKey(questID, title)
        local quest = {
            key = key,
            id = tonumber(questID),
            title = title,
            complete = cachedQuest.complete,
            objectives = {},
        }
        for objectiveIndex, cachedObjective in ipairs(cachedQuest.objectives) do
            local text, objectiveType = cachedObjective.text, cachedObjective.type
            local targetType, targetID = ObjectiveTarget(
                tonumber(questID), title, objectiveIndex, text or "", objectiveType
            )
            quest.objectives[objectiveIndex] = {
                text = text or ("Objective " .. objectiveIndex),
                finished = cachedObjective.finished,
                type = objectiveType or "",
                current = cachedObjective.current,
                required = cachedObjective.required,
                targetType = targetType,
                targetID = targetID,
            }
        end
        quests[key] = quest

        local questItems = AQ.DataStore.GetQuestItemIDsByTitle(title)
        for _, itemID in ipairs(questItems or {}) do
            items[itemID] = items[itemID] or {}
            table.insert(items[itemID], key)
        end
    end
    return quests, items
end

local function QueueCount()
    return #outgoing.urgent + #outgoing.bulk
end

local function ClearOutgoing()
    wipe(outgoing.urgent)
    wipe(outgoing.bulk)
    wipe(outgoingKeys)
    wipe(outgoing.snapshotBarriers)
    outgoing.activeBatch = nil
    outgoingOrder = 0
end

local function NextOutgoingOrder()
    outgoingOrder = outgoingOrder + 1
    return outgoingOrder
end

local function QueueMessage(
    message, channel, target, priority, coalesceKey, batch, batchEnd, messagePrefix, sequenced
)
    if not SendAddonMessage or type(message) ~= "string"
        or string.len(message) > MAX_PAYLOAD_BYTES
    then
        return false
    end
    local queueName = priority == "bulk" and "bulk" or "urgent"
    local queue = outgoing[queueName]
    if coalesceKey and queueName == "urgent" then
        local key = table.concat({
            messagePrefix or PREFIX, channel or "", target or "", coalesceKey,
        }, SEP)
        local existing = outgoingKeys[key]
        if existing then
            if existing.sequence then
                local fields = Split(message)
                fields[4] = tostring(existing.sequence)
                message = table.concat(fields, SEP)
            end
            existing.message = message
            return true
        end
        if QueueCount() >= MAX_QUEUE then return false end
        local sequence
        if sequenced then
            sequence = NextSequence()
            local fields = Split(message)
            fields[4] = tostring(sequence)
            message = table.concat(fields, SEP)
        end
        local entry = {
            message=message, channel=channel, target=target, key=key,
            prefix=messagePrefix, sequence=sequence, order=NextOutgoingOrder(),
        }
        queue[#queue + 1] = entry
        outgoingKeys[key] = entry
        return true
    end
    if QueueCount() >= MAX_QUEUE then return false end
    local sequence
    if sequenced then
        sequence = NextSequence()
        local fields = Split(message)
        fields[4] = tostring(sequence)
        message = table.concat(fields, SEP)
    end
    queue[#queue + 1] = {
        message=message, channel=channel, target=target,
        batch=batch, batchEnd=batchEnd, prefix=messagePrefix, sequence=sequence,
        order=NextOutgoingOrder(),
    }
    return true
end

local function EncodeQuest(quest, sequence)
    return table.concat({
        "Q", VERSION, sessionID, tostring(sequence or 0), quest.key,
        tostring(quest.id or ""), CleanField(quest.title, 80), quest.complete and "1" or "0",
        tostring(#quest.objectives),
    }, SEP)
end

local function EncodeObjective(questKey, index, objective, sequence)
    return table.concat({
        "O", VERSION, sessionID, tostring(sequence or 0), questKey, tostring(index),
        objective.finished and "1" or "0", CleanField(objective.type, 12),
        CleanField(objective.targetType, 8), tostring(objective.targetID or ""),
        tostring(objective.current or ""), tostring(objective.required or ""),
        CleanField(objective.text, 100),
    }, SEP)
end

local function ObjectiveChanged(before, after)
    if not before then return true end
    return before.finished ~= after.finished or before.text ~= after.text
        or before.type ~= after.type or before.current ~= after.current
        or before.required ~= after.required or before.targetType ~= after.targetType
        or before.targetID ~= after.targetID
end

local function QueueDelta(before, after)
    local channel = GroupChannel()
    if not channel or not SyncActive() then return end

    for key in pairs(before or {}) do
        if not after[key] then
            QueueMessage(table.concat({
                "X", VERSION, sessionID, "0", key,
            }, SEP), channel, nil, "urgent", nil, nil, nil, nil, true)
        end
    end
    for key, quest in pairs(after) do
        local previous = before and before[key]
        if not previous or previous.title ~= quest.title or previous.complete ~= quest.complete
            or #previous.objectives ~= #quest.objectives then
            QueueMessage(EncodeQuest(quest, 0), channel, nil, "urgent", nil,
                nil, nil, nil, true)
        end
        for index, objective in ipairs(quest.objectives) do
            if not previous or ObjectiveChanged(previous.objectives[index], objective) then
                QueueMessage(EncodeObjective(key, index, objective, 0), channel, nil,
                    "urgent", nil, nil, nil, nil, true)
            end
        end
    end
end

local function QueueSnapshot(target)
    if not SyncActive() or not target then return false end
    local targetKey = NormalizeName(target)
    if not baselineReady then
        if targetKey then pendingSnapshotTargets[targetKey] = target end
        return false
    end
    if targetKey and lastSnapshotAt[targetKey] and GetTime() - lastSnapshotAt[targetKey] < 2 then
        return true
    end

    local questKeys, objectiveCount = {}, 0
    for key, quest in pairs(localQuests) do
        questKeys[#questKeys + 1] = key
        objectiveCount = objectiveCount + #quest.objectives
    end
    table.sort(questKeys)
    local questCount = #questKeys
    local requiredCapacity = questCount + objectiveCount + 2
    if requiredCapacity > MAX_QUEUE or QueueCount() + requiredCapacity > MAX_QUEUE then
        if targetKey then pendingSnapshotTargets[targetKey] = target end
        return false
    end

    snapshotSerial = snapshotSerial + 1
    local snapshotID = sessionID .. ":" .. tostring(snapshotSerial)
    local digest = QuestDigest(localQuests)
    local messages = {
        table.concat({
            "B", VERSION, sessionID, snapshotID, tostring(localSequence),
            tostring(questCount), tostring(objectiveCount), PlayerClass(), CAPABILITIES, digest,
        }, SEP),
    }
    for _, key in ipairs(questKeys) do
        local quest = localQuests[key]
        messages[#messages + 1] = EncodeQuest(quest, 0)
        for index, objective in ipairs(quest.objectives) do
            messages[#messages + 1] = EncodeObjective(quest.key, index, objective, 0)
        end
    end
    messages[#messages + 1] = table.concat({
        "E", VERSION, sessionID, snapshotID, tostring(localSequence),
        tostring(questCount), tostring(objectiveCount), digest,
    }, SEP)
    for _, message in ipairs(messages) do
        if string.len(message) > MAX_PAYLOAD_BYTES then
            if targetKey then pendingSnapshotTargets[targetKey] = target end
            return false
        end
    end

    local bulkStart, orderStart = #outgoing.bulk, outgoingOrder
    outgoing.snapshotBarriers[#outgoing.snapshotBarriers + 1] = {
        batch=snapshotID, order=outgoingOrder,
    }
    for index, message in ipairs(messages) do
        if not QueueMessage(message, "WHISPER", target, "bulk", nil,
            snapshotID, index == #messages)
        then
            while #outgoing.bulk > bulkStart do table.remove(outgoing.bulk) end
            table.remove(outgoing.snapshotBarriers)
            outgoingOrder = orderStart
            if targetKey then pendingSnapshotTargets[targetKey] = target end
            return false
        end
    end
    if targetKey then lastSnapshotAt[targetKey] = GetTime() end
    if targetKey then pendingSnapshotTargets[targetKey] = nil end
    return true
end

local function FlushPendingSnapshots()
    for targetKey, target in pairs(pendingSnapshotTargets) do
        if not IsRosterMember(target) then
            pendingSnapshotTargets[targetKey] = nil
        elseif QueueSnapshot(target) then
            pendingSnapshotTargets[targetKey] = nil
        end
    end
end

local function SendRequest()
    local channel = GroupChannel()
    if not baselineReady then requestPending = true; return false end
    if SyncActive() and channel and GetTime() - lastRequestAt >= 2 then
        if QueueMessage(table.concat({
            "R", VERSION, sessionID, CAPABILITIES,
        }, SEP), channel, nil, "urgent", "R") then
            lastRequestAt = GetTime()
            requestPending = false
            if AQ.QuestieSyncCompat and AQ.QuestieSyncCompat.QueueRequest then
                AQ.QuestieSyncCompat.QueueRequest(channel)
            end
            return true
        end
        requestPending = true
    end
    return false
end

local function RequestSnapshotFrom(target)
    if not SyncActive() or not target then return false end
    local targetKey = RosterKey(target)
    if not targetKey then return false end
    local now = GetTime()
    if lastResyncAt[targetKey] and now - lastResyncAt[targetKey] < 2 then return true end
    if QueueMessage(table.concat({
        "R", VERSION, sessionID, CAPABILITIES,
    }, SEP), "WHISPER", target, "urgent", "R:" .. targetKey) then
        lastResyncAt[targetKey] = now
        return true
    end
    return false
end

local function QueueHeartbeat()
    local channel = GroupChannel()
    if not baselineReady or not SyncActive() or not channel or #outgoing.urgent > 0 then
        return false
    end
    return QueueMessage(table.concat({
        "H", VERSION, sessionID, tostring(localSequence), CAPABILITIES,
        QuestDigest(localQuests),
    }, SEP), channel, nil, "urgent", "H")
end

local function AnnouncementChannel()
    local selected = string.upper(tostring(Setting("questAnnouncementChannel", "GROUP") or "GROUP"))
    if selected == "SAY" or selected == "EMOTE" then return selected end
    if selected == "GROUP" then
        local channel = GroupChannel()
        if channel == "PARTY" or channel == "RAID" then return channel end
    end
    return nil
end

local function Announce(text, emoteText, sayText)
    local channel = AnnouncementChannel()
    if not channel or not SendChatMessage then return end
    if channel == "EMOTE" then
        SendChatMessage(emoteText or text, channel)
    elseif channel == "SAY" then
        SendChatMessage(sayText or text, channel)
    else
        SendChatMessage(text, channel)
    end
end

-- Blizzard classifies the ordinary Questie-style steps we want to surface as
-- monster (kills), item (loot), object (interact), or event (scripted use/
-- interaction). Progress-only categories such as reputation stay silent.
local ANNOUNCED_OBJECTIVE_TYPES = {
    monster = true,
    item = true,
    object = true,
    event = true,
}

local function ShouldAnnounceObjective(objective)
    return objective and ANNOUNCED_OBJECTIVE_TYPES[string.lower(objective.type or "")] == true
end

local function ObjectiveIdentity(text)
    local label = string.gsub(text or "", "|c%x%x%x%x%x%x%x%x", "")
    label = string.gsub(label, "|r", "")
    label = string.gsub(label, "%s*%d+%s*/%s*%d+%s*$", "")
    label = string.gsub(label, "%s*%d+%%%s*$", "")
    label = string.gsub(label, ":%s*$", "")
    label = string.gsub(label, "^%s+", "")
    label = string.gsub(label, "%s+$", "")
    label = string.gsub(label, "%s+", " ")
    return string.lower(label)
end

local function AnnounceObjective(objective)
    local text = CleanField(objective.text, 165)
    -- Keep the wording factual. Custom quests do not always use Blizzard's
    -- objective type consistently, so flavor text that claims a kill, loot,
    -- or interaction can be wrong even when the completion transition is real.
    Announce("{rt1} Objective complete: " .. text,
        string.format("completes an objective - %s.", text),
        string.format("Objective complete: %s.", text))
end

local function AnnounceQuest(quest)
    local title = CleanField(quest.title, 145)
    Announce("{rt1} Completed quest objectives: " .. title,
        "{rt1} stands victorious - every objective for \"" .. title .. "\" is complete! {rt1}",
        "{rt1} Every objective is complete for \"" .. title .. "\"! {rt1}")
    if Setting("cheerQuestCompletion", false) and DoEmote then DoEmote("CHEER") end
end

local function RememberTurnIn()
    local title = rewardQuestTitle
    if (not title or title == "") and GetTitleText then title = GetTitleText() end
    title = CleanField(title, 145)
    if title == "" then return end

    local key
    for questKey, quest in pairs(localQuests) do
        if quest.title == title then key = questKey; break end
    end
    for _, pending in ipairs(pendingTurnIns) do
        if (key and pending.key == key) or pending.title == title then
            pending.expires = GetTime() + 15
            return
        end
    end
    table.insert(pendingTurnIns, { key = key, title = title, expires = GetTime() + 15 })
end

local function HookQuestReward()
    if rewardHooked or not hooksecurefunc or not GetQuestReward then return end
    hooksecurefunc("GetQuestReward", RememberTurnIn)
    rewardHooked = true
end

local function AnnounceSuccessfulTurnIns(current)
    for index = #pendingTurnIns, 1, -1 do
        local pending = pendingTurnIns[index]
        local stillActive = false
        for key, quest in pairs(current) do
            if (pending.key and key == pending.key) or quest.title == pending.title then
                stillActive = true
                break
            end
        end
        if GetTime() > pending.expires then
            table.remove(pendingTurnIns, index)
        elseif not stillActive then
            if Setting("announceQuestCompletion", true) then AnnounceQuest({ title = pending.title }) end
            table.remove(pendingTurnIns, index)
        end
    end
    if #pendingTurnIns == 0 then rewardQuestTitle = nil end
end

local function AnnounceTransitions(before, after)
    if not baselineReady then return end
    for key, quest in pairs(after) do
        local previous = before and before[key]
        if previous then
            if Setting("announceObjectiveCompletion", true) then
                for _, objective in ipairs(quest.objectives) do
                    local identity = ObjectiveIdentity(objective.text)
                    local oldObjective
                    for _, candidate in ipairs(previous.objectives or {}) do
                        if ObjectiveIdentity(candidate.text) == identity then
                            oldObjective = candidate
                            break
                        end
                    end
                    if oldObjective and not oldObjective.finished and objective.finished
                        and ShouldAnnounceObjective(objective)
                    then
                        AnnounceObjective(objective)
                    end
                end
            end
        end
    end
end

local function ProcessQuestUpdate()
    local wasReady = baselineReady
    local previous = localQuests
    local current, itemMap = BuildLocalState()
    AnnounceSuccessfulTurnIns(current)
    AnnounceTransitions(previous, current)
    -- The first scan is a local baseline, not a broadcast snapshot. Existing
    -- members answer our targeted request; later quest-log changes are deltas.
    if baselineReady then
        QueueDelta(previous, current)
        if AQ.QuestieSyncCompat and AQ.QuestieSyncCompat.QueueDelta then
            AQ.QuestieSyncCompat.QueueDelta(previous, current)
        end
    end
    localQuests = current
    itemQuestKeys = itemMap
    baselineReady = true
    -- This snapshot is also the settled state used for completion
    -- announcements. Invalidate the independently cached nameplate and map
    -- indexes now so a completed objective cannot keep its old marker, pin,
    -- or remaining count until another quest-log event happens.
    if AQ.Markers and AQ.Markers.RequestRefresh then AQ.Markers.RequestRefresh() end
    if AQ.Map and AQ.Map.RequestRefresh then AQ.Map.RequestRefresh() end
    FlushPendingSnapshots()
    if requestPending or not wasReady then SendRequest() end
end

local function ScheduleUpdate(delay)
    updateAt = GetTime() + (delay or UPDATE_DELAY)
end

local function ScheduleRosterCleanup(delay)
    rosterCleanupAt = GetTime() + (delay or ROSTER_SETTLE_DELAY)
end

local function TrimMemberObjectives(quest, count)
    for index in pairs(quest.objectives) do
        if type(index) == "number" and index > count then quest.objectives[index] = nil end
    end
end

local function ReceiveMessage(prefix, message, channel, sender)
    if prefix ~= PREFIX or not sender or not IsRosterMember(sender) then return end
    if ShortName(sender) == ShortName(UnitFullName("player")) then return end
    if not SyncActive() then return end
    if type(message) ~= "string" or string.len(message) > MAX_PAYLOAD_BYTES then return end

    local fields = Split(message)
    local kind = fields[1]
    if not VALID_KINDS[kind] then return end
    if fields[2] ~= VERSION then return end
    local remoteSession = CleanField(fields[3], 40)
    if remoteSession == "" then return end
    local senderKey = RosterKey(sender)
    if not senderKey then return end

    local member = memberQuests[senderKey]
    if not member then
        member = {
            name=sender, quests={}, completeSnapshot=false, updated=GetTime(),
            rateStarted=GetTime(), rateCount=0,
        }
        memberQuests[senderKey] = member
    end
    member.name = sender
    local now = GetTime()
    if now - (member.rateStarted or 0) >= MESSAGE_WINDOW then
        member.rateStarted, member.rateCount = now, 0
    end
    member.rateCount = (member.rateCount or 0) + 1
    if member.rateCount > MAX_MESSAGES_PER_WINDOW then return end

    if member.session ~= remoteSession then
        member.session = remoteSession
        member.snapshot = nil
        member.lastSequence = 0
        if member.completeSnapshot and next(member.quests or {}) then
            member.resyncPending = true
        else
            member.quests = {}
            member.completeSnapshot = false
        end
        RequestSnapshotFrom(sender)
    end
    member.transport = "AEQ2"
    member.updated = now

    if kind == "R" then
        member.capabilities = CleanField(fields[4], 80)
        if channel == GroupChannel() or channel == "WHISPER" then QueueSnapshot(sender) end
        return
    end

    if kind == "H" then
        if channel ~= GroupChannel() then return end
        member.capabilities = CleanField(fields[5], 80)
        local advertised = SafeInteger(fields[4], 0, 2147483647)
        if not advertised then return end
        local digest = SafeDigest(fields[6])
        local digestMismatch = digest and member.completeSnapshot
            and advertised == (member.lastSequence or 0)
            and QuestDigest(member.quests) ~= digest
        if advertised > (member.lastSequence or 0) or not member.completeSnapshot
            or digestMismatch
        then
            -- Keep the last complete snapshot visible while its replacement is
            -- transferred. The E packet commits the new snapshot atomically.
            member.resyncPending = true
            RequestSnapshotFrom(sender)
        end
        return
    end

    local sequence
    if kind == "B" or kind == "E" then
        sequence = 0
    else
        sequence = SafeInteger(fields[4], 0, 2147483647)
        if not sequence then return end
    end
    local snapshotPacket = sequence == 0
    if (kind == "B" or kind == "E" or snapshotPacket) and channel ~= "WHISPER" then return end
    if not snapshotPacket and kind ~= "B" and kind ~= "E" and channel ~= GroupChannel() then return end
    if snapshotPacket and (kind == "Q" or kind == "O") and not member.snapshot then
        -- The begin packet was dropped or this row belongs to an already
        -- rejected snapshot. Never fall back to mutating the live quest table.
        member.resyncPending = true
        RequestSnapshotFrom(sender)
        return
    end

    if sequence > 0 then
        local previous = member.lastSequence or 0
        if sequence <= previous then return end
        if previous > 0 and sequence > previous + 1 and HasCapability(member, "contig") then
            -- A later delta cannot prove that an earlier one was irrelevant.
            -- Preserve the last complete view until its atomic replacement is
            -- ready, preventing all of this member's pins from flickering out.
            member.resyncPending = true
            RequestSnapshotFrom(sender)
        end
        member.lastSequence = sequence
    end

    if kind == "B" then
        local expectedQuests = SafeInteger(fields[6], 0, MAX_REMOTE_QUESTS)
        local expectedObjectives = SafeInteger(fields[7], 0, MAX_REMOTE_OBJECTIVES)
        local snapshotSequence = SafeInteger(fields[5], 0, 2147483647)
        if not expectedQuests or not expectedObjectives or not snapshotSequence
            or not fields[4] or fields[4] == ""
        then
            member.snapshot = nil
            member.resyncPending = true
            RequestSnapshotFrom(sender)
            return
        end
        member.snapshot = {
            id = fields[4],
            sequence = snapshotSequence,
            expectedQuests = expectedQuests,
            expectedObjectives = expectedObjectives,
            receivedQuests = 0,
            receivedObjectives = 0,
            quests = {},
            hadComplete = member.completeSnapshot,
            digest = SafeDigest(fields[10]),
        }
        member.class = CleanField(fields[8], 16)
        member.capabilities = CleanField(fields[9], 80)
    elseif kind == "E" then
        local snapshot = member.snapshot
        local hadComplete = member.completeSnapshot
        local valid = snapshot ~= nil
        if valid and snapshot.expectedQuests ~= nil then
            valid = snapshot.id == fields[4]
                and snapshot.sequence == SafeInteger(fields[5], 0, 2147483647)
                and snapshot.expectedQuests == SafeInteger(fields[6], 0, MAX_REMOTE_QUESTS)
                and snapshot.expectedObjectives == SafeInteger(fields[7], 0, MAX_REMOTE_OBJECTIVES)
                and snapshot.receivedQuests == snapshot.expectedQuests
                and snapshot.receivedObjectives == snapshot.expectedObjectives
            local actualQuests, actualObjectives = 0, 0
            if valid then
                for _, quest in pairs(snapshot.quests) do
                    actualQuests = actualQuests + 1
                    for index = 1, quest.objectiveCount or 0 do
                        if quest.objectives[index] then
                            actualObjectives = actualObjectives + 1
                        else
                            valid = false
                            break
                        end
                    end
                    if not valid then break end
                end
                valid = actualQuests == snapshot.expectedQuests
                    and actualObjectives == snapshot.expectedObjectives
            end
            if valid and HasCapability(member, "digest") then
                local endingDigest = SafeDigest(fields[8])
                valid = snapshot.digest ~= nil and snapshot.digest == endingDigest
                    and QuestDigest(snapshot.quests) == snapshot.digest
            end
        end
        if valid then
            member.quests = snapshot.quests
            member.completeSnapshot = true
            member.lastSequence = snapshot.sequence
            member.validSnapshotAt = now
            member.stale = false
            member.resyncPending = false
        else
            member.completeSnapshot = snapshot and snapshot.hadComplete or hadComplete
            member.resyncPending = true
            RequestSnapshotFrom(sender)
        end
        member.snapshot = nil
    elseif kind == "X" and fields[5] and not snapshotPacket then
        local key = CleanField(fields[5], 40)
        if key ~= "" then member.quests[key] = nil end
    elseif kind == "Q" and fields[5] then
        local key = CleanField(fields[5], 40)
        local count = SafeInteger(fields[9], 0, 20)
        if key == "" or not count then return end
        local snapshot = snapshotPacket and member.snapshot or nil
        local quests = snapshot and snapshot.quests or member.quests
        if not quests then return end
        local quest = quests[key] or { objectives = {} }
        quest.key = key
        quest.id = SafeInteger(fields[6], 1, 20000000)
        quest.title = CleanField(fields[7] or "Unknown quest", 80)
        quest.complete = fields[8] == "1"
        quest.objectiveCount = count
        TrimMemberObjectives(quest, count)
        quests[key] = quest
        if snapshot then
            snapshot.receivedQuests = snapshot.receivedQuests + 1
        end
    elseif kind == "O" and fields[5] then
        local key = CleanField(fields[5], 40)
        local index = SafeInteger(fields[6], 1, 20)
        if key == "" or not index then return end
        local snapshot = snapshotPacket and member.snapshot or nil
        local quests = snapshot and snapshot.quests or member.quests
        if not quests then return end
        local quest = quests[key] or { key = key, title = "Unknown quest", objectives = {} }
        quest.objectives[index] = {
            finished = fields[7] == "1",
            type = CleanField(fields[8], 12),
            targetType = CleanField(fields[9], 8),
            targetID = SafeInteger(fields[10], 1, 20000000),
            current = SafeInteger(fields[11], 0, 100000000),
            required = SafeInteger(fields[12], 0, 100000000),
            text = CleanField(fields[13] or ("Objective " .. index), 100),
        }
        quests[key] = quest
        if snapshot then
            snapshot.receivedObjectives = snapshot.receivedObjectives + 1
        end
    end

    -- Group objective badges are built by QuestMarkers, which loads after
    -- this file. Refresh whenever a snapshot/delta changes remote quest data;
    -- RequestRefresh is deliberately cheap and coalesces rapid objective rows.
    if kind == "B" or kind == "E" or kind == "X" or kind == "Q" or kind == "O" then
        if AQ.Markers and AQ.Markers.RequestRefresh then AQ.Markers.RequestRefresh() end
        if AQ.Map and AQ.Map.RequestRefresh then AQ.Map.RequestRefresh() end
    end
end

local function CleanupRoster()
    local roster, units = CurrentRoster()
    local migrations, removals = {}, {}
    for name in pairs(memberQuests) do
        local rosterKey = MatchingRosterKey(roster, name)
        if not rosterKey then
            removals[#removals + 1] = name
        elseif rosterKey ~= name then
            migrations[#migrations + 1] = { from=name, to=rosterKey }
        end
    end
    for _, name in ipairs(removals) do
        memberQuests[name] = nil
        lastSnapshotAt[name] = nil
        lastResyncAt[name] = nil
    end
    for _, migration in ipairs(migrations) do
        local member = memberQuests[migration.from]
        local existing = memberQuests[migration.to]
        if member and (not existing
            or (member.updated or 0) >= (existing.updated or 0))
        then
            memberQuests[migration.to] = member
        end
        memberQuests[migration.from] = nil
        lastSnapshotAt[migration.to] = math.max(
            lastSnapshotAt[migration.to] or 0, lastSnapshotAt[migration.from] or 0)
        lastResyncAt[migration.to] = math.max(
            lastResyncAt[migration.to] or 0, lastResyncAt[migration.from] or 0)
        lastSnapshotAt[migration.from] = nil
        lastResyncAt[migration.from] = nil
    end
    for name, target in pairs(pendingSnapshotTargets) do
        local rosterKey = MatchingRosterKey(roster, name)
        if not rosterKey then
            pendingSnapshotTargets[name] = nil
        elseif rosterKey ~= name then
            pendingSnapshotTargets[rosterKey] = target
            pendingSnapshotTargets[name] = nil
        end
    end

    -- A departed member can leave a long multipart whisper snapshot at the
    -- head of the bulk queue. Remove those packets and their barrier so fresh
    -- deltas for the members who remain are not blocked behind dead traffic.
    for _, queueName in ipairs({ "urgent", "bulk" }) do
        local queue = outgoing[queueName]
        for index = #queue, 1, -1 do
            local entry = queue[index]
            if entry.channel == "WHISPER"
                and not MatchingRosterKey(roster, entry.target)
            then
                if entry.key then outgoingKeys[entry.key] = nil end
                table.remove(queue, index)
            end
        end
    end
    local remainingBatches = {}
    for _, entry in ipairs(outgoing.bulk) do
        if entry.batch then remainingBatches[entry.batch] = true end
    end
    if outgoing.activeBatch and not remainingBatches[outgoing.activeBatch] then
        outgoing.activeBatch = nil
    end
    for index = #outgoing.snapshotBarriers, 1, -1 do
        if not remainingBatches[outgoing.snapshotBarriers[index].batch] then
            table.remove(outgoing.snapshotBarriers, index)
        end
    end
    for name, member in pairs(memberQuests) do
        local unit = units[name]
        member.connected = not unit or not UnitIsConnected or UnitIsConnected(unit) ~= false
    end
    if AQ.QuestieSyncCompat and AQ.QuestieSyncCompat.CleanupRoster then
        AQ.QuestieSyncCompat.CleanupRoster()
    end
    if not SyncActive() then
        ClearOutgoing()
        wipe(memberQuests)
        wipe(pendingSnapshotTargets)
        wipe(lastResyncAt)
        requestPending = false
        nextAuditAt = 0
        profileSyncActive = false
        if AQ.Markers and AQ.Markers.RequestRefresh then AQ.Markers.RequestRefresh() end
        if AQ.Map and AQ.Map.RequestRefresh then AQ.Map.RequestRefresh() end
        return
    end
    profileSyncActive = true
    nextAuditAt = 0
    SendRequest()
    if AQ.Markers and AQ.Markers.RequestRefresh then AQ.Markers.RequestRefresh() end
    if AQ.Map and AQ.Map.RequestRefresh then AQ.Map.RequestRefresh() end
end

local function MissingMemberData()
    local playerKey = NormalizeName(UnitFullName("player"))
    for name in pairs(CurrentRoster()) do
        if name ~= playerKey then
            local member = memberQuests[name]
            if not member or not member.completeSnapshot or member.stale then return true end
        end
    end
    return false
end

local function AuditSync(now)
    if not SyncActive() or not baselineReady then return end
    local auditInterval = RaidCount() > 0 and RAID_AUDIT_INTERVAL or PARTY_AUDIT_INTERVAL
    local staleAfter = auditInterval + STALE_GRACE
    local expireAfter = staleAfter + EXPIRE_GRACE
    local freshnessChanged = false
    for _, member in pairs(memberQuests) do
        local age = now - (member.updated or 0)
        if age >= staleAfter and not member.stale then
            member.stale = true
            member.completeSnapshot = false
            freshnessChanged = true
            requestPending = true
            nextAuditAt = 0
        end
        if age >= expireAfter and next(member.quests or {}) then
            member.quests = {}
            freshnessChanged = true
        end
    end
    if freshnessChanged then
        if AQ.Markers and AQ.Markers.RequestRefresh then AQ.Markers.RequestRefresh() end
        if AQ.Map and AQ.Map.RequestRefresh then AQ.Map.RequestRefresh() end
    end
    if now < nextAuditAt then return end
    local missing = MissingMemberData()
    if requestPending or missing then
        SendRequest()
        nextAuditAt = now + RETRY_INTERVAL
    else
        SendRequest()
        nextAuditAt = now + (RaidCount() > 0 and RAID_AUDIT_INTERVAL or PARTY_AUDIT_INTERVAL)
    end
end

local function PopOutgoing()
    local entry
    if outgoing.activeBatch then
        entry = table.remove(outgoing.bulk, 1)
        if not entry or entry.batch ~= outgoing.activeBatch then
            outgoing.activeBatch = nil
            if entry then table.insert(outgoing.bulk, 1, entry) end
            entry = nil
        end
    end
    if not entry and not outgoing.activeBatch then
        local barrier = outgoing.snapshotBarriers[1]
        local urgent = outgoing.urgent[1]
        if urgent and (not barrier or (urgent.order or 0) <= barrier.order) then
            entry = table.remove(outgoing.urgent, 1)
        elseif #outgoing.bulk > 0 then
            entry = table.remove(outgoing.bulk, 1)
            if entry.batch then outgoing.activeBatch = entry.batch end
        elseif urgent then
            -- A barrier can only outlive its batch if a defensive queue limit
            -- rejected part of that batch. Do not deadlock all later deltas.
            table.remove(outgoing.snapshotBarriers, 1)
            entry = table.remove(outgoing.urgent, 1)
        end
    end
    if entry and entry.key then outgoingKeys[entry.key] = nil end
    if entry and entry.batchEnd and outgoing.activeBatch == entry.batch then
        outgoing.activeBatch = nil
    end
    local barrier = outgoing.snapshotBarriers[1]
    if entry and entry.batchEnd and barrier and barrier.batch == entry.batch then
        table.remove(outgoing.snapshotBarriers, 1)
    end
    return entry
end

local function ObjectiveProgress(objective)
    if not objective then return nil end
    if objective.current and objective.required then
        return tostring(objective.current) .. "/" .. tostring(objective.required)
    end
    local current, total = AQ.ObjectiveResolver.Progress(objective.text)
    if current and total then return current .. "/" .. total end
    return objective.finished and "Complete" or "In progress"
end

local function MatchingObjective(quest, itemName)
    local lowerName = itemName and string.lower(itemName) or nil
    if lowerName and lowerName ~= "" then
        for _, objective in ipairs(quest.objectives or {}) do
            if string.find(string.lower(objective.text or ""), lowerName, 1, true) then return objective end
        end
    end
    if #(quest.objectives or {}) == 1 then return quest.objectives[1] end
    return nil
end

local function ColoredMemberName(name, class)
    local display = string.match(tostring(name or "Unknown"), "^[^-]+") or tostring(name or "Unknown")
    local color = type(RAID_CLASS_COLORS) == "table" and RAID_CLASS_COLORS[class or ""] or nil
    if not color then return display end
    return string.format("|cff%02x%02x%02x%s|r",
        math.floor((color.r or 0.8) * 255 + 0.5),
        math.floor((color.g or 0.8) * 255 + 0.5),
        math.floor((color.b or 0.8) * 255 + 0.5), display)
end

local function MemberRowsForQuest(key, itemName)
    local rows = {}
    local roster = CurrentRoster()
    local playerKey = NormalizeName(UnitFullName("player"))
    for normalized, displayName in pairs(roster) do
        local quest, known, memberClass, stale
        if normalized == playerKey then
            quest, known = localQuests[key], true
            if UnitClass then
                local _, class = UnitClass("player")
                memberClass = class
            end
        else
            local member = memberQuests[normalized]
            stale = member and member.stale
            local offline = member and member.connected == false
            quest = not stale and not offline and member and member.quests[key]
            known = member and member.completeSnapshot
            memberClass = member and member.class
            if member and quest and not stale then known = true end
            if offline then stale = "offline" end
        end

        local status, complete
        if quest then
            local objective = MatchingObjective(quest, itemName)
            status = ObjectiveProgress(objective) or (quest.complete and "Complete" or "In progress")
            complete = (objective and (objective.finished
                or (objective.current and objective.required and objective.required > 0
                    and objective.current >= objective.required))) or quest.complete
        elseif stale then
            status = stale == "offline" and "Offline" or "Stale"
        elseif known then
            status = "Does not have quest"
        else
            status = "No sync data"
        end
        table.insert(rows, {
            name=displayName, displayName=ColoredMemberName(displayName, memberClass),
            status=status, complete=complete, stale=stale,
        })
    end
    table.sort(rows, function(a, b)
        if NormalizeName(a.name) == playerKey then return true end
        if NormalizeName(b.name) == playerKey then return false end
        return string.lower(a.name) < string.lower(b.name)
    end)
    return rows
end

local function QuestKeysForItem(itemID)
    local keys, seen = {}, {}
    for _, key in ipairs(itemQuestKeys[itemID] or {}) do
        keys[#keys + 1] = key
        seen[key] = true
    end
    for _, member in pairs(memberQuests) do
        if member.completeSnapshot and not member.stale and member.connected ~= false then
            for key, quest in pairs(member.quests or {}) do
                if not seen[key] then
                    local remoteItems = {}
                    for _, objective in ipairs(quest.objectives or {}) do
                        if objective.targetType == "item" and tonumber(objective.targetID) then
                            remoteItems[#remoteItems + 1] = tonumber(objective.targetID)
                        end
                    end
                    for _, questItemID in ipairs(AQ.DataStore.GetQuestItemIDsByTitle(quest.title) or {}) do
                        remoteItems[#remoteItems + 1] = tonumber(questItemID)
                    end
                    for _, questItemID in ipairs(remoteItems) do
                        if tonumber(questItemID) == itemID then
                            keys[#keys + 1] = key
                            seen[key] = true
                            break
                        end
                    end
                end
            end
        end
    end
    return keys
end

local function QuestForKey(key)
    if localQuests[key] then return localQuests[key] end
    for _, member in pairs(memberQuests) do
        if member.completeSnapshot and not member.stale and member.connected ~= false
            and member.quests and member.quests[key]
        then
            return member.quests[key]
        end
    end
end

local function AddTooltipProgress(tooltip, link)
    if not tooltip or Setting("showGroupQuestTooltips", true) == false or not SyncActive() then return end
    local itemID = link and tonumber(string.match(link, "item:(%-?%d+)"))
    local questKeys = itemID and QuestKeysForItem(itemID)
    if not questKeys or #questKeys == 0 then return end

    local marker = tostring(itemID) .. ":" .. table.concat(questKeys, ",")
    if tooltip.__aeGroupQuestMarker == marker then return end
    tooltip.__aeGroupQuestMarker = marker

    local itemName = GetItemInfo and GetItemInfo(link)
    tooltip:AddLine(" ")
    tooltip:AddLine("AutoQuest Group Progress", 0.35, 0.65, 1)
    for _, key in ipairs(questKeys) do
        local quest = QuestForKey(key)
        if quest then
            tooltip:AddLine(quest.title, 1, 0.82, 0.2)
            for _, row in ipairs(MemberRowsForQuest(key, itemName)) do
                if row.complete then
                    tooltip:AddDoubleLine("  " .. row.displayName, row.status, 0.82, 0.82, 0.82, 0.35, 1, 0.35)
                else
                    local statusColor = row.stale and 0.45 or 0.7
                    tooltip:AddDoubleLine("  " .. row.displayName, row.status,
                        0.82, 0.82, 0.82, statusColor, statusColor, statusColor)
                end
            end
        end
    end
    tooltip:Show()
end

local function AddUnitTooltipProgress(tooltip)
    if not tooltip or Setting("showGroupQuestTooltips", true) == false then return end
    if not tooltip.GetUnit or not AQ.Markers or not AQ.Markers.GetGroupTooltipRows then return end
    local _, unit = tooltip:GetUnit()
    if not unit and UnitExists and UnitExists("mouseover") then unit = "mouseover" end
    if not unit or not UnitExists(unit) or UnitIsPlayer(unit) then return end

    local rows = AQ.Markers.GetGroupTooltipRows(unit)
    if not rows or #rows == 0 then return end
    local signatureParts = { tostring(UnitGUID and UnitGUID(unit) or UnitName(unit) or unit) }
    for _, row in ipairs(rows) do
        signatureParts[#signatureParts + 1] = row.name
        for _, step in ipairs(row.steps or {}) do
            signatureParts[#signatureParts + 1] = step.text or ""
        end
    end
    local signature = table.concat(signatureParts, SEP)
    if tooltip.__aeGroupUnitMarker == signature then return end
    tooltip.__aeGroupUnitMarker = signature

    tooltip:AddLine(" ")
    tooltip:AddLine(SyncActive() and "Group Quest Progress" or "Quest Progress", 0.35, 0.65, 1)
    local shown, total, maximum = 0, 0, 12
    for _, row in ipairs(rows) do total = total + #(row.steps or {}) end
    for _, row in ipairs(rows) do
        if shown >= maximum then break end
        tooltip:AddLine("  " .. ColoredMemberName(row.name, row.class), 1, 0.82, 0.2)
        for _, step in ipairs(row.steps or {}) do
            if shown >= maximum then break end
            tooltip:AddLine("    " .. (step.text or "Quest objective"), 0.82, 0.82, 0.82, true)
            shown = shown + 1
        end
    end
    if shown < total then
        tooltip:AddLine("  Additional group objectives omitted", 0.6, 0.6, 0.6)
    end
    tooltip:Show()
end

local function HookTooltip(tooltip)
    if not tooltip then return end
    if tooltip.HookScript then
        tooltip:HookScript("OnTooltipCleared", function(self)
            self.__aeGroupQuestMarker = nil
            self.__aeGroupUnitMarker = nil
        end)
        tooltip:HookScript("OnTooltipSetUnit", function(self) AddUnitTooltipProgress(self) end)
    end
    if tooltip.SetBagItem then
        hooksecurefunc(tooltip, "SetBagItem", function(self, bag, slot)
            AddTooltipProgress(self, GetContainerItemLink and GetContainerItemLink(bag, slot))
        end)
    end
    if tooltip.SetQuestLogItem then
        hooksecurefunc(tooltip, "SetQuestLogItem", function(self, itemType, index)
            AddTooltipProgress(self, GetQuestLogItemLink and GetQuestLogItemLink(itemType, index))
        end)
    end
    if tooltip.SetHyperlink then
        hooksecurefunc(tooltip, "SetHyperlink", function(self, link) AddTooltipProgress(self, link) end)
    end
end

local function AutoShareQuest(index)
    if not index or RaidCount() > 0 or PartyCount() == 0 or Setting("autoShareQuests", false) ~= true then return end
    if acceptedSharedTitle and GetTime() <= acceptedSharedUntil then
        QuestState.Refresh()
        local quest = QuestState.GetByLogIndex(index)
        if quest and quest.title == acceptedSharedTitle then
            acceptedSharedTitle = nil
            return
        end
    end
    table.insert(pendingShares, { index = index, at = GetTime() + 0.35 })
end

local function ProcessShare(entry)
    if not QuestLogPushQuest or not SelectQuestLogEntry then return end
    local oldSelection = GetQuestLogSelection and GetQuestLogSelection() or nil
    SelectQuestLogEntry(entry.index)
    local pushable = true
    if GetQuestLogPushable then
        local ok, result = pcall(GetQuestLogPushable)
        pushable = ok and result ~= false and result ~= nil
    end
    if pushable then pcall(QuestLogPushQuest, entry.index) end
    if oldSelection and oldSelection > 0 and oldSelection ~= entry.index then
        SelectQuestLogEntry(oldSelection)
    end
end

driver:RegisterEvent("ADDON_LOADED")
driver:RegisterEvent("PLAYER_ENTERING_WORLD")
driver:RegisterEvent("QUEST_ACCEPTED")
driver:RegisterEvent("QUEST_ACCEPT_CONFIRM")
driver:RegisterEvent("QUEST_PROGRESS")
driver:RegisterEvent("QUEST_COMPLETE")
driver:RegisterEvent("PARTY_MEMBERS_CHANGED")
driver:RegisterEvent("RAID_ROSTER_UPDATE")
driver:RegisterEvent("CHAT_MSG_ADDON")

driver:SetScript("OnEvent", function(self, event, ...)
    local arg1, arg2, arg3, arg4 = ...
    if event == "ADDON_LOADED" then
        if arg1 ~= "AutoEverything" then return end
        if RegisterAddonMessagePrefix then
            pcall(RegisterAddonMessagePrefix, PREFIX)
            pcall(RegisterAddonMessagePrefix, "questie")
        end
        HookTooltip(GameTooltip)
        HookTooltip(ItemRefTooltip)
        HookQuestReward()
        ScheduleUpdate(0)
    elseif event == "PLAYER_ENTERING_WORLD" then
        baselineReady = false
        nextHeartbeatAt = 0
        nextLocalPollAt = 0
        rewardQuestTitle = nil
        wipe(pendingTurnIns)
        ScheduleUpdate(0.5)
        ScheduleRosterCleanup()
    elseif event == "QUEST_ACCEPTED" then
        AutoShareQuest(arg1)
    elseif event == "QUEST_PROGRESS" then
        rewardQuestTitle = CleanField(GetTitleText and GetTitleText() or "", 145)
    elseif event == "QUEST_COMPLETE" then
        rewardQuestTitle = CleanField(GetTitleText and GetTitleText() or "", 145)
    elseif event == "QUEST_ACCEPT_CONFIRM" then
        local sender, title = arg1, arg2
        if Setting("autoAcceptSharedQuests", false) and AQ.ShouldAutoAcceptShared then
            local allowed, reason = AQ.ShouldAutoAcceptShared(title)
            if allowed and ConfirmAcceptQuest then
                acceptedSharedTitle = title
                acceptedSharedUntil = GetTime() + 5
                ConfirmAcceptQuest()
            elseif AutoCore and AutoCore.Debug then
                AutoCore.Debug("Quest", "Left shared quest '" .. tostring(title) .. "' manual: " .. tostring(reason))
            end
        end
    elseif event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
        ScheduleRosterCleanup()
        ScheduleUpdate(0.5)
    elseif event == "CHAT_MSG_ADDON" then
        if arg1 == "questie" and AQ.QuestieSyncCompat
            and AQ.QuestieSyncCompat.Receive
        then
            AQ.QuestieSyncCompat.Receive(arg2, arg3, arg4)
        else
            ReceiveMessage(arg1, arg2, arg3, arg4)
        end
    end
end)

QuestState.Subscribe(function(changes)
    if changes.semanticChanged then ScheduleUpdate(changes.settled and 0 or nil) end
end)

local sendElapsed = 0
driver:SetScript("OnUpdate", function(self, elapsed)
    local now = GetTime()
    if not SyncActive() and not updateAt and not rosterCleanupAt
        and #pendingShares == 0 and not next(pendingSnapshotTargets)
    then
        sendElapsed = 0
        return
    end
    if updateAt and now >= updateAt then
        updateAt = nil
        ProcessQuestUpdate()
    end
    if rosterCleanupAt and now >= rosterCleanupAt then
        rosterCleanupAt = nil
        CleanupRoster()
    end

    if SyncActive() and baselineReady then
        if now >= nextLocalPollAt then
            QuestState.Refresh("GROUP_SYNC_POLL", true)
            nextLocalPollAt = now + LOCAL_POLL_INTERVAL
        end
    else
        nextLocalPollAt = 0
    end

    for index = #pendingShares, 1, -1 do
        local entry = pendingShares[index]
        if now >= entry.at then
            table.remove(pendingShares, index)
            ProcessShare(entry)
        end
    end

    if next(pendingSnapshotTargets) then FlushPendingSnapshots() end
    if AQ.QuestieSyncCompat and AQ.QuestieSyncCompat.OnUpdate then
        AQ.QuestieSyncCompat.OnUpdate(now)
    end
    AuditSync(now)

    if SyncActive() and baselineReady then
        if now >= nextHeartbeatAt then
            nextHeartbeatAt = now + (QueueHeartbeat() and HEARTBEAT_INTERVAL or 1)
        end
    else
        nextHeartbeatAt = 0
    end

    sendElapsed = sendElapsed + elapsed
    if sendElapsed < SEND_INTERVAL or QueueCount() == 0 then return end
    sendElapsed = 0
    local entry = PopOutgoing()
    if not entry then return end
    if entry.channel == "WHISPER" or entry.channel == GroupChannel() then
        pcall(SendAddonMessage, entry.prefix or PREFIX,
            entry.message, entry.channel, entry.target)
    end
end)

function Sync.RequestUpdate()
    ProcessQuestUpdate()
    SendRequest()
end

function Sync.ApplyProfile()
    local active = SyncActive()
    if active and not profileSyncActive then
        requestPending = true
        nextAuditAt = 0
        ScheduleUpdate(0)
    elseif not active and profileSyncActive then
        ClearOutgoing()
        wipe(memberQuests)
        wipe(pendingSnapshotTargets)
        wipe(lastResyncAt)
        requestPending = false
        nextAuditAt = 0
        if AQ.QuestieSyncCompat and AQ.QuestieSyncCompat.CleanupRoster then
            AQ.QuestieSyncCompat.CleanupRoster()
        end
        if AQ.Markers and AQ.Markers.RequestRefresh then AQ.Markers.RequestRefresh() end
        if AQ.Map and AQ.Map.RequestRefresh then AQ.Map.RequestRefresh() end
    end
    profileSyncActive = active
end

function Sync.GetMemberQuestData()
    return memberQuests
end

function Sync.GetLocalQuestData()
    return localQuests
end

function Sync.GetGroupChannel()
    return GroupChannel()
end

function Sync.CanAcceptExternal(sender, channel)
    return SyncActive() and IsRosterMember(sender)
        and ShortName(sender) ~= ShortName(UnitFullName("player"))
        and (channel == GroupChannel() or channel == "WHISPER")
end

function Sync.QueueCompatMessage(prefix, message, channel, target, priority, coalesceKey)
    if prefix ~= "questie" or not SyncActive()
        or (channel ~= GroupChannel() and channel ~= "WHISPER")
    then
        return false
    end
    return QueueMessage(message, channel, target, priority or "bulk",
        coalesceKey, nil, nil, prefix)
end

function Sync.QueueCompatBatch(prefix, messages, channel, target)
    if prefix ~= "questie" or not SyncActive() or type(messages) ~= "table"
        or (channel ~= GroupChannel() and channel ~= "WHISPER")
        or #messages == 0 or #messages > MAX_QUEUE - QueueCount()
    then
        return false
    end
    for _, message in ipairs(messages) do
        if type(message) ~= "string" or string.len(message) > MAX_PAYLOAD_BYTES then
            return false
        end
    end
    compatBatchSerial = compatBatchSerial + 1
    local batch = "compat:" .. compatBatchSerial
    for index, message in ipairs(messages) do
        if not QueueMessage(message, channel, target, "bulk", nil,
            batch, index == #messages, prefix)
        then
            return false
        end
    end
    return true
end

local function ExternalMember(sender)
    if not sender or not IsRosterMember(sender) or not SyncActive() then return nil end
    if ShortName(sender) == ShortName(UnitFullName("player")) then return nil end
    local senderKey = RosterKey(sender)
    if not senderKey then return nil end
    local member = memberQuests[senderKey]
    if member and member.transport == "AEQ2" then return nil end
    if not member then
        member = { name=sender, quests={}, completeSnapshot=false, updated=GetTime() }
        memberQuests[senderKey] = member
    end
    member.name = sender
    member.updated = GetTime()
    member.transport = "questie"
    member.capabilities = "questie-v5"
    member.stale = false
    return member
end

local function RefreshExternalData()
    if AQ.Markers and AQ.Markers.RequestRefresh then AQ.Markers.RequestRefresh() end
    if AQ.Map and AQ.Map.RequestRefresh then AQ.Map.RequestRefresh() end
end

function Sync.ApplyExternalSnapshot(sender, quests, memberClass)
    local member = ExternalMember(sender)
    if not member or type(quests) ~= "table" then return false end
    local questCount, objectiveCount = 0, 0
    for _, quest in pairs(quests) do
        questCount = questCount + 1
        objectiveCount = objectiveCount + #(quest.objectives or {})
        if questCount > MAX_REMOTE_QUESTS or objectiveCount > MAX_REMOTE_OBJECTIVES then
            return false
        end
    end
    member.quests = quests
    member.class = CleanField(memberClass or member.class or "", 16)
    member.completeSnapshot = true
    member.validSnapshotAt = GetTime()
    RefreshExternalData()
    return true
end

function Sync.ApplyExternalQuest(sender, quest)
    local member = ExternalMember(sender)
    if not member or type(quest) ~= "table" or type(quest.key) ~= "string" then
        return false
    end
    member.quests[quest.key] = quest
    -- A delta is complete only when it extends a previously complete snapshot.
    if member.completeSnapshot then RefreshExternalData() end
    return true
end

function Sync.RemoveExternalQuest(sender, questID)
    questID = tonumber(questID)
    if not questID or questID < 1 or questID ~= math.floor(questID) then return false end
    local member = ExternalMember(sender)
    local key = QuestState.QuestKey(questID, "")
    if not member or not key then return false end
    member.quests[key] = nil
    if member.completeSnapshot then RefreshExternalData() end
    return true
end

function Sync.Debug()
    local localCount = 0
    for _ in pairs(localQuests) do localCount = localCount + 1 end
    print("|cff33ccffQuest Sync|r")
    print("  active=" .. tostring(SyncActive()) .. " channel=" .. tostring(GroupChannel())
        .. " baseline=" .. tostring(baselineReady) .. " localQuests=" .. localCount
        .. " queued=" .. QueueCount() .. " protocol=" .. VERSION
        .. " session=" .. sessionID .. " sequence=" .. localSequence)
    local playerKey = NormalizeName(UnitFullName("player"))
    for name, displayName in pairs(CurrentRoster()) do
        if name ~= playerKey then
            local member = memberQuests[name]
            local questCount = 0
            for _ in pairs(member and member.quests or {}) do questCount = questCount + 1 end
            print("  " .. tostring(displayName) .. ": snapshot="
                .. tostring(member and member.completeSnapshot or false)
                .. " stale=" .. tostring(member and member.stale or false)
                .. " transport=" .. tostring(member and member.transport or "unknown")
                .. " class=" .. tostring(member and member.class or "unknown")
                .. " protocol=" .. tostring(member and member.capabilities or "unknown")
                .. " sequence=" .. tostring(member and member.lastSequence or "none")
                .. " quests=" .. questCount .. " age="
                .. tostring(member and math.floor(GetTime() - member.updated) or "never"))
        end
    end
end
