----------------------------------------------------------------------
-- ActionBarEffects.lua
-- ====================
-- Backports the newer ElvUI cooldown-visual controls to Ascension's
-- older cooldown widget. This client has no SetDrawSwipe/SetDrawBling,
-- so the native cooldown layer is hidden instead. ElvUI's countdown text
-- is a separate sibling frame and remains visible.
----------------------------------------------------------------------

AutoCore = AutoCore or {}
local Core = AutoCore

local Effects = {}
Core.ActionBarEffects = Effects

local tracked = setmetatable({}, { __mode = "k" })
local hideSwipe = false
local hideBling = false
local BLING_LEAD = 0.08
local BLING_DURATION = 1.10

local function GetOptions()
    local defaults = AutoCoreConfig or {}
    hideSwipe = Core.GetSetting("core", "disableActionBarSwipe", defaults.disableActionBarSwipe) == true
    hideBling = Core.GetSetting("core", "disableActionBarBling", defaults.disableActionBarBling) == true
end

local function SetLayerHidden(cooldown, state, hidden)
    if hidden then
        if not state.hidden then
            state.originalAlpha = cooldown:GetAlpha()
            state.hidden = true
        end
        cooldown:SetAlpha(0)
    elseif state.hidden then
        cooldown:SetAlpha(state.originalAlpha or 1)
        state.hidden = false
    end
end

local function OnSetCooldown(cooldown, start, duration)
    local state = tracked[cooldown]
    if not state then return end

    local now = GetTime()
    if type(start) == "number" and type(duration) == "number" and start > 0 and duration > 0 then
        state.endTime = start + duration
        state.suppressUntil = state.endTime + BLING_DURATION
    elseif state.endTime and now > state.endTime + BLING_DURATION then
        state.endTime = nil
        state.suppressUntil = nil
    end

    -- SetCooldown may be called again with zeroes exactly when the cooldown
    -- completes. Do not restore the native layer during its completion flash.
    local inCompletionWindow = state.endTime and now >= state.endTime - BLING_LEAD
        and now <= (state.suppressUntil or state.endTime + BLING_DURATION)
    if hideSwipe then
        -- If bling is still wanted, reveal only its short completion window.
        SetLayerHidden(cooldown, state, hideBling or not inCompletionWindow)
    elseif hideBling and inCompletionWindow then
        SetLayerHidden(cooldown, state, true)
    end
end

local function TrackCooldown(cooldown)
    if not cooldown or tracked[cooldown] then return end
    local state = {
        originalAlpha = cooldown:GetAlpha(),
    }
    if cooldown.timer and cooldown.timer.endTime then
        state.endTime = cooldown.timer.endTime
        state.suppressUntil = state.endTime + BLING_DURATION
    end
    tracked[cooldown] = state
    if hooksecurefunc and cooldown.SetCooldown then
        hooksecurefunc(cooldown, "SetCooldown", OnSetCooldown)
    end
end

local function ScanElvUIButtons()
    if not ElvUI or not ElvUI[1] then return end
    local actionBars = ElvUI[1]:GetModule("ActionBars", true)
    if not actionBars or not actionBars.handledbuttons then return end

    for button in pairs(actionBars.handledbuttons) do
        TrackCooldown(button.cooldown or (button.GetName and _G[button:GetName() .. "Cooldown"]))
    end
end

local function Apply(now)
    for cooldown, state in pairs(tracked) do
        local inCompletionWindow = state.endTime
            and now >= state.endTime - BLING_LEAD
            and now <= (state.suppressUntil or state.endTime + BLING_DURATION)

        if hideSwipe then
            -- The old widget draws swipe and bling in one layer. Reveal that
            -- layer only for the completion window when bling remains enabled.
            SetLayerHidden(cooldown, state, hideBling or not inCompletionWindow)
        elseif hideBling and inCompletionWindow then
            SetLayerHidden(cooldown, state, true)
        else
            SetLayerHidden(cooldown, state, false)
        end

        if state.endTime and now > state.endTime + BLING_DURATION then
            state.endTime = nil
            state.suppressUntil = nil
        end
    end
end

function Effects.Refresh()
    GetOptions()
    ScanElvUIButtons()
    Apply(GetTime())
end

local driver = CreateFrame("Frame")
local scanElapsed = 0
local updateElapsed = 0
driver:RegisterEvent("PLAYER_LOGIN")
driver:RegisterEvent("PLAYER_ENTERING_WORLD")
driver:SetScript("OnEvent", function()
    Effects.Refresh()
end)
driver:SetScript("OnUpdate", function(_, elapsed)
    scanElapsed = scanElapsed + elapsed
    updateElapsed = updateElapsed + elapsed

    -- ElvUI can create pet, stance, or extra-bar buttons after login.
    if scanElapsed >= 1 then
        scanElapsed = 0
        ScanElvUIButtons()
    end

    -- The two effects share one native layer, so independent control needs a
    -- short update around each cooldown's completion window.
    if (hideSwipe or hideBling) and updateElapsed >= 0.03 then
        updateElapsed = 0
        Apply(GetTime())
    end
end)
