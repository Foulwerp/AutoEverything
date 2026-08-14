----------------------------------------------------------------------
-- Activity.lua - opt-in Dungeon Finder and battleground conveniences.
----------------------------------------------------------------------

AutoActivity = AutoActivity or {}
local Activity = AutoActivity
local config = AutoCoreConfig or {}

BINDING_HEADER_AUTOMATION_UTILITIES = "Automation Utilities"
BINDING_NAME_AUTOMATION_TARGET_ENEMY_FLAG = "Target Enemy Flag Carrier"
BINDING_NAME_AUTOMATION_DROP_FLAG_AURA = "Drop Flag or Selected Aura"

local function Setting(key, fallback)
    if AutoCore and AutoCore.GetSetting then
        return AutoCore.GetSetting("core", key, config[key] ~= nil and config[key] or fallback)
    end
    if config[key] ~= nil then return config[key] end
    return fallback
end

----------------------------------------------------------------------
-- Reusable cancellable departure countdown
----------------------------------------------------------------------
local countdown = { active = false }
local countdownFrame = CreateFrame("Frame", nil, UIParent)
countdownFrame:SetSize(320, 104)
countdownFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 170)
countdownFrame:SetFrameStrata("DIALOG")
countdownFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
countdownFrame:Hide()

local countdownTitle = countdownFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
countdownTitle:SetPoint("TOP", 0, -18)
local countdownText = countdownFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
countdownText:SetPoint("TOP", countdownTitle, "BOTTOM", 0, -8)
local cancelButton = CreateFrame("Button", nil, countdownFrame, "UIPanelButtonTemplate")
cancelButton:SetSize(92, 22)
cancelButton:SetPoint("BOTTOM", 0, 15)
cancelButton:SetText("Cancel")

local function StopCountdown(cancelled)
    local cancelMessage = countdown.cancelMessage
    countdown.active = false
    countdown.action = nil
    countdown.kind = nil
    countdown.cancelMessage = nil
    countdownFrame:SetScript("OnUpdate", nil)
    countdownFrame:Hide()
    if cancelled and AutoCore and AutoCore.Info then
        AutoCore.Info("Activity", cancelMessage or "Automatic action cancelled.")
    end
end

cancelButton:SetScript("OnClick", function() StopCountdown(true) end)

local function StartCountdown(title, verb, action, settingKey, defaultDelay, maxDelay, kind, cancelMessage)
    if countdown.active then return end
    local delay = tonumber(Setting(settingKey, defaultDelay)) or defaultDelay
    if delay < 1 then delay = 1 elseif delay > maxDelay then delay = maxDelay end
    countdown.active = true
    countdown.endsAt = GetTime() + delay
    countdown.action = action
    countdown.kind = kind
    countdown.cancelMessage = cancelMessage
    countdownTitle:SetText(title)
    countdownFrame:Show()
    local lastShown
    countdownFrame:SetScript("OnUpdate", function()
        if not countdown.active then return end
        local remaining = countdown.endsAt - GetTime()
        local shown = math.max(0, math.ceil(remaining))
        if shown ~= lastShown then
            lastShown = shown
            countdownText:SetText(verb .. " in " .. shown .. "...")
        end
        if remaining <= 0 then
            local actionToRun = countdown.action
            StopCountdown(false)
            if actionToRun then actionToRun() end
        end
    end)
end

----------------------------------------------------------------------
-- Queue acceptance and completion handling
----------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("LFG_PROPOSAL_SHOW")
eventFrame:RegisterEvent("LFG_COMPLETION_REWARD")
eventFrame:RegisterEvent("LFG_UPDATE")
eventFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
eventFrame:RegisterEvent("UPDATE_BATTLEFIELD_STATUS")
eventFrame:RegisterEvent("UPDATE_BATTLEFIELD_SCORE")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("CHAT_MSG_BG_SYSTEM_ALLIANCE")
eventFrame:RegisterEvent("CHAT_MSG_BG_SYSTEM_HORDE")
eventFrame:RegisterEvent("CHAT_MSG_BG_SYSTEM_NEUTRAL")

local acceptedBattlefield = {}
local battlegroundCompletionHandled = false
local dungeonCompletionHandled = false
local pendingDungeonRequeue = false
local pendingDungeonPartyLeave = false
local dungeonPartyLeaveRequested = false
local battlefieldPollElapsed = 0

local function IsLFGQueueActive()
    if not GetLFGMode then return false end
    local mode, submode = GetLFGMode()
    local value = string.lower(tostring(mode or "") .. " " .. tostring(submode or ""))
    return string.find(value, "queue", 1, true)
        or string.find(value, "proposal", 1, true)
        or string.find(value, "rolecheck", 1, true)
end

local function MaybeStartDungeonRequeue()
    if not pendingDungeonRequeue and not pendingDungeonPartyLeave then return end
    local inInstance, instanceType = IsInInstance()
    if inInstance and instanceType == "party" then return end

    local partyMembers = GetNumPartyMembers and GetNumPartyMembers() or 0
    if pendingDungeonPartyLeave and partyMembers > 0 then
        if LeaveParty then
            if not dungeonPartyLeaveRequested then
                dungeonPartyLeaveRequested = true
                LeaveParty()
            end
            return
        end
        pendingDungeonPartyLeave = false
        if AutoCore and AutoCore.Warn then
            AutoCore.Warn("Activity", "Leaving the dungeon party is unavailable on this client.")
        end
    end

    local shouldRequeue = pendingDungeonRequeue
    pendingDungeonRequeue = false
    pendingDungeonPartyLeave = false
    dungeonPartyLeaveRequested = false
    if not shouldRequeue or IsLFGQueueActive() then return end
    StartCountdown("Dungeon Requeue", "Joining Dungeon Finder", function()
        if IsLFGQueueActive() then return end
        if JoinLFG then
            JoinLFG()
        elseif AutoCore and AutoCore.Warn then
            AutoCore.Warn("Activity", "Dungeon Finder requeue is unavailable on this client.")
        end
    end, "dungeonRequeueDelay", 30, 300, "dungeonRequeue",
        "Automatic dungeon requeue cancelled.")
end

local function ScanBattlefieldQueues()
    if not GetBattlefieldStatus then return end
    for i = 1, (MAX_BATTLEFIELD_QUEUES or 3) do
        local status = GetBattlefieldStatus(i)
        if status == "confirm" and Setting("autoAcceptBattlegroundPop", false) then
            if not acceptedBattlefield[i] and AcceptBattlefieldPort then
                acceptedBattlefield[i] = true
                AcceptBattlefieldPort(i, true)
                if StaticPopup_Hide then StaticPopup_Hide("CONFIRM_BATTLEFIELD_ENTRY") end
            end
        elseif status ~= "confirm" then
            acceptedBattlefield[i] = nil
        end
    end
end

local function CheckBattlegroundCompletion()
    local inInstance, instanceType = IsInInstance()
    if not inInstance or instanceType ~= "pvp" then
        battlegroundCompletionHandled = false
        return
    end
    if battlegroundCompletionHandled or not Setting("autoLeaveCompletedBattleground", false) then return end
    if not GetBattlefieldWinner or GetBattlefieldWinner() == nil then return end
    battlegroundCompletionHandled = true
    StartCountdown("Battleground Complete", "Leaving battleground", function()
        local stillInside, currentType = IsInInstance()
        if stillInside and currentType == "pvp" and LeaveBattlefield then LeaveBattlefield() end
    end, "activityLeaveDelay", 3, 30, "battlegroundDeparture",
        "Automatic battleground departure cancelled for this run.")
end

eventFrame:SetScript("OnUpdate", function(_, elapsed)
    battlefieldPollElapsed = battlefieldPollElapsed + elapsed
    if battlefieldPollElapsed < 0.5 then return end
    battlefieldPollElapsed = 0
    CheckBattlegroundCompletion()
end)

eventFrame:SetScript("OnEvent", function(_, event, message)
    if event == "LFG_PROPOSAL_SHOW" then
        dungeonCompletionHandled = false
        if Setting("autoAcceptLFGProposal", false) and AcceptProposal then AcceptProposal() end
    elseif event == "LFG_COMPLETION_REWARD" then
        if not dungeonCompletionHandled and Setting("autoExitCompletedDungeon", false) then
            local inInstance, instanceType = IsInInstance()
            if inInstance and instanceType == "party" then
                dungeonCompletionHandled = true
                StartCountdown("Dungeon Complete", "Leaving dungeon", function()
                    local stillInside, currentType = IsInInstance()
                    if stillInside and currentType == "party" and LFGTeleport then
                        pendingDungeonRequeue = Setting("autoRequeueDungeon", false)
                        pendingDungeonPartyLeave = Setting("autoLeaveDungeonParty", false)
                        dungeonPartyLeaveRequested = false
                        LFGTeleport(true)
                    end
                end, "dungeonExitDelay", 120, 300, "dungeonDeparture",
                    "Automatic dungeon departure cancelled for this run.")
            end
        end
    elseif event == "UPDATE_BATTLEFIELD_STATUS" then
        ScanBattlefieldQueues()
        CheckBattlegroundCompletion()
    elseif event == "UPDATE_BATTLEFIELD_SCORE" then
        CheckBattlegroundCompletion()
    elseif event == "PLAYER_ENTERING_WORLD" then
        if countdown.active then StopCountdown(false) end
        local inInstance, instanceType = IsInInstance()
        if not inInstance or instanceType ~= "party" then dungeonCompletionHandled = false end
        ScanBattlefieldQueues()
        CheckBattlegroundCompletion()
        MaybeStartDungeonRequeue()
    elseif event == "PARTY_MEMBERS_CHANGED" then
        MaybeStartDungeonRequeue()
    elseif event == "LFG_UPDATE" then
        if countdown.active and countdown.kind == "dungeonRequeue" and IsLFGQueueActive() then
            StopCountdown(false)
        end
    else
        Activity.TrackEnemyFlagCarrier(message)
    end
end)

----------------------------------------------------------------------
-- Enemy flag-carrier tracking and explicit aura removal
----------------------------------------------------------------------
local enemyFlagCarrier

local function CleanCarrierName(name)
    if not name then return nil end
    name = string.gsub(name, "[%!%.]+$", "")
    name = string.gsub(name, "^%s+", "")
    name = string.gsub(name, "%s+$", "")
    return name ~= "" and name or nil
end

function Activity.TrackEnemyFlagCarrier(message)
    if not Setting("trackEnemyFlagCarrier", true) or not message then return end
    local lower = string.lower(message)
    local flagFaction, carrier = string.match(lower, "the (alliance) flag was picked up by (.+)")
    if not flagFaction then
        flagFaction, carrier = string.match(lower, "the (horde) flag was picked up by (.+)")
    end
    local playerFaction = UnitFactionGroup and UnitFactionGroup("player") or nil
    if flagFaction and playerFaction and flagFaction == string.lower(playerFaction) then
        enemyFlagCarrier = CleanCarrierName(carrier)
        return
    end
    if playerFaction then
        local ownFlag = "the " .. string.lower(playerFaction) .. " flag"
        if string.find(lower, ownFlag, 1, true)
            and (string.find(lower, "was dropped", 1, true)
                or string.find(lower, "was captured", 1, true)
                or string.find(lower, "was returned", 1, true))
        then
            enemyFlagCarrier = nil
        end
    end
end

function Activity.TargetEnemyFlagCarrier()
    if not enemyFlagCarrier then
        if AutoCore and AutoCore.Warn then AutoCore.Warn("Activity", "No enemy flag carrier is currently tracked.") end
        return
    end
    if TargetByName then TargetByName(enemyFlagCarrier, true) end
    if not UnitExists("target") or string.lower(UnitName("target") or "") ~= string.lower(enemyFlagCarrier) then
        if AutoCore and AutoCore.Warn then
            AutoCore.Warn("Activity", enemyFlagCarrier .. " is not currently targetable or is out of range.")
        end
    end
end

local FLAG_AURAS = { [23333] = true, [23335] = true, [34976] = true }

function Activity.DropFlagOrSelectedAura()
    local selectedID = tonumber(Setting("dropAuraSpellID", 0)) or 0
    for index = 1, 40 do
        local name, _, _, _, _, _, _, _, _, _, spellID = UnitBuff("player", index)
        if not name then break end
        if FLAG_AURAS[spellID] or (selectedID > 0 and spellID == selectedID) then
            if CancelUnitBuff then CancelUnitBuff("player", index) end
            return
        end
    end
    if AutoCore and AutoCore.Warn then AutoCore.Warn("Activity", "No carried flag or selected removable aura was found.") end
end
