----------------------------------------------------------------------
-- AutoQuest.lua
-- ============
-- AutoQuest module for the combined addon (WoW 3.3.5a APIs only).
-- Automatically accepts and completes quests when talking to NPCs,
-- based on the settings in AutoQuestConfig.lua.
--
--   * GOSSIP_SHOW   : turn in completable quests, accept available ones
--   * QUEST_GREETING: same, for quest-giver NPCs
--   * QUEST_DETAIL  : accept if safe; otherwise leave open for the player
--   * QUEST_PROGRESS: complete if ready; otherwise leave open
--   * QUEST_COMPLETE: choose the strongest upgrade reward, otherwise value
--
-- Safety: high-risk quest pattern list, max level difference check,
-- configurable daily/PvP policies, and holding SHIFT to temporarily disable.
-- Uses AutoCore.GetCharKey() for per-character config profiles.
----------------------------------------------------------------------

-- Namespace
AutoQuest = AutoQuest or {}
local AQ = AutoQuest

-- Saved variables (per character)
AQ.db = {}

-- Default settings if not present (fallback; corrected at ADDON_LOADED)
if AQ.db.enabled == nil then
    AQ.db.enabled = true
end

----------------------------------------------------------------------
-- Per-character config resolution
-- AutoQuestConfig.lua defines global scalar policies / highRiskQuests
-- plus a "characters" table keyed by
-- "Name-Realm" + a "default" profile. A profile's highRiskQuests are
-- ADDED on top of the global ones; profile scalars override global values.
-- Cached between events and invalidated whenever profile settings change.
----------------------------------------------------------------------
local activeConfig = nil

-- A quest is trivial once it is more than this many levels below you - the
-- point at which it stops being worth doing and the quest text greys out.
local TRIVIAL_LEVEL_GAP = 9

local function IsTrivialQuest(questLevel, playerLevel)
    if not questLevel or questLevel <= 0 then return false end
    playerLevel = playerLevel or UnitLevel("player")
    return (playerLevel - questLevel) > TRIVIAL_LEVEL_GAP
end

----------------------------------------------------------------------
-- Quick Abandon
-- Finds quests worth bulk-abandoning and clears them, the same rules and
-- flow as the standalone ClearQuests addon: always protects Prestige/
-- Mentorship quests, keeps whatever the options below say to keep, and
-- shows a confirmation list before anything is abandoned.
----------------------------------------------------------------------
-- Same resolution order as GetActiveConfig's own ResolveBoolean below (saved
-- setting, else the config file's default, else the hardcoded fallback), just
-- without forcing the result to a boolean - used for the whitelist, which is
-- a table. QuickAbandonFlag wraps this for the actual boolean options.
local function QuickAbandonSetting(key, fallback)
    local value = AutoCore.GetSetting("quest", key, nil)
    if value == nil then value = AutoQuestConfig and AutoQuestConfig[key] end
    if value == nil then value = fallback end
    return value
end

local function QuickAbandonFlag(key, fallback)
    return QuickAbandonSetting(key, fallback) ~= false
end

local function HasPartialProgress(questIndex)
    local numObjectives = GetNumQuestLeaderBoards(questIndex)
    if not numObjectives or numObjectives == 0 then return false end
    for i = 1, numObjectives do
        local description, _, isCompleted = GetQuestLogLeaderBoard(i, questIndex)
        if isCompleted then return true end
        if description then
            local current, total = description:match("(%d+)/(%d+)")
            if current and total and tonumber(current) and tonumber(current) > 0 then
                return true
            end
        end
    end
    return false
end

-- Case-insensitive, but still an exact match - "prestige: renewed" whitelists
-- "Prestige: Renewed" but not a quest that merely contains that text.
local function IsWhitelisted(title)
    local lowerTitle = string.lower(title)
    for _, entry in ipairs(QuickAbandonSetting("quickAbandonWhitelist", {}) or {}) do
        if string.lower(entry) == lowerTitle then return true end
    end
    return false
end

-- Returns true if this quest should be left alone.
local function QuickAbandonShouldKeep(title, level, questTag, isComplete, isDaily, playerLevel, questIndex)
    if title:match("Prestige") or title:match("Mentorship") then return true end

    local trivial = IsTrivialQuest(level, playerLevel)

    if QuickAbandonFlag("quickAbandonKeepPathToAscension", true) and title:match("Path to Ascension") then
        return true
    end
    if QuickAbandonFlag("quickAbandonKeepComplete", true) and isComplete == 1 then
        if not trivial or QuickAbandonFlag("quickAbandonKeepTrivialComplete", false) then return true end
    end
    if QuickAbandonFlag("quickAbandonKeepDaily", true) and isDaily == 1 then return true end
    if QuickAbandonFlag("quickAbandonKeepDungeon", true) and questTag == "Dungeon" then
        if not trivial or QuickAbandonFlag("quickAbandonKeepTrivialDungeon", false) then return true end
    end
    if QuickAbandonFlag("quickAbandonKeepPartialProgress", false) and HasPartialProgress(questIndex) then
        if not trivial or QuickAbandonFlag("quickAbandonKeepTrivialPartialProgress", false) then return true end
    end
    if IsWhitelisted(title) then return true end
    return false
end

-- Every entry currently in the quest log that Quick Abandon would abandon.
function AQ.GetQuickAbandonCandidates()
    local playerLevel = UnitLevel("player")
    local candidates = {}
    for i = 1, GetNumQuestLogEntries() do
        local title, level, questTag, _, isHeader, _, isComplete, isDaily = GetQuestLogTitle(i)
        if title and not isHeader and not QuickAbandonShouldKeep(title, level, questTag, isComplete, isDaily, playerLevel, i) then
            table.insert(candidates, { index = i, title = title, level = level or 0, tag = questTag or "" })
        end
    end
    return candidates
end

-- Abandons exactly the entries passed in (a snapshot from GetQuickAbandonCandidates,
-- taken right before this call so indices are still valid). Reverse order keeps
-- earlier indices correct as later ones are removed from the log.
function AQ.ExecuteQuickAbandon(candidates)
    if not candidates or #candidates == 0 then return 0 end
    for i = #candidates, 1, -1 do
        local quest = candidates[i]
        SelectQuestLogEntry(quest.index)
        SetAbandonQuest()
        AbandonQuest()
    end
    return #candidates
end

local function GetActiveConfig()
    if not activeConfig then
        local config = AutoQuestConfig
        if not config then
            return nil
        end

        local charKey = AutoCore.GetCharKey()
        local profile = AutoCore.GetProfile(config)
        if not profile then
            profile = config.default or {}
        end

        -- Merge global + profile high-risk patterns
        local highRiskQuests = {}
        for _, p in ipairs(config.highRiskQuests or {}) do
            table.insert(highRiskQuests, p)
        end
        for _, p in ipairs(profile.highRiskQuests or {}) do
            table.insert(highRiskQuests, p)
        end

        -- Profile overrides for scalars
        local disableOnShift = profile.disableOnShift
        if disableOnShift == nil then
            disableOnShift = config.disableOnShift
        end
        if disableOnShift == nil then
            disableOnShift = true
        end

        local function ResolveBoolean(key, fallback)
            local value = profile[key]
            if value == nil then
                value = config[key]
            end
            if value == nil then
                value = fallback
            end
            return value ~= false
        end

        activeConfig = {
            enabled        = ResolveBoolean("enabled", true),
            acceptTrivialQuests = ResolveBoolean("acceptTrivialQuests", true),
            disableOnShift = disableOnShift,
            acceptQuests   = ResolveBoolean("acceptQuests", true),
            turnInQuests   = ResolveBoolean("turnInQuests", false),
            autoSelectRewards = ResolveBoolean("autoSelectRewards", false),
            acceptDailyQuests = ResolveBoolean("acceptDailyQuests", true),
            turnInDailyQuests = ResolveBoolean("turnInDailyQuests", false),
            acceptPvPQuests   = ResolveBoolean("acceptPvPQuests", false),
            turnInPvPQuests   = ResolveBoolean("turnInPvPQuests", false),
            highRiskQuests = highRiskQuests,
            charKey        = charKey,
        }
    end
    return activeConfig
end

function AQ.ClearConfigCache()
    activeConfig = nil
end

function AQ.ApplyProfile()
    if AutoCore and AutoCore.GetProfileSection then
        AQ.db = AutoCore.GetProfileSection("quest", true)
    end
    if AQ.db.enabled == nil then AQ.db.enabled = (AutoQuestConfig or {}).enabled ~= false end
    if AQ.Markers and AQ.Markers.ApplyProfile then AQ.Markers.ApplyProfile() end
    if AQ.Map and AQ.Map.ApplyProfile then AQ.Map.ApplyProfile() end
    if AQ.GroupSync and AQ.GroupSync.ApplyProfile then AQ.GroupSync.ApplyProfile() end
end

----------------------------------------------------------------------
-- Quest DB resolution (shared by QuestMarkers and QuestMap)
-- AscensionQuestLocationDB (Quest/QuestDatabase.lua) is keyed by questID.
-- Some database entries share a title across difficulties/phases (e.g. the
-- three "Spirit Wars: Reclaiming Auchindoun" tiers), so questID is preferred
-- whenever the client provides one; title is a database compatibility lookup
-- for 3.3.5 quest-log entries that do not report a questID.
----------------------------------------------------------------------
local questEntriesByTitle = nil

local function BuildQuestTitleIndex()
    questEntriesByTitle = {}
    if type(AscensionQuestLocationDB) ~= "table" then return end
    for entryQuestID, entry in pairs(AscensionQuestLocationDB) do
        local title = entry.title
        if title and title ~= "" then
            local bucket = questEntriesByTitle[title]
            if not bucket then
                bucket = {}
                questEntriesByTitle[title] = bucket
            end
            table.insert(bucket, { id = entryQuestID, entry = entry })
        end
    end
end

-- Returns a list of { id = questID, entry = AscensionQuestLocationDB[questID] }
-- matches for the given quest-log questID/title, or an empty table if none.
function AQ.ResolveQuestEntries(questID, title)
    if type(AscensionQuestLocationDB) ~= "table" then return {} end

    if questID then
        local entry = AscensionQuestLocationDB[questID]
        if entry then
            return { { id = questID, entry = entry } }
        end
    end

    if not title or title == "" then return {} end

    if not questEntriesByTitle then
        BuildQuestTitleIndex()
    end
    return questEntriesByTitle[title] or {}
end

----------------------------------------------------------------------
-- High-risk quest check: title matches any configured Lua pattern
----------------------------------------------------------------------
local function IsHighRiskQuest(name)
    if not name then return false end
    local cfg = GetActiveConfig()
    if not cfg then return false end
    for _, pattern in ipairs(cfg.highRiskQuests or {}) do
        if name:match(pattern) then
            return true
        end
    end
    return false
end

local function DebugSkip(action, title, reason)
    AutoCore.Debug("Quest", "Skipped " .. action .. " for '" .. tostring(title or "unknown quest") .. "': " .. tostring(reason))
end

local function IsDailyFrequency(frequency)
    if frequency == nil then return false end
    if frequency == true then return true end
    if QUEST_FREQUENCY_DAILY and frequency == QUEST_FREQUENCY_DAILY then
        return true
    end
    return frequency == 1 or frequency == "DAILY" or frequency == "Daily"
end

-- Quest-detail APIs vary between 3.3.5a and Ascension. Every optional call
-- is guarded so an unavailable/custom signature cannot interrupt quest UI.
local function GetDetailQuestMetadata()
    local metadata = {
        level = nil,
        isDaily = false,
        isPvP = false,
    }

    if GetQuestLevel then
        local ok, level = pcall(GetQuestLevel)
        if ok and type(level) == "number" then
            metadata.level = level
        end
    end

    if GetQuestFrequency then
        local ok, frequency = pcall(GetQuestFrequency)
        if ok then
            metadata.isDaily = IsDailyFrequency(frequency)
        end
    end

    if GetQuestTagInfo then
        local questID = nil
        if GetQuestID then
            local ok, id = pcall(GetQuestID)
            if ok then questID = id end
        end

        local ok, tagName, tagID, worldQuestType
        if questID then
            ok, tagName, tagID, worldQuestType = pcall(GetQuestTagInfo, questID)
        else
            ok, tagName, tagID, worldQuestType = pcall(GetQuestTagInfo)
        end

        if ok then
            local pvpLabel = type(PVP) == "string" and PVP or nil
            -- pairs is intentional: optional return values may contain nil
            -- gaps, which would make ipairs stop before later metadata.
            for _, value in pairs({ tagName, tagID, worldQuestType }) do
                if value == "PvP" or (pvpLabel and value == pvpLabel) then
                    metadata.isPvP = true
                    break
                end
            end
        end
    end

    return metadata
end

----------------------------------------------------------------------
-- Pre-accept check: only title + level are knowable at this point
----------------------------------------------------------------------
local function ShouldAutoAcceptWithLevel(title, level, isDaily, isPvP)
    if not title or title == "" then return false, "missing quest title" end
    local cfg = GetActiveConfig()
    if not cfg or not cfg.acceptQuests then
        return false, "quest acceptance is disabled"
    end
    if IsHighRiskQuest(title) then
        return false, "title matches a high-risk pattern"
    end
    if isDaily and not cfg.acceptDailyQuests then
        return false, "daily quest acceptance is disabled"
    end
    if isPvP and not cfg.acceptPvPQuests then
        return false, "PvP quest acceptance is disabled"
    end
    if IsTrivialQuest(level) and not cfg.acceptTrivialQuests then
        return false, "quest is trivial (more than " .. TRIVIAL_LEVEL_GAP .. " levels below you)"
    end
    return true, nil
end

local function ShouldAutoAccept()
    local title = GetTitleText()
    local metadata = GetDetailQuestMetadata()
    return ShouldAutoAcceptWithLevel(title, metadata.level, metadata.isDaily, metadata.isPvP)
end

----------------------------------------------------------------------
-- Checks whether `title` is turn-in-ready in the quest log (correct
-- 3.3.5a field order: title, level, questTag, suggestedGroup, isHeader,
-- isCollapsed, isComplete, isDaily, questID). Applies configured daily,
-- PvP, and level-diff policies and confirms actual completion via
-- isComplete/leaderboards.
----------------------------------------------------------------------
local function IsQuestReadyToTurnIn(title)
    if not title or title == "" then return false, "missing quest title" end
    local cfg = GetActiveConfig()
    if not cfg or not cfg.turnInQuests then
        return false, "quest turn-in is disabled"
    end
    if IsHighRiskQuest(title) then
        return false, "title matches a high-risk pattern"
    end

    local playerLevel = UnitLevel("player")
    local foundTitle = false
    local lastReason = "quest is not in the quest log"

    for i = 1, GetNumQuestLogEntries() do
        local questTitle, level, questTag, suggestedGroup, isHeader, isCollapsed, isComplete, isDaily = GetQuestLogTitle(i)

        if not isHeader and questTitle == title then
            foundTitle = true
            if isDaily and not cfg.turnInDailyQuests then
                lastReason = "daily quest turn-in is disabled"
            elseif questTag == "PvP" and not cfg.turnInPvPQuests then
                lastReason = "PvP quest turn-in is disabled"
            elseif IsTrivialQuest(level, playerLevel) and not cfg.acceptTrivialQuests then
                lastReason = "quest is trivial (more than " .. TRIVIAL_LEVEL_GAP .. " levels below you)"
            elseif (isComplete == 1) or (GetNumQuestLeaderBoards(i) == 0) then
                return true, nil
            else
                lastReason = "quest objectives are incomplete"
            end
        end
    end
    return false, foundTitle and lastReason or "quest is not in the quest log"
end

-- Used for progress / complete (quest IS in the log, full info available)
local function ShouldAutoComplete()
    local title = GetTitleText()
    return IsQuestReadyToTurnIn(title)
end

----------------------------------------------------------------------
-- Select the strongest complete-set upgrade reward, or the highest total
-- vendor value if no reward is an upgrade. Ring and weapon rewards are
-- evaluated with their best legal partner from bags/equipped gear. Returns
-- nil when item data is incomplete so the
-- player keeps control instead of the addon guessing.
----------------------------------------------------------------------
local function GetBestQuestReward()
    local numChoices = GetNumQuestChoices()
    if not numChoices or numChoices <= 0 then return 1, "only reward" end

    local rewards = {}
    local missingData = false
    for i = 1, numChoices do
        local name, texture, count = GetQuestItemInfo("choice", i)
        local link = GetQuestItemLink("choice", i)
        local vendorPrice = nil
        if link then
            vendorPrice = select(11, GetItemInfo(link))
        end
        if not link or not name or vendorPrice == nil then
            missingData = true
        else
            local isUpgrade, newScore, equippedScore = false, 0, 0
            if AutoUpgrade and AutoUpgrade.EvaluateItem then
                isUpgrade, newScore, equippedScore = AutoUpgrade.EvaluateItem(
                    link, { questType = "choice", questIndex = i }
                )
            end
            table.insert(rewards, {
                index = i,
                link = link,
                isUpgrade = isUpgrade,
                gain = (newScore or 0) - (equippedScore or 0),
                value = vendorPrice * (count or 1),
            })
        end
    end

    if missingData or #rewards ~= numChoices then return nil end

    local bestUpgrade = nil
    local bestValue = nil
    for _, reward in ipairs(rewards) do
        if reward.isUpgrade and (not bestUpgrade or reward.gain > bestUpgrade.gain) then
            bestUpgrade = reward
        end
        if not bestValue or reward.value > bestValue.value then
            bestValue = reward
        end
    end
    if bestUpgrade then return bestUpgrade.index, "best upgrade", bestUpgrade.link end
    return bestValue and bestValue.index, "highest vendor value", bestValue and bestValue.link
end

----------------------------------------------------------------------
-- Event handling (quests) — passive, no InteractUnit, no taint
----------------------------------------------------------------------

-- Same-visit dedupe: prevents re-selecting a quest we already accepted
-- this gossip session, in case the server re-fires GOSSIP_SHOW after
-- an accept.
local acceptedQuests = {}
local interactionNPC = nil
local acceptedResetAt = nil

local function BeginQuestInteraction()
    local npcGUID = UnitGUID and UnitGUID("npc") or nil
    local delayedResetExpired = acceptedResetAt and GetTime() >= acceptedResetAt
    local changedNPC = interactionNPC and npcGUID and interactionNPC ~= npcGUID

    if delayedResetExpired or changedNPC then
        wipe(acceptedQuests)
    end

    interactionNPC = npcGUID or interactionNPC
    acceptedResetAt = nil
end

----------------------------------------------------------------------
-- Single-pass quest processors
-- Each scans the currently open gossip/greeting window, selects at most
-- one quest (turn-ins first, then acceptances), and returns true if it
-- selected something. Selecting a quest opens QUEST_DETAIL/QUEST_PROGRESS
-- and hides the window until that step resolves, so only one selection is
-- possible per pass - the pump below re-runs these once the window returns.
----------------------------------------------------------------------
local function ProcessGossipQuests()
    -- 1. Prefer completable turn-ins (4 fields per active quest on 3.3.5).
    --    Don't trust the gossip API's own isComplete flag here - check the
    --    quest log directly via IsQuestReadyToTurnIn.
    local on_quest = 1
    repeat
        local name = select(1 + ((on_quest - 1) * 4), GetGossipActiveQuests())
        if name and type(name) == "string" then
            local ready, reason = IsQuestReadyToTurnIn(name)
            if ready then
                SelectGossipActiveQuest(on_quest)
                return true
            end
            DebugSkip("turn-in", name, reason)
        end
        on_quest = on_quest + 1
    until not name

    -- 2. Take an available quest (5 fields per available quest on 3.3.5),
    --    filtered by title/level, skipping anything already accepted this visit.
    on_quest = 1
    repeat
        local name, level, isTrivial, isDaily = select(1 + ((on_quest - 1) * 5), GetGossipAvailableQuests())
        if name and type(name) == "string" and not acceptedQuests[name] then
            local shouldAccept, reason = ShouldAutoAcceptWithLevel(name, level, IsDailyFrequency(isDaily), false)
            if shouldAccept then
                acceptedQuests[name] = true
                SelectGossipAvailableQuest(on_quest)
                return true
            end
            DebugSkip("acceptance", name, reason)
        end
        on_quest = on_quest + 1
    until not name
    return false
end

local function ProcessGreetingQuests()
    local numActive = GetNumActiveQuests()
    for i = 1, numActive do
        local title, isComplete = GetActiveTitle(i)
        if isComplete then
            local ready, reason = IsQuestReadyToTurnIn(title)
            if ready then
                SelectActiveQuest(i)
                return true
            end
            DebugSkip("turn-in", title, reason)
        end
    end

    local numAvailable = GetNumAvailableQuests()
    for i = 1, numAvailable do
        local title = GetAvailableTitle(i)
        local level = GetAvailableLevel and GetAvailableLevel(i) or nil
        if title and not acceptedQuests[title] then
            local shouldAccept, reason = ShouldAutoAcceptWithLevel(title, level, false, false)
            if shouldAccept then
                acceptedQuests[title] = true
                SelectAvailableQuest(i)
                return true
            end
            DebugSkip("acceptance", title, reason)
        end
    end
    return false
end

----------------------------------------------------------------------
-- Accept-all pump
-- The server does not reliably re-fire GOSSIP_SHOW/QUEST_GREETING after
-- each accept on Ascension, which would leave multi-quest NPCs half-done
-- and force the player to re-talk. Instead, while the window is open we
-- re-run the processor on a throttle and keep selecting the next eligible
-- quest until none remain. This never opens a window itself (no InteractUnit,
-- no taint) - it only drives one that is already showing.
----------------------------------------------------------------------
local PUMP_INTERVAL = 0.1   -- seconds between passes; lets the window repopulate
local PUMP_TIMEOUT  = 2     -- stop after this long with no window open (accept round-trip is well under 1s)
local pumpAccum = 0
local pumpDeadline = 0

-- Forward-declared; assigned after GetActiveConfig/AQ.db are in scope below.
local IsAutomationActive

local questPump = CreateFrame("Frame")
questPump:Hide()

local function StartQuestPump()
    pumpAccum = 0
    pumpDeadline = GetTime() + PUMP_TIMEOUT
    questPump:Show()
end

questPump:SetScript("OnUpdate", function(self, elapsed)
    pumpAccum = pumpAccum + elapsed
    if pumpAccum < PUMP_INTERVAL then return end
    pumpAccum = 0

    if not (IsAutomationActive and IsAutomationActive()) then
        self:Hide()
        return
    end

    local gossipOpen = GossipFrame and GossipFrame:IsShown()
    local greetingOpen = QuestFrameGreetingPanel and QuestFrameGreetingPanel:IsShown()

    if gossipOpen then
        -- Window is up: if nothing is left to select, we're done for good.
        if ProcessGossipQuests() then
            pumpDeadline = GetTime() + PUMP_TIMEOUT
        else
            self:Hide()
        end
    elseif greetingOpen then
        if ProcessGreetingQuests() then
            pumpDeadline = GetTime() + PUMP_TIMEOUT
        else
            self:Hide()
        end
    elseif GetTime() > pumpDeadline then
        -- No window open past the grace period: the interaction really ended
        -- (or a QUEST_DETAIL/COMPLETE panel is waiting on the player). Stop.
        self:Hide()
    end
end)

-- Assigns the forward-declared upvalue used by the pump: automation runs only
-- when the module is enabled by config and SHIFT is not suppressing it.
function IsAutomationActive()
    local cfg = GetActiveConfig()
    if not (AQ.db.enabled and cfg and cfg.enabled) then return false end
    if IsShiftKeyDown() and cfg.disableOnShift then return false end
    return true
end

local questFrame = CreateFrame("Frame")
questFrame:RegisterEvent("GOSSIP_SHOW")
questFrame:RegisterEvent("QUEST_GREETING")
questFrame:RegisterEvent("QUEST_DETAIL")
questFrame:RegisterEvent("QUEST_PROGRESS")
questFrame:RegisterEvent("QUEST_COMPLETE")
questFrame:RegisterEvent("ADDON_LOADED")
questFrame:RegisterEvent("GOSSIP_CLOSED")
questFrame:RegisterEvent("QUEST_FINISHED")

questFrame:SetScript("OnEvent", function(self, event, ...)
    local arg1 = ...
    if event == "ADDON_LOADED" then
        if arg1 == "AutoEverything" then
            AQ.db = AutoCore.GetProfileSection("quest", true)
            if AQ.db.enabled == nil then
                AQ.db.enabled = (AutoQuestConfig or {}).enabled ~= false
            end
            -- Confirm the saved state was loaded so the user knows the
            -- on/off toggle persists across reloads/logouts.
            AutoCore.Debug("Quest", "Saved state loaded.")
        end
        return
    end

    if event == "GOSSIP_CLOSED" or event == "QUEST_FINISHED" then
        -- Accepting a quest often closes the quest frame and immediately
        -- reopens gossip for the same NPC. Delay cleanup so that refresh
        -- keeps the dedupe table; a later interaction resets it.
        acceptedResetAt = GetTime() + 1
        return
    end

    local cfg = GetActiveConfig()
    if not (AQ.db.enabled and cfg and cfg.enabled) then
        return
    end

    if IsShiftKeyDown() and cfg.disableOnShift then return end

    if event == "GOSSIP_SHOW" then
        BeginQuestInteraction()
        -- Do one pass now for immediate feedback, then let the pump chain
        -- through the rest of this NPC's quests without the player re-talking.
        ProcessGossipQuests()
        StartQuestPump()
        return
    end

    if event == "QUEST_GREETING" then
        BeginQuestInteraction()
        ProcessGreetingQuests()
        StartQuestPump()
        return
    end

    if event == "QUEST_DETAIL" then
        local shouldAccept, reason = ShouldAutoAccept()
        if shouldAccept then
            AcceptQuest()
        else
            -- Leave declined quests open so the player can review/accept them.
            DebugSkip("acceptance", GetTitleText(), reason)
        end
        return
    end

    if event == "QUEST_PROGRESS" then
        local shouldComplete, reason = ShouldAutoComplete()
        if IsQuestCompletable() and shouldComplete then
            CompleteQuest()
        else
            -- Leave incomplete/filtered quests open for manual interaction.
            DebugSkip("turn-in", GetTitleText(), reason or "quest is not completable")
        end
        return
    end

    if event == "QUEST_COMPLETE" then
        local shouldComplete, reason = ShouldAutoComplete()
        local numChoices = GetNumQuestChoices()
        if shouldComplete and numChoices == 0 then
            GetQuestReward(1)
        elseif shouldComplete and cfg.autoSelectRewards then
            local rewardIndex, rewardReason, rewardLink = GetBestQuestReward()
            if rewardIndex then
                AutoCore.Info("Quest", "Choosing " .. tostring(rewardLink or "reward") .. " (" .. rewardReason .. ").")
                GetQuestReward(rewardIndex)
            else
                DebugSkip("reward selection", GetTitleText(), "reward item data is not available yet")
            end
        elseif shouldComplete then
            DebugSkip("reward selection", GetTitleText(), "automatic reward selection is disabled")
        else
            DebugSkip("turn-in", GetTitleText(), reason)
        end
        return
    end
end)

----------------------------------------------------------------------
-- Client quest API probe
--
-- Ascension's 3.3.5 client may expose server-backed quest POIs in addition
-- to the normal quest log. Keep this diagnostic read-only and guard every
-- optional API so custom/missing client functions cannot break AutoQuest.
----------------------------------------------------------------------
local activeDebugReport = nil

local function DebugPrint(line)
    if activeDebugReport then
        table.insert(activeDebugReport, tostring(line))
    else
        print(line)
    end
end

local function DebugValue(value)
    if value == nil then return "<nil>" end
    if type(value) == "string" then return '"' .. value .. '"' end
    return tostring(value)
end

local function DebugCall(label, func, ...)
    if type(func) ~= "function" then
        DebugPrint("  " .. label .. ": unavailable")
        return nil
    end

    local ok, a, b, c, d, e, f, g, h = pcall(func, ...)
    if not ok then
        DebugPrint("  " .. label .. ": ERROR " .. tostring(a))
        return nil
    end

    local values = { a, b, c, d, e, f, g, h }
    local last = 0
    for i = 1, 8 do
        if values[i] ~= nil then last = i end
    end

    if last == 0 then
        DebugPrint("  " .. label .. ": OK (no return values)")
    else
        local output = {}
        for i = 1, last do
            output[i] = DebugValue(values[i])
        end
        DebugPrint("  " .. label .. ": " .. table.concat(output, ", "))
    end

    return a, b, c, d, e, f, g, h
end

function AQ.DebugQuestClient()
    -- WoW addons cannot write arbitrary files. Saving an array in the addon's
    -- account-wide SavedVariables produces a readable report after logout or
    -- /reload at WTF/Account/<account>/SavedVariables/AutoEverything.lua.
    AutoEverythingDB = AutoEverythingDB or {}
    activeDebugReport = {}
    AutoEverythingDB.questDebugReport = activeDebugReport

    DebugPrint("AutoQuest client probe")
    DebugPrint("Character: " .. DebugValue(UnitName and UnitName("player") or nil)
        .. ", realm: " .. DebugValue(GetRealmName and GetRealmName() or nil))
    DebugPrint("Results are raw client values; <nil> gaps are preserved.")

    -- GetPlayerMapPosition reports coordinates for the currently selected
    -- map, so first select the player's current zone when the API exists.
    DebugCall("SetMapToCurrentZone()", SetMapToCurrentZone)
    DebugPrint("Map/player")
    DebugPrint("  zone=" .. DebugValue(GetZoneText and GetZoneText() or nil)
        .. ", subzone=" .. DebugValue(GetSubZoneText and GetSubZoneText() or nil))
    local originalContinent = GetCurrentMapContinent and GetCurrentMapContinent() or nil
    local originalZone = GetCurrentMapZone and GetCurrentMapZone() or nil
    local originalDungeonLevel = GetCurrentMapDungeonLevel and GetCurrentMapDungeonLevel() or nil
    DebugCall("GetCurrentMapContinent()", GetCurrentMapContinent)
    DebugCall("GetCurrentMapZone()", GetCurrentMapZone)
    DebugCall("GetCurrentMapAreaID()", GetCurrentMapAreaID)
    DebugCall("GetCurrentMapDungeonLevel()", GetCurrentMapDungeonLevel)
    DebugCall("GetPlayerMapPosition(player)", GetPlayerMapPosition, "player")

    DebugPrint("Target")
    local targetGUID = UnitGUID and UnitGUID("target") or nil
    -- Ascension uses creature entries above the stock 16-bit range, so read
    -- all six entry hex digits from the 3.3.5 creature GUID (0xF130EEEEEE...).
    local npcID = targetGUID and tonumber(string.sub(targetGUID, 7, 12), 16) or nil
    DebugPrint("  name=" .. DebugValue(UnitName and UnitName("target") or nil)
        .. ", guid=" .. DebugValue(targetGUID)
        .. ", npcID=" .. DebugValue(npcID))

    DebugPrint("Quest API availability")
    local apiNames = {
        "GetQuestLink",
        "GetQuestID",
        "GetQuestTagInfo",
        "GetQuestWorldMapAreaID",
        "GetNumQuestPOIWorldMap",
        "QuestPOIGetQuestIDByVisibleIndex",
        "QuestPOIGetIconInfo",
        "QuestMapUpdateAllQuests",
        "SetMapByID",
    }
    for _, name in ipairs(apiNames) do
        DebugPrint("  " .. name .. "=" .. (type(_G[name]) == "function" and "function" or "unavailable"))
    end

    -- Ask the client to refresh its POI cache before querying it. The call is
    -- optional and its exact Ascension signature/result is deliberately shown.
    local refreshedPOICount = DebugCall("QuestMapUpdateAllQuests()", QuestMapUpdateAllQuests)

    DebugPrint("Active quest log")
    local numEntries, numQuests = GetNumQuestLogEntries()
    local destinationProbes = {}
    DebugPrint("  entries=" .. DebugValue(numEntries) .. ", quests=" .. DebugValue(numQuests))

    for questLogIndex = 1, (numEntries or 0) do
        local title, level, questTag, suggestedGroup, isHeader, isCollapsed,
            isComplete, isDaily, questID = GetQuestLogTitle(questLogIndex)

        if title and not isHeader then
            DebugPrint("Quest log " .. questLogIndex .. ": " .. tostring(title))
            DebugPrint("  level=" .. DebugValue(level)
                .. ", tag=" .. DebugValue(questTag)
                .. ", group=" .. DebugValue(suggestedGroup)
                .. ", collapsed=" .. DebugValue(isCollapsed)
                .. ", complete=" .. DebugValue(isComplete)
                .. ", daily=" .. DebugValue(isDaily)
                .. ", questID=" .. DebugValue(questID))

            DebugCall("GetQuestLink(" .. questLogIndex .. ")", GetQuestLink, questLogIndex)
            if questID then
                local destinationMapID, destinationFloor = DebugCall(
                    "GetQuestWorldMapAreaID(" .. questID .. ")",
                    GetQuestWorldMapAreaID,
                    questID
                )
                DebugCall("QuestPOIGetIconInfo(" .. questID .. ")", QuestPOIGetIconInfo, questID)
                table.insert(destinationProbes, {
                    questID = questID,
                    questLogIndex = questLogIndex,
                    title = title,
                    mapID = destinationMapID,
                    floor = destinationFloor,
                })
            end

            local objectiveCount = GetNumQuestLeaderBoards(questLogIndex) or 0
            DebugPrint("  objectives=" .. tostring(objectiveCount))
            for objectiveIndex = 1, objectiveCount do
                local description, objectiveType, objectiveComplete =
                    GetQuestLogLeaderBoard(objectiveIndex, questLogIndex)
                DebugPrint("    [" .. objectiveIndex .. "] text=" .. DebugValue(description)
                    .. ", type=" .. DebugValue(objectiveType)
                    .. ", complete=" .. DebugValue(objectiveComplete))
            end
        end
    end

    DebugPrint("Visible world-map quest POIs")
    local poiCount = DebugCall("GetNumQuestPOIWorldMap()", GetNumQuestPOIWorldMap)
    if type(poiCount) ~= "number" and type(refreshedPOICount) == "number" then
        poiCount = refreshedPOICount
        DebugPrint("  using QuestMapUpdateAllQuests() count=" .. tostring(poiCount))
    end
    if type(poiCount) == "number" then
        for visibleIndex = 1, poiCount do
            local questID = DebugCall(
                "QuestPOIGetQuestIDByVisibleIndex(" .. visibleIndex .. ")",
                QuestPOIGetQuestIDByVisibleIndex,
                visibleIndex
            )
            if questID then
                DebugCall("QuestPOIGetIconInfo(" .. questID .. ")", QuestPOIGetIconInfo, questID)
            end
        end
    end

    -- POI coordinates depend on the selected world map. Probe each quest on
    -- the map reported by GetQuestWorldMapAreaID, then restore the player's
    -- original map selection. This is diagnostic only and creates no waypoint.
    DebugPrint("Destination-map POI probes")
    if type(SetMapByID) ~= "function" then
        DebugPrint("  unavailable: SetMapByID is not a function")
    else
        for _, probe in ipairs(destinationProbes) do
            if type(probe.mapID) == "number" and probe.mapID > 0 then
                DebugPrint("Quest " .. tostring(probe.questID) .. ": " .. tostring(probe.title))
                DebugPrint("  requested mapID=" .. DebugValue(probe.mapID)
                    .. ", floor=" .. DebugValue(probe.floor))
                DebugCall("SetMapByID(" .. probe.mapID .. ")", SetMapByID, probe.mapID)
                DebugCall("selected GetCurrentMapAreaID()", GetCurrentMapAreaID)
                DebugCall("selected GetCurrentMapDungeonLevel()", GetCurrentMapDungeonLevel)
                DebugCall("QuestMapUpdateAllQuests()", QuestMapUpdateAllQuests)
                DebugCall("destination QuestPOIGetIconInfo(" .. probe.questID .. ")",
                    QuestPOIGetIconInfo, probe.questID)
            end
        end
    end

    if type(SetMapZoom) == "function" and originalContinent and originalZone then
        DebugCall("restore SetMapZoom(" .. originalContinent .. ", " .. originalZone .. ")",
            SetMapZoom, originalContinent, originalZone)
        if type(SetDungeonMapLevel) == "function" and originalDungeonLevel then
            DebugCall("restore SetDungeonMapLevel(" .. originalDungeonLevel .. ")",
                SetDungeonMapLevel, originalDungeonLevel)
        end
        DebugCall("restore QuestMapUpdateAllQuests()", QuestMapUpdateAllQuests)
    else
        DebugCall("restore SetMapToCurrentZone()", SetMapToCurrentZone)
        DebugCall("restore QuestMapUpdateAllQuests()", QuestMapUpdateAllQuests)
    end

    DebugPrint("AutoQuest client probe complete.")

    activeDebugReport = nil
    print("|cff00ff00AutoQuest:|r client probe captured. Run /reload or log out to write it to disk.")
    print("  Copy questDebugReport from this addon's SavedVariables file after /reload.")
end

----------------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------------
SLASH_AUTOQUEST1 = "/autoquest"
SLASH_AUTOQUEST2 = "/aq"

SlashCmdList["AUTOQUEST"] = function(msg)
    msg = string.lower(strtrim(msg or ""))

    if msg == "on" then
        AQ.db.enabled = true
        AutoCore.NotifyProfileChanged("quest")
        AutoCore.Info("Quest", "Auto-quest enabled (saved - will persist on reload).")
    elseif msg == "off" then
        AQ.db.enabled = false
        AutoCore.NotifyProfileChanged("quest")
        AutoCore.Info("Quest", "Auto-quest disabled (saved - will persist on reload).")
    elseif msg == "debugquest" then
        AQ.DebugQuestClient()
    elseif msg == "markers on" then
        if AQ.Markers and AQ.Markers.SetEnabled then
            AQ.Markers.SetEnabled(true)
        else
            AutoCore.Warn("Quest", "Nameplate markers are unavailable.")
        end
    elseif msg == "markers off" then
        if AQ.Markers and AQ.Markers.SetEnabled then
            AQ.Markers.SetEnabled(false)
        else
            AutoCore.Warn("Quest", "Nameplate markers are unavailable.")
        end
    elseif msg == "markers debug" then
        if AQ.Markers and AQ.Markers.Debug then
            AQ.Markers.Debug()
        else
            AutoCore.Warn("Quest", "Nameplate markers are unavailable.")
        end
    elseif msg == "pins on" then
        if AQ.Map and AQ.Map.SetEnabled then
            AQ.Map.SetEnabled(true)
        else
            AutoCore.Warn("Quest", "Quest map pins are unavailable.")
        end
    elseif msg == "pins off" then
        if AQ.Map and AQ.Map.SetEnabled then
            AQ.Map.SetEnabled(false)
        else
            AutoCore.Warn("Quest", "Quest map pins are unavailable.")
        end
    elseif msg == "pins debug" then
        if AQ.Map and AQ.Map.Debug then
            AQ.Map.Debug()
        else
            AutoCore.Warn("Quest", "Quest map pins are unavailable.")
        end
    elseif msg == "whoami" then
        local cfg = GetActiveConfig()
        if not cfg then
            print("|cff00ff00AutoQuest:|r AutoQuestConfig not loaded.")
        else
            print("|cff00ff00AutoQuest:|r Character key: " .. cfg.charKey)
            print("  acceptTrivialQuests: " .. tostring(cfg.acceptTrivialQuests))
            print("  disableOnShift: " .. tostring(cfg.disableOnShift))
            print("  acceptQuests / turnInQuests: " .. tostring(cfg.acceptQuests) .. " / " .. tostring(cfg.turnInQuests))
            print("  autoSelectRewards: " .. tostring(cfg.autoSelectRewards))
            print("  acceptDaily / turnInDaily: " .. tostring(cfg.acceptDailyQuests) .. " / " .. tostring(cfg.turnInDailyQuests))
            print("  acceptPvP / turnInPvP: " .. tostring(cfg.acceptPvPQuests) .. " / " .. tostring(cfg.turnInPvPQuests))
            print("  High-risk patterns: " .. #cfg.highRiskQuests)
        end
    else
        if AQ.db.enabled then
            AutoCore.Info("Quest", "Auto-quest enabled.")
        else
            AutoCore.Info("Quest", "Auto-quest disabled.")
        end
        AutoCore.Info("Quest", "Commands:")
        print("  /autoquest on    - Enable auto-quest")
        print("  /autoquest off   - Disable auto-quest")
        print("  /autoquest debugquest - Save quest, objective, map, target, and POI API data")
        print("  /autoquest markers on|off - Toggle skull, coin, turn-in, and accept nameplate badges")
        print("  /autoquest markers debug - Diagnose the targeted objective NPC nameplate")
        print("  /autoquest pins on|off - Toggle active quest locations on the map and minimap")
        print("  /autoquest pins debug - Diagnose active quest map/minimap matching")
        print("  /autoquest whoami - Show which config profile this character is using")
    end
end

-- QUEST_ACCEPT_CONFIRM only exposes the sender and title on this client. The
-- group-sync extension uses this conservative public check before confirming a
-- shared quest: normal acceptance must be enabled and high-risk titles remain
-- manual. Daily/PvP metadata is not available until the quest detail exists.
function AQ.ShouldAutoAcceptShared(title)
    if not AQ.db or AQ.db.enabled == false then
        return false, "AutoQuest is disabled"
    end
    local cfg = GetActiveConfig()
    if not cfg or not cfg.enabled or not cfg.acceptQuests then
        return false, "quest acceptance is disabled"
    end
    if IsHighRiskQuest(title) then
        return false, "title matches a high-risk pattern"
    end
    return true
end
