----------------------------------------------------------------------
-- Activity.lua - opt-in Dungeon Finder and battleground conveniences.
----------------------------------------------------------------------

AutoActivity = AutoActivity or {}
local Activity = AutoActivity
local config = AutoCoreConfig or {}
local UI = AutoCore and AutoCore.UI

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
countdownFrame:SetSize(340, 112)
countdownFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 170)
countdownFrame:SetFrameStrata("DIALOG")
if countdownFrame.SetClampedToScreen then countdownFrame:SetClampedToScreen(true) end
if UI and UI.Backdrop then
    UI.Backdrop(countdownFrame, UI.Colors.window, 0.98)
else
    countdownFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    countdownFrame:SetBackdropColor(0.05, 0.07, 0.09, 0.98)
    countdownFrame:SetBackdropBorderColor(0.19, 0.21, 0.24, 1)
end

local countdownAccent = countdownFrame:CreateTexture(nil, "BORDER")
countdownAccent:SetTexture("Interface\\Buttons\\WHITE8X8")
countdownAccent:SetPoint("TOPLEFT", 1, -1)
countdownAccent:SetPoint("TOPRIGHT", -1, -1)
countdownAccent:SetHeight(2)
if UI then
    countdownAccent:SetVertexColor(UI.Unpack(UI.Colors.brand))
else
    countdownAccent:SetVertexColor(0.35, 0.65, 1, 1)
end

local countdownDivider = countdownFrame:CreateTexture(nil, "BORDER")
countdownDivider:SetTexture("Interface\\Buttons\\WHITE8X8")
countdownDivider:SetPoint("TOPLEFT", 16, -44)
countdownDivider:SetPoint("TOPRIGHT", -16, -44)
countdownDivider:SetHeight(1)
if UI then
    countdownDivider:SetVertexColor(UI.Unpack(UI.Colors.border))
else
    countdownDivider:SetVertexColor(0.19, 0.21, 0.24, 1)
end
countdownFrame:Hide()

local countdownTitle = countdownFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
countdownTitle:SetPoint("TOPLEFT", 16, -14)
local countdownText = countdownFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
countdownText:SetPoint("TOPLEFT", 16, -57)
local cancelButton = CreateFrame("Button", nil, countdownFrame, "UIPanelButtonTemplate")
cancelButton:SetSize(92, 22)
cancelButton:SetPoint("BOTTOMRIGHT", -16, 14)
cancelButton:SetText("Cancel")

if UI then
    UI.ApplyFont(countdownTitle, 15)
    UI.ApplyFont(countdownText, 12)
    countdownTitle:SetTextColor(UI.Unpack(UI.Colors.text))
    countdownText:SetTextColor(UI.Unpack(UI.Colors.textMuted))
    UI.StripTemplateArt(cancelButton)
    UI.Backdrop(cancelButton, UI.Colors.control, 1)
    local cancelText = cancelButton:GetFontString()
    UI.ApplyFont(cancelText, 12)
    if cancelText then cancelText:SetTextColor(UI.Unpack(UI.Colors.text)) end
    cancelButton:SetScript("OnEnter", function(self)
        self:SetBackdropColor(UI.Unpack(UI.Colors.surfaceRaised))
        self:SetBackdropBorderColor(UI.Unpack(UI.Colors.brand))
    end)
    cancelButton:SetScript("OnLeave", function(self)
        self:SetBackdropColor(UI.Unpack(UI.Colors.control))
        self:SetBackdropBorderColor(UI.Unpack(UI.Colors.border))
    end)
end

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
    local delay = defaultDelay
    if settingKey then delay = tonumber(Setting(settingKey, defaultDelay)) or defaultDelay end
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

-- Dungeon follow-up decisions should be quick. Values from older profiles
-- used minute-scale timers; normalize those to the new default instead of
-- preserving an unexpectedly long wait or exposing a hidden legacy option.
local SHORT_DUNGEON_DELAYS = { [5] = true, [10] = true, [15] = true, [20] = true, [30] = true }
local function ShortDungeonDelay(settingKey)
    local delay = tonumber(Setting(settingKey, 10))
    return SHORT_DUNGEON_DELAYS[delay] and delay or 10
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
    end, nil, ShortDungeonDelay("dungeonRequeueDelay"), 30, "dungeonRequeue",
        "Automatic dungeon requeue cancelled.")
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
                end, nil, ShortDungeonDelay("dungeonExitDelay"), 30, "dungeonDeparture",
                    "Automatic dungeon departure cancelled for this run.")
            end
        end
    elseif event == "UPDATE_BATTLEFIELD_STATUS" then
        CheckBattlegroundCompletion()
    elseif event == "UPDATE_BATTLEFIELD_SCORE" then
        CheckBattlegroundCompletion()
    elseif event == "PLAYER_ENTERING_WORLD" then
        if countdown.active then StopCountdown(false) end
        local inInstance, instanceType = IsInInstance()
        if not inInstance or instanceType ~= "party" then dungeonCompletionHandled = false end
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
