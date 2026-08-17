----------------------------------------------------------------------
-- MinimapButton.lua
-- Lightweight access to module status and common mode toggles.
----------------------------------------------------------------------

local button = CreateFrame("Button", "AutoEverythingMinimapButton", Minimap)
button:SetWidth(32)
button:SetHeight(32)
button:SetFrameStrata("MEDIUM")
button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
button:SetMovable(true)
button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
button:RegisterForDrag("LeftButton")

local icon = button:CreateTexture(nil, "BACKGROUND")
icon:SetTexture("Interface\\AddOns\\AutoEverything\\Images\\AutoEverythingIcon.tga")
icon:SetWidth(20)
icon:SetHeight(20)
icon:SetPoint("CENTER", 0, 1)

local border = button:CreateTexture(nil, "OVERLAY")
border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
border:SetWidth(54)
border:SetHeight(54)
border:SetPoint("TOPLEFT")

local function UpdatePosition()
    local angle = math.rad((AutoEverythingCharDB and AutoEverythingCharDB.minimapAngle) or 220)
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * 80, math.sin(angle) * 80)
end

local function UpdateDragPosition()
    local mx, my = Minimap:GetCenter()
    local scale = Minimap:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    cx, cy = cx / scale, cy / scale
    local dy, dx = cy - my, cx - mx
    local angle
    if math.atan2 then
        angle = math.atan2(dy, dx)
    elseif dx > 0 then
        angle = math.atan(dy / dx)
    elseif dx < 0 and dy >= 0 then
        angle = math.atan(dy / dx) + math.pi
    elseif dx < 0 then
        angle = math.atan(dy / dx) - math.pi
    elseif dy > 0 then
        angle = math.pi / 2
    elseif dy < 0 then
        angle = -math.pi / 2
    else
        -- dx == 0 and dy == 0: cursor sits exactly on the minimap's center.
        -- Match the standard atan2(0, 0) convention instead of guessing -90 deg.
        angle = 0
    end
    AutoEverythingCharDB = AutoEverythingCharDB or {}
    AutoEverythingCharDB.minimapAngle = math.deg(angle)
    UpdatePosition()
end

button:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", UpdateDragPosition)
end)
button:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
end)

local quickMenu = CreateFrame("Frame", "AutoEverythingMinimapQuickMenu", UIParent, "UIDropDownMenuTemplate")
local MODULE_INFO = {
    { "Loot", "loot", AutoLootConfig, "Loot Rules" },
    { "Junk", "junk", AutoJunkConfig, "Junk Rules" },
    { "Sell", "sell", AutoSellConfig, "Sell Rules" },
    { "Roll", "roll", AutoRollConfig, "Roll Rules" },
    { "Quest", "quest", AutoQuestConfig, "Quest" },
    { "Buff", "buff", AutoBuffConfig, "Buff" },
    { "Upgrade", "upgrade", AutoUpgradeConfig, "Upgrade" },
}

local function OpenQuickMenu(anchor)
    local entries = {
        { text = "Automation", isTitle = true, notCheckable = true },
    }
    for _, info in ipairs(MODULE_INFO) do
        -- Per-entry locals keep callbacks correct on the client's Lua 5.1.
        local label, moduleName, config, page = info[1], info[2], info[3], info[4]
        local enabled = AutoCore.GetSetting(moduleName, "enabled", config and config.enabled) ~= false
        table.insert(entries, {
            text = (enabled and "|cff26bff2●|r  " or "|cff707880○|r  ") .. "Auto" .. label,
            notCheckable = true,
            tooltipTitle = "Auto" .. label,
            tooltipText = "Click to " .. (enabled and "pause" or "enable") .. " this module.",
            func = function()
                AutoCore.SetSetting(moduleName, "enabled", not enabled)
            end,
        })
    end
    table.insert(entries, { text = " ", disabled = true, notCheckable = true })
    table.insert(entries, {
        text = "Open Overview", notCheckable = true,
        func = function() if AutoCore.Settings and AutoCore.Settings.Open then AutoCore.Settings.Open("Overview") end end,
    })
    table.insert(entries, {
        text = "Manage Profiles", notCheckable = true,
        func = function() if AutoCore.Settings and AutoCore.Settings.Open then AutoCore.Settings.Open("Profiles") end end,
    })
    EasyMenu(entries, quickMenu, anchor, 0, 0, "MENU", 0.15)
end

button:SetScript("OnClick", function(self, mouseButton)
    if mouseButton == "RightButton" then
        OpenQuickMenu(self)
    elseif IsShiftKeyDown and IsShiftKeyDown() then
        local anyEnabled = false
        for _, info in ipairs(MODULE_INFO) do
            if AutoCore.GetSetting(info[2], "enabled", info[3] and info[3].enabled) ~= false then
                anyEnabled = true
                break
            end
        end
        for _, info in ipairs(MODULE_INFO) do
            AutoCore.SetSetting(info[2], "enabled", not anyEnabled)
        end
        AutoCore.Info("Settings", anyEnabled and "All automation paused." or "All automation enabled.")
    elseif AutoCore.Settings and AutoCore.Settings.Open then
        AutoCore.Settings.Open("Overview")
    end
end)

button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("Automation")
    if AutoCore.GetProfileName then
        GameTooltip:AddLine("Profile: " .. AutoCore.GetProfileName(), 0.15, 0.75, 0.95)
    end
    local activeModules = 0
    local statusModules = {
        { "junk", AutoJunkConfig }, { "loot", AutoLootConfig }, { "sell", AutoSellConfig },
        { "roll", AutoRollConfig }, { "quest", AutoQuestConfig }, { "buff", AutoBuffConfig },
        { "upgrade", AutoUpgradeConfig },
    }
    for _, info in ipairs(statusModules) do
        if AutoCore.GetSetting(info[1], "enabled", info[2] and info[2].enabled) ~= false then
            activeModules = activeModules + 1
        end
    end
    GameTooltip:AddLine(activeModules .. " of " .. #statusModules .. " modules active", 0.75, 0.78, 0.82)
    local showSession = AutoCore.GetSetting("core", "showSessionInTooltip",
        AutoCoreConfig and AutoCoreConfig.showSessionInTooltip)
    if showSession ~= false and AutoCore.GetSessionSummary then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("This session", 0.15, 0.75, 0.95)
        for _, line in ipairs(AutoCore.GetSessionSummary()) do
            GameTooltip:AddLine(line, 1, 1, 1)
        end
        GameTooltip:AddLine(" ")
    end
    GameTooltip:AddLine("Left-click: open overview", 1, 1, 1)
    GameTooltip:AddLine("Right-click: quick controls", 1, 1, 1)
    GameTooltip:AddLine("Shift-left-click: pause/enable all", 1, 1, 1)
    GameTooltip:AddLine("Drag: move button", 1, 1, 1)
    GameTooltip:Show()
end)
button:SetScript("OnLeave", function() GameTooltip:Hide() end)

----------------------------------------------------------------------
-- Independent group-finder button. Two buttons are intentional: opening the
-- bulletin board should remain one click and must not disturb quick controls.
----------------------------------------------------------------------
local lfgButton = CreateFrame("Button", "AutoGroupFinderMinimapButton", Minimap)
lfgButton:SetWidth(32)
lfgButton:SetHeight(32)
lfgButton:SetFrameStrata("MEDIUM")
lfgButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
lfgButton:SetMovable(true)
lfgButton:RegisterForClicks("LeftButtonUp")
lfgButton:RegisterForDrag("LeftButton")

local lfgIcon = lfgButton:CreateTexture(nil, "BACKGROUND")
lfgIcon:SetTexture("Interface\\Icons\\Spell_Holy_PrayerOfShadowProtection")
lfgIcon:SetWidth(20)
lfgIcon:SetHeight(20)
lfgIcon:SetPoint("CENTER", 0, 1)

local lfgBorder = lfgButton:CreateTexture(nil, "OVERLAY")
lfgBorder:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
lfgBorder:SetWidth(54)
lfgBorder:SetHeight(54)
lfgBorder:SetPoint("TOPLEFT")

local lfgCount = lfgButton:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
lfgCount:SetPoint("BOTTOMRIGHT", lfgButton, "BOTTOMRIGHT", 0, 1)
lfgCount:SetTextColor(0.35, 0.75, 1)

local function UpdateLFGPosition()
    local angle = math.rad((AutoEverythingCharDB and AutoEverythingCharDB.lfgMinimapAngle) or 260)
    lfgButton:ClearAllPoints()
    lfgButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * 80, math.sin(angle) * 80)
end

local function UpdateLFGDragPosition()
    local mx, my = Minimap:GetCenter()
    local scale = Minimap:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    cx, cy = cx / scale, cy / scale
    local dy, dx = cy - my, cx - mx
    local angle
    if math.atan2 then
        angle = math.atan2(dy, dx)
    elseif dx > 0 then
        angle = math.atan(dy / dx)
    elseif dx < 0 and dy >= 0 then
        angle = math.atan(dy / dx) + math.pi
    elseif dx < 0 then
        angle = math.atan(dy / dx) - math.pi
    elseif dy > 0 then
        angle = math.pi / 2
    elseif dy < 0 then
        angle = -math.pi / 2
    else
        angle = 0
    end
    AutoEverythingCharDB = AutoEverythingCharDB or {}
    AutoEverythingCharDB.lfgMinimapAngle = math.deg(angle)
    UpdateLFGPosition()
end

lfgButton:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", UpdateLFGDragPosition) end)
lfgButton:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
lfgButton:SetScript("OnClick", function()
    if AutoCore.LFG and AutoCore.LFG.Toggle then AutoCore.LFG.Toggle() end
end)
lfgButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("Group Finder")
    local count = AutoCore.LFG and AutoCore.LFG.GetRequestCount and AutoCore.LFG.GetRequestCount() or 0
    GameTooltip:AddLine(count .. (count == 1 and " active request" or " active requests"), 0.15, 0.75, 0.95)
    GameTooltip:AddLine("Left-click: open bulletin board", 1, 1, 1)
    GameTooltip:AddLine("Drag: move button", 1, 1, 1)
    GameTooltip:Show()
end)
lfgButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

local loadFrame = CreateFrame("Frame")
AutoCore.MinimapButton = AutoCore.MinimapButton or {}
function AutoCore.MinimapButton.Refresh()
    local visible = AutoCore.GetSetting("core", "showMinimapButton",
        AutoCoreConfig and AutoCoreConfig.showMinimapButton)
    if visible == false then button:Hide() else button:Show() end
    local lfgVisible = AutoCore.GetSetting("core", "showLFGMinimapButton",
        AutoCoreConfig and AutoCoreConfig.showLFGMinimapButton)
    if lfgVisible == false then lfgButton:Hide() else lfgButton:Show() end
end
function AutoCore.MinimapButton.RefreshLFG()
    local count = AutoCore.LFG and AutoCore.LFG.GetRequestCount and AutoCore.LFG.GetRequestCount() or 0
    if count > 99 then lfgCount:SetText("99+")
    elseif count > 0 then lfgCount:SetText(tostring(count))
    else lfgCount:SetText("") end
end
loadFrame:RegisterEvent("ADDON_LOADED")
loadFrame:SetScript("OnEvent", function(self, _, addonName)
    if addonName ~= "AutoEverything" then return end
    AutoEverythingCharDB = AutoEverythingCharDB or {}
    if AutoEverythingCharDB.minimapAngle == nil then AutoEverythingCharDB.minimapAngle = 220 end
    if AutoEverythingCharDB.lfgMinimapAngle == nil then AutoEverythingCharDB.lfgMinimapAngle = 260 end
    UpdatePosition()
    UpdateLFGPosition()
    AutoCore.MinimapButton.Refresh()
    AutoCore.MinimapButton.RefreshLFG()
    self:UnregisterEvent("ADDON_LOADED")
end)
