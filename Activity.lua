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
    countdown.active = false
    countdown.action = nil
    countdownFrame:SetScript("OnUpdate", nil)
    countdownFrame:Hide()
    if cancelled and AutoCore and AutoCore.Info then
        AutoCore.Info("Activity", "Automatic departure cancelled for this run.")
    end
end

cancelButton:SetScript("OnClick", function() StopCountdown(true) end)

local function StartCountdown(title, verb, action)
    if countdown.active then return end
    local delay = tonumber(Setting("activityLeaveDelay", 3)) or 3
    if delay < 1 then delay = 1 elseif delay > 30 then delay = 30 end
    countdown.active = true
    countdown.endsAt = GetTime() + delay
    countdown.action = action
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
eventFrame:RegisterEvent("UPDATE_BATTLEFIELD_STATUS")
eventFrame:RegisterEvent("UPDATE_BATTLEFIELD_SCORE")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("CHAT_MSG_BG_SYSTEM_ALLIANCE")
eventFrame:RegisterEvent("CHAT_MSG_BG_SYSTEM_HORDE")
eventFrame:RegisterEvent("CHAT_MSG_BG_SYSTEM_NEUTRAL")

local acceptedBattlefield = {}
local battlegroundCompletionHandled = false
local battlefieldPollElapsed = 0

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
    end)
end

eventFrame:SetScript("OnUpdate", function(_, elapsed)
    battlefieldPollElapsed = battlefieldPollElapsed + elapsed
    if battlefieldPollElapsed < 0.5 then return end
    battlefieldPollElapsed = 0
    CheckBattlegroundCompletion()
end)

eventFrame:SetScript("OnEvent", function(_, event, message)
    if event == "LFG_PROPOSAL_SHOW" and Setting("autoAcceptLFGProposal", false) then
        if AcceptProposal then AcceptProposal() end
    elseif event == "LFG_COMPLETION_REWARD" and Setting("autoExitCompletedDungeon", false) then
        local inInstance, instanceType = IsInInstance()
        if inInstance and instanceType == "party" then
            StartCountdown("Dungeon Complete", "Leaving dungeon", function()
                local stillInside, currentType = IsInInstance()
                if stillInside and currentType == "party" and LFGTeleport then LFGTeleport() end
            end)
        end
    elseif event == "UPDATE_BATTLEFIELD_STATUS" then
        ScanBattlefieldQueues()
        CheckBattlegroundCompletion()
    elseif event == "UPDATE_BATTLEFIELD_SCORE" then
        CheckBattlegroundCompletion()
    elseif event == "PLAYER_ENTERING_WORLD" then
        if countdown.active then StopCountdown(false) end
        ScanBattlefieldQueues()
        CheckBattlegroundCompletion()
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
