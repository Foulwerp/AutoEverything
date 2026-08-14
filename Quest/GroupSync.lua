----------------------------------------------------------------------
-- GroupSync.lua
-- =============
-- AutoQuest extension for invisible party/raid quest synchronization.
--
-- Full snapshots are whispered only in response to a group request. Normal
-- PARTY/RAID traffic contains debounced deltas, so hovering an item is always
-- cache-only and never generates network traffic. WoW 3.3.5a / Lua 5.1.
----------------------------------------------------------------------

AutoQuest = AutoQuest or {}
local AQ = AutoQuest

AQ.GroupSync = AQ.GroupSync or {}
local Sync = AQ.GroupSync

local PREFIX = "AEQ1"
local VERSION = "1"
local SEP = "\31"
local SEND_INTERVAL = 0.12
local UPDATE_DELAY = 0.65
local MAX_QUEUE = 400

local localQuests = {}
local memberQuests = {}
local itemQuestKeys = {}
local outgoing = {}
local baselineReady = false
local updateAt = nil
local acceptedSharedTitle = nil
local acceptedSharedUntil = 0
local pendingShares = {}
local lastRequestAt = 0
local lastSnapshotAt = {}
local rewardQuestTitle = nil
local pendingTurnIns = {}
local rewardHooked = false

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
    name = string.lower(tostring(name))
    return string.match(name, "^[^-]+") or name
end

local function CurrentRoster()
    local roster = {}
    local playerName = UnitName and UnitName("player")
    if playerName then roster[NormalizeName(playerName)] = playerName end

    if RaidCount() > 0 then
        for index = 1, RaidCount() do
            local name = UnitName and UnitName("raid" .. index)
            if name then roster[NormalizeName(name)] = name end
        end
    else
        for index = 1, PartyCount() do
            local name = UnitName and UnitName("party" .. index)
            if name then roster[NormalizeName(name)] = name end
        end
    end
    return roster
end

local function IsRosterMember(name)
    return CurrentRoster()[NormalizeName(name)] ~= nil
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

local function TitleHash(title)
    local hash = 5381
    for index = 1, string.len(title or "") do
        hash = math.fmod((hash * 33) + string.byte(title, index), 4294967296)
    end
    return string.format("T%08x", hash)
end

local function QuestKey(questID, title)
    if type(questID) == "number" and questID > 0 then return "I" .. tostring(questID) end
    return TitleHash(title or "")
end

local function IsComplete(value)
    return value == true or value == 1
end

local function BuildLocalState()
    local quests = {}
    local items = {}
    local entries = GetNumQuestLogEntries and GetNumQuestLogEntries() or 0

    for questIndex = 1, entries do
        local title, level, questTag, suggestedGroup, isHeader, isCollapsed,
            questComplete, isDaily, questID = GetQuestLogTitle(questIndex)
        if title and not isHeader then
            local key = QuestKey(questID, title)
            local quest = {
                key = key,
                title = title,
                complete = IsComplete(questComplete),
                objectives = {},
            }
            local objectiveCount = GetNumQuestLeaderBoards and (GetNumQuestLeaderBoards(questIndex) or 0) or 0
            for objectiveIndex = 1, objectiveCount do
                local text, objectiveType, finished = GetQuestLogLeaderBoard(objectiveIndex, questIndex)
                quest.objectives[objectiveIndex] = {
                    text = text or ("Objective " .. objectiveIndex),
                    finished = IsComplete(finished),
                    type = objectiveType or "",
                }
            end
            quests[key] = quest

            local questItems = QuestByTitle and QuestByTitle[title]
            for _, itemID in ipairs(questItems or {}) do
                items[itemID] = items[itemID] or {}
                table.insert(items[itemID], key)
            end
        end
    end
    return quests, items
end

local function QueueMessage(message, channel, target)
    if not SendAddonMessage or #outgoing >= MAX_QUEUE then return end
    table.insert(outgoing, { message = message, channel = channel, target = target })
end

local function EncodeQuest(quest)
    return table.concat({
        "Q", quest.key, CleanField(quest.title, 100), quest.complete and "1" or "0",
        tostring(#quest.objectives),
    }, SEP)
end

local function EncodeObjective(questKey, index, objective)
    return table.concat({
        "O", questKey, tostring(index), objective.finished and "1" or "0",
        CleanField(objective.text, 125),
    }, SEP)
end

local function QueueQuest(quest, channel, target)
    QueueMessage(EncodeQuest(quest), channel, target)
    for index, objective in ipairs(quest.objectives) do
        QueueMessage(EncodeObjective(quest.key, index, objective), channel, target)
    end
end

local function ObjectiveChanged(before, after)
    if not before then return true end
    return before.finished ~= after.finished or before.text ~= after.text
end

local function QueueDelta(before, after)
    local channel = GroupChannel()
    if not channel or not SyncActive() then return end

    for key in pairs(before or {}) do
        if not after[key] then QueueMessage(table.concat({ "X", key }, SEP), channel) end
    end
    for key, quest in pairs(after) do
        local previous = before and before[key]
        if not previous or previous.title ~= quest.title or previous.complete ~= quest.complete
            or #previous.objectives ~= #quest.objectives then
            QueueMessage(EncodeQuest(quest), channel)
        end
        for index, objective in ipairs(quest.objectives) do
            if not previous or ObjectiveChanged(previous.objectives[index], objective) then
                QueueMessage(EncodeObjective(key, index, objective), channel)
            end
        end
    end
end

local function QueueSnapshot(target)
    if not SyncActive() or not target then return end
    local targetKey = NormalizeName(target)
    if targetKey and lastSnapshotAt[targetKey] and GetTime() - lastSnapshotAt[targetKey] < 2 then return end
    if targetKey then lastSnapshotAt[targetKey] = GetTime() end
    QueueMessage(table.concat({ "B", VERSION }, SEP), "WHISPER", target)
    for _, quest in pairs(localQuests) do QueueQuest(quest, "WHISPER", target) end
    QueueMessage(table.concat({ "E", VERSION }, SEP), "WHISPER", target)
end

local function SendRequest()
    local channel = GroupChannel()
    if SyncActive() and channel and GetTime() - lastRequestAt >= 2 then
        lastRequestAt = GetTime()
        QueueMessage(table.concat({ "R", VERSION }, SEP), channel)
    end
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
    local previous = localQuests
    local current, itemMap = BuildLocalState()
    AnnounceSuccessfulTurnIns(current)
    AnnounceTransitions(previous, current)
    -- The first scan is a local baseline, not a broadcast snapshot. Existing
    -- members answer our targeted request; later quest-log changes are deltas.
    if baselineReady then QueueDelta(previous, current) end
    localQuests = current
    itemQuestKeys = itemMap
    baselineReady = true
end

local function ScheduleUpdate(delay)
    updateAt = GetTime() + (delay or UPDATE_DELAY)
end

local function TrimMemberObjectives(quest, count)
    for index in pairs(quest.objectives) do
        if type(index) == "number" and index > count then quest.objectives[index] = nil end
    end
end

local function ReceiveMessage(prefix, message, channel, sender)
    if prefix ~= PREFIX or not sender or not IsRosterMember(sender) then return end
    if NormalizeName(sender) == NormalizeName(UnitName("player")) then return end
    if not SyncActive() then return end

    local fields = Split(message)
    local kind = fields[1]
    local senderKey = NormalizeName(sender)

    if kind == "R" then
        QueueSnapshot(sender)
        return
    end

    local member = memberQuests[senderKey]
    if not member then
        member = { name = sender, quests = {}, completeSnapshot = false, updated = GetTime() }
        memberQuests[senderKey] = member
    end
    member.name = sender
    member.updated = GetTime()

    if kind == "B" then
        member.quests = {}
        member.completeSnapshot = false
    elseif kind == "E" then
        member.completeSnapshot = true
    elseif kind == "X" and fields[2] then
        member.quests[fields[2]] = nil
    elseif kind == "Q" and fields[2] then
        local key = fields[2]
        local quest = member.quests[key] or { objectives = {} }
        quest.key = key
        quest.title = fields[3] or "Unknown quest"
        quest.complete = fields[4] == "1"
        local count = tonumber(fields[5]) or 0
        TrimMemberObjectives(quest, count)
        member.quests[key] = quest
    elseif kind == "O" and fields[2] and tonumber(fields[3]) then
        local key, index = fields[2], tonumber(fields[3])
        local quest = member.quests[key] or { key = key, title = "Unknown quest", objectives = {} }
        quest.objectives[index] = { finished = fields[4] == "1", text = fields[5] or ("Objective " .. index) }
        member.quests[key] = quest
    end
end

local function CleanupRoster()
    local roster = CurrentRoster()
    for name in pairs(memberQuests) do
        if not roster[name] then memberQuests[name] = nil end
    end
    if not SyncActive() then
        wipe(outgoing)
        return
    end
    SendRequest()
end

local function ObjectiveProgress(objective)
    if not objective then return nil end
    local current, total = string.match(objective.text or "", "(%d+)%s*/%s*(%d+)")
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

local function MemberRowsForQuest(key, itemName)
    local rows = {}
    local roster = CurrentRoster()
    local playerKey = NormalizeName(UnitName("player"))
    for normalized, displayName in pairs(roster) do
        local quest, known
        if normalized == playerKey then
            quest, known = localQuests[key], true
        else
            local member = memberQuests[normalized]
            quest = member and member.quests[key]
            known = member and member.completeSnapshot
            if member and quest then known = true end
        end

        local status, complete
        if quest then
            local objective = MatchingObjective(quest, itemName)
            status = ObjectiveProgress(objective) or (quest.complete and "Complete" or "In progress")
            complete = (objective and objective.finished) or quest.complete
        elseif known then
            status = "Does not have quest"
        else
            status = "No sync data"
        end
        table.insert(rows, { name = displayName, status = status, complete = complete })
    end
    table.sort(rows, function(a, b)
        if NormalizeName(a.name) == playerKey then return true end
        if NormalizeName(b.name) == playerKey then return false end
        return string.lower(a.name) < string.lower(b.name)
    end)
    return rows
end

local function AddTooltipProgress(tooltip, link)
    if not tooltip or Setting("showGroupQuestTooltips", true) == false or not SyncActive() then return end
    local itemID = link and tonumber(string.match(link, "item:(%-?%d+)"))
    local questKeys = itemID and itemQuestKeys[itemID]
    if not questKeys or #questKeys == 0 then return end

    local marker = tostring(itemID) .. ":" .. table.concat(questKeys, ",")
    if tooltip.__aeGroupQuestMarker == marker then return end
    tooltip.__aeGroupQuestMarker = marker

    local itemName = GetItemInfo and GetItemInfo(link)
    tooltip:AddLine(" ")
    tooltip:AddLine("AutoQuest Group Progress", 0.35, 0.65, 1)
    for _, key in ipairs(questKeys) do
        local quest = localQuests[key]
        if quest then
            tooltip:AddLine(quest.title, 1, 0.82, 0.2)
            for _, row in ipairs(MemberRowsForQuest(key, itemName)) do
                if row.complete then
                    tooltip:AddDoubleLine("  " .. row.name, row.status, 0.82, 0.82, 0.82, 0.35, 1, 0.35)
                else
                    tooltip:AddDoubleLine("  " .. row.name, row.status, 0.82, 0.82, 0.82, 0.7, 0.7, 0.7)
                end
            end
        end
    end
    tooltip:Show()
end

local function HookTooltip(tooltip)
    if not tooltip then return end
    if tooltip.HookScript then
        tooltip:HookScript("OnTooltipCleared", function(self) self.__aeGroupQuestMarker = nil end)
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
        local title = GetQuestLogTitle(index)
        if title == acceptedSharedTitle then
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
driver:RegisterEvent("QUEST_LOG_UPDATE")
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
        HookTooltip(GameTooltip)
        HookTooltip(ItemRefTooltip)
        HookQuestReward()
        ScheduleUpdate(0)
    elseif event == "PLAYER_ENTERING_WORLD" then
        baselineReady = false
        rewardQuestTitle = nil
        wipe(pendingTurnIns)
        ScheduleUpdate(0.5)
        CleanupRoster()
    elseif event == "QUEST_LOG_UPDATE" then
        ScheduleUpdate()
    elseif event == "QUEST_ACCEPTED" then
        AutoShareQuest(arg1)
        ScheduleUpdate()
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
        CleanupRoster()
        ScheduleUpdate(0.5)
    elseif event == "CHAT_MSG_ADDON" then
        ReceiveMessage(arg1, arg2, arg3, arg4)
    end
end)

local sendElapsed = 0
driver:SetScript("OnUpdate", function(self, elapsed)
    local now = GetTime()
    if updateAt and now >= updateAt then
        updateAt = nil
        ProcessQuestUpdate()
    end

    for index = #pendingShares, 1, -1 do
        local entry = pendingShares[index]
        if now >= entry.at then
            table.remove(pendingShares, index)
            ProcessShare(entry)
        end
    end

    sendElapsed = sendElapsed + elapsed
    if sendElapsed < SEND_INTERVAL or #outgoing == 0 then return end
    sendElapsed = 0
    local entry = table.remove(outgoing, 1)
    if entry.channel == "WHISPER" or entry.channel == GroupChannel() then
        pcall(SendAddonMessage, PREFIX, entry.message, entry.channel, entry.target)
    end
end)

function Sync.RequestUpdate()
    ProcessQuestUpdate()
    SendRequest()
end

function Sync.GetMemberQuestData()
    return memberQuests
end
