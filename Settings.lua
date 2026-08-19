----------------------------------------------------------------------
-- Settings.lua - account-wide profiles and in-game configuration UI.
-- WoW 3.3.5a compatible. This window paints itself entirely (see Backdrop),
-- so it looks the same regardless of which other UI addons are loaded.
----------------------------------------------------------------------
local Core = AutoCore
Core.Settings = Core.Settings or {}
local Settings = Core.Settings

local frame, pageHost, titleText, profileText, saveStatus, globalStatus, globalToggle
local overviewRefresh
local savePulse = CreateFrame("Frame")
local currentPage = "Overview"
local pageBuilders = {}
local controls = {}
local pageCache = {}
local activePageFrame
local Track
local navButtons = {}
local ruleSelections = {}
local suppressRefresh = false
local openMenuButton
local openMenuState
local menuHideHooked = false
local ruleEditorBlockers = {}
local focusedEditBox
local sliderSerial = 0
local CloseOpenMenu
local MultiChoiceEditor
local OpenQuickAbandonWindow
local OpenTextPopup
local StyledCloseButton
local PromptText
local Alert
local BuildScrollList
local popupMenu = CreateFrame("Frame", "AutoEverythingSettingsMenu", UIParent, "UIDropDownMenuTemplate")

----------------------------------------------------------------------
-- Theme
-- One palette drives the whole window. BRAND is the AutoEverything blue
-- from the title text (#58a6ff) and is the only accent color used for
-- selection, focus, hover, and headings - yellow is not used anywhere.
-- Toggles are the one deliberate exception: they read green/red so an
-- on/off state is obvious at a glance without reading the label.
----------------------------------------------------------------------
local UI = Core.UI
local COLORS = UI.Colors
local BRAND      = COLORS.brand
local BRAND_DIM  = COLORS.brandDim
local TEXT       = COLORS.text
local TEXT_MUTED = COLORS.textMuted
local TOGGLE_ON  = COLORS.toggleOn
local TOGGLE_OFF = COLORS.toggleOff
local CLOSE_RED  = COLORS.danger
local BORDER     = COLORS.border
local CTRL_BG    = COLORS.control
local SELECT_BG  = COLORS.selected
local TRACK_BG   = COLORS.track
local BRAND_HEX  = "58a6ff"

local WHITE_TEX = UI.Textures.white
local CIRCLE_TEX = UI.Textures.circle
local Unpack = UI.Unpack
local ApplyUIFont = UI.ApplyFont

----------------------------------------------------------------------
-- Capsule
-- A pill is the left half of the disc, a plain rectangle, and the right
-- half of the disc - exactly the standard "two round caps plus a
-- connecting rectangle" construction. Halves (rather than two whole
-- circles centred a radius in from each end) mean the three pieces butt
-- up edge to edge with no overlap, so nothing double-blends when the
-- shape is tinted with alpha.
----------------------------------------------------------------------
local function Capsule(parent, layer, height)
    local radius = height / 2
    local shape = {}

    local center = parent:CreateTexture(nil, layer)
    center:SetTexture(WHITE_TEX)

    local left = parent:CreateTexture(nil, layer)
    left:SetTexture(CIRCLE_TEX)
    left:SetTexCoord(0, 0.5, 0, 1)
    left:SetWidth(radius)

    local right = parent:CreateTexture(nil, layer)
    right:SetTexture(CIRCLE_TEX)
    right:SetTexCoord(0.5, 1, 0, 1)
    right:SetWidth(radius)

    local parts = { center, left, right }

    -- A negative inset grows the shape past its anchor; drawing the same
    -- capsule twice at different insets (and on different draw layers) is how
    -- an outlined pill is made.
    function shape:AnchorTo(anchorTo, inset)
        inset = inset or 0
        left:ClearAllPoints()
        left:SetPoint("TOPLEFT", anchorTo, "TOPLEFT", inset, -inset)
        left:SetPoint("BOTTOMLEFT", anchorTo, "BOTTOMLEFT", inset, inset)
        right:ClearAllPoints()
        right:SetPoint("TOPRIGHT", anchorTo, "TOPRIGHT", -inset, -inset)
        right:SetPoint("BOTTOMRIGHT", anchorTo, "BOTTOMRIGHT", -inset, inset)
        center:ClearAllPoints()
        center:SetPoint("TOPLEFT", left, "TOPRIGHT", 0, 0)
        center:SetPoint("BOTTOMRIGHT", right, "BOTTOMLEFT", 0, 0)
    end

    function shape:SetColor(r, g, b, a)
        for _, part in ipairs(parts) do part:SetVertexColor(r, g, b, a or 1) end
    end

    return shape
end

local QUALITY_NAMES = {
    [0] = "Poor", [1] = "Common", [2] = "Uncommon", [3] = "Rare",
    [4] = "Epic", [5] = "Legendary", [6] = "Artifact / Heirloom",
}
local QUALITY_COLORS = {
    [0] = "9d9d9d", [1] = "ffffff", [2] = "1eff00", [3] = "0070dd",
    [4] = "a335ee", [5] = "ff8000", [6] = "e6cc80",
}
local function QualityText(value)
    return "|cff" .. (QUALITY_COLORS[value] or "ffffff") .. (QUALITY_NAMES[value] or tostring(value)) .. "|r"
end
local function QualityChoices()
    local choices = {}
    for value = 0, 6 do table.insert(choices, { text = QualityText(value), value = value }) end
    return choices
end
local function TextChoices(values)
    local choices = {}
    for _, value in ipairs(values) do table.insert(choices, { text = value, value = value }) end
    return choices
end
local UPGRADE_ARMOR_CHOICES = TextChoices({ "Cloth", "Leather", "Mail", "Plate" })
local UPGRADE_WEAPON_CHOICES = TextChoices({
    "One-Handed Axes", "Two-Handed Axes", "One-Handed Maces", "Two-Handed Maces",
    "One-Handed Swords", "Two-Handed Swords", "Daggers", "Fist Weapons", "Polearms",
    "Staves", "Bows", "Crossbows", "Guns", "Wands", "Thrown", "Fishing Poles",
})
local UPGRADE_RANGED_CHOICES = TextChoices({
    "Bows", "Crossbows", "Guns", "Wands", "Thrown",
    "Idols", "Librams", "Totems", "Sigils",
})
local UPGRADE_OFFHAND_CHOICES = TextChoices({
    "One-Handed Axes", "Two-Handed Axes", "One-Handed Maces", "Two-Handed Maces",
    "One-Handed Swords", "Two-Handed Swords", "Daggers", "Fist Weapons", "Polearms",
    "Staves", "Shields", "Held In Off-hand",
})

local StripTemplateArt = UI.StripTemplateArt

-- Solid panel with a 1px border. Corners are square: WoW's backdrop system has
-- no corner radius, and building one out of textures means giving up SetBackdrop
-- entirely - which costs the solid fill that makes these panels readable. The
-- rounded shapes in this file are reserved for small controls (toggles, slider
-- badges), where a capsule is the whole point.
local function Backdrop(object, r, g, b, a)
    if r == nil then UI.Backdrop(object, COLORS.window, a or 0.99)
    else UI.Backdrop(object, { r, g, b }, a or 0.98) end
end

-- Lightweight section surface built entirely from regions, so it never sits
-- above or intercepts the controls it visually groups.
local function SectionCard(parent, x, y, width, height)
    local fill = Track(parent:CreateTexture(nil, "BACKGROUND"))
    fill:SetTexture(WHITE_TEX)
    fill:SetPoint("TOPLEFT", x, y)
    fill:SetSize(width, height)
    fill:SetVertexColor(COLORS.surface[1], COLORS.surface[2], COLORS.surface[3], 0.96)
    local edges = {}
    for index = 1, 4 do
        edges[index] = Track(parent:CreateTexture(nil, "BORDER"))
        edges[index]:SetTexture(WHITE_TEX)
        edges[index]:SetVertexColor(BORDER[1], BORDER[2], BORDER[3], 0.7)
    end
    edges[1]:SetPoint("TOPLEFT", fill); edges[1]:SetPoint("TOPRIGHT", fill); edges[1]:SetHeight(1)
    edges[2]:SetPoint("BOTTOMLEFT", fill); edges[2]:SetPoint("BOTTOMRIGHT", fill); edges[2]:SetHeight(1)
    edges[3]:SetPoint("TOPLEFT", fill); edges[3]:SetPoint("BOTTOMLEFT", fill); edges[3]:SetWidth(1)
    edges[4]:SetPoint("TOPRIGHT", fill); edges[4]:SetPoint("BOTTOMRIGHT", fill); edges[4]:SetWidth(1)
    return fill
end

-- Cards use a shared content-driven bottom inset. Callers provide the bottom
-- edge of their final control rather than guessing a generous fixed height;
-- this keeps every group compact while preserving the same breathing room.
local PAGE_CANVAS_INSET = 18
local SECTION_BOTTOM_INSET = 14
local function FitSectionCard(parent, x, top, width, contentBottom)
    return SectionCard(parent, x, top, width, top - contentBottom + SECTION_BOTTOM_INSET)
end

-- Shared treatment for full-pane editors and centered dialogs. A raised
-- blue-grey surface and subtle header wash make modal content feel like part
-- of AutoEverything instead of an unstyled black frame.
local function ModalSurface(object)
    UI.Backdrop(object, COLORS.surface, 1)
    local header = object:CreateTexture(nil, "BACKGROUND")
    header:SetTexture(WHITE_TEX)
    header:SetPoint("TOPLEFT", object, "TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", object, "TOPRIGHT", -1, -1)
    header:SetHeight(54)
    header:SetVertexColor(COLORS.surfaceRaised[1], COLORS.surfaceRaised[2], COLORS.surfaceRaised[3], 0.42)
    local accent = object:CreateTexture(nil, "BORDER")
    accent:SetTexture(WHITE_TEX)
    accent:SetPoint("TOPLEFT", object, "TOPLEFT", 1, -1)
    accent:SetPoint("TOPRIGHT", object, "TOPRIGHT", -1, -1)
    accent:SetHeight(2)
    accent:SetGradientAlpha("HORIZONTAL", BRAND[1], BRAND[2], BRAND[3], 0.85,
        BRAND[1], BRAND[2], BRAND[3], 0.12)
end

local function SkinButton(button)
    StripTemplateArt(button)
    Backdrop(button, Unpack(CTRL_BG))
    -- UIPanelButtonTemplate defaults to GameFontNormal, which is yellow. Every
    -- button, dropdown, and multi-select in this window is built from that
    -- template, so overriding the font object here is what keeps the whole UI
    -- off yellow.
    if button.SetNormalFontObject then
        button:SetNormalFontObject("GameFontHighlight")
        button:SetHighlightFontObject("GameFontHighlight")
        if button.SetDisabledFontObject then button:SetDisabledFontObject("GameFontDisable") end
    end
    local font = button.GetFontString and button:GetFontString()
    if font then
        ApplyUIFont(font, 12)
        font:SetTextColor(Unpack(TEXT))
    end
    -- Keep controls visibly lighter than the pane behind them.
    button:SetBackdropColor(Unpack(CTRL_BG))
    button:SetBackdropBorderColor(Unpack(BORDER))
    if button.HookScript then
        local function Border(self, hovered)
            self:SetBackdropBorderColor(Unpack(hovered and BRAND or BORDER))
        end
        button:HookScript("OnEnter", function(self) Border(self, true) end)
        button:HookScript("OnLeave", function(self) Border(self, false) end)
        button:HookScript("OnMouseDown", function(self)
            if focusedEditBox and focusedEditBox ~= self then focusedEditBox:ClearFocus() end
            if openMenuButton and self ~= openMenuButton and CloseOpenMenu then CloseOpenMenu() end
        end)
    end
end

-- Give primary and destructive actions a stronger, consistent hierarchy while
-- retaining the shared button behavior and hover handling.
local function EmphasizeButton(button, color)
    if not button then return end
    local function Paint(hovered)
        local strength = hovered and 0.24 or 0.14
        button:SetBackdropColor(color[1] * strength, color[2] * strength, color[3] * strength, 1)
        button:SetBackdropBorderColor(color[1], color[2], color[3], hovered and 1 or 0.78)
    end
    button:HookScript("OnEnter", function() Paint(true) end)
    button:HookScript("OnLeave", function() Paint(false) end)
    Paint(false)
end

local function SkinEdit(edit)
    StripTemplateArt(edit)
    UI.Backdrop(edit, COLORS.control, 1)
    -- Brand-blue focus ring, so "where am I typing" uses the same accent as
    -- selection everywhere else.
    local function Border(focused)
        edit:SetBackdropBorderColor(Unpack(focused and BRAND or BORDER))
    end
    Border(false)
    edit:HookScript("OnEditFocusGained", function() Border(true) end)
    edit:HookScript("OnEditFocusLost", function() Border(false) end)
end

local function HideAllPages()
    -- Do not rely solely on activePageFrame: a model refresh can retire a
    -- cached page while navigation is in progress, leaving that pointer out of
    -- sync. Every direct child of pageHost is a settings page, so hiding all of
    -- them before showing the requested page is cheap and prevents controls
    -- from different pages ever being visible at the same time.
    if pageHost and pageHost.GetChildren then
        local children = { pageHost:GetChildren() }
        for _, child in ipairs(children) do child:Hide() end
    elseif activePageFrame then
        activePageFrame:Hide()
    end
    activePageFrame = nil
end

Track = function(object)
    table.insert(controls, object)
    if object and object.HookScript then
        object:HookScript("OnMouseDown", function(self)
            if focusedEditBox and focusedEditBox ~= self then focusedEditBox:ClearFocus() end
            if openMenuButton and self ~= openMenuButton and CloseOpenMenu then CloseOpenMenu() end
        end)
    end
    return object
end

-- Title-case short labels/headings consistently: capitalize the first letter
-- of each significant word, but leave the little joining words (by, is, an, of,
-- ...) lowercase unless they lead. Only the first letter is forced up, so
-- acronyms and mixed case authored in the source (IDs, DPS, 1H) survive intact.
-- Used for labels only - never for body sentences, which keep normal casing.
local TITLE_MINOR = {
    a = true, an = true, ["and"] = true, as = true, at = true, but = true,
    by = true, ["for"] = true, ["in"] = true, ["is"] = true, are = true,
    of = true, ["on"] = true, ["or"] = true, per = true, the = true,
    to = true, vs = true, ["with"] = true,
}
local function TitleCase(text)
    if type(text) ~= "string" then return text end
    local index = 0
    return (text:gsub("%S+", function(word)
        index = index + 1
        if index > 1 and TITLE_MINOR[word:lower()] then return word:lower() end
        return word:sub(1, 1):upper() .. word:sub(2)
    end))
end

-- size given = a heading: drawn in brand blue so headings, selection, and
-- focus all share one accent color. Body copy stays soft white.
local function Label(parent, text, x, y, size)
    local fontObject = size and "GameFontNormal" or "GameFontHighlight"
    local label = Track(parent:CreateFontString(nil, "OVERLAY", fontObject))
    label:SetPoint("TOPLEFT", x, y)
    -- Authored sentence case is preserved instead of forcing every label into
    -- title case; this keeps dense settings pages calmer and easier to scan.
    label:SetText(text)
    ApplyUIFont(label, size or 12)
    if size then
        label:SetTextColor(Unpack(BRAND))
    else
        label:SetTextColor(Unpack(TEXT))
    end
    return label
end

local function PageHeader(parent, title, description)
    Label(parent, title, 20, -20, 20)
    if description and description ~= "" then
        local intro = Label(parent, description, 20, -50)
        intro:SetWidth(680)
        intro:SetJustifyH("LEFT")
        intro:SetTextColor(Unpack(TEXT_MUTED))
        ApplyUIFont(intro, 12)
        return intro
    end
end

local function AddTooltip(object, title, text)
    if not object or not text then return end
    local function ShowTip()
        GameTooltip:SetOwner(object, "ANCHOR_RIGHT")
        GameTooltip:SetText(title or "Help", Unpack(BRAND))
        GameTooltip:AddLine(text, 1, 1, 1, true)
        GameTooltip:Show()
    end
    local function HideTip() GameTooltip:Hide() end
    if object.SetScript then
        object:EnableMouse(true)
        -- Hook rather than replace when the control already paints itself on
        -- hover (toggles, nav items), so adding a tooltip never silently
        -- removes a control's hover styling.
        if object.GetScript and object:GetScript("OnEnter") then
            object:HookScript("OnEnter", ShowTip)
            object:HookScript("OnLeave", HideTip)
        else
            object:SetScript("OnEnter", ShowTip)
            object:SetScript("OnLeave", HideTip)
        end
    end
    -- Toggles (Check()) render their label as a separate FontString rather
    -- than part of the clickable control, so hovering the label needs its own
    -- hit area to show the same tooltip. Toggles already build one to make the
    -- label clickable - hook that instead of covering it with a second frame,
    -- which would swallow the click.
    if object.labelHit then
        object.labelHit:HookScript("OnEnter", ShowTip)
        object.labelHit:HookScript("OnLeave", HideTip)
    elseif object.text and object.text.GetObjectType then
        local hitFrame = object.hoverHitFrame
        if not hitFrame then
            hitFrame = CreateFrame("Frame", nil, object)
            hitFrame:SetAllPoints(object.text)
            object.hoverHitFrame = hitFrame
        end
        hitFrame:EnableMouse(true)
        hitFrame:SetScript("OnEnter", ShowTip)
        hitFrame:SetScript("OnLeave", HideTip)
    end
end

local function AddEditHint(edit, hint, help)
    if hint and hint ~= "" then
        local hintText = edit:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        hintText:SetPoint("LEFT", edit, "LEFT", 7, 0)
        hintText:SetText(hint)
        local function UpdateHint()
            if (edit:GetText() or "") == "" and not edit:HasFocus() then hintText:Show() else hintText:Hide() end
        end
        edit:HookScript("OnTextChanged", UpdateHint)
        edit:HookScript("OnEditFocusGained", UpdateHint)
        edit:HookScript("OnEditFocusLost", UpdateHint)
        UpdateHint()
    end
    if help then AddTooltip(edit, "Accepted values", help) end
    return edit
end

-- Shared skinned-button construction, without page-control tracking. Used for
-- widgets whose parent frame already owns its own show/hide lifecycle (for
-- example, a rule-editor overlay rather than the cached settings page).
local function SkinnedButton(parent, text, x, y, width, callback, height)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width or 100, height or 24)
    button:SetPoint("TOPLEFT", x, y)
    button:SetText(text)
    if callback then button:SetScript("OnClick", callback) end
    SkinButton(button)
    return button
end

local function Button(parent, text, x, y, width, callback, height)
    return Track(SkinnedButton(parent, text, x, y, width, callback, height))
end

local function Edit(parent, x, y, width, value)
    local edit = Track(CreateFrame("EditBox", nil, parent))
    edit:SetSize(width or 180, 22)
    edit:SetPoint("TOPLEFT", x, y)
    edit:SetAutoFocus(false)
    edit:SetFontObject(ChatFontNormal)
    edit:SetTextInsets(6, 6, 0, 0)
    edit:SetText(tostring(value or ""))
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    edit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    edit:SetScript("OnEditFocusGained", function(self) focusedEditBox = self end)
    edit:SetScript("OnEditFocusLost", function(self) if focusedEditBox == self then focusedEditBox = nil end end)
    SkinEdit(edit)
    return edit
end

----------------------------------------------------------------------
-- Pill toggle
-- Replaces the stock checkbox everywhere. A capsule track (flat center
-- plus two round end caps) turns green when on and red when off, and a
-- white knob slides to the matching side. The label sits to the right
-- and the whole row is clickable.
----------------------------------------------------------------------
local TOGGLE_WIDTH, TOGGLE_HEIGHT, KNOB_SIZE = 28, 14, 10

local function Check(parent, text, x, y, checked, callback)
    local toggle = Track(CreateFrame("Button", nil, parent))
    toggle:SetSize(TOGGLE_WIDTH, TOGGLE_HEIGHT)
    toggle:SetPoint("TOPLEFT", x, y)
    -- Preserve the compact visual while providing a forgiving click target.
    -- SetHitRectInsets is available on the Wrath button widget and does not
    -- affect layout, so dense two-column pages keep their alignment.
    if toggle.SetHitRectInsets then toggle:SetHitRectInsets(-5, -5, -5, -5) end
    toggle.checked = (checked == true)
    toggle.available = true
    toggle.onChanged = nil

    local track = Capsule(toggle, "BACKGROUND", TOGGLE_HEIGHT)
    track:AnchorTo(toggle)

    -- The knob is the whole disc, drawn above the track.
    local knob = toggle:CreateTexture(nil, "ARTWORK")
    knob:SetTexture(CIRCLE_TEX)
    knob:SetSize(KNOB_SIZE, KNOB_SIZE)
    knob:SetVertexColor(1, 1, 1, 1)

    toggle.text = toggle:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    toggle.text:SetPoint("LEFT", toggle, "RIGHT", 10, 0)
    toggle.text:SetText(text)
    toggle.text:SetJustifyH("LEFT")
    ApplyUIFont(toggle.text, 12)

    local function Paint(hovered)
        local base = toggle.checked and TOGGLE_ON or TOGGLE_OFF
        if not toggle.available then
            track:SetColor(TOGGLE_OFF[1], TOGGLE_OFF[2], TOGGLE_OFF[3], 0.38)
        else
            -- Lift the track slightly on hover instead of changing hue, so
            -- enabled and disabled states remain unambiguous.
            local lift = hovered and 0.12 or 0
            track:SetColor(base[1] + lift, base[2] + lift, base[3] + lift, 1)
        end
        knob:ClearAllPoints()
        if toggle.checked then
            knob:SetPoint("RIGHT", toggle, "RIGHT", -2, 0)
        else
            knob:SetPoint("LEFT", toggle, "LEFT", 2, 0)
        end
        knob:SetAlpha(toggle.available and 1 or 0.38)
        toggle.text:SetTextColor(Unpack(toggle.available and TEXT or TEXT_MUTED))
    end

    local function ToggleValue(hovered)
        if not toggle.available then return end
        toggle.checked = not toggle.checked
        Paint(hovered)
        callback(toggle.checked)
        if toggle.onChanged then toggle.onChanged(toggle.checked) end
    end

    toggle:SetScript("OnEnter", function() Paint(true) end)
    toggle:SetScript("OnLeave", function() Paint(false) end)
    toggle:SetScript("OnClick", function() ToggleValue(true) end)

    -- Clicking the label toggles too - the text is a region, not part of the
    -- button's own hit box, so it needs its own transparent hit frame.
    local labelHit = CreateFrame("Button", nil, toggle)
    labelHit:SetPoint("TOPLEFT", toggle.text, "TOPLEFT", 0, 2)
    labelHit:SetPoint("BOTTOMRIGHT", toggle.text, "BOTTOMRIGHT", 0, -2)
    labelHit:SetScript("OnEnter", function() Paint(true) end)
    labelHit:SetScript("OnLeave", function() Paint(false) end)
    labelHit:SetScript("OnClick", function() ToggleValue(true) end)
    -- The label sits outside the tracked toggle's hit box, so it needs the
    -- same dismiss-on-click behavior Track() gives every other control.
    labelHit:HookScript("OnMouseDown", function()
        if focusedEditBox then focusedEditBox:ClearFocus() end
        if openMenuButton and CloseOpenMenu then CloseOpenMenu() end
    end)
    toggle.labelHit = labelHit
    function toggle:SetAvailable(available)
        self.available = available ~= false
        Paint(false)
    end
    function toggle:SetOnChanged(handler)
        self.onChanged = handler
    end

    Paint(false)
    return toggle
end

local function SetDropdownOpen(button, open)
    if button and button.dropdownArrow and button.dropdownArrow.SetText then
        -- Up (open) / down (closed) makes the menu state obvious without
        -- adding extra chrome.
        button.dropdownArrow:SetText(open and "\226\150\178" or "\226\150\188")
    end
end

local function AddDropdownIndicator(button)
    local arrow = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    arrow:SetPoint("RIGHT", button, "RIGHT", -6, 0)
    arrow:SetTextColor(Unpack(BRAND))
    -- Reserve a fixed lane for the triangle. Long profile and choice labels
    -- stay inside the remaining button width instead of drawing under it.
    local font = button.GetFontString and button:GetFontString()
    if font then
        font:ClearAllPoints()
        font:SetPoint("LEFT", button, "LEFT", 8, 0)
        font:SetPoint("RIGHT", button, "RIGHT", -22, 0)
        font:SetJustifyH("LEFT")
    end
    button.dropdownArrow = arrow
    SetDropdownOpen(button, false)
    -- Record this on mouse-down, before WoW's global menu handler gets a
    -- chance to hide the list in response to the same click.
    button:HookScript("OnMouseDown", function(self)
        self.closeDropdownOnClick = openMenuButton == self
            and DropDownList1 and DropDownList1:IsShown()
        if openMenuButton and openMenuButton ~= self and CloseOpenMenu then CloseOpenMenu() end
    end)
end

CloseOpenMenu = function()
    CloseDropDownMenus()
    if openMenuButton then SetDropdownOpen(openMenuButton, false) end
    openMenuButton = nil
    openMenuState = nil
end

-- World clicks do not bubble through UIParent on older clients, so close the
-- menu explicitly instead of waiting for UIDropDownMenu's long auto-hide timer.
if WorldFrame and WorldFrame.HookScript then
    WorldFrame:HookScript("OnMouseDown", function()
        if focusedEditBox then focusedEditBox:ClearFocus() end
        if openMenuButton then CloseOpenMenu() end
    end)
end

local function CancelRuleEditors()
    CloseOpenMenu()
    if focusedEditBox then focusedEditBox:ClearFocus(); focusedEditBox = nil end
    for _, blocker in ipairs(ruleEditorBlockers) do blocker:Hide() end
    wipe(ruleEditorBlockers)
end

local function ForgetRuleEditor(blocker)
    for index = #ruleEditorBlockers, 1, -1 do
        if ruleEditorBlockers[index] == blocker then
            table.remove(ruleEditorBlockers, index)
            return
        end
    end
end

local function StyleOpenMenu(anchor)
    local list = DropDownList1
    if not list or not list:IsShown() then return end
    local width = math.max(80, anchor:GetWidth() or 80)
    list:SetWidth(width)

    -- Put a fully opaque layer behind Blizzard's translucent menu artwork.
    if not list.autoEverythingOpaque then
        local background = list:CreateTexture(nil, "BACKGROUND")
        background:SetAllPoints(list)
        background:SetTexture("Interface\\Buttons\\WHITE8X8")
        background:SetVertexColor(COLORS.surface[1], COLORS.surface[2], COLORS.surface[3], 1)
        list.autoEverythingOpaque = background
    end
    list.autoEverythingOpaque:Show()

    local maximum = UIDROPDOWNMENU_MAXBUTTONS or 32
    for index = 1, maximum do
        local item = _G["DropDownList1Button" .. index]
        if item and item:IsShown() then item:SetWidth(math.max(40, width - 24)) end
    end
end

local OpenMenuPage

local function MenuPageSize(anchor, entryCount)
    -- UIDropDownMenu rows are approximately 16px tall with about 16px of
    -- backdrop padding. Use only the room below the button inside pageHost so
    -- the list can grow naturally without ever extending outside the pane.
    local anchorBottom = anchor.GetBottom and anchor:GetBottom()
    local paneBottom = pageHost and pageHost.GetBottom and pageHost:GetBottom()
    local available = anchorBottom and paneBottom and (anchorBottom - paneBottom - 6) or 190
    local maximumRows = math.floor((available - 16) / 16)
    if maximumRows < 3 then maximumRows = 3 end
    if maximumRows > 30 then maximumRows = 30 end
    if entryCount <= maximumRows then return math.max(1, entryCount) end
    return math.max(1, maximumRows - 2) -- reserve rows for both scroll controls
end

OpenMenuPage = function(anchor, entries, offset)
    local pageSize = MenuPageSize(anchor, #entries)
    offset = math.max(1, tonumber(offset) or 1)
    local maximumOffset = math.max(1, #entries - pageSize + 1)
    if offset > maximumOffset then offset = maximumOffset end

    CloseDropDownMenus()
    local menu = {}
    if offset > 1 then
        table.insert(menu, {
            text = "|cff" .. BRAND_HEX .. "▲  Scroll up|r", notCheckable = true, keepShownOnClick = true,
            func = function() OpenMenuPage(anchor, entries, math.max(1, offset - 3)) end,
        })
    end
    local last = math.min(#entries, offset + pageSize - 1)
    for index = offset, last do
        local entry = entries[index]
        table.insert(menu, {
            text = entry.text, checked = entry.checked, notCheckable = entry.notCheckable,
            disabled = entry.disabled, keepShownOnClick = entry.keepShownOnClick, func = entry.func,
        })
    end
    if last < #entries then
        table.insert(menu, {
            text = "|cff" .. BRAND_HEX .. "▼  Scroll down|r", notCheckable = true, keepShownOnClick = true,
            func = function() OpenMenuPage(anchor, entries, math.min(maximumOffset, offset + 3)) end,
        })
    end

    -- Passing the button frame as the anchor makes WoW place the menu directly
    -- below it. Long menus are capped and can be scrolled with the wheel or the
    -- arrow rows instead of extending beyond the screen.
    EasyMenu(menu, popupMenu, anchor, 0, 0, "MENU", 0.15)
    openMenuButton = anchor
    openMenuState = { anchor = anchor, entries = entries, offset = offset }
    SetDropdownOpen(anchor, true)
    StyleOpenMenu(anchor)

    if DropDownList1 and not menuHideHooked then
        DropDownList1:EnableMouseWheel(true)
        DropDownList1:HookScript("OnMouseWheel", function(_, delta)
            local state = openMenuState
            if not state then return end
            local nextOffset = state.offset + (delta > 0 and -3 or 3)
            OpenMenuPage(state.anchor, state.entries, nextOffset)
        end)
        DropDownList1:HookScript("OnHide", function()
            if openMenuButton then SetDropdownOpen(openMenuButton, false) end
            openMenuButton = nil
            openMenuState = nil
        end)
        menuHideHooked = true
    end
end

local function ShowMenu(anchor, entries)
    -- A second click on the same button closes its menu.
    if anchor.closeDropdownOnClick or (openMenuButton == anchor and DropDownList1 and DropDownList1:IsShown()) then
        anchor.closeDropdownOnClick = nil
        CloseOpenMenu()
        return
    end
    anchor.closeDropdownOnClick = nil
    if openMenuButton then SetDropdownOpen(openMenuButton, false) end
    OpenMenuPage(anchor, entries, 1)
end

-- Menu rows mark their selection with a small brand-blue dot instead of
-- Blizzard's checkmark. Unselected rows draw the same glyph at zero alpha
-- (|c00......) so every label starts at exactly the same x.
local MENU_DOT = "ic"   -- U+25CF BLACK CIRCLE
local function MenuLabel(text, selected)
    local dot = selected and ("|cff" .. BRAND_HEX .. MENU_DOT .. "|r") or ("|c00000000" .. MENU_DOT .. "|r")
    return dot .. "  " .. tostring(text)
end

local function ChoiceButton(parent, label, x, y, width, choices, selected, callback, height)
    local button
    local selectedText = tostring(selected)
    for _, choice in ipairs(choices) do
        local value = choice.value
        if value == nil then value = choice.text end
        if selected == value then selectedText = choice.text; break end
    end
    button = Button(parent, label .. ": " .. selectedText, x, y, width, function(self)
        local entries = {}
        for _, choice in ipairs(choices) do
            local value = choice.value
            if value == nil then value = choice.text end
            local choiceText = choice.text
            table.insert(entries, {
                text = MenuLabel(choiceText, selected == value), notCheckable = true,
                func = function()
                    selected = value
                    self:SetText(label .. ": " .. choiceText)
                    callback(value)
                end,
            })
        end
        ShowMenu(self, entries)
    end, height)
    AddDropdownIndicator(button)
    return button
end

local function Default(config, key, fallback)
    if config and config[key] ~= nil then return config[key] end
    return fallback
end

local function ResolvedDefault(config, key, fallback)
    local resolved = config and Core.GetProfile(config)
    if resolved and resolved[key] ~= nil then return resolved[key] end
    return Default(config, key, fallback)
end

local function MarkSaved()
    if not saveStatus then return end
    saveStatus:SetText("Saved")
    saveStatus:SetAlpha(1)
    saveStatus:Show()
    local elapsed = 0
    savePulse:SetScript("OnUpdate", function(self, delta)
        elapsed = elapsed + (delta or 0)
        if elapsed > 1.2 then
            local alpha = math.max(0, 1 - (elapsed - 1.2) / 0.8)
            saveStatus:SetAlpha(alpha)
            if alpha <= 0 then self:SetScript("OnUpdate", nil); saveStatus:Hide() end
        end
    end)
end

local function SetSettingWithoutRefresh(moduleName, key, value)
    suppressRefresh = true
    Core.SetSetting(moduleName, key, value)
    suppressRefresh = false
    MarkSaved()
end

local function ScalarCheck(parent, moduleName, config, key, text, x, y, fallback, tooltip)
    local value = Core.GetSetting(moduleName, key, ResolvedDefault(config, key, fallback))
    local check = Check(parent, text, x, y, value, function(checked) SetSettingWithoutRefresh(moduleName, key, checked) end)
    if tooltip then AddTooltip(check, text, tooltip) end
    return check
end

-- Dense preference pages keep explanations in hover tooltips instead of
-- repeating them as body copy beneath every toggle.
local function ScalarSettingRow(parent, moduleName, config, key, text, x, y, fallback, description)
    return ScalarCheck(parent, moduleName, config, key, text, x, y, fallback, description)
end

local function BindToggleDependency(parentToggle, ...)
    local children = { ... }
    local function Update(available)
        for _, child in ipairs(children) do
            if child and child.SetAvailable then child:SetAvailable(available) end
        end
    end
    Update(parentToggle and parentToggle.checked)
    if parentToggle then parentToggle:SetOnChanged(Update) end
end

-- Layout: the title sits at the left of a header row with the current value
-- in a badge at the right end, and the track runs just underneath - brand
-- blue up to the handle, dark grey after it, with a plain blue ball on the
-- handle. The header is kept tight to the track so each slider reads as one
-- block rather than three loose pieces.
local function ScalarSlider(parent, moduleName, config, key, text, x, y, fallback, minimum, maximum, tooltip, valueLabel, width, suffix)
    local rawValue = tonumber(Core.GetSetting(moduleName, key, ResolvedDefault(config, key, fallback))) or fallback
    local value = math.floor(rawValue + 0.5)
    if value < minimum then value = minimum end
    if value > maximum then value = maximum end
    if value ~= rawValue then SetSettingWithoutRefresh(moduleName, key, value) end

    local suffixText = suffix or ""
    local title = text or valueLabel
    -- The current value stays in the header badge; endpoint numbers are kept
    -- in the tooltip so tracks can align cleanly with the surrounding grid.
    local sliderWidth = math.min(width or 290, 680)
    -- Size the badge for the widest number it can ever show so it never
    -- resizes mid-drag.
    local widest = math.max(#tostring(math.floor(minimum)), #tostring(math.floor(maximum)))
    local badgeWidth = math.max(40, 20 + 8 * (widest + #suffixText))

    if title then
        local caption = Track(parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight"))
        caption:SetPoint("TOPLEFT", x, y - 3)
        caption:SetText(title)
        caption:SetJustifyH("LEFT")
        caption:SetTextColor(Unpack(TEXT))
    end

    -- Value badge, right-aligned with the end of the track.
    local badge = Track(CreateFrame("Frame", nil, parent))
    badge:SetSize(badgeWidth, 20)
    badge:SetPoint("TOPLEFT", x + sliderWidth - badgeWidth, y)
    local badgeEdge = Capsule(badge, "BACKGROUND", 20)
    badgeEdge:AnchorTo(badge, 0)
    badgeEdge:SetColor(Unpack(BRAND, 0.5))
    local badgeFill = Capsule(badge, "BORDER", 16)
    badgeFill:AnchorTo(badge, 2)
    badgeFill:SetColor(0.04, 0.05, 0.06, 1)
    local valueText = badge:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    valueText:SetPoint("CENTER", badge, "CENTER", 0, 0)
    valueText:SetTextColor(Unpack(BRAND))

    sliderSerial = sliderSerial + 1
    local slider = Track(CreateFrame("Slider", "AutoEverythingSettingsSlider" .. sliderSerial, parent))
    slider:SetPoint("TOPLEFT", x, y - 26)
    slider:SetSize(sliderWidth, 16)
    slider:SetOrientation("HORIZONTAL")
    slider:SetMinMaxValues(minimum, maximum)
    slider:SetValueStep(1)

    local line = slider:CreateTexture(nil, "BACKGROUND")
    line:SetTexture(WHITE_TEX)
    line:SetHeight(4)
    line:SetPoint("LEFT", slider, "LEFT", 0, 0)
    line:SetPoint("RIGHT", slider, "RIGHT", 0, 0)
    line:SetVertexColor(Unpack(TRACK_BG))

    slider:SetThumbTexture(WHITE_TEX)
    local thumb = slider:GetThumbTexture()
    if thumb then
        thumb:SetSize(16, 16)
        -- Invisible: the ball drawn over it is the visible handle. A slider
        -- decides what you grabbed from the thumb's rectangle, not its
        -- pixels, so a transparent thumb still drags.
        thumb:SetVertexColor(1, 1, 1, 0)

        -- Travelled portion of the track, anchored to the moving thumb so it
        -- follows the value with no per-frame maths.
        local fill = slider:CreateTexture(nil, "ARTWORK")
        fill:SetTexture(WHITE_TEX)
        fill:SetHeight(4)
        fill:SetPoint("LEFT", slider, "LEFT", 0, 0)
        fill:SetPoint("RIGHT", thumb, "CENTER", 0, 0)
        fill:SetVertexColor(Unpack(BRAND))

        local ball = slider:CreateTexture(nil, "OVERLAY")
        ball:SetTexture(CIRCLE_TEX)
        ball:SetSize(14, 14)
        ball:SetPoint("CENTER", thumb, "CENTER", 0, 0)
        ball:SetVertexColor(Unpack(BRAND))

        slider:HookScript("OnEnter", function() ball:SetVertexColor(1, 1, 1, 1) end)
        slider:HookScript("OnLeave", function() ball:SetVertexColor(Unpack(BRAND)) end)
    end

    local lastValue = value
    slider:SetValue(value)
    slider:SetScript("OnValueChanged", function(self, newValue)
        local rounded = math.floor((newValue or minimum) + 0.5)
        if rounded < minimum then rounded = minimum end
        if rounded > maximum then rounded = maximum end
        valueText:SetText(tostring(rounded) .. suffixText)
        if rounded ~= newValue then self:SetValue(rounded); return end
        if rounded ~= lastValue then
            lastValue = rounded
            SetSettingWithoutRefresh(moduleName, key, rounded)
        end
    end)
    valueText:SetText(tostring(value) .. suffixText)
    slider:EnableMouseWheel(true)
    slider:SetScript("OnMouseWheel", function(self, delta) self:SetValue(lastValue + (delta > 0 and 1 or -1)) end)

    -- The value badge doubles as precise entry, while a small reset control
    -- restores the shipped default. This keeps sliders quick without forcing
    -- players to drag to an exact number.
    badge:EnableMouse(true)
    badge:SetScript("OnMouseUp", function()
        PromptText("Enter " .. title .. " (" .. minimum .. " to " .. maximum .. ")", "Apply", function(text)
            local entered = tonumber(strtrim(text or ""))
            if not entered then Alert("Enter a number from " .. minimum .. " to " .. maximum .. "."); return end
            slider:SetValue(entered)
        end)
    end)
    AddTooltip(badge, title .. " value", "Click to type an exact value instead of dragging the slider.")

    AddTooltip(slider, title or "Setting", tooltip or ("Choose a value from " .. minimum .. " to " .. maximum .. "."))
    return slider
end

local function UpdateGlobalAutomationStatus()
    if not globalStatus and not globalToggle then return end
    local moduleDefaults = {
        loot = AutoLootConfig, junk = AutoJunkConfig, sell = AutoSellConfig,
        auction = AutoAuctionConfig, roll = AutoRollConfig,
        quest = AutoQuestConfig, buff = AutoBuffConfig, upgrade = AutoUpgradeConfig,
    }
    local active, total = 0, 0
    for moduleName, config in pairs(moduleDefaults) do
        total = total + 1
        if Core.GetSetting(moduleName, "enabled", config and config.enabled) ~= false then active = active + 1 end
    end
    if globalStatus then
        globalStatus:SetText(active .. " / " .. total .. " ACTIVE")
        globalStatus:SetTextColor(Unpack(active > 0 and BRAND or TEXT_MUTED))
    end
    if globalToggle then globalToggle:SetText(active > 0 and "Pause all" or "Enable all") end
end

local function Refresh(rebuild)
    if suppressRefresh then return end
    if not frame or not frame:IsShown() or not profileText or not pageHost then return end
    -- Menus are top-level Blizzard frames, not children of pageHost. Close
    -- them before replacing a page so they cannot remain over another panel.
    if openMenuButton and CloseOpenMenu then CloseOpenMenu() end
    profileText:SetText("Profile:  " .. Core.GetProfileName())
    UpdateGlobalAutomationStatus()
    HideAllPages()

    -- Paint navigation before constructing the destination page. If a page
    -- encounters bad saved data or an old-client API quirk, the sidebar still
    -- immediately reflects what the player clicked instead of leaving the
    -- previous highlight stuck.
    local activeNavPage = currentPage
    for name, button in pairs(navButtons) do
        button.selected = name == activeNavPage
        button.hovered = false
        button:Paint(false)
    end

    local cached = pageCache[currentPage]
    if rebuild and cached then
        -- Model changes are uncommon and may alter the number or shape of
        -- controls. Retire that page only then; ordinary opens and navigation
        -- reuse its existing UI objects instead of creating permanent frames.
        cached.frame:Hide()
        pageCache[currentPage] = nil
        cached = nil
    end
    if not cached and pageBuilders[currentPage] then
        local page = CreateFrame("Frame", nil, pageHost)
        -- The authored page grid is 724 pixels wide. Center it inside the
        -- 760-pixel host so the 12-pixel card gutters read equally on both
        -- sides instead of leaving all spare width on the right.
        page:SetPoint("TOPLEFT", pageHost, "TOPLEFT", PAGE_CANVAS_INSET, 0)
        page:SetPoint("BOTTOMRIGHT", pageHost, "BOTTOMRIGHT", -PAGE_CANVAS_INSET, 0)
        controls = {}
        pageBuilders[currentPage](page)
        cached = { frame = page, controls = controls }
        pageCache[currentPage] = cached
    end
    if cached then
        activePageFrame = cached.frame
        activePageFrame:Show()
    end

end
-- External model notifications require fresh values; internal page changes
-- call Refresh() and reuse the cached page. A nil module means a profile-wide
-- change, while a named module only retires pages that display that section.
local modulePages = {
    core = { "Overview", "General", "Convenience", "Groups & Queues" },
    junk = { "Overview", "Junk Rules" },
    loot = { "Overview", "Loot Rules" },
    sell = { "Overview", "Sell Rules" },
    auction = { "Overview", "Auction Rules" },
    roll = { "Overview", "Roll Rules" },
    quest = { "Overview", "Quest" },
    buff = { "Overview", "Buff" },
    upgrade = { "Overview", "Upgrade" },
}
Settings.Refresh = function(moduleName)
    -- Internal controls already paint their new value in place. Do not retire
    -- cached pages while one of those controls is handling its own update;
    -- hidden retired frames cannot be destroyed by the WoW client and would
    -- otherwise accumulate after every click.
    if suppressRefresh then return end
    local pages = moduleName and modulePages[moduleName]
    if pages then
        for _, pageName in ipairs(pages) do
            local cached = pageCache[pageName]
            if cached then cached.frame:Hide(); pageCache[pageName] = nil end
        end
    else
        for pageName, cached in pairs(pageCache) do
            cached.frame:Hide()
            pageCache[pageName] = nil
        end
    end
    Refresh(false)
end

-- Checkbox clicks must not rebuild and detach the button while WoW is still
-- processing its click. The module/cache update still happens immediately.
local function NotifyWithoutRefresh(moduleName)
    suppressRefresh = true
    Core.NotifyProfileChanged(moduleName)
    suppressRefresh = false
end

local function Confirm(text, onAccept)
    StaticPopupDialogs.AUTOEVERYTHING_CONFIRM = {
        text = text, button1 = YES, button2 = NO, timeout = 0,
        whileDead = true, hideOnEscape = true, preferredIndex = 3,
        OnAccept = onAccept,
    }
    StaticPopup_Show("AUTOEVERYTHING_CONFIRM")
end

-- A dismiss-only popup, for validation problems that need the player's
-- attention (e.g. a non-numeric stat weight) rather than a yes/no decision.
Alert = function(text)
    StaticPopupDialogs.AUTOEVERYTHING_ALERT = {
        text = text, button1 = OKAY or "OK", timeout = 0,
        whileDead = true, hideOnEscape = true, preferredIndex = 3,
    }
    StaticPopup_Show("AUTOEVERYTHING_ALERT")
end

-- A native single-line text prompt (Blizzard's StaticPopup edit box), used
-- instead of a hand-built nested frame - it renders above everything with no
-- frame-strata bookkeeping of our own, and Enter/Escape already work.
PromptText = function(text, buttonLabel, onAccept)
    StaticPopupDialogs.AUTOEVERYTHING_PROMPT = {
        text = text, button1 = buttonLabel, button2 = CANCEL,
        hasEditBox = true, maxLetters = 120, timeout = 0,
        whileDead = true, hideOnEscape = true, preferredIndex = 3,
        OnShow = function(self) self.editBox:SetText(""); self.editBox:SetFocus() end,
        OnAccept = function(self) onAccept(self.editBox:GetText()) end,
        EditBoxOnEnterPressed = function(self)
            onAccept(self:GetText())
            self:GetParent():Hide()
        end,
        EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    }
    StaticPopup_Show("AUTOEVERYTHING_PROMPT")
end

----------------------------------------------------------------------
-- Overview
----------------------------------------------------------------------
-- A calm landing page: every module exposes its current state, a useful
-- one-line summary, and a direct route to its detailed configuration.
pageBuilders.Overview = function(parent)
    PageHeader(parent, "Overview", "Your automation at a glance. Changes are saved immediately to the active profile.")

    local modules = {
        { "Loot", "loot", AutoLootConfig, "Loot only items matched by your items-to-loot rules.", "Loot Rules", "rules" },
        { "Junk", "junk", AutoJunkConfig, "Keep bag space clear using your junk rules.", "Junk Rules", "rules" },
        { "Sell", "sell", AutoSellConfig, "Sell matched items and protect important gear.", "Sell Rules", "rules" },
        { "Auction", "auction", AutoAuctionConfig, "Price and post auctionable items through guarded rules.", "Auction Rules", "rules" },
        { "Roll", "roll", AutoRollConfig, "Handle group loot using your roll priorities.", "Roll Rules", "rules" },
        { "Quest", "quest", AutoQuestConfig, "Automate quest interactions and objective markers.", "Quest" },
        { "Buff", "buff", AutoBuffConfig, "Track configured buffs and prepare the next secure cast.", "Buff" },
        { "Upgrade", "upgrade", AutoUpgradeConfig, "Score equipment and equip meaningful upgrades.", "Upgrade" },
    }

    local CARD_W, CARD_H = 330, 118
    local X = { 22, 372 }
    local Y = { -82, -208, -334, -460 }
    local stateButtons = {}
    for index, item in ipairs(modules) do
        -- Copy loop values into per-card locals. Older Lua clients reuse the
        -- generic-for control variable, which would otherwise make every
        -- callback open or toggle the final module in the list.
        local moduleLabel, moduleName, moduleConfig = item[1], item[2], item[3]
        local moduleDescription, modulePage = item[4], item[5]
        local rulesKey, safetyRulesKey = item[6], item[7]
        local column = ((index - 1) % 2) + 1
        local row = math.floor((index - 1) / 2) + 1
        local card = Track(CreateFrame("Frame", nil, parent))
        card:SetSize(CARD_W, CARD_H)
        card:SetPoint("TOPLEFT", X[column], Y[row])
        UI.Backdrop(card, COLORS.surface, 1)

        local accent = card:CreateTexture(nil, "ARTWORK")
        accent:SetTexture(WHITE_TEX)
        accent:SetPoint("TOPLEFT", card, "TOPLEFT", 0, 0)
        accent:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 0, 0)
        accent:SetWidth(2)
        accent:SetVertexColor(Unpack(BRAND, 0.85))

        local title = card:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        title:SetPoint("TOPLEFT", 16, -14)
        title:SetText("Auto" .. moduleLabel)
        title:SetTextColor(Unpack(TEXT))
        ApplyUIFont(title, 15)

        local enabled = Core.GetSetting(moduleName, "enabled", ResolvedDefault(moduleConfig, "enabled", true))
        local state = SkinnedButton(card, enabled and "Active" or "Paused", 240, -10, 74, function()
            local isEnabled = Core.GetSetting(moduleName, "enabled", ResolvedDefault(moduleConfig, "enabled", true)) ~= false
            SetSettingWithoutRefresh(moduleName, "enabled", not isEnabled)
            if overviewRefresh then overviewRefresh() end
            local navButton = navButtons[modulePage]
            if navButton then navButton:Paint() end
            UpdateGlobalAutomationStatus()
        end, 24)
        stateButtons[moduleName] = state
        state:HookScript("OnLeave", function()
            if overviewRefresh then overviewRefresh() end
        end)
        AddTooltip(state, "Toggle Auto" .. moduleLabel, "Enable or pause this module for the active profile.")

        local description = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        description:SetPoint("TOPLEFT", 16, -39)
        description:SetWidth(296)
        description:SetJustifyH("LEFT")
        description:SetText(moduleDescription)
        description:SetTextColor(Unpack(TEXT_MUTED))
        ApplyUIFont(description, 11)

        local detailValue
        if moduleName == "loot" then
            detailValue = "Fast looting: " .. (Core.GetSetting("loot", "fasterLooting", true) and "On" or "Off")
        elseif moduleName == "junk" then
            detailValue = "Mode: " .. (Core.GetSetting("junk", "deleteMode", "target") == "target" and "Maintain free slots" or "Immediate")
        elseif moduleName == "sell" then
            local repair = Core.GetSetting("sell", "autoRepair", AutoSellConfig.autoRepair or {}) or {}
            detailValue = "Auto repair: " .. (repair.enabled == false and "Off" or (repair.useGuildBank == false and "Personal gold" or "Guild funds"))
        elseif moduleName == "auction" then
            detailValue = "Posting: " .. (Core.GetSetting("auction", "postingMode", "queue") == "auto" and "Automatic" or "Preview queue")
        elseif moduleName == "roll" then
            detailValue = "Automation: " .. (Core.GetSetting("roll", "notifyOnly", false) and "Notify only" or "Automatic")
        elseif moduleName == "quest" then
            detailValue = "Map icons: " .. (Core.GetSetting("quest", "mapPins", true) and "On" or "Off")
        elseif moduleName == "buff" then
            local buffs = Core.GetSetting("buff", "buffs", AutoBuffConfig and AutoBuffConfig.buffs) or {}
            detailValue = "Configured buffs: " .. tostring(#buffs)
        elseif moduleName == "upgrade" then
            detailValue = "Auto equip: " .. (Core.GetSetting("upgrade", "autoEquip", true) and "On" or "Off")
        end
        local detail = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        detail:SetPoint("TOPLEFT", 16, -61)
        detail:SetText(detailValue or "")
        detail:SetTextColor(Unpack(TEXT))
        ApplyUIFont(detail, 11)

        if rulesKey then
            local section = Core.GetProfileSection(moduleName, false) or {}
            local count = type(section[rulesKey]) == "table" and #section[rulesKey] or 0
            if safetyRulesKey and type(section[safetyRulesKey]) == "table" then count = count + #section[safetyRulesKey] end
            local rules = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            rules:SetPoint("BOTTOMLEFT", 16, 34)
            rules:SetText(count .. (count == 1 and " configured rule" or " configured rules"))
            rules:SetTextColor(Unpack(TEXT_MUTED))
            ApplyUIFont(rules, 10)
        end

        local configure = Button(card, "Configure  >", 202, -84, 112, function()
            currentPage = modulePage
            Refresh()
        end, 24)
        AddTooltip(configure, "Configure Auto" .. moduleLabel, "Open this module's detailed settings.")
    end

    -- Match the footer edges to the overview card columns and center both
    -- summary rows so the final card follows the same visual axis.
    SectionCard(parent, 22, -586, 680, 48)
    local profileSummary = Label(parent, "", 22, -598, 13)
    profileSummary:SetWidth(680)
    profileSummary:SetJustifyH("CENTER")
    profileSummary:SetTextColor(Unpack(TEXT))
    overviewRefresh = function()
        local active = 0
        for _, item in ipairs(modules) do
            local enabled = Core.GetSetting(item[2], "enabled", ResolvedDefault(item[3], "enabled", true)) ~= false
            if enabled then active = active + 1 end
            local state = stateButtons[item[2]]
            if state then
                state:SetText(enabled and "Active" or "Paused")
                local stateText = state.GetFontString and state:GetFontString()
                if stateText then stateText:SetTextColor(Unpack(enabled and BRAND or TEXT_MUTED)) end
                if enabled then
                    state:SetBackdropColor(BRAND[1] * 0.14, BRAND[2] * 0.14, BRAND[3] * 0.14, 1)
                    state:SetBackdropBorderColor(Unpack(BRAND))
                else
                    state:SetBackdropColor(Unpack(CTRL_BG))
                    state:SetBackdropBorderColor(Unpack(BORDER))
                end
            end
        end
        profileSummary:SetText("Profile: " .. Core.GetProfileName() .. "   |cff" .. BRAND_HEX
            .. active .. " of " .. #modules .. " modules active|r")
    end
    overviewRefresh()
    local upgradeSection = Core.GetProfileSection("upgrade", false) or {}
    local hasWeight = false
    for _, value in pairs(upgradeSection.weights or {}) do
        if tonumber(value) and tonumber(value) ~= 0 then hasWeight = true; break end
    end
    if Core.GetSetting("upgrade", "enabled", true) and not hasWeight then
        local warning = Label(parent, "!  Upgrade weights need review", 470, -598, 12)
        warning:SetTextColor(0.95, 0.68, 0.24)
        AddTooltip(warning, "Configuration warning", "AutoUpgrade is enabled but every stat weight is zero. Configure weights or import a set before relying on item scores.")
    end
    local session = Core.GetSessionSummary and Core.GetSessionSummary() or {}
    local sessionText = #session > 0 and table.concat(session, "   •   ", 1, math.min(3, #session)) or "Session statistics begin after login."
    local sessionSummary = Label(parent, sessionText, 22, -620)
    sessionSummary:SetWidth(680)
    sessionSummary:SetJustifyH("CENTER")
    sessionSummary:SetTextColor(Unpack(TEXT_MUTED))
end

----------------------------------------------------------------------
-- Profiles
----------------------------------------------------------------------
-- A multi-line, editable box inside a scroll frame. Export fills it and selects
-- all so Ctrl+C just works; import reads whatever was pasted in.
local function TextBox(parent, x, y, width, height)
    local scroll = Track(CreateFrame("ScrollFrame", nil, parent))
    scroll:SetPoint("TOPLEFT", x, y); scroll:SetSize(width, height)
    scroll:EnableMouseWheel(true); scroll:EnableMouse(true)
    local backdrop = Track(CreateFrame("Frame", nil, parent))
    backdrop:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
    backdrop:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", 0, 0)
    UI.Backdrop(backdrop, COLORS.control, 1)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetWidth(width - 18)          -- leave the right edge clear for the slim scrollbar; height auto-fits text
    edit:SetAutoFocus(false)
    edit:SetFontObject(ChatFontNormal)
    edit:SetTextInsets(6, 6, 4, 4)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    edit:SetScript("OnEditFocusGained", function(self) focusedEditBox = self end)
    edit:SetScript("OnEditFocusLost", function(self) if focusedEditBox == self then focusedEditBox = nil end end)
    scroll:SetScrollChild(edit)
    -- Clicking the empty area below a short entry still focuses the box. Done on
    -- mouse-up so it runs after Track()'s mouse-down handler (which clears the
    -- previously focused field) rather than being undone by it.
    scroll:SetScript("OnMouseUp", function() edit:SetFocus() end)

    local SCROLL_STEP = 40
    local scrollbar = Track(UI.CreateVerticalScrollbar(parent, height - 4, function(value)
        scroll:SetVerticalScroll(value)
    end, SCROLL_STEP))
    scrollbar:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", -2, -2)
    local function UpdateScrollbar()
        local maxScroll = math.max(0, (edit:GetHeight() or 0) - height)
        scrollbar:SetScrollRange(maxScroll, scroll:GetVerticalScroll() or 0)
    end
    local function ScrollBy(delta)
        local maxScroll = math.max(0, (edit:GetHeight() or 0) - height)
        local value = (scroll:GetVerticalScroll() or 0) + delta
        if value < 0 then value = 0 elseif value > maxScroll then value = maxScroll end
        scrollbar:SetScrollRange(maxScroll, value)
    end
    scroll:SetScript("OnMouseWheel", function(_, delta) ScrollBy(delta > 0 and -SCROLL_STEP or SCROLL_STEP) end)
    edit:EnableMouseWheel(true)
    edit:SetScript("OnMouseWheel", function(_, delta) ScrollBy(delta > 0 and -SCROLL_STEP or SCROLL_STEP) end)
    edit:SetScript("OnTextChanged", UpdateScrollbar)
    return edit
end

pageBuilders.Profiles = function(parent)
    SectionCard(parent, 12, -88, 700, 160)
    SectionCard(parent, 12, -258, 700, 170)
    SectionCard(parent, 12, -440, 700, 112)
    Label(parent, "Profiles", 20, -20, 18)
    local intro = Label(parent, "Profiles are account-wide and hold every setting and rule. "
        .. "Each character remembers which one it uses, so you can keep a melee profile and a caster "
        .. "profile and switch between them at any time - or with /ae profile <name>.", 20, -50)
    intro:SetWidth(690)

    local names = Core.GetProfileNames()
    local GAP = 10
    local COL_X, FIELD_W, BTN_W = 20, 300, 110
    local COL2 = COL_X + FIELD_W + GAP

    Label(parent, "Available profiles", 20, -100, 14)
    local activeProfile = Core.GetProfileName()
    local profileSelector = Button(parent, activeProfile, 20, -124, 310, function(self)
        local entries = {}
        for _, profileName in ipairs(names) do
            local name = profileName
            local users = Core.GetProfileUsers(name)
            local suffix = #users .. (#users == 1 and " character" or " characters")
            table.insert(entries, {
                text = MenuLabel(name .. "   •   " .. suffix, name == activeProfile),
                notCheckable = true,
                func = function()
                    local ok, err = Core.SetProfile(name)
                    if not ok then Core.Warn("Settings", err) end
                end,
            })
        end
        ShowMenu(self, entries)
    end)
    AddDropdownIndicator(profileSelector)
    AddTooltip(profileSelector, "Available profiles", "Choose the active profile for this character.")

    Label(parent, "Manage active profile", 356, -100, 14)
    local activeUsers = Core.GetProfileUsers(Core.GetProfileName())
    local usage = Label(parent, Core.GetProfileName() .. " • " .. #activeUsers
        .. (#activeUsers == 1 and " character" or " characters"), 356, -124)
    usage:SetTextColor(Unpack(TEXT_MUTED))
    local nameBox = Edit(parent, 356, -150, 336, "")
    AddEditHint(nameBox, "Profile name", "Used by New and Rename. Duplicate uses it when provided, or creates an automatic copy name.")
    local profileError = Label(parent, "", 356, -216)
    profileError:SetWidth(336)
    profileError:SetTextColor(1, 0.35, 0.25)
    profileError:Hide()
    local function ShowProfileError(err)
        profileError:SetText(err or "Unable to update the profile.")
        profileError:Show()
        nameBox:SetBackdropBorderColor(Unpack(CLOSE_RED))
    end

    local function UniqueCopyName(base)
        local existing = {}
        for _, name in ipairs(Core.GetProfileNames()) do existing[name] = true end
        if not existing[base .. " (Copy)"] then return base .. " (Copy)" end
        local suffix = 2
        while existing[base .. " (Copy " .. suffix .. ")"] do suffix = suffix + 1 end
        return base .. " (Copy " .. suffix .. ")"
    end
    local newButton = Button(parent, "New", 356, -184, 104, function()
        local ok, err = Core.CreateProfile(nameBox:GetText())
        if ok then nameBox:SetText(""); profileError:Hide() else ShowProfileError(err) end
    end)
    EmphasizeButton(newButton, BRAND)
    AddTooltip(newButton, "New profile", "Creates a profile from addon defaults and switches this character to it.")
    local copyButton = Button(parent, "Duplicate", 472, -184, 104, function()
        local current = Core.GetProfileName()
        local typed = strtrim(nameBox:GetText() or "")
        local newName = typed ~= "" and typed or UniqueCopyName(current)
        local ok, err = Core.CreateProfile(newName, current)
        if ok then nameBox:SetText(""); profileError:Hide(); Core.Info("Settings", "Copied as '" .. newName .. "'.")
        else ShowProfileError(err) end
    end)
    AddTooltip(copyButton, "Duplicate profile", "Copies every setting and rule from the active profile.")
    local renameButton = Button(parent, "Rename", 588, -184, 104, function()
        local ok, err = Core.RenameProfile(Core.GetProfileName(), nameBox:GetText())
        if ok then nameBox:SetText(""); profileError:Hide() else ShowProfileError(err) end
    end)
    AddTooltip(renameButton, "Rename profile", "Renames the active profile for every character using it.")

    ---------------------------------------------------------------- sharing
    local scopeChoices = { { text = "Whole profile", value = "all" }, { text = "Stat weights only", value = "weights" } }
    for _, moduleName in ipairs(Core.MODULE_ORDER) do
        table.insert(scopeChoices, { text = Core.MODULE_LABELS[moduleName] .. " only", value = moduleName })
    end
    local exportScope = "all"

    Label(parent, "Share and restore", COL_X, -272, 14)
    local shareDescription = Label(parent, "Export opens selected text ready to copy. Import uses a focused paste window.", COL_X, -296)
    shareDescription:SetTextColor(Unpack(TEXT_MUTED))
    local scopeButton = ChoiceButton(parent, "Export", COL_X, -326, FIELD_W, scopeChoices, exportScope, function(value)
        exportScope = value
    end)
    AddTooltip(scopeButton, "What to export", "Export the whole profile, just your stat weights, or one module's settings and rules.")
    local exportButton = Button(parent, "Copy Export", COL2, -326, BTN_W, function()
        local text, err = Core.Export(exportScope)
        if not text then Core.Warn("Settings", err or "Nothing to export."); return end
        OpenTextPopup({
            title = "Export " .. Core.GetProfileName(),
            subtitle = "The export is selected. Press Ctrl+C to copy it, then close this window.",
            text = text,
        })
    end)
    EmphasizeButton(exportButton, BRAND)
    AddTooltip(exportButton, "Copy export", "Opens the selected export in a copy-ready window.")

    local function ParseProfileImport(text)
        local payload, err = Core.ParseImport(text)
        if not payload then Core.Warn("Settings", err); return nil end
        if payload.kind == "rule" then
            Core.Warn("Settings", "Single rules are imported from the module rule page.")
            return nil
        end
        return payload
    end

    local applyButton = Button(parent, "Import into Current", COL_X, -370, 210, function()
        OpenTextPopup({
            title = "Import into " .. Core.GetProfileName(),
            subtitle = "Paste a settings export. You will confirm before matching settings are replaced.",
            acceptLabel = "Review Import",
            onAccept = function(text)
                local payload = ParseProfileImport(text)
                if not payload then return false end
                Confirm("Import " .. Core.DescribeImport(payload) .. " into '" .. Core.GetProfileName()
                    .. "'? This replaces those settings.", function()
                    local ok, importErr = Core.Import(payload)
                    if ok then Core.Info("Settings", "Import complete.")
                    else Core.Warn("Settings", importErr or "Import failed.") end
                end)
                return true
            end,
        })
    end)
    EmphasizeButton(applyButton, BRAND)
    AddTooltip(applyButton, "Import into current profile", "Replaces only the settings contained in the export; everything else remains untouched.")

    local asNewButton = Button(parent, "Import as New Profile", 240, -370, 210, function()
        OpenTextPopup({
            title = "Import as New Profile",
            subtitle = "Paste an export to create a separate profile. A name typed above overrides its exported name.",
            acceptLabel = "Create Profile",
            onAccept = function(text)
                local payload = ParseProfileImport(text)
                if not payload then return false end
                local typed = strtrim(nameBox:GetText() or "")
                local ok, importErr = Core.ImportAsNewProfile(payload, typed ~= "" and typed or nil)
                if not ok then Core.Warn("Settings", importErr or "Import failed."); return false end
                nameBox:SetText("")
                Core.Info("Settings", "Imported as a new profile.")
                return true
            end,
        })
    end)
    AddTooltip(asNewButton, "Import as new profile", "Creates a new profile instead of overwriting the current one.")

    ---------------------------------------------------------------- danger
    Label(parent, "Danger zone", COL_X, -454, 14)
    local dangerText = Label(parent, "These actions permanently change the active profile and always ask for confirmation.", COL_X, -478)
    dangerText:SetTextColor(Unpack(TEXT_MUTED))
    local resetButton = Button(parent, "Reset to Defaults", COL_X, -510, 160, function()
        Confirm("Reset profile '" .. Core.GetProfileName() .. "' to the addon defaults?",
            function() Core.ResetProfile() end)
    end)
    AddTooltip(resetButton, "Reset to defaults", "Restores the shipped rules and settings in this profile.")
    local deleteButton = Button(parent, "Delete Profile", 190, -510, 160, function()
        local current = Core.GetProfileName()
        local currentUsers = Core.GetProfileUsers(current)
        local warning = ""
        if #currentUsers > 1 then warning = " It is also used by " .. (#currentUsers - 1) .. " other character(s)." end
        Confirm("Delete profile '" .. current .. "'?" .. warning, function()
            local ok, err = Core.DeleteProfile(current)
            if not ok then Core.Warn("Settings", err) end
        end)
    end)
    EmphasizeButton(deleteButton, CLOSE_RED)
    AddTooltip(deleteButton, "Delete this profile", "Permanently removes the profile. Characters using it fall back to another profile.")
end

----------------------------------------------------------------------
-- Scalar settings pages
----------------------------------------------------------------------
pageBuilders.General = function(parent)
    PageHeader(parent, "General", "Interface preferences and shared display behavior.")
    FitSectionCard(parent, 12, -76, 700, -214)
    FitSectionCard(parent, 12, -240, 700, -298)

    Label(parent, "Interface", 20, -84, 13)
    ScalarSettingRow(parent, "core", AutoCoreConfig, "showLoginSummary", "Show login summary",
        20, -116, true,
        "Prints one combined status line for all modules when you log in.")
    ScalarSettingRow(parent, "core", AutoCoreConfig, "showMinimapButton", "Show minimap button",
        20, -144, true,
        "Shows the automation icon on the minimap for quick access to status and toggles.")
    ScalarSettingRow(parent, "core", AutoCoreConfig, "showLFGMinimapButton", "Show group finder button",
        20, -172, true,
        "Shows a separate minimap button that opens the group-request bulletin board.")
    ScalarSettingRow(parent, "core", AutoCoreConfig, "showSessionInTooltip", "Show session stats on minimap",
        20, -200, true,
        "Shows this session's gold, items sold, junk deleted, and repair costs on the minimap button tooltip.")
    ScalarSettingRow(parent, "core", AutoCoreConfig, "showPlayerItemLevel", "Show player item level",
        390, -200, true,
        "Adds the average equipped item level to player hover tooltips. Nearby players are inspected automatically when the client allows it; recent results are cached briefly.")
    ScalarSettingRow(parent, "core", AutoCoreConfig, "setCameraDistance", "Set camera zoom",
        390, -116, true,
        "Raises the maximum camera zoom-out distance to the value below, past the game's normal default limit.")
    ScalarSlider(parent, "core", AutoCoreConfig, "cameraDistanceMax", nil, 390, -152, 50, 10, 50,
        "Sets the maximum camera zoom distance. Changes apply immediately while the camera-zoom option above is enabled.",
        "Camera Zoom", 310)

    -- Verbose diagnostics remain a slash-command troubleshooting switch,
    -- rather than a persistent interface preference.
    Label(parent, "ElvUI Action Bar Cooldowns", 20, -248, 13)
    ScalarSettingRow(parent, "core", AutoCoreConfig, "disableActionBarSwipe", "Disable cooldown swipe",
        20, -284, false,
        "Hides the dark radial cooldown sweep on ElvUI action buttons. ElvUI's cooldown numbers remain visible.")
    ScalarSettingRow(parent, "core", AutoCoreConfig, "disableActionBarBling", "Disable cooldown bling",
        390, -284, false,
        "Suppresses the blue-white shine animation when an ElvUI action-button cooldown finishes.")
end

pageBuilders.Convenience = function(parent)
    PageHeader(parent, "Convenience", "Optional world, safety, social, and NPC interaction behavior.")
    FitSectionCard(parent, 12, -76, 340, -242)
    FitSectionCard(parent, 370, -76, 342, -186)
    FitSectionCard(parent, 12, -268, 340, -426)
    FitSectionCard(parent, 370, -212, 342, -434)

    Label(parent, "Safety", 20, -84, 13)
    local resurrect = ScalarSettingRow(parent, "core", AutoCoreConfig, "autoAcceptResurrect",
        "Auto accept resurrection", 20, -116, false,
        "Accepts resurrection offers using the safety restrictions directly below.")
    local resurrectInstances = ScalarSettingRow(parent, "core", AutoCoreConfig,
        "autoAcceptResurrectInstancesOnly", "Instances only", 50, -144, true,
        "Only accepts resurrection offers in dungeons, raids, and battlegrounds.")
    local resurrectCombat = ScalarSettingRow(parent, "core", AutoCoreConfig,
        "autoAcceptResurrectOutOfCombatOnly", "Out of combat only", 50, -172, true,
        "Leaves resurrection offers manual while you are in combat.")
    local resurrectVisible = ScalarSettingRow(parent, "core", AutoCoreConfig,
        "autoAcceptResurrectVisibleOffererOnly", "Visible offerer only", 50, -200, true,
        "Requires the offerer to be a visible, out-of-combat party or raid member.")
    ScalarSettingRow(parent, "core", AutoCoreConfig, "autoDeclineDuels", "Auto decline duels",
        20, -228, false,
        "Declines duel requests unless Shift is held when the request arrives.")
    BindToggleDependency(resurrect, resurrectInstances, resurrectCombat, resurrectVisible)

    Label(parent, "World", 378, -84, 13)
    ScalarSettingRow(parent, "core", AutoCoreConfig, "autoDismount", "Auto dismount",
        378, -116, false,
        "Dismounts after the client rejects an action because you are mounted, and before opening an enabled single-option flight map. Repeat the original rejected action once dismounted.")
    ScalarSettingRow(parent, "core", AutoCoreConfig, "skipCinematics", "Skip cinematics",
        378, -144, false,
        "Automatically skips in-game cinematics and movies - including first-time story scenes.")
    ScalarSettingRow(parent, "core", AutoCoreConfig, "autoLearnTrainerSpells", "Auto learn trainer spells",
        378, -172, false,
        "When you open a class/profession trainer, buys every available spell you can afford, cheapest first. This spends your gold.")

    Label(parent, "Whisper Invites", 20, -276, 13)
    local whisperInvite = ScalarSettingRow(parent, "core", AutoCoreConfig, "autoInviteOnWhisper",
        "Auto invite on whisper", 20, -308, false,
        "Sends a party or raid invite to anyone who whispers you the keyword below. The keyword is matched anywhere in the message. In a raid, you must be the leader or an assistant.")
    local whisperFriends = ScalarSettingRow(parent, "core", AutoCoreConfig, "autoInviteFriendsOnly",
        "Only from friends/guild", 50, -336, false,
        "When auto-inviting on a whisper, only invite friends or guildmates.")
    BindToggleDependency(whisperInvite, whisperFriends)
    Label(parent, "Keyword", 50, -368, 11)
    local keyword = Core.GetSetting("core", "autoInviteKeyword",
        ResolvedDefault(AutoCoreConfig, "autoInviteKeyword", "inv"))
    local keyEdit = Edit(parent, 130, -362, 200, keyword)
    local function SaveKeyword(self)
        SetSettingWithoutRefresh("core", "autoInviteKeyword", strtrim(self:GetText() or ""))
    end
    keyEdit:SetScript("OnEnterPressed", function(self) SaveKeyword(self); self:ClearFocus() end)
    keyEdit:HookScript("OnEditFocusLost", SaveKeyword)
    AddEditHint(keyEdit, "inv",
        "The whisper keyword that triggers an automatic group invite. Matched as a case-insensitive substring, "
        .. "so \"inv\" also fires on \"invite\" or \"invite me warrior\".")
    Label(parent, "Minimum level", 50, -400, 11)
    local minimumLevel = Core.GetSetting("core", "autoInviteMinimumLevel",
        ResolvedDefault(AutoCoreConfig, "autoInviteMinimumLevel", 0))
    local levelEdit = Edit(parent, 180, -394, 150, minimumLevel)
    local function SaveMinimumLevel(self)
        local value = tonumber(strtrim(self:GetText() or ""))
        if not value then
            value = Core.GetSetting("core", "autoInviteMinimumLevel",
                ResolvedDefault(AutoCoreConfig, "autoInviteMinimumLevel", 0))
        end
        value = math.max(0, math.min(60, math.floor(value)))
        self:SetText(tostring(value))
        SetSettingWithoutRefresh("core", "autoInviteMinimumLevel", value)
    end
    levelEdit:SetScript("OnEnterPressed", function(self) SaveMinimumLevel(self); self:ClearFocus() end)
    levelEdit:HookScript("OnEditFocusLost", SaveMinimumLevel)
    AddEditHint(levelEdit, "0",
        "The lowest character level allowed for keyword invites (0 to 60). Zero allows any level. "
        .. "Unknown players are checked with an exact Who lookup, so their invite may be delayed a few seconds. "
        .. "If their level cannot be verified, they are not invited.")

    Label(parent, "NPC Interactions", 378, -220, 13)
    local autoGossip = ScalarSettingRow(parent, "core", AutoCoreConfig, "autoSelectSingleGossip",
        "Auto gossip", 378, -252, true,
        "Automatically selects an eligible sole gossip option. Enable only the service types wanted below.")
    local gossipFields = {
        { "autoGossipVendor", "Open vendor", 408, -280,
            "Selects a sole Vendor option. It does not buy or sell anything by itself." },
        { "autoGossipTrainer", "Open trainer", 408, -308,
            "Selects a sole Trainer option. Trainer purchases still follow their separate setting." },
        { "autoGossipTaxi", "Open flight map", 408, -336,
            "Selects a sole Flight Master option. It does not choose or purchase a flight." },
        { "autoGossipBanker", "Open bank", 408, -364,
            "Selects a sole Banker option." },
        { "autoGossipBattlemaster", "Open battleground list", 408, -392,
            "Selects a sole Battlemaster option. It does not queue for a battleground." },
        { "autoGossipInnkeeper", "Open bind confirmation", 408, -420,
            "Selects a sole Innkeeper bind option but never confirms changing your home location." },
    }
    local gossipControls = {}
    for _, field in ipairs(gossipFields) do
        gossipControls[#gossipControls + 1] = ScalarSettingRow(parent, "core", AutoCoreConfig,
            field[1], field[2], field[3], field[4], false, field[5])
    end
    BindToggleDependency(autoGossip, unpack(gossipControls))
end

pageBuilders["Groups & Queues"] = function(parent)
    PageHeader(parent, "Groups & Queues", "Party prompts, Dungeon Finder flow, and battleground automation in one place.")
    FitSectionCard(parent, 12, -76, 340, -306)
    FitSectionCard(parent, 370, -76, 342, -317)
    FitSectionCard(parent, 12, -372, 700, -513)

    Label(parent, "Party & Raid", 20, -84, 13)
    ScalarSettingRow(parent, "core", AutoCoreConfig, "autoAcceptReadyCheck",
        "Auto accept ready checks", 20, -116, false,
        "Automatically confirms a party or raid ready check.")
    ScalarSettingRow(parent, "core", AutoCoreConfig, "autoConfirmSummon",
        "Auto accept summons", 20, -144, false,
        "Accepts warlock and meeting-stone summons using the timing directly below.")
    local summonMode = Core.GetSetting("core", "summonAcceptMode",
        ResolvedDefault(AutoCoreConfig, "summonAcceptMode", "delayed"))
    local summonModeButton = ChoiceButton(parent, "Summons", 20, -172, 310, {
        { text = "Accept near expiration", value = "delayed" },
        { text = "Accept immediately", value = "immediate" },
    }, summonMode, function(value)
        SetSettingWithoutRefresh("core", "summonAcceptMode", value)
    end)
    AddTooltip(summonModeButton, "Summon timing",
        "Choose immediate acceptance or wait until the summon is near expiration.")
    local summonSeconds = Core.GetSetting("core", "summonAcceptSeconds",
        ResolvedDefault(AutoCoreConfig, "summonAcceptSeconds", 3))
    local summonDelayButton = ChoiceButton(parent, "Delayed at", 20, -204, 310, {
        { text = "1 second remaining", value = 1 },
        { text = "2 seconds remaining", value = 2 },
        { text = "3 seconds remaining", value = 3 },
        { text = "5 seconds remaining", value = 5 },
        { text = "10 seconds remaining", value = 10 },
    }, summonSeconds, function(value)
        SetSettingWithoutRefresh("core", "summonAcceptSeconds", value)
    end)
    AddTooltip(summonDelayButton, "Delayed summon acceptance",
        "When summon timing is delayed, accepts at this many seconds remaining.")
    local partyInvite = ScalarSettingRow(parent, "core", AutoCoreConfig, "autoAcceptGroupInvite",
        "Auto accept party invites", 20, -236, false,
        "Automatically accepts party or raid invitations using the restrictions below.")
    local partyInviteFriends = ScalarSettingRow(parent, "core", AutoCoreConfig,
        "autoAcceptInviteFriendsOnly", "Only from friends/guild", 50, -264, true,
        "Only accepts invitations from friends or guildmates.")
    local partyInviteQueued = ScalarSettingRow(parent, "core", AutoCoreConfig,
        "autoAcceptInviteWhileQueued", "Accept while queued", 50, -292, false,
        "Allows party invitations while a battleground or Dungeon Finder queue or proposal is active.")
    BindToggleDependency(partyInvite, partyInviteFriends, partyInviteQueued)

    Label(parent, "Dungeon Finder", 378, -84, 13)
    local roleCheck = ScalarSettingRow(parent, "core", AutoCoreConfig, "autoAcceptLFGRoleCheck",
        "Accept role check", 378, -116, false,
        "Chooses the role below and confirms the Dungeon Finder role check.")
    local role = Core.GetSetting("core", "lfgAutoRole", ResolvedDefault(AutoCoreConfig, "lfgAutoRole", "current"))
    local roleButton = ChoiceButton(parent, "Role", 378, -144, 310, {
        { text = "Keep current selection", value = "current" },
        { text = "Tank", value = "tank" },
        { text = "Healer", value = "healer" },
        { text = "Damage", value = "damage" },
    }, role, function(value) SetSettingWithoutRefresh("core", "lfgAutoRole", value) end)
    AddTooltip(roleButton, "Role-check selection",
        "Keep current selection confirms the roles already checked in Dungeon Finder. A named role replaces them before confirmation.")
    local dungeonExit = ScalarSettingRow(parent, "core", AutoCoreConfig, "autoExitCompletedDungeon",
        "Exit completed dungeon", 378, -176, false,
        "After the Dungeon Finder completion reward, shows a countdown with Cancel before teleporting out. Leaving the party is controlled separately below.")
    local dungeonPartyLeave = ScalarSettingRow(parent, "core", AutoCoreConfig, "autoLeaveDungeonParty",
        "Leave party when exiting", 408, -204, false,
        "After teleporting out of a completed dungeon, leaves the current party. Only applies to automatic dungeon departure.")
    local dungeonExitDelay = Core.GetSetting("core", "dungeonExitDelay",
        ResolvedDefault(AutoCoreConfig, "dungeonExitDelay", 10))
    local shortDungeonDelays = { [5] = true, [10] = true, [15] = true, [20] = true, [30] = true }
    if not shortDungeonDelays[tonumber(dungeonExitDelay)] then dungeonExitDelay = 10 end
    local dungeonDelayButton = ChoiceButton(parent, "Departure timer", 378, -232, 310, {
        { text = "5 seconds", value = 5 },
        { text = "10 seconds", value = 10 },
        { text = "15 seconds", value = 15 },
        { text = "20 seconds", value = 20 },
        { text = "30 seconds", value = 30 },
    }, dungeonExitDelay, function(value) SetSettingWithoutRefresh("core", "dungeonExitDelay", value) end)
    AddTooltip(dungeonDelayButton, "Dungeon departure timer",
        "Waits after completion before teleporting out. Cancel keeps you in the dungeon for the rest of that run so the group can continue.")
    local dungeonRequeue = ScalarSettingRow(parent, "core", AutoCoreConfig, "autoRequeueDungeon",
        "Requeue after exiting", 408, -264, false,
        "After automatic dungeon departure and optional party leave, shows a second cancellable timer before rejoining the retained Dungeon Finder selection.")
    local dungeonRequeueDelay = Core.GetSetting("core", "dungeonRequeueDelay",
        ResolvedDefault(AutoCoreConfig, "dungeonRequeueDelay", 10))
    if not shortDungeonDelays[tonumber(dungeonRequeueDelay)] then dungeonRequeueDelay = 10 end
    local requeueDelayButton = ChoiceButton(parent, "Requeue timer", 378, -292, 310, {
        { text = "5 seconds", value = 5 },
        { text = "10 seconds", value = 10 },
        { text = "15 seconds", value = 15 },
        { text = "20 seconds", value = 20 },
        { text = "30 seconds", value = 30 },
    }, dungeonRequeueDelay, function(value) SetSettingWithoutRefresh("core", "dungeonRequeueDelay", value) end)
    AddTooltip(requeueDelayButton, "Dungeon requeue timer",
        "Waits after leaving the dungeon before joining the same retained Dungeon Finder selection. Cancel skips this requeue.")
    BindToggleDependency(dungeonExit, dungeonPartyLeave, dungeonRequeue)

    Label(parent, "Battleground", 20, -380, 13)
    ScalarSettingRow(parent, "core", AutoCoreConfig, "autoLeaveCompletedBattleground",
        "Leave after completion", 20, -412, false,
        "After the battlefield reports a winner, shows a countdown with Cancel before leaving.")

    local leaveDelay = Core.GetSetting("core", "activityLeaveDelay",
        ResolvedDefault(AutoCoreConfig, "activityLeaveDelay", 3))
    local delayButton = ChoiceButton(parent, "Departure timer", 20, -440, 310, {
        { text = "3 seconds", value = 3 },
        { text = "5 seconds", value = 5 },
        { text = "10 seconds", value = 10 },
        { text = "15 seconds", value = 15 },
        { text = "30 seconds", value = 30 },
    }, leaveDelay, function(value) SetSettingWithoutRefresh("core", "activityLeaveDelay", value) end)
    AddTooltip(delayButton, "Cancellable departure timer",
        "The visible countdown used after a battleground reports a winner. Cancel suppresses departure for that run.")
    ScalarSettingRow(parent, "core", AutoCoreConfig, "autoReleaseInBattleground",
        "Auto release after death", 20, -468, false,
        "Automatically releases your spirit in battlegrounds. Arenas and world or dungeon deaths remain manual.")

    Label(parent, "Battleground Keybinds", 378, -380, 13)
    ScalarSettingRow(parent, "core", AutoCoreConfig, "trackEnemyFlagCarrier",
        "Track enemy flag carrier", 378, -412, true,
        "Tracks the enemy carrying your faction's flag for the Target Enemy Flag Carrier keybind under Automation Utilities.")
    local auraID = Core.GetSetting("core", "dropAuraSpellID", ResolvedDefault(AutoCoreConfig, "dropAuraSpellID", 0))
    local auraChoices = { { text = "No extra aura", value = 0 } }
    local activeAuraIDs = {}
    for index = 1, 40 do
        local name, _, _, _, _, _, _, _, _, _, spellID = UnitBuff("player", index)
        if not name then break end
        if spellID and not activeAuraIDs[spellID] then
            activeAuraIDs[spellID] = true
            table.insert(auraChoices, { text = name .. " (" .. spellID .. ")", value = spellID })
        end
    end
    auraID = tonumber(auraID) or 0
    if auraID > 0 and not activeAuraIDs[auraID] then
        table.insert(auraChoices, { text = "Saved aura (" .. auraID .. ")", value = auraID })
    end
    local auraButton = ChoiceButton(parent, "Removable aura", 378, -440, 310,
        auraChoices, auraID, function(value)
            SetSettingWithoutRefresh("core", "dropAuraSpellID", value)
        end)
    AddTooltip(auraButton, "Optional removable aura",
        "Choose one current helpful aura for the Drop Flag or Selected Aura keybind under Automation Utilities. Known battleground flags are always checked first. Reopen this page to refresh the list.")
end

----------------------------------------------------------------------
-- Action bars
----------------------------------------------------------------------
pageBuilders["Action Bars"] = function(parent)
    PageHeader(parent, "Action Bars", "Save complete layouts and restore one automatically when an Ascension specialization activates.")

    local AAB = AutoActionBars
    if not AAB then
        local warning = Label(parent, "AutoActionBars.lua did not load. Fully restart the game client after updating the addon.", 20, -88)
        warning:SetTextColor(1, 0.25, 0.25)
        return
    end

    local specID, specName = AAB.GetCurrentSpec()
    local names = AAB.GetProfileNames()
    local selected = AAB.GetSelectedProfile()
    local options = AAB.GetOptions()

    FitSectionCard(parent, 12, -82, 700, -234)
    Label(parent, "SAVED LAYOUTS", 26, -98, 13)
    local profileChoices = {}
    for _, name in ipairs(names) do table.insert(profileChoices, { text = name, value = name }) end
    if #profileChoices > 0 then
        ChoiceButton(parent, "Profile", 26, -128, 300, profileChoices, selected, function(value)
            AAB.SetSelectedProfile(value)
            selected = value
        end)
    else
        local empty = Label(parent, "No layouts saved for this class yet.", 26, -132)
        empty:SetTextColor(Unpack(TEXT_MUTED))
    end

    local newButton = Button(parent, "Save New", 368, -128, 104, function()
        PromptText("Name this action-bar layout", "Save", function(name)
            local ok, err = AAB.SaveProfile(name)
            if not ok then Alert(err) else Refresh(true) end
        end)
    end)
    EmphasizeButton(newButton, BRAND)

    Button(parent, "Overwrite", 26, -170, 104, function()
        if not selected then Alert("Save a layout first."); return end
        Confirm("Overwrite the action-bar layout '" .. selected .. "'?", function()
            local ok, err = AAB.SaveProfile(selected)
            if not ok then Alert(err) else MarkSaved() end
        end)
    end)
    local restoreButton = Button(parent, "Restore", 140, -170, 104, function()
        if not selected then Alert("Choose a saved layout first."); return end
        local ok, err = AAB.RestoreProfile(selected)
        if not ok then Alert(err) end
    end)
    EmphasizeButton(restoreButton, BRAND)
    Button(parent, "Rename", 254, -170, 104, function()
        if not selected then Alert("Choose a saved layout first."); return end
        PromptText("Rename '" .. selected .. "'", "Rename", function(name)
            local ok, err = AAB.RenameProfile(selected, name)
            if not ok then Alert(err) else Refresh(true) end
        end)
    end)
    local deleteButton = Button(parent, "Delete", 368, -170, 104, function()
        if not selected then Alert("Choose a saved layout first."); return end
        Confirm("Delete the action-bar layout '" .. selected .. "'?", function()
            local ok, err = AAB.DeleteProfile(selected)
            if not ok then Alert(err) else Refresh(true) end
        end)
    end)
    EmphasizeButton(deleteButton, CLOSE_RED)

    local macroToggle = Check(parent, "Restore saved macro bodies", 26, -220, options.restoreMacros, function(value)
        AAB.SetOption("restoreMacros", value); MarkSaved()
    end)
    AddTooltip(macroToggle, "Restore macros", "Updates a uniquely named macro to its saved body and recreates missing macros. Leave this off if you manage macros separately.")
    local rankToggle = Check(parent, "Use the highest learned spell rank", 360, -220, options.restoreHighestRank, function(value)
        AAB.SetOption("restoreHighestRank", value); MarkSaved()
    end)
    AddTooltip(rankToggle, "Spell ranks", "When enabled, restoring a spell uses the highest learned rank. When disabled, AutoActionBars first tries the rank that was saved.")

    FitSectionCard(parent, 12, -260, 700, -484)
    Label(parent, "SPECIALIZATION AUTOMATION", 26, -276, 13)
    local specLabel = Label(parent, "Current: " .. tostring(specName) .. " (" .. tostring(specID) .. ")", 26, -306)
    specLabel:SetTextColor(Unpack(TEXT))

    local assignment = AAB.GetSpecAssignment(specID)
    local assignmentValue = assignment.profile or "off"
    local assignmentChoices = {
        { text = "Off", value = "off" },
        { text = "Specialization default", value = "default" },
    }
    for _, name in ipairs(names) do table.insert(assignmentChoices, { text = name, value = name }) end
    ChoiceButton(parent, "Auto restore", 26, -336, 330, assignmentChoices, assignmentValue, function(value)
        if value == "off" then value = nil end
        local ok, err = AAB.SetSpecProfile(specID, value)
        if not ok then Alert(err) else MarkSaved() end
    end)

    local autoSave = Check(parent, "Auto-save this specialization before switching", 26, -380, assignment.autoSave == true, function(value)
        AAB.GetSpecAssignment(specID).autoSave = value
        MarkSaved()
    end)
    AddTooltip(autoSave, "Auto-save", "Captures the current bars as this specialization's private default when an Ascension specialization cast begins.")

    Button(parent, "Save Spec Default", 26, -422, 150, function()
        AAB.SaveSpecDefault(specID)
        MarkSaved()
    end)
    local restoreDefault = Button(parent, "Restore Spec Default", 186, -422, 160, function()
        local ok, err = AAB.RestoreSpecDefault(specID)
        if not ok then Alert(err) end
    end)
    EmphasizeButton(restoreDefault, BRAND)

    local note = Label(parent, "Slots 121-132 are possession/vehicle controls and are intentionally left untouched. Restores are blocked in combat.", 26, -470)
    note:SetWidth(650)
    note:SetTextColor(Unpack(TEXT_MUTED))
end

pageBuilders.Quest = function(parent)
    FitSectionCard(parent, 12, -76, 340, -218)
    FitSectionCard(parent, 370, -76, 342, -218)
    FitSectionCard(parent, 12, -244, 700, -424)
    FitSectionCard(parent, 12, -450, 700, -583)
    PageHeader(parent, "Quest", "Control quest interactions first, then tune optional map and minimap guidance.")
    local quickAbandonButton = Button(parent, "Quick Abandon", 540, -20, 160, function() OpenQuickAbandonWindow() end)
    AddTooltip(quickAbandonButton, "Quick Abandon",
        "Reviews your quest log and lists quests worth abandoning in bulk - always keeping Prestige and Mentorship "
        .. "quests, plus whatever the options in that window say to keep. Shows the list and asks for confirmation "
        .. "before abandoning anything.")
    Label(parent, "Quest Acceptance", 28, -84, 13)
    Label(parent, "Completion and Display", 390, -84, 13)

    -- Two columns so all the plain on/off toggles fit above the fold instead
    -- of trailing down the page one per row.
    local leftFields = {
        { "acceptQuests", "Auto accept quests",
            "Automatically accepts quests when talking to a quest giver, as long as they pass the safety checks on this page (level difference, daily/PvP settings, and any high-risk quest patterns in AutoQuestConfig.lua)." },
        { "acceptDailyQuests", "Auto accept daily quests", "Also accepts quests flagged as Daily. Turn off to require accepting dailies manually." },
        { "acceptPvPQuests", "Auto accept PvP quests", "Also accepts quests flagged as PvP-related." },
        { "acceptTrivialQuests", "Accept trivial quests",
            "Trivial quests are more than 9 levels below you - the point where they grey out and stop being worth doing. "
            .. "Off means they are skipped and left for you to take manually." },
        { "autoSelectRewards", "Auto choose quest reward",
            "When a quest offers a choice of rewards, automatically picks the one that scores as the best upgrade (using your AutoUpgrade weights), or the highest vendor value if none are upgrades." },
    }
    local rightFields = {
        { "turnInQuests", "Auto turn in quests",
            "Automatically turns in completed quests when talking to the quest giver." },
        { "turnInDailyQuests", "Auto turn in daily quests", "Also turns in quests flagged as Daily." },
        { "turnInPvPQuests", "Auto turn in PvP quests", "Also turns in quests flagged as PvP-related." },
        { "disableOnShift", "Hold Shift to pause automation",
            "Hold Shift while talking to an NPC to temporarily disable all AutoQuest automation for that interaction." },
        { "mapPins", "Show map icons",
            "Shows quest objectives and known service NPCs on the world map and minimap using the bundled location database." },
    }
    local leftControls, rightControls = {}, {}
    local y = -108
    for _, field in ipairs(leftFields) do
        leftControls[field[1]] = ScalarCheck(parent, "quest", AutoQuestConfig, field[1], field[2], 20, y, true, field[3])
        y = y - 24
    end
    local y2 = -108
    for _, field in ipairs(rightFields) do
        rightControls[field[1]] = ScalarCheck(parent, "quest", AutoQuestConfig, field[1], field[2], 390, y2, true, field[3])
        y2 = y2 - 24
    end
    BindToggleDependency(leftControls.acceptQuests,
        leftControls.acceptDailyQuests, leftControls.acceptPvPQuests,
        leftControls.acceptTrivialQuests, leftControls.autoSelectRewards)
    BindToggleDependency(rightControls.turnInQuests,
        rightControls.turnInDailyQuests, rightControls.turnInPvPQuests)
    ScalarCheck(parent, "quest", AutoQuestConfig, "useElvUIQuestMarkers", "Use ElvUI icons", 540, -204, false,
        "On uses ElvUI's quest icons and hides the addon's nameplate badges. Off uses the addon's kill, loot, and interaction badges and disables ElvUI's NPC quest icons. If ElvUI is unavailable, the addon badges remain active.")
    -- These settings are always visible. Two equal-width columns keep every
    -- track aligned: world map on the left, minimap on the right. Config keys
    -- still say "pin" because they are saved-variable
    -- names, but all user-facing labels say "icon".
    Label(parent, "Map and Minimap Icons", 28, -260, 13)
    local patrolPaths = ScalarCheck(parent, "quest", AutoQuestConfig, "showPatrolPaths", "Patrol paths", 410, -256, true,
        "Shows grey dotted paths for service NPCs with recorded patrol locations. Hover a route endpoint icon to highlight that NPC's path.")
    patrolPaths:SetOnChanged(function()
        if AutoQuest and AutoQuest.Map then
            AutoQuest.Map.UpdateWorldMap()
            AutoQuest.Map.UpdateMinimap()
        end
    end)
    local leftX, rightX = 28, 388
    local firstRow, secondRow, thirdRow = -286, -334, -382

    ScalarSlider(parent, "quest", AutoQuestConfig, "worldPinSize", nil, leftX, firstRow, 10, 8, 40,
        "Pixel size of objective icons on the world map.", "World Map Icon Size", 306)
    ScalarSlider(parent, "quest", AutoQuestConfig, "maxWorldPins", nil, leftX, secondRow, 500, 50, 2000,
        "Maximum icons shown on the world map at once. World map icons are never distance-limited - only this cap applies.",
        "World Map Max Icons", 306)

    ScalarSlider(parent, "quest", AutoQuestConfig, "minimapPinSize", nil, rightX, firstRow, 10, 6, 30,
        "Pixel size of objective icons on the minimap.", "Minimap Icon Size", 306)
    ScalarSlider(parent, "quest", AutoQuestConfig, "minimapPinRadiusPercent", nil, rightX, secondRow, 95, 25, 150,
        "How far out an icon still shows on the minimap, as a percentage of the minimap's own view radius. 100% is right at the edge; lower values only show icons that are closer.",
        "Minimap Icon Distance", 306, "%")
    ScalarSlider(parent, "quest", AutoQuestConfig, "maxMinimapPins", nil, rightX, thirdRow, 150, 10, 500,
        "Maximum icons shown on the minimap at once, closest first.",
        "Minimap Max Icons", 306)
    local notableNPCs = ScalarCheck(parent, "quest", AutoQuestConfig, "showNotableNPCPins",
        "Bosses", 190, -256, true,
        "Shows known bosses on the minimap and on world or instance maps. Dungeon icons follow the selected floor.")
    local knownRares = ScalarCheck(parent, "quest", AutoQuestConfig, "showRareNPCPins",
        "Known rares", 290, -256, false,
        "Shows every known rare location and recorded patrol path. Off by default: rares found by the live scanner still receive a temporary pulsing icon.")
    local rareScanner = ScalarCheck(parent, "quest", AutoQuestConfig, "rareScannerEnabled",
        "Rare alerts", 520, -256, true,
        "Detects nearby rares through nameplates, targets, party targets, combat activity, and an incremental current-zone creature-cache scan. A detection creates a temporary bright map icon and a visual alert.")
    local rareSound = ScalarCheck(parent, "quest", AutoQuestConfig, "rareScannerSound",
        "Sound", 640, -256, false,
        "Plays the built-in raid-warning sound for a new rare sighting. Repeated observations of the same active sighting do not replay it.")
    BindToggleDependency(rareScanner, rareSound)

    local serviceIconChoices = {
        { text = "Auctioneer", value = "auctioneer" },
        { text = "Banker", value = "banker" },
        { text = "Battlemaster", value = "battlemaster" },
        { text = "Flight Master", value = "flightmaster" },
        { text = "Guild Master", value = "guildmaster" },
        { text = "Innkeeper", value = "innkeeper" },
        { text = "Stable Master", value = "stablemaster" },
        { text = "Tabard Vendor", value = "tabardvendor" },
        { text = "Talent Unlearner", value = "talentunlearner" },
        { text = "Trainer", value = "trainer" },
        { text = "Vendor", value = "vendor" },
    }
    local selectedServiceIcons = Core.GetSetting("quest", "mapServiceIconTypes",
        ResolvedDefault(AutoQuestConfig, "mapServiceIconTypes",
            {
                "auctioneer", "banker", "battlemaster", "flightmaster", "guildmaster",
                "innkeeper", "talentunlearner", "tabardvendor", "stablemaster", "trainer", "vendor",
            }))
    local serviceIcons = MultiChoiceEditor(parent, "Service Icons", leftX, thirdRow, 306,
        serviceIconChoices, selectedServiceIcons, "None")
    serviceIcons:SetOnSelectionChanged(function()
        local selected = serviceIcons:GetSelected()
        if selected == nil then selected = {}
        elseif type(selected) ~= "table" then selected = { selected } end
        SetSettingWithoutRefresh("quest", "mapServiceIconTypes", selected)
    end)
    AddTooltip(serviceIcons, "Service icons",
        "Choose any combination of service NPC icons for both the world map and minimap. Choose None to hide every service icon while keeping quest-objective icons visible.")
    BindToggleDependency(rightControls.mapPins, patrolPaths, serviceIcons, notableNPCs, knownRares)

    -- Group progress travels through invisible PARTY/RAID addon messages.
    -- Keep the controls in the owning Quest page; AutoBuff has its own module.
    Label(parent, "Group Questing", 28, -458, 13)
    local syncToggle = ScalarCheck(parent, "quest", AutoQuestConfig, "groupQuestSync", "Sync party progress", 20, -480, false,
        "Shares quest and objective changes through hidden addon messages, including compatible Questie-X party progress. Progress tooltips only read the local cache and never send traffic.")
    local raidToggle = ScalarCheck(parent, "quest", AutoQuestConfig, "groupQuestSyncRaid", "Include raid groups", 246, -480, false,
        "Also synchronizes quest progress in raids. Off by default to keep large-group traffic deliberate.")
    local tooltipToggle = ScalarCheck(parent, "quest", AutoQuestConfig, "showGroupQuestTooltips", "Progress in tooltips", 472, -480, true,
        "Shows synchronized member progress on required item tooltips and on relevant NPCs or corpses you hover.")
    local mapToggle = ScalarCheck(parent, "quest", AutoQuestConfig, "showGroupQuestMapPins", "Party objective icons", 20, -506, true,
        "Shows unfinished objectives for synchronized party members on the world map and minimap using the addon's existing quest and spawn records. It never reads client DBC files.")
    ScalarCheck(parent, "quest", AutoQuestConfig, "autoShareQuests", "Share newly accepted quests", 246, -506, false,
        "Automatically pushes a newly accepted, shareable quest to your party. Quests are not automatically pushed in raids.")
    ScalarCheck(parent, "quest", AutoQuestConfig, "autoAcceptSharedQuests", "Accept shared quests", 472, -506, false,
        "Accepts party-shared quests when normal AutoQuest acceptance is enabled. High-risk title patterns remain manual.")
    ScalarCheck(parent, "quest", AutoQuestConfig, "announceQuestCompletion", "Announce quest turn-ins", 20, -532, true,
        "Announces after your quest reward is claimed and the quest is successfully removed from your log. Reload and synchronization never announce.")
    ScalarCheck(parent, "quest", AutoQuestConfig, "announceObjectiveCompletion", "Announce completed steps", 246, -532, true,
        "Announces completed objectives with a skull for kills, diamond for loot, triangle for interactions, and star for scripted events. Progress updates remain silent.")
    local announcementChannel = string.upper(tostring(Core.GetSetting("quest", "questAnnouncementChannel",
        ResolvedDefault(AutoQuestConfig, "questAnnouncementChannel", "GROUP")) or "GROUP"))
    local channelButton = ChoiceButton(parent, "Channel", 472, -532, 206, {
        { text = "Party (raid if enabled)", value = "GROUP" },
        { text = "Emote", value = "EMOTE" },
        { text = "Say", value = "SAY" },
    }, announcementChannel, function(value)
        SetSettingWithoutRefresh("quest", "questAnnouncementChannel", value)
    end)
    ScalarCheck(parent, "quest", AutoQuestConfig, "cheerQuestCompletion", "Cheer on quest turn-in", 20, -558, false,
        "Plays your character's cheer emote once after a quest is successfully turned in.")
    AddTooltip(channelButton, "Announcement channel",
        "Party is the default. Raid announcements remain off unless Include raid groups is enabled. Emote and Say are nearby-only alternatives and also work while solo.")
    BindToggleDependency(syncToggle, raidToggle, tooltipToggle, mapToggle)
end

local function AttachVerticalScroll(parent, scroll, child, contentHeight,
    viewportHeight, x, y, sliderHeight, wheelStep)
    local maximum = math.max(0, contentHeight - viewportHeight)
    child:SetHeight(math.max(viewportHeight, contentHeight))
    if scroll.UpdateScrollChildRect then scroll:UpdateScrollChildRect() end

    local slider = Track(UI.CreateVerticalScrollbar(parent, sliderHeight, function(value)
        scroll:SetVerticalScroll(value)
    end, wheelStep or 30))
    slider:SetPoint("TOPLEFT", x, y)
    slider:SetScrollRange(maximum, 0)

    local function ScrollBy(delta)
        local value = math.max(0, math.min(maximum,
            (scroll:GetVerticalScroll() or 0) + delta))
        slider:SetScrollValue(value)
    end
    local function BindWheel(control)
        control:EnableMouse(true)
        control:EnableMouseWheel(true)
        control:SetScript("OnMouseWheel", function(_, delta)
            ScrollBy(delta > 0 and -(wheelStep or 30) or (wheelStep or 30))
        end)
    end
    BindWheel(scroll)
    BindWheel(child)
    return ScrollBy, BindWheel
end

pageBuilders.Buff = function(parent)
    SectionCard(parent, 12, -76, 700, 140)
    SectionCard(parent, 12, -228, 700, 374)
    PageHeader(parent, "Auto Buff", "Assign learned helpful spells to yourself or a group role, then click the secure Buff Next action.")

    if not AutoBuff then
        local warning = Label(parent, "AutoBuff.lua did not load. Fully restart the game client after updating the addon.", 28, -88)
        warning:SetTextColor(1, 0.25, 0.25)
        return
    end

    Label(parent, "Behavior", 28, -86, 13)
    local windowToggle = ScalarCheck(parent, "buff", AutoBuffConfig, "showWindow", "Show buff window", 20, -112, true,
        "Shows the movable AutoBuff status window and secure Buff Next button.")
    local hideToggle = ScalarCheck(parent, "buff", AutoBuffConfig, "hideWhenComplete", "Hide when unable to buff", 246, -112, false,
        "Hides the status window in combat, when targets are out of range, on a long spell cooldown, or fully buffed. It stays visible through the global cooldown and post-cast delay.")
    BindToggleDependency(windowToggle, hideToggle)
    ScalarCheck(parent, "buff", AutoBuffConfig, "includeSelf", "Include yourself", 20, -140, true,
        "Includes your character when buffs are assigned to Self.")
    ScalarCheck(parent, "buff", AutoBuffConfig, "includeParty", "Include party", 246, -140, true,
        "Scans party members for configured buffs.")
    ScalarCheck(parent, "buff", AutoBuffConfig, "includeRaid", "Include raid", 472, -140, true,
        "Scans raid members for configured buffs. Spell casts remain click initiated.")
    ScalarSlider(parent, "buff", AutoBuffConfig, "rebuffSeconds", nil, 28, -174, 60, 0, 300,
        "Treat a configured buff as missing when it has this many seconds or less remaining.",
        "Rebuff Threshold", 650, " sec")

    Label(parent, "Buff Assignments", 28, -238, 13)
    local learnedChoices = {}
    for _, record in ipairs(AutoBuff and AutoBuff.GetAvailableBuffs and AutoBuff.GetAvailableBuffs() or {}) do
        table.insert(learnedChoices, { text = record.name, value = record.name })
    end
    if #learnedChoices == 0 then
        learnedChoices[1] = { text = "No helpful spells found", value = "" }
    end
    local assignmentRows = {
        { label = "Self", target = "self", help = "When any buffs are assigned here, only these buffs are used for your character. Leave Self empty to use the buffs assigned to your detected role." },
        { label = "Caster", target = "caster", help = "Buffs for group members assigned as casters. These also apply to you when Self is empty and your detected role is Caster." },
        { label = "Tank", target = "tank", help = "Buffs for group members assigned as tanks. These also apply to you when Self is empty and your detected role is Tank." },
        { label = "Healer", target = "healer", help = "Buffs for group members assigned as healers. These also apply to you when Self is empty and your detected role is Healer." },
        { label = "Melee", target = "melee", help = "Buffs for group members assigned as melee. These also apply to you when Self is empty and your detected role is Melee." },
    }
    for index, definition in ipairs(assignmentRows) do
        local assignmentTarget = definition.target
        local y = -270 - ((index - 1) * 58)
        local roleLabel = Label(parent, definition.label, 28, y - 3, 12)
        roleLabel:SetWidth(104)
        roleLabel:SetJustifyH("LEFT")
        local selector = MultiChoiceEditor(parent, "Buffs", 144, y, 548, learnedChoices,
            AutoBuff.GetAssignedBuffs(assignmentTarget), "None")
        selector:SetOnSelectionChanged(function()
            local list, err = AutoBuff.BuildAssignedBuffs(assignmentTarget, selector:GetSelected() or {})
            if not list then Alert(err); return end
            SetSettingWithoutRefresh("buff", "buffs", list)
        end)
        AddTooltip(roleLabel, definition.label .. " buffs", definition.help)
        AddTooltip(selector, definition.label .. " buffs", definition.help)
    end
end

local LOCKED_GEAR_SLOTS = {
    { 1, "Head" }, { 2, "Neck" }, { 3, "Shoulder" }, { 4, "Shirt" },
    { 5, "Chest" }, { 6, "Waist" }, { 7, "Legs" }, { 8, "Feet" },
    { 9, "Wrist" }, { 10, "Hands" }, { 11, "Ring 1" }, { 12, "Ring 2" },
    { 13, "Trinket 1" }, { 14, "Trinket 2" }, { 15, "Back" },
    { 16, "Main Hand" }, { 17, "Off Hand" }, { 18, "Ranged / Relic" },
    { 19, "Tabard" },
}

local UPGRADE_NOTICE_COOLDOWNS = {
    { text = "1 min", value = 1 }, { text = "2 min", value = 2 },
    { text = "3 min", value = 3 }, { text = "4 min", value = 4 },
    { text = "5 min", value = 5 },
}

local function OpenLockedGearWindow()
    local blocker = CreateFrame("Frame", nil, pageHost)
    table.insert(ruleEditorBlockers, blocker)
    blocker:SetAllPoints(pageHost)
    blocker:SetFrameStrata("DIALOG"); blocker:SetFrameLevel(90); blocker:EnableMouse(true)

    local dim = blocker:CreateTexture(nil, "BACKGROUND")
    dim:SetAllPoints(blocker); dim:SetTexture(WHITE_TEX); dim:SetVertexColor(0, 0, 0, 0.55)

    local window = CreateFrame("Frame", nil, blocker)
    window:SetFrameStrata("DIALOG"); window:SetFrameLevel(100); window:EnableMouse(true)
    window:SetPoint("CENTER", blocker, "CENTER", 0, 20)
    window:SetSize(640, 430)
    ModalSurface(window)

    local function Close()
        GameTooltip:Hide()
        ForgetRuleEditor(blocker)
        blocker:Hide()
    end
    StyledCloseButton(window, Close)

    local heading = window:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    heading:SetPoint("TOPLEFT", 20, -18); heading:SetText("Locked Gear")
    heading:SetTextColor(Unpack(BRAND))
    local subtitle = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", 20, -44); subtitle:SetWidth(590); subtitle:SetJustifyH("LEFT")
    subtitle:SetText("Click an equipped item to protect or unprotect its slot from automatic upgrades.")
    subtitle:SetTextColor(Unpack(TEXT_MUTED))

    local resolved = Core.GetSetting("upgrade", "lockedSlots", {})
    local lockedSlots = {}
    if type(resolved) == "table" then
        for slotId, locked in pairs(resolved) do
            if locked == true then lockedSlots[slotId] = true end
        end
    end

    local shown = 0
    for _, definition in ipairs(LOCKED_GEAR_SLOTS) do
        local slotId, slotName = definition[1], definition[2]
        local link = GetInventoryItemLink("player", slotId)
        if link then
            local index = shown
            shown = shown + 1
            local column = math.floor(index / 10)
            local rowIndex = index % 10
            local x = 20 + column * 305
            local y = -76 - rowIndex * 32
            local row = SkinnedButton(window, "", x, y, 295, function(self)
                lockedSlots[slotId] = not lockedSlots[slotId] or nil
                SetSettingWithoutRefresh("upgrade", "lockedSlots", lockedSlots)
                self:PaintLock()
            end, 28)

            local icon = row:CreateTexture(nil, "ARTWORK")
            icon:SetPoint("LEFT", row, "LEFT", 4, 0); icon:SetSize(22, 22)
            icon:SetTexture(GetInventoryItemTexture("player", slotId))

            local slotLabel = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            slotLabel:SetPoint("LEFT", icon, "RIGHT", 7, 7); slotLabel:SetWidth(235)
            slotLabel:SetJustifyH("LEFT"); slotLabel:SetText(slotName)
            slotLabel:SetTextColor(Unpack(TEXT_MUTED))

            local itemLabel = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            itemLabel:SetPoint("LEFT", icon, "RIGHT", 7, -7); itemLabel:SetWidth(235)
            itemLabel:SetJustifyH("LEFT"); itemLabel:SetText(link)

            local lockIcon = row:CreateTexture(nil, "OVERLAY")
            lockIcon:SetPoint("CENTER", icon, "CENTER", 4, -3)
            lockIcon:SetSize(22, 22)
            lockIcon:SetTexture("Interface\\Buttons\\LockButton-Locked-Up")

            function row:PaintLock()
                if lockedSlots[slotId] then
                    lockIcon:Show()
                    self:SetBackdropColor(Unpack(SELECT_BG))
                    self:SetBackdropBorderColor(Unpack(BRAND))
                else
                    lockIcon:Hide()
                    self:SetBackdropColor(Unpack(CTRL_BG))
                    self:SetBackdropBorderColor(Unpack(BORDER))
                end
            end
            row:HookScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetInventoryItem("player", slotId)
                GameTooltip:AddLine(lockedSlots[slotId]
                    and (slotName .. " is locked. Click to allow automatic replacement.")
                    or (slotName .. " is unlocked. Click to prevent automatic replacement."),
                    0.35, 0.85, 1, true)
                GameTooltip:Show()
            end)
            row:HookScript("OnLeave", function(self) GameTooltip:Hide(); self:PaintLock() end)
            row:PaintLock()
        end
    end

    if shown == 0 then
        local empty = window:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        empty:SetPoint("CENTER", window, "CENTER", 0, 0)
        empty:SetText("No equipped items are available to lock.")
        empty:SetTextColor(Unpack(TEXT_MUTED))
    end

    local done = SkinnedButton(window, "Done", 0, 0, 100, Close)
    done:ClearAllPoints(); done:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -20, 16)
end

pageBuilders.Upgrade = function(parent)
    SectionCard(parent, 12, -76, 700, 76)
    SectionCard(parent, 12, -156, 700, 88)
    SectionCard(parent, 12, -248, 700, 60)
    PageHeader(parent, "Upgrade", "Choose what can be equipped, how much better it must be, and how each stat is valued.")
    local noticeCooldown = Core.GetSetting("upgrade", "notifyCooldownMinutes",
        ResolvedDefault(AutoUpgradeConfig, "notifyCooldownMinutes", 2))
    local noticeCooldownButton = ChoiceButton(parent, "Notify delay", 390, -20, 180,
        UPGRADE_NOTICE_COOLDOWNS, noticeCooldown, function(value)
            SetSettingWithoutRefresh("upgrade", "notifyCooldownMinutes", value)
        end)
    AddTooltip(noticeCooldownButton, "Upgrade notification cooldown",
        "Suppresses repeat notices for the same item and equipment slot during automatic scans. Manual scans and successful equips still report immediately.")
    local lockedGearButton = Button(parent, "Locked Gear", 580, -20, 120, OpenLockedGearWindow)
    AddTooltip(lockedGearButton, "Locked gear", "Choose equipped slots that automatic upgrades must never replace.")
    local autoEquipToggle = ScalarCheck(parent, "upgrade", AutoUpgradeConfig, "autoEquip", "Auto equip upgrades", 20, -84, false,
        "Automatically equips items found in your bags that beat what you have equipped. Turn off to only report upgrades in chat without equipping them.")
    ScalarCheck(parent, "upgrade", AutoUpgradeConfig, "printMessages", "Print upgrade results", 20, -110, true)
    ScalarCheck(parent, "upgrade", AutoUpgradeConfig, "showTooltipScores", "Show item scores in tooltips", 20, -136, true)
    ScalarCheck(parent, "upgrade", AutoUpgradeConfig, "verbose", "Log when no upgrade found", 300, -84, false,
        "Off by default: automatic scans stay silent when nothing beats your gear (they run on every bag change). "
        .. "Equipped upgrades are always reported. Turn on to also log 'no upgrades found' after each automatic scan. "
        .. "A manual /ae upgrade scan always reports either way.")
    local notifyOnlyToggle = ScalarCheck(parent, "upgrade", AutoUpgradeConfig, "notifyOnly", "Notify only", 300, -110, false,
        "Reports upgrades without equipping them automatically, even while Auto Equip is enabled.")
    ScalarCheck(parent, "upgrade", AutoUpgradeConfig, "pvpGearToggle", "Allow PvP gear upgrades", 300, -136, false,
        "Controls auto-equip only. When enabled, Bloodforged and pure-PvP-Power items may be equipped as upgrades. The best set is protected from junking, selling, and auctioning either way.")
    BindToggleDependency(autoEquipToggle, notifyOnlyToggle)
    local resolvedUpgrade = Core.GetProfile(AutoUpgradeConfig) or {}
    local function CurrentList(key)
        local values = Core.GetSetting("upgrade", key, Default(resolvedUpgrade, key, Default(AutoUpgradeConfig, key, {})))
        -- "Any" is stored as an explicit main-hand policy but represented by
        -- the checked Any row rather than as another subtype in the menu.
        if key == "mainHandTypes" and type(values) == "table" and #values == 1 and values[1] == "Any" then return {} end
        return values
    end
    local function SelectedList(button)
        local value = button:GetSelected()
        if value == nil then return {} end
        return type(value) == "table" and value or { value }
    end
    local function SaveList(key, button)
        local values = SelectedList(button)
        if key == "mainHandTypes" and #values == 0 then values = { "Any" } end
        Core.GetProfileSection("upgrade", true)[key] = values
        NotifyWithoutRefresh("upgrade")
    end
    -- Weapon types, armor, and minimum quality all share a single row now
    -- there is no longer a Best Seen panel sharing the row.
    -- Five selectors on one row: labels are kept short so the captions fit,
    -- with the full explanation in each tooltip.
    local SELECTOR_WIDTH, SELECTOR_STEP = 128, 136
    local function SelectorX(index) return 20 + (index - 1) * SELECTOR_STEP end

    local mainHandTypes = MultiChoiceEditor(parent, "Main", SelectorX(1), -164, SELECTOR_WIDTH, UPGRADE_WEAPON_CHOICES, CurrentList("mainHandTypes"), "Any weapon")
    local offHandTypes = MultiChoiceEditor(parent, "Off", SelectorX(2), -164, SELECTOR_WIDTH, UPGRADE_OFFHAND_CHOICES, CurrentList("offHandTypes"), "Nothing")
    local rangedTypes = MultiChoiceEditor(parent, "Ranged", SelectorX(3), -164, SELECTOR_WIDTH, UPGRADE_RANGED_CHOICES, CurrentList("rangedTypes"), "Nothing")
    local armorTypes = MultiChoiceEditor(parent, "Armor", SelectorX(4), -164, SELECTOR_WIDTH, UPGRADE_ARMOR_CHOICES, CurrentList("armorTypes"), "Any armor")
    armorTypes:SetOnSelectionChanged(function() SaveList("armorTypes", armorTypes) end)
    mainHandTypes:SetOnSelectionChanged(function() SaveList("mainHandTypes", mainHandTypes) end)
    offHandTypes:SetOnSelectionChanged(function() SaveList("offHandTypes", offHandTypes) end)
    rangedTypes:SetOnSelectionChanged(function() SaveList("rangedTypes", rangedTypes) end)
    AddTooltip(armorTypes, "Allowed armor", "Choose every body-armor class this profile may equip, or Any armor.")
    AddTooltip(mainHandTypes, "Main-hand weapons", "Choose every weapon subtype AutoUpgrade may place in the main hand, or Any weapon. Include any two-handed types you use.")
    AddTooltip(offHandTypes, "Off-hand items", "Choose off-hand weapon types, Shields, and/or Held In Off-hand. Weapon choices in both hand lists enable dual wield. Two-handed choices in both lists enable dual two-hand. Choose Nothing for a standard single two-handed setup.")
    AddTooltip(rangedTypes, "Ranged and relic slot",
        "Choose what may go in the ranged/relic slot: bows, crossbows, guns, wands, thrown, or a relic type. "
        .. "Nothing (the default) means the slot is ignored entirely - which is what stops AutoRoll rolling on wands "
        .. "and thrown weapons your character will never equip.")

    local minimumQuality = Core.GetSetting("upgrade", "minQuality", ResolvedDefault(AutoUpgradeConfig, "minQuality", 0))
    local minQualityButton = ChoiceButton(parent, "Quality", SelectorX(5), -164, SELECTOR_WIDTH, QualityChoices(), minimumQuality, function(value)
        SetSettingWithoutRefresh("upgrade", "minQuality", value)
    end, 22)
    AddTooltip(minQualityButton, "Minimum quality",
        "Only auto-equip (and count as an upgrade) items at or above this quality tier. Set to Poor/Common to also consider white/grey upgrades.")

    -- Align the threshold track with the equipment-policy card above.
    ScalarSlider(parent, "upgrade", AutoUpgradeConfig, "upgradeThreshold", nil, 28, -200, 0, 0, 100,
        "Required percentage improvement over the equipped item's score. 0 still requires an actual score increase.",
        "Upgrade Threshold", 660, "%")

    Label(parent, "Stat Weights", 20, -258, 14)
    local resolved = Core.GetProfile(AutoUpgradeConfig) or {}
    local activeWeights = resolved.weights or AutoUpgradeConfig.weights or {}
    local statColumns = {
        {
            { "Primary", { "Strength", "Agility", "Stamina", "Intellect", "Spirit" } },
            { "General Offense", { "Attack Power", "Ranged Attack Power", "Hit Rating", "Critical Strike Rating",
                "Haste Rating", "Expertise Rating", "Armor Penetration Rating", "Resilience Rating" } },
        },
        {
            { "Defense", { "Armor", "Defense Rating", "Dodge Rating", "Parry Rating", "Block Rating",
                "Block Value", "Shield Block" } },
            { "Magic Offense", { "Spell Power", "Spell Damage", "Healing Power", "Spell Penetration" } },
        },
        {
            { "Weapons", { "Weapon DPS", "Ranged DPS", "Weapon Damage", "Min Damage", "Max Damage", "Weapon Speed" } },
            { "Recovery and Resistance", { "Mana Per 5", "Health Per 5", "Fire Resistance", "Arcane Resistance",
                "Shadow Resistance", "Frost Resistance", "Nature Resistance" } },
        },
    }
    local statNames, known = {}, {}
    for _, column in ipairs(statColumns) do
        for _, category in ipairs(column) do
            for _, name in ipairs(category[2]) do
                table.insert(statNames, name)
                known[name] = true
            end
        end
    end

    -- Weights table this page keeps authoritative and saves from - seeded
    -- with any custom/legacy stat names Config.lua does not know about (kept
    -- untouched, since this grid has no field for them), then every known
    -- stat's starting value.
    local weights = {}
    for name, value in pairs(activeWeights) do
        if not known[name] then weights[name] = value end
    end
    for _, name in ipairs(statNames) do
        weights[name] = activeWeights[name] ~= nil and activeWeights[name] or 0
    end

    -- Validates and saves ONE field on blur, rather than re-validating the
    -- whole grid: a typo in one box no longer blocks every other field from
    -- saving. A bad value pops an alert and reverts to the last good value;
    -- a good value is renormalized in place (".01" -> "0.01", "2.50" -> "2.5")
    -- so the displayed text always matches what's actually stored.
    local weightEdits, weightRows, categoryRows = {}, {}, {}
    local LayoutWeights
    local weightError = Label(parent, "", 20, -304)
    weightError:SetWidth(660)
    weightError:SetTextColor(1, 0.35, 0.25)
    weightError:Hide()
    local function ValidateAndSaveField(name)
        local edit = weightEdits[name]
        local text = strtrim(edit:GetText() or "")
        if text == "" then text = "0" end
        local value = tonumber(text)
        if not value then
            weightError:SetText('"' .. text .. '" is not a valid number for ' .. name .. '. Use numbers such as 1, 0.5, or .25.')
            weightError:Show()
            edit:SetBackdropBorderColor(Unpack(CLOSE_RED))
            edit:SetText(tostring(weights[name] or 0))
            return
        end
        weightError:Hide()
        edit:SetBackdropBorderColor(Unpack(BORDER))
        weights[name] = value
        edit:SetText(tostring(value))
        SetSettingWithoutRefresh("upgrade", "weights", weights)
        if LayoutWeights then LayoutWeights() end
    end

    local statDescriptions = {
        ["Strength"] = "Increases melee attack power and improves shield block value for shield users.",
        ["Agility"] = "Increases armor and, depending on class, attack power, critical chance, and dodge.",
        ["Stamina"] = "Increases maximum health.",
        ["Intellect"] = "Increases maximum mana and spell critical chance.",
        ["Spirit"] = "Improves health and mana regeneration, especially while outside combat or not casting.",
        ["Attack Power"] = "Increases melee weapon and ability damage.",
        ["Ranged Attack Power"] = "Increases damage dealt with ranged weapons and ranged abilities.",
        ["Hit Rating"] = "Reduces the chance for attacks and spells to miss.",
        ["Critical Strike Rating"] = "Increases the chance for attacks and spells to deal critical effects.",
        ["Haste Rating"] = "Speeds up attacks and spell casting.",
        ["Expertise Rating"] = "Reduces the chance for enemies to dodge or parry melee attacks.",
        ["Armor Penetration Rating"] = "Allows physical attacks to ignore part of an enemy's armor.",
        ["Resilience Rating"] = "Reduces damage taken from players, especially from critical strikes.",
        ["Armor"] = "Reduces physical damage taken.",
        ["Defense Rating"] = "Raises defense, improving avoidance and reducing the chance to be critically hit.",
        ["Dodge Rating"] = "Increases the chance to completely avoid a melee attack.",
        ["Parry Rating"] = "Increases the chance to parry a frontal melee attack.",
        ["Block Rating"] = "Increases the chance to block an attack with a shield.",
        ["Block Value"] = "Increases how much physical damage a successful shield block absorbs.",
        ["Shield Block"] = "The amount of damage the shield itself blocks before other bonuses.",
        ["Spell Power"] = "Increases damage and healing done by spells.",
        ["Spell Damage"] = "Increases spell damage but not spell healing; found on legacy item text.",
        ["Healing Power"] = "Increases spell healing but not spell damage; found on legacy item text.",
        ["Spell Penetration"] = "Reduces an enemy's resistance to your spells.",
        ["Weapon DPS"] = "The melee weapon's average damage per second.",
        ["Ranged DPS"] = "The ranged weapon's average damage per second.",
        ["Weapon Damage"] = "The average of a weapon's minimum and maximum damage per hit.",
        ["Min Damage"] = "The lowest base damage a weapon can deal per hit.",
        ["Max Damage"] = "The highest base damage a weapon can deal per hit.",
        ["Weapon Speed"] = "The seconds between weapon swings; higher values mean a slower weapon.",
        ["Mana Per 5"] = "Restores this much mana every five seconds.",
        ["Health Per 5"] = "Restores this much health every five seconds.",
        ["Fire Resistance"] = "Reduces damage taken from Fire spells.",
        ["Arcane Resistance"] = "Reduces damage taken from Arcane spells.",
        ["Shadow Resistance"] = "Reduces damage taken from Shadow spells.",
        ["Frost Resistance"] = "Reduces damage taken from Frost spells.",
        ["Nature Resistance"] = "Reduces damage taken from Nature spells.",
    }
    local function WeightField(name)
        -- A transparent frame beneath the edit box makes the complete row a
        -- tooltip target, including the label and the space between controls.
        local row = Track(CreateFrame("Frame", nil, parent))
        row:SetFrameLevel(parent:GetFrameLevel() + 1)
        local label = Label(parent, name, 0, 0)
        ApplyUIFont(label, 10)
        local edit = Edit(parent, 0, 0, 48, weights[name])
        edit:SetFrameLevel(row:GetFrameLevel() + 1)
        edit:SetHeight(16)
        AddEditHint(edit, "0")
        AddTooltip(row, name, statDescriptions[name])
        AddTooltip(edit, name, statDescriptions[name])
        edit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
        edit:HookScript("OnEditFocusLost", function() ValidateAndSaveField(name) end)
        weightEdits[name] = edit
        weightRows[name] = { row = row, label = label, edit = edit }
    end
    -- Derive every card from the same spacing rules instead of maintaining
    -- hand-tuned heights. This keeps the heading and stat names on one left
    -- edge and guarantees breathing room above the title and below the final
    -- weight field, even in the longer categories.
    -- Three equal cards span the exact x=12..712 bounds used by the 700px
    -- section panels above. Eight-pixel gutters divide that width evenly.
    local CARD_LEFT = 12
    local CARD_TOP = -316
    local CARD_WIDTH = 228
    local CARD_COLUMN_GAP = 8
    local CARD_VERTICAL_GAP = 8
    local CARD_LEFT_INSET = 8
    local CARD_TOP_INSET = 10
    local FIRST_ROW_OFFSET = 30
    local ROW_HEIGHT = 16
    local CARD_BOTTOM_INSET = 12
    local EDIT_WIDTH = 48
    for columnIndex, categories in ipairs(statColumns) do
        categoryRows[columnIndex] = {}
        local x = CARD_LEFT + (columnIndex - 1) * (CARD_WIDTH + CARD_COLUMN_GAP)
        local top = CARD_TOP
        for _, category in ipairs(categories) do
            local categoryTitle, categoryNames = category[1], category[2]
            local height = FIRST_ROW_OFFSET + #categoryNames * ROW_HEIGHT + CARD_BOTTOM_INSET
            SectionCard(parent, x, top, CARD_WIDTH, height)
            local heading = Label(parent, categoryTitle, x + CARD_LEFT_INSET, top - CARD_TOP_INSET, 13)
            heading:SetTextColor(Unpack(BRAND))
            local record = { heading = heading, title = categoryTitle, names = categoryNames, x = x, top = top }
            table.insert(categoryRows[columnIndex], record)
            for _, name in ipairs(categoryNames) do WeightField(name) end
            top = top - height - CARD_VERTICAL_GAP
        end
    end

    local weightSearch = Edit(parent, 20, -280, 160, "")
    AddEditHint(weightSearch, "Search stats...", "Filter the categorized weight grid by stat name.")
    local nonZeroOnly = false
    local nonZeroToggle = Check(parent, "Non-zero only", 194, -280, false, function(value)
        nonZeroOnly = value
        if LayoutWeights then LayoutWeights() end
    end)
    AddTooltip(nonZeroToggle, "Show non-zero only", "Hide stats currently weighted at 0 without deleting them.")

    local presets = {
        melee = { Strength = 1, Agility = 1, ["Attack Power"] = 0.5, ["Hit Rating"] = 0.8,
            ["Critical Strike Rating"] = 0.7, ["Haste Rating"] = 0.5, ["Expertise Rating"] = 0.7, ["Weapon DPS"] = 2 },
        caster = { Intellect = 1, ["Spell Power"] = 1, ["Hit Rating"] = 0.8,
            ["Critical Strike Rating"] = 0.6, ["Haste Rating"] = 0.7, ["Mana Per 5"] = 0.3 },
        healer = { Intellect = 1, Spirit = 0.7, ["Spell Power"] = 1,
            ["Critical Strike Rating"] = 0.5, ["Haste Rating"] = 0.7, ["Mana Per 5"] = 0.8 },
        tank = { Stamina = 1, Strength = 0.4, Armor = 0.08, ["Defense Rating"] = 1,
            ["Dodge Rating"] = 0.8, ["Parry Rating"] = 0.8, ["Block Rating"] = 0.6, ["Block Value"] = 0.3 },
    }
    local templateChoices = {
        { text = "Choose template...", value = "none" },
        { text = "Melee starter", value = "starter:melee" },
        { text = "Caster starter", value = "starter:caster" },
        { text = "Healer starter", value = "starter:healer" },
        { text = "Tank starter", value = "starter:tank" },
    }
    local shippedTemplates = AutoEverythingWeightTemplates and AutoEverythingWeightTemplates.list or {}
    for index, template in ipairs(shippedTemplates) do
        table.insert(templateChoices, { text = template.name, value = "spec:" .. index })
    end
    local templateButton = ChoiceButton(parent, "Template", 470, -280, 230, templateChoices, "none", function(value)
        if value == "none" then return end
        local starterName = string.match(value, "^starter:(.+)$")
        local template = starterName and { name = starterName .. " starter", weights = presets[starterName] }
            or shippedTemplates[tonumber(string.match(value, "^spec:(%d+)$")) or 0]
        if not template then return end
        Confirm("Copy the " .. template.name .. " weights into this profile? This replaces its current weights, but the shipped template is never changed.", function()
            Core.SetSetting("upgrade", "weights", template.weights)
        end)
    end, 22)
    AddTooltip(templateButton, "Weight template",
        "Copies a starter or Ascension class/spec template into this profile. Later edits save only to the profile and never modify the shipped defaults.")

    LayoutWeights = function()
        local query = string.lower(strtrim(weightSearch:GetText() or ""))
        for _, categories in ipairs(categoryRows) do
            for _, category in ipairs(categories) do
                local visibleIndex = 0
                for _, name in ipairs(category.names) do
                    local record = weightRows[name]
                    local matchesText = query == "" or string.find(string.lower(name), query, 1, true) ~= nil
                    local matchesValue = not nonZeroOnly or (tonumber(weights[name]) or 0) ~= 0
                    if matchesText and matchesValue then
                        local y = category.top - FIRST_ROW_OFFSET - visibleIndex * ROW_HEIGHT
                        record.row:ClearAllPoints(); record.row:SetPoint("TOPLEFT", category.x + CARD_LEFT_INSET, y)
                        record.row:SetSize(CARD_WIDTH - CARD_LEFT_INSET * 2, ROW_HEIGHT); record.row:Show()
                        record.label:ClearAllPoints(); record.label:SetPoint("TOPLEFT", category.x + CARD_LEFT_INSET, y - 2); record.label:Show()
                        record.edit:ClearAllPoints(); record.edit:SetPoint("TOPLEFT", category.x + CARD_WIDTH - CARD_LEFT_INSET - EDIT_WIDTH, y); record.edit:Show()
                        visibleIndex = visibleIndex + 1
                    else
                        record.row:Hide()
                        record.label:Hide()
                        record.edit:Hide()
                    end
                end
                category.heading:SetText(visibleIndex > 0 and category.title or (category.title .. "  •  no matches"))
            end
        end
    end
    weightSearch:SetScript("OnTextChanged", LayoutWeights)
    LayoutWeights()

    -- Sharing lives in the toolbar so the lower category cards can use the
    -- full pane height without clipping their final rows.
    local exportWeights = Button(parent, "Export", 326, -280, 64, function()
        if focusedEditBox then focusedEditBox:ClearFocus() end
        local text = Core.Export("weights")
        if not text then Core.Warn("Settings", "Could not export weights."); return end
        OpenTextPopup({
            title = "Export Weights",
            subtitle = "Copy this text with Ctrl+C to share just your stat weights - no rules or other settings.",
            text = text,
        })
    end, 22)
    AddTooltip(exportWeights, "Export stat weights",
        "Opens a box with your stat weights as shareable text, already selected so Ctrl+C copies it.")
    local importWeights = Button(parent, "Import", 398, -280, 64, function()
        OpenTextPopup({
            title = "Import Weights",
            subtitle = "Paste a stat weight set, then press Import to replace this profile's weights. Rules are untouched.",
            acceptLabel = "Import",
            onAccept = function(text)
                local payload, err = Core.ParseImport(text)
                if not payload then Core.Warn("Settings", err); return false end
                if payload.kind ~= "weights" then
                    Core.Warn("Settings", "That text is not a stat weight export.")
                    return false
                end
                local ok, importErr = Core.Import(payload)
                if ok then Core.Info("Settings", "Stat weights imported."); return true end
                Core.Warn("Settings", importErr or "Import failed.")
                return false
            end,
        })
    end, 22)
    AddTooltip(importWeights, "Import stat weights",
        "Opens a box to paste a shared weight set. It replaces every stat weight in this profile; rules and other settings stay.")

end

----------------------------------------------------------------------
-- Structured rule editor
----------------------------------------------------------------------
local RULE_FIELDS = {
    { "itemID", "Item IDs", "numberList", "19019, 17182", "Comma-separated numeric item IDs." },
    { "name", "Name contains", "string", "healing potion", "Case-insensitive text contained anywhere in the item name." },
}

local ITEM_TYPES = {
    "Armor", "Weapon", "Consumable", "Container", "Trade Goods", "Recipe", "Gem", "Quest",
    "Miscellaneous", "Key", "Projectile", "Glyph", "Reagent", "Quiver", "Generic", "Money", "Permanent",
}
local ITEM_SUBTYPES = {
    "Cloth", "Leather", "Mail", "Plate", "Buckler", "Shield", "Libram", "Idol", "Totem", "Sigil", "Miscellaneous",
    "One-Handed Axes", "Two-Handed Axes", "One-Handed Maces", "Two-Handed Maces",
    "One-Handed Swords", "Two-Handed Swords", "Daggers", "Fist Weapons", "Polearms",
    "Staves", "Bows", "Crossbows", "Guns", "Wands", "Thrown", "Fishing Poles", "Exotic", "Exotic 2", "Spear",
    "Consumable", "Food & Drink", "Potion", "Elixir", "Flask", "Scroll", "Item Enhancement", "Bandage", "Other",
    "Bag", "Enchanting Bag", "Herb Bag", "Engineering Bag", "Gem Bag", "Leatherworking Bag",
    "Inscription Bag", "Mining Bag", "Soul Bag", "Elemental", "Enchanting", "Herb",
    "Jewelcrafting", "Metal & Stone", "Meat", "Parts", "Devices", "Explosives", "Materials",
    "Cooking", "Inscription", "Trade Goods", "Armor Enchantment", "Weapon Enchantment", "Book",
    "Leatherworking Pattern", "Tailoring Pattern", "Blacksmithing Plan", "Enchanting Formula",
    "Engineering Schematic", "Alchemy Recipe", "Cooking Recipe", "First Aid Manual", "Fishing Manual",
    "Jewelcrafting Design", "Inscription Technique", "Red", "Blue", "Yellow", "Purple", "Green", "Orange",
    "Meta", "Simple", "Prismatic", "Junk", "Reagent", "Companion Pets", "Pet", "Pets", "Mount", "Holiday",
    "Key", "Lockpick", "Arrow", "Bullet", "Quiver", "Ammo Pouch", "Quest", "Generic", "Money", "Permanent",
    "Warrior", "Paladin", "Hunter", "Rogue", "Priest", "Death Knight", "Shaman", "Mage", "Warlock", "Druid",
}
-- Subtype choices are filtered by the selected item types. Values that occur
-- in more than one category are de-duplicated when multiple types are chosen.
local SUBTYPES_BY_TYPE = {
    Armor = { "Cloth", "Leather", "Mail", "Plate", "Buckler", "Shield", "Libram", "Idol", "Totem", "Sigil", "Miscellaneous" },
    Weapon = {
        "One-Handed Axes", "Two-Handed Axes", "One-Handed Maces", "Two-Handed Maces",
        "One-Handed Swords", "Two-Handed Swords", "Daggers", "Fist Weapons", "Polearms",
        "Staves", "Bows", "Crossbows", "Guns", "Wands", "Thrown", "Fishing Poles", "Exotic", "Exotic 2", "Spear", "Miscellaneous",
    },
    Consumable = { "Consumable", "Food & Drink", "Potion", "Elixir", "Flask", "Scroll", "Item Enhancement", "Bandage", "Explosives", "Devices", "Other" },
    Container = { "Bag", "Enchanting Bag", "Herb Bag", "Engineering Bag", "Gem Bag", "Leatherworking Bag", "Inscription Bag", "Mining Bag", "Soul Bag" },
    ["Trade Goods"] = { "Elemental", "Enchanting", "Herb", "Jewelcrafting", "Cloth", "Leather", "Metal & Stone", "Meat", "Parts", "Devices", "Explosives", "Materials", "Cooking", "Inscription", "Trade Goods", "Armor Enchantment", "Weapon Enchantment", "Other" },
    Recipe = { "Book", "Leatherworking Pattern", "Tailoring Pattern", "Blacksmithing Plan", "Enchanting Formula", "Engineering Schematic", "Alchemy Recipe", "Cooking Recipe", "First Aid Manual", "Fishing Manual", "Jewelcrafting Design", "Inscription Technique" },
    Gem = { "Red", "Blue", "Yellow", "Purple", "Green", "Orange", "Meta", "Simple", "Prismatic" },
    Miscellaneous = { "Junk", "Reagent", "Companion Pets", "Pet", "Pets", "Mount", "Holiday", "Other" },
    Key = { "Key", "Lockpick" },
    Projectile = { "Arrow", "Bullet" },
    Reagent = { "Reagent" },
    Quiver = { "Quiver", "Ammo Pouch" },
    Quest = { "Quest" },
    Generic = { "Generic" },
    Money = { "Money" },
    Permanent = { "Permanent" },
    Glyph = { "Warrior", "Paladin", "Hunter", "Rogue", "Priest", "Death Knight", "Shaman", "Mage", "Warlock", "Druid" },
}

-- Merge the live client's Auction House categories as well. Ascension can add
-- custom types or subtypes without requiring this list to be patched again.
local auctionClassificationsLoaded = false
local function LoadAuctionClassifications()
    if auctionClassificationsLoaded or not GetAuctionItemClasses then return end
    local classes = { pcall(GetAuctionItemClasses) }
    if not classes[1] then return end
    auctionClassificationsLoaded = true
    table.remove(classes, 1)
    local knownTypes = {}; for _, value in ipairs(ITEM_TYPES) do knownTypes[value] = true end
    local knownSubtypes = {}; for _, value in ipairs(ITEM_SUBTYPES) do knownSubtypes[value] = true end
    for classIndex, itemType in ipairs(classes) do
        if type(itemType) == "string" and itemType ~= "" then
            if not knownTypes[itemType] then table.insert(ITEM_TYPES, itemType); knownTypes[itemType] = true end
            SUBTYPES_BY_TYPE[itemType] = SUBTYPES_BY_TYPE[itemType] or {}
            if GetAuctionItemSubClasses then
                local subtypes = { pcall(GetAuctionItemSubClasses, classIndex) }
                if subtypes[1] then
                    table.remove(subtypes, 1)
                    local mapped = {}; for _, value in ipairs(SUBTYPES_BY_TYPE[itemType]) do mapped[value] = true end
                    for _, subType in ipairs(subtypes) do
                        if type(subType) == "string" and subType ~= "" then
                            if not knownSubtypes[subType] then table.insert(ITEM_SUBTYPES, subType); knownSubtypes[subType] = true end
                            if not mapped[subType] then table.insert(SUBTYPES_BY_TYPE[itemType], subType); mapped[subType] = true end
                        end
                    end
                end
            end
        end
    end
end
local EQUIP_SLOTS = {
    "INVTYPE_HEAD", "INVTYPE_NECK", "INVTYPE_SHOULDER", "INVTYPE_BODY", "INVTYPE_CHEST",
    "INVTYPE_WAIST", "INVTYPE_LEGS", "INVTYPE_FEET", "INVTYPE_WRIST", "INVTYPE_HAND",
    "INVTYPE_FINGER", "INVTYPE_TRINKET", "INVTYPE_CLOAK", "INVTYPE_MAINHAND", "INVTYPE_OFFHAND",
    "INVTYPE_RANGED", "INVTYPE_RELIC", "INVTYPE_HOLDABLE", "INVTYPE_WEAPON",
    "INVTYPE_WEAPONMAINHAND", "INVTYPE_WEAPONOFFHAND", "INVTYPE_2HWEAPON", "INVTYPE_TABARD", "INVTYPE_BAG",
}
local BINDING_STATES = { "soulbound", "bop", "boe", "bou", "unbound" }
-- Human-readable labels for the raw API/shorthand values above. The stored
-- rule values stay the same (INVTYPE_* / bop / boe / ...) - only what the menus
-- and the readable summary show changes, so a player never has to decode a
-- constant like "INVTYPE_WEAPONMAINHAND" or an abbreviation like "bou".
local EQUIP_SLOT_NAMES = {
    INVTYPE_HEAD = "Head", INVTYPE_NECK = "Neck", INVTYPE_SHOULDER = "Shoulder",
    INVTYPE_BODY = "Shirt", INVTYPE_CHEST = "Chest", INVTYPE_WAIST = "Waist",
    INVTYPE_LEGS = "Legs", INVTYPE_FEET = "Feet", INVTYPE_WRIST = "Wrist",
    INVTYPE_HAND = "Hands", INVTYPE_FINGER = "Finger", INVTYPE_TRINKET = "Trinket",
    INVTYPE_CLOAK = "Back", INVTYPE_MAINHAND = "Main Hand", INVTYPE_OFFHAND = "Off Hand",
    INVTYPE_RANGED = "Ranged", INVTYPE_RELIC = "Relic", INVTYPE_HOLDABLE = "Held In Off-hand",
    INVTYPE_WEAPON = "One-Hand", INVTYPE_WEAPONMAINHAND = "Main Hand (1H)",
    INVTYPE_WEAPONOFFHAND = "Off Hand (1H)", INVTYPE_2HWEAPON = "Two-Hand",
    INVTYPE_TABARD = "Tabard", INVTYPE_BAG = "Bag",
}
local BINDING_NAMES = {
    soulbound = "Soulbound", bop = "Bind on Pickup", boe = "Bind on Equip",
    bou = "Bind on Use", unbound = "Unbound",
}
local MONEY_ICONS = {
    gold = "|TInterface\\MoneyFrame\\UI-GoldIcon:14:14:0:0|t",
    silver = "|TInterface\\MoneyFrame\\UI-SilverIcon:14:14:0:0|t",
    copper = "|TInterface\\MoneyFrame\\UI-CopperIcon:14:14:0:0|t",
}
local LEVEL_OPERATORS = {
    { text = "Any", value = "any" }, { text = "Lower than (<)", value = "lower" },
    { text = "Lower or equal (<=)", value = "lowerOrEqual" }, { text = "Equal (=)", value = "equal" },
    { text = "Higher or equal (>=)", value = "higherOrEqual" }, { text = "Higher than (>)", value = "higher" },
}
local LEVEL_TARGETS = { { text = "Player Level", value = "player" }, { text = "Entered Level", value = "value" } }

local function ParseList(text, numbers)
    local result = {}
    for value in string.gmatch(text or "", "[^,]+") do
        value = strtrim(value)
        if value ~= "" then
            if numbers then
                value = tonumber(value)
                if not value then return nil, "Expected a comma-separated number list." end
            end
            table.insert(result, value)
        end
    end
    if #result == 0 then return nil end
    if #result == 1 then return result[1] end
    return result
end

local function ValueText(value, names)
    local values = type(value) == "table" and value or { value }
    local parts = {}
    for _, entry in ipairs(values) do table.insert(parts, names and names[entry] or tostring(entry)) end
    return table.concat(parts, ", ")
end

local function RuleTitle(rule, index)
    if type(rule) ~= "table" then return "Invalid Rule" end
    if type(rule.title) == "string" and strtrim(rule.title) ~= "" then return rule.title end
    if rule.quality == 0 then return "Sell Junk" end
    if rule.itemType then return "Match " .. ValueText(rule.itemType) end
    if rule.itemID then return "Match Specific Item" end
    return "Rule " .. tostring(index or "")
end

local function RuleDetails(rule)
    if type(rule) ~= "table" then return "This rule is invalid." end
    local lines = {}
    local function Add(label, value)
        if value ~= nil then table.insert(lines, TitleCase(label) .. ":  " .. tostring(value)) end
    end
    Add("Item IDs", rule.itemID and ValueText(rule.itemID))
    Add("Name contains", rule.name)
    Add("Item types", rule.itemType and ValueText(rule.itemType))
    Add("Subtypes", rule.subType and ValueText(rule.subType))
    Add("Qualities", rule.quality and ValueText(rule.quality, QUALITY_NAMES))
    local operatorText = { lower = "lower than", lowerOrEqual = "lower than or equal to", equal = "equal to", higherOrEqual = "higher than or equal to", higher = "higher than" }
    local function ComparisonText(comparison, legacy)
        if type(comparison) == "table" then
            local target = comparison.target == "player" and "player level" or ("level " .. tostring(comparison.value))
            return (operatorText[comparison.operator] or tostring(comparison.operator)) .. " " .. target
        end
        if type(legacy) == "number" then return "equal to level " .. legacy end
        if legacy then return (operatorText[legacy] or tostring(legacy)) .. " player level" end
    end
    Add("Required level", ComparisonText(rule.reqLevelCompare, rule.reqLevel))
    Add("Binding", rule.bound and ValueText(rule.bound, BINDING_NAMES))
    if rule.unusable ~= nil then
        Add("Usable by player", rule.unusable and "No" or "Yes")
    end
    if rule.isUpgrade ~= nil then
        Add("Item is an upgrade", rule.isUpgrade and "Yes" or "No")
    end
    Add("Equip slots", rule.equipSlot and ValueText(rule.equipSlot, EQUIP_SLOT_NAMES))
    local function MoneyText(copper)
        if copper == nil then return nil end
        local gold = math.floor(copper / 10000); local silver = math.floor((copper % 10000) / 100); local remainder = copper % 100
        return gold .. MONEY_ICONS.gold .. "  " .. silver .. MONEY_ICONS.silver .. "  " .. remainder .. MONEY_ICONS.copper
    end
    Add("Minimum vendor price", MoneyText(rule.minVendorPrice))
    Add("Maximum vendor price", MoneyText(rule.maxVendorPrice))
    Add("Item level", ComparisonText(rule.itemLevelCompare))
    Add("Minimum item level", rule.minItemLevel and tostring(rule.minItemLevel))
    Add("Maximum item level", rule.maxItemLevel and tostring(rule.maxItemLevel))
    Add("Roll order", rule.rollPriority and table.concat(rule.rollPriority, "  >  "))
    Add("Exceptions", rule.exceptions and (#rule.exceptions .. " exception(s)"))
    return #lines > 0 and table.concat(lines, "\n") or "No matching conditions have been configured."
end

-- Selection never uses a solid blue fill: a bright block of color at this size
-- overwhelms the pane. Selected means a dark control that keeps its own
-- background, outlined in blue with blue text.
local function PaintButtonText(button, selected)
    local font = button:GetFontString()
    if not font then return end
    font:SetShadowColor(0, 0, 0, 1)
    font:SetShadowOffset(1, -1)
    font:SetTextColor(Unpack(selected and BRAND or TEXT))
end

local function PaintNavStyleButton(self, hovered)
    if self.selected then
        self:SetBackdropColor(Unpack(SELECT_BG))
        self:SetBackdropBorderColor(Unpack(BRAND))
        PaintButtonText(self, true)
    else
        self:SetBackdropColor(Unpack(CTRL_BG))
        if hovered then
            self:SetBackdropBorderColor(Unpack(BRAND, 0.55))
        else
            self:SetBackdropBorderColor(Unpack(BORDER))
        end
        PaintButtonText(self, false)
    end
end

-- Borderless close: just a glyph in the corner, with a soft red disc fading in
-- behind it on hover. No backdrop box, so it reads as part of the title bar
-- rather than as another button competing with the content.
StyledCloseButton = function(parent, callback)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(22, 22)
    button:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -8, -8)

    local disc = button:CreateTexture(nil, "BACKGROUND")
    disc:SetTexture(CIRCLE_TEX)
    disc:SetAllPoints(button)
    disc:Hide()

    -- Lower-case x: its arms are equal length, so it reads as a square cross.
    -- A capital X is noticeably taller than it is wide at this size. Sized up
    -- explicitly because a lower-case glyph is small for its font.
    local glyph = button:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    glyph:SetPoint("CENTER", button, "CENTER", 0, 0)
    glyph:SetText("x")
    local fontPath, _, fontFlags = glyph:GetFont()
    if fontPath then glyph:SetFont(fontPath, 20, fontFlags) end

    local function Paint(hovered)
        if hovered then
            disc:SetVertexColor(CLOSE_RED[1], CLOSE_RED[2], CLOSE_RED[3], 0.18)
            disc:Show()
            glyph:SetTextColor(1, 0.5, 0.5)
        else
            disc:Hide()
            glyph:SetTextColor(Unpack(CLOSE_RED))
        end
    end

    button:SetScript("OnEnter", function(self)
        Paint(true)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Close", Unpack(BRAND))
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() Paint(false); GameTooltip:Hide() end)
    button:SetScript("OnClick", callback)
    Paint(false)
    return button
end


-- A centered modal with a multi-line text box, used for sharing import/export
-- strings without a permanent box eating room on the page. Export mode passes
-- opts.text and no onAccept: the box is pre-filled and selected for copying,
-- with a single Close button. Import mode passes opts.onAccept and no text: the
-- box starts blank, and the accept button hands whatever was pasted to
-- onAccept, closing only when it returns a non-false value so a failed paste
-- can be corrected in place. Registered as a rule-editor blocker so a page
-- change or Escape tears it down cleanly.
OpenTextPopup = function(opts)
    local blocker = CreateFrame("Frame", nil, pageHost)
    table.insert(ruleEditorBlockers, blocker)
    blocker:SetAllPoints(pageHost)
    blocker:SetFrameStrata("DIALOG"); blocker:SetFrameLevel(90); blocker:EnableMouse(true)

    -- Dim the pane behind the dialog so the modal reads as on top.
    local dim = blocker:CreateTexture(nil, "BACKGROUND")
    dim:SetAllPoints(blocker); dim:SetTexture(WHITE_TEX); dim:SetVertexColor(0, 0, 0, 0.55)

    local window = CreateFrame("Frame", nil, blocker)
    window:SetFrameStrata("DIALOG"); window:SetFrameLevel(100); window:EnableMouse(true)
    window:SetPoint("CENTER", blocker, "CENTER", 0, 30)
    window:SetSize(500, 244)
    ModalSurface(window)

    local function Close()
        if focusedEditBox then focusedEditBox:ClearFocus(); focusedEditBox = nil end
        ForgetRuleEditor(blocker)
        blocker:Hide()
    end
    StyledCloseButton(window, Close)
    blocker:SetScript("OnMouseDown", function() if focusedEditBox then focusedEditBox:ClearFocus() end end)
    window:SetScript("OnMouseDown", function() if focusedEditBox then focusedEditBox:ClearFocus() end end)

    local heading = window:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    heading:SetPoint("TOPLEFT", 18, -16); heading:SetText(opts.title or ""); heading:SetTextColor(Unpack(BRAND))
    if opts.subtitle then
        local sub = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        sub:SetPoint("TOPLEFT", 18, -40); sub:SetWidth(430); sub:SetJustifyH("LEFT")
        sub:SetText(opts.subtitle); sub:SetTextColor(Unpack(TEXT))
    end

    -- Multi-line box inside a scroll frame, parented to the window so it lives
    -- and dies with this dialog rather than the page beneath it.
    local scroll = CreateFrame("ScrollFrame", nil, window)
    scroll:SetPoint("TOPLEFT", 24, -82); scroll:SetSize(430, 96)
    local box = CreateFrame("Frame", nil, window)
    box:SetPoint("TOPLEFT", scroll, "TOPLEFT", -6, 6)
    box:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", 6, -6)
    UI.Backdrop(box, COLORS.control, 1)
    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true); edit:SetSize(412, 96); edit:SetAutoFocus(false)
    edit:SetFontObject(ChatFontNormal); edit:SetTextInsets(4, 4, 4, 4)
    edit:SetScript("OnEscapePressed", function() Close() end)
    edit:SetScript("OnEditFocusGained", function(self) focusedEditBox = self end)
    edit:SetScript("OnEditFocusLost", function(self) if focusedEditBox == self then focusedEditBox = nil end end)
    scroll:SetScrollChild(edit)
    local popupScrollbar = UI.CreateVerticalScrollbar(window, 92, function(value)
        scroll:SetVerticalScroll(value)
    end, 30)
    popupScrollbar:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", -2, -2)
    local function UpdatePopupScrollbar()
        popupScrollbar:SetScrollRange(math.max(0, (edit:GetHeight() or 0) - 96),
            scroll:GetVerticalScroll() or 0)
    end
    local function ScrollPopup(delta)
        local maximum = math.max(0, (edit:GetHeight() or 0) - 96)
        popupScrollbar:SetScrollRange(maximum,
            math.max(0, math.min(maximum, (scroll:GetVerticalScroll() or 0) + delta)))
    end
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(_, delta) ScrollPopup(delta > 0 and -30 or 30) end)
    edit:EnableMouseWheel(true)
    edit:SetScript("OnMouseWheel", function(_, delta) ScrollPopup(delta > 0 and -30 or 30) end)
    edit:HookScript("OnTextChanged", UpdatePopupScrollbar)

    -- Buttons anchored bottom-right; the accept button (import) sits left of
    -- the Cancel button, matching the Yes/No ordering used elsewhere. Export
    -- has no accept button - just Cancel to dismiss once the text is copied.
    local dismiss = SkinnedButton(window, CANCEL or "Cancel", 0, 0, 100, Close)
    dismiss:ClearAllPoints(); dismiss:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -18, 16)
    if opts.onAccept then
        local accept = SkinnedButton(window, opts.acceptLabel or "OK", 0, 0, 110, function()
            if opts.onAccept(edit:GetText()) ~= false then Close() end
        end)
        accept:ClearAllPoints(); accept:SetPoint("BOTTOMRIGHT", dismiss, "BOTTOMLEFT", -10, 0)
    end

    if opts.text then
        edit:SetText(opts.text); edit:SetFocus(); edit:HighlightText()
    else
        edit:SetFocus()
    end
    return edit
end


-- Full-pane confirmation window for Quick Abandon (ported from the
-- ClearQuests addon): a small options grid, a scrollable list of exactly
-- what will be abandoned recomputed after every change, and nothing is
-- abandoned until the button at the bottom is confirmed. Built fresh each
-- open, like OpenRuleEditor, so it always reflects the current quest log.
local function SelectionButton(parent, text, x, y, width, callback)
    local button = Track(CreateFrame("Button", nil, parent))
    button:SetSize(width, 25); button:SetPoint("TOPLEFT", x, y)
    button:SetNormalFontObject("GameFontHighlight"); button:SetHighlightFontObject("GameFontHighlight")
    -- Template-less buttons do not reliably create their implicit font string
    -- on older clients. Own one explicitly so virtual rows can always anchor
    -- their summary and strike-through regions to a real label.
    local ownedFont = button:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    ownedFont:SetPoint("LEFT", button, "LEFT", 12, 0)
    ownedFont:SetPoint("RIGHT", button, "RIGHT", -8, 0)
    ownedFont:SetJustifyH("LEFT")
    ownedFont:SetText(text)
    button.fontString = ownedFont

    local wash = button:CreateTexture(nil, "BACKGROUND")
    wash:SetTexture(WHITE_TEX)
    wash:SetAllPoints(button)
    wash:Hide()

    local accent = button:CreateTexture(nil, "ARTWORK")
    accent:SetTexture(WHITE_TEX)
    accent:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
    accent:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0)
    accent:SetWidth(2)
    accent:Hide()

    button:SetScript("OnClick", callback)
    button.selected = false
    local function Paint(self, hovered)
        if self.selected then
            wash:SetVertexColor(Unpack(BRAND, 0.15)); wash:Show()
            accent:SetVertexColor(Unpack(self.inactive and BRAND_DIM or BRAND)); accent:Show()
        else
            accent:Hide()
            if hovered then
                wash:SetVertexColor(1, 1, 1, 0.06); wash:Show()
            else
                wash:Hide()
            end
        end
        -- Deactivated rules read dimmer than active ones in either state.
        local label = self.fontString
        if label then
            label:SetShadowColor(0, 0, 0, 1)
            label:SetShadowOffset(1, -1)
            if self.inactive then
                label:SetTextColor(Unpack(self.selected and BRAND_DIM or TEXT_MUTED))
            else
                label:SetTextColor(Unpack(self.selected and BRAND or TEXT))
            end
        end
        if self.strike then
            if self.inactive then
                local color = self.selected and BRAND_DIM or TEXT_MUTED
                self.strike:SetTexture(color[1], color[2], color[3], 1); self.strike:Show()
            else
                self.strike:Hide()
            end
        end
    end
    button:SetScript("OnEnter", function(self)
        Paint(self, true)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self.tooltipTitle or "Rule", Unpack(BRAND))
        GameTooltip:AddLine(self.tooltipText or "Click to select this rule.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function(self) Paint(self, false); GameTooltip:Hide() end)
    button.Paint = Paint
    return button
end


OpenQuickAbandonWindow = function()
    local blocker = CreateFrame("Frame", nil, pageHost)
    table.insert(ruleEditorBlockers, blocker)
    blocker:SetAllPoints(pageHost); blocker:SetFrameStrata("DIALOG"); blocker:SetFrameLevel(90); blocker:EnableMouse(true)
    blocker:SetScript("OnMouseDown", function() end)
    local window = CreateFrame("Frame", nil, blocker)
    window:SetAllPoints(blocker)
    window:SetFrameStrata("DIALOG"); window:SetFrameLevel(100)
    window:EnableMouse(true)
    window:SetScript("OnMouseDown", function()
        if focusedEditBox then focusedEditBox:ClearFocus() end
        CloseOpenMenu()
    end)
    ModalSurface(window)

    local function Close()
        ForgetRuleEditor(blocker)
        blocker:Hide()
    end
    StyledCloseButton(window, Close)

    local heading = window:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    heading:SetPoint("TOPLEFT", 18, -16)
    heading:SetText("Quick Abandon")
    heading:SetTextColor(Unpack(BRAND))
    local subheading = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subheading:SetPoint("TOPLEFT", 18, -38)
    subheading:SetText("Prestige and Mentorship quests are always kept. Everything else follows the options below.")
    subheading:SetTextColor(Unpack(TEXT))

    ------------------------------------------------------------------
    -- Options: real pill toggles (Check(), the same green/red control every
    -- other page uses). IMPORTANT: every mutation in this window goes
    -- through SetSettingWithoutRefresh, never AutoCore.SetSetting directly -
    -- the plain version triggers a full Core.Settings.Refresh(), which
    -- rebuilds the underlying Quest page and hides every Track()-registered
    -- widget on it, INCLUDING this window's own rows and buttons
    -- (SelectionButton/Button/Check all call Track() internally).
    ------------------------------------------------------------------
    local Refresh, RefreshWhitelist
    local function QuestToggle(key, label, x, y)
        local initial = AutoCore.GetSetting("quest", key, AutoQuestConfig and AutoQuestConfig[key]) ~= false
        Check(window, label, x, y, initial, function(checked)
            SetSettingWithoutRefresh("quest", key, checked)
            Refresh()
        end)
    end
    -- Second toggle column sits directly above the right-hand list box
    -- (RIGHT_X = LEFT_X + COLUMN_WIDTH + COLUMN_GAP = 380 below), so the two
    -- toggle columns line up with the two boxes beneath them.
    local TOGGLE_COL2_X = 380
    QuestToggle("quickAbandonKeepDaily", "Keep Daily Quests", 18, -68)
    QuestToggle("quickAbandonKeepPathToAscension", "Keep Path to Ascension", 18, -94)
    QuestToggle("quickAbandonKeepComplete", "Keep Complete Quests", 18, -120)
    QuestToggle("quickAbandonKeepTrivialComplete", "Keep Trivial Complete Quests", 18, -146)
    QuestToggle("quickAbandonKeepDungeon", "Keep Dungeon Quests", TOGGLE_COL2_X, -68)
    QuestToggle("quickAbandonKeepTrivialDungeon", "Keep Trivial Dungeon Quests", TOGGLE_COL2_X, -94)
    QuestToggle("quickAbandonKeepPartialProgress", "Keep Partial Progress Quests", TOGGLE_COL2_X, -120)
    QuestToggle("quickAbandonKeepTrivialPartialProgress", "Keep Trivial Partial Progress Quests", TOGGLE_COL2_X, -146)

    ------------------------------------------------------------------
    -- Column geometry. Fixed sizes throughout so nothing can drift out of
    -- sync between the two columns. Margins are symmetric now (6px each
    -- side) since there is no built-in scrollbar reserving extra room on
    -- the right any more - both panels are genuinely the same size, not
    -- just nominally the same width with lopsided borders.
    ------------------------------------------------------------------
    local LEFT_X, COLUMN_WIDTH, COLUMN_GAP = 18, 320, 42
    local RIGHT_X = LEFT_X + COLUMN_WIDTH + COLUMN_GAP
    local LIST_TOP, LIST_HEIGHT = -208, 360
    local PANEL_MARGIN = 6
    local BUTTON_GAP_ABOVE = 16
    local BUTTON_Y = LIST_TOP - LIST_HEIGHT - BUTTON_GAP_ABOVE
    local BUTTON_H, BUTTON_GAP = 26, 10
    -- The button pair spans the panel's full visual width, border to border
    -- (x - PANEL_MARGIN to x + width + PANEL_MARGIN), not just the inner
    -- scroll area, so the buttons line up with the panel edges above them.
    local BUTTON_ROW_WIDTH = COLUMN_WIDTH + PANEL_MARGIN * 2
    local PAIR_BUTTON_W = math.floor((BUTTON_ROW_WIDTH - BUTTON_GAP) / 2)

    ------------------------------------------------------------------
    -- A selectable, scrollable list of rows (SelectionButton, the control
    -- the rule pages use for the same highlight-and-act interaction).
    -- Each list uses the shared arrowless pill scrollbar.
    ------------------------------------------------------------------
    local SCROLL_STEP = 50
    local function BuildSelectableList(x, y, width, height, rowTooltipTitle, rowTooltipText)
        local scrollFrame = CreateFrame("ScrollFrame", nil, window)
        scrollFrame:SetPoint("TOPLEFT", x, y)
        scrollFrame:SetSize(width, height)
        scrollFrame:EnableMouseWheel(true)
        local backdrop = CreateFrame("Frame", nil, window)
        backdrop:SetPoint("TOPLEFT", scrollFrame, "TOPLEFT", -PANEL_MARGIN, PANEL_MARGIN)
        backdrop:SetPoint("BOTTOMRIGHT", scrollFrame, "BOTTOMRIGHT", PANEL_MARGIN, -PANEL_MARGIN)
        UI.Backdrop(backdrop, COLORS.control, 1)
        local scrollChild = CreateFrame("Frame", nil, scrollFrame)
        local rowWidth = width - 10
        scrollChild:SetSize(rowWidth, 1)
        scrollFrame:SetScrollChild(scrollChild)
        local contentHeight = 1

        -- contentHeight is tracked locally rather than read back via
        -- scrollChild:GetHeight() - keeping the one true value we just set
        -- avoids any dependency on the frame reporting it back correctly.
        local scrollbar = UI.CreateVerticalScrollbar(window, height - 4, function(value)
            scrollFrame:SetVerticalScroll(value)
        end, SCROLL_STEP)
        scrollbar:SetPoint("TOPRIGHT", scrollFrame, "TOPRIGHT", -2, -2)
        local function UpdateScrollbar()
            local maxScroll = math.max(0, contentHeight - height)
            scrollbar:SetScrollRange(maxScroll, scrollFrame:GetVerticalScroll() or 0)
        end
        local function ScrollBy(delta)
            local maxScroll = math.max(0, contentHeight - height)
            local newValue = (scrollFrame:GetVerticalScroll() or 0) + delta
            if newValue < 0 then newValue = 0 end
            if newValue > maxScroll then newValue = maxScroll end
            scrollbar:SetScrollRange(maxScroll, newValue)
        end
        scrollFrame:SetScript("OnMouseWheel", function(_, delta) ScrollBy(delta > 0 and -SCROLL_STEP or SCROLL_STEP) end)

        local list = {}
        local rows = {}
        local items = {}
        local selectedIndex

        function list:SetItems(newItems)
            items = newItems
            for _, row in ipairs(rows) do row:Hide() end
            wipe(rows)
            if selectedIndex and not items[selectedIndex] then selectedIndex = nil end
            local rowY = 0
            for index, item in ipairs(items) do
                local row = SelectionButton(scrollChild, item.text, 0, rowY, rowWidth, function()
                    selectedIndex = index
                    for i, r in ipairs(rows) do r.selected = (i == index); r:Paint(false) end
                end)
                row.selected = (index == selectedIndex)
                -- Otherwise these fall back to SelectionButton's own default
                -- ("Rule" / "Click to select this rule.") which is rule-editor
                -- wording, not something that makes sense for a quest list.
                row.tooltipTitle = rowTooltipTitle
                row.tooltipText = rowTooltipText
                row:Paint(false)
                table.insert(rows, row)
                rowY = rowY - 25
            end
            contentHeight = math.max(1, -rowY)
            scrollChild:SetHeight(contentHeight)
            scrollFrame:SetVerticalScroll(0)
            UpdateScrollbar()
        end

        function list:GetSelectedValue()
            return selectedIndex and items[selectedIndex] and items[selectedIndex].value or nil
        end

        return list
    end

    local leftHeading = window:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    leftHeading:SetPoint("TOPLEFT", LEFT_X, LIST_TOP + 24)
    leftHeading:SetTextColor(Unpack(BRAND))
    local rightHeading = window:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    rightHeading:SetPoint("TOPLEFT", RIGHT_X, LIST_TOP + 24)
    rightHeading:SetTextColor(Unpack(BRAND))

    local abandonList = BuildSelectableList(LEFT_X, LIST_TOP, COLUMN_WIDTH, LIST_HEIGHT,
        "Quest", "Click to select this quest, then use the buttons below.")
    local whitelistList = BuildSelectableList(RIGHT_X, LIST_TOP, COLUMN_WIDTH, LIST_HEIGHT,
        "Whitelisted Quest", "Click to select this quest, then use the buttons below.")

    Refresh = function()
        local candidates = AutoQuest and AutoQuest.GetQuickAbandonCandidates and AutoQuest.GetQuickAbandonCandidates() or {}
        local items = {}
        for _, quest in ipairs(candidates) do
            local levelText = quest.level > 0 and ("[" .. quest.level .. "] ") or ""
            local tagText = quest.tag ~= "" and (" (" .. quest.tag .. ")") or ""
            table.insert(items, { text = levelText .. quest.title .. tagText, value = quest })
        end
        abandonList:SetItems(items)
        leftHeading:SetText("Will Be Abandoned (" .. #candidates .. ")")
    end

    RefreshWhitelist = function()
        local list = AutoCore.GetSetting("quest", "quickAbandonWhitelist", AutoQuestConfig and AutoQuestConfig.quickAbandonWhitelist) or {}
        local items = {}
        for _, title in ipairs(list) do table.insert(items, { text = title, value = title }) end
        whitelistList:SetItems(items)
        rightHeading:SetText("Always Keep These Quests (" .. #list .. ")")
    end

    -- Adds one title to the whitelist (case-insensitively de-duplicated) and
    -- refreshes both lists. Shared by "Move to Whitelist" and "Add Custom".
    local function AddToWhitelist(title)
        title = strtrim(title or "")
        if title == "" then return end
        local list = AutoCore.GetSetting("quest", "quickAbandonWhitelist", AutoQuestConfig and AutoQuestConfig.quickAbandonWhitelist) or {}
        local lowerTitle = string.lower(title)
        for _, entry in ipairs(list) do
            if string.lower(entry) == lowerTitle then Refresh(); RefreshWhitelist(); return end
        end
        local copy = {}
        for _, entry in ipairs(list) do table.insert(copy, entry) end
        table.insert(copy, title)
        SetSettingWithoutRefresh("quest", "quickAbandonWhitelist", copy)
        Refresh()
        RefreshWhitelist()
    end

    ------------------------------------------------------------------
    -- Two buttons directly under EACH list, spanning that panel's full
    -- width edge to edge and sharing one Y with the pair under the other
    -- list, so both rows line up across the window.
    ------------------------------------------------------------------
    local LEFT_ROW_X, RIGHT_ROW_X = LEFT_X - PANEL_MARGIN, RIGHT_X - PANEL_MARGIN

    local abandonButton = Button(window, "Abandon", LEFT_ROW_X, BUTTON_Y, PAIR_BUTTON_W, function()
        local candidates = AutoQuest and AutoQuest.GetQuickAbandonCandidates and AutoQuest.GetQuickAbandonCandidates() or {}
        if #candidates == 0 then return end
        local names = {}
        for _, quest in ipairs(candidates) do table.insert(names, quest.title) end
        Confirm("Abandon " .. #candidates .. " quest" .. (#candidates == 1 and "" or "s") .. "?\n\n" .. table.concat(names, "\n"),
            function()
                local abandoned = AutoQuest.ExecuteQuickAbandon(AutoQuest.GetQuickAbandonCandidates())
                Core.Info("Quest", "Abandoned " .. abandoned .. " quest" .. (abandoned == 1 and "" or "s") .. ".")
                Refresh()
            end)
    end, BUTTON_H)
    AddTooltip(abandonButton, "Abandon", "Abandons every quest currently in the Will Be Abandoned list.")

    local moveButton = Button(window, "Move to Whitelist", LEFT_ROW_X + PAIR_BUTTON_W + BUTTON_GAP, BUTTON_Y, PAIR_BUTTON_W, function()
        local quest = abandonList:GetSelectedValue()
        if not quest then Core.Info("Quest", "Select a quest on the left first."); return end
        AddToWhitelist(quest.title)
    end, BUTTON_H)
    AddTooltip(moveButton, "Move to whitelist",
        "Moves the highlighted quest to the whitelist, so it is kept this run and every future one.")

    local addButton = Button(window, "Add Custom", RIGHT_ROW_X, BUTTON_Y, PAIR_BUTTON_W, function()
        PromptText(
            "Add a quest to the whitelist.\n\nThe name does not need to be capitalized correctly, but it must match the quest's title exactly - not just part of it.",
            "Add", AddToWhitelist)
    end, BUTTON_H)
    AddTooltip(addButton, "Add a custom quest", "Type in a quest title to whitelist it, even if it is not currently in your quest log.")

    local removeButton = Button(window, "Remove from Whitelist", RIGHT_ROW_X + PAIR_BUTTON_W + BUTTON_GAP, BUTTON_Y, PAIR_BUTTON_W, function()
        local title = whitelistList:GetSelectedValue()
        if not title then Core.Info("Quest", "Select a quest on the right first."); return end
        local list = AutoCore.GetSetting("quest", "quickAbandonWhitelist", AutoQuestConfig and AutoQuestConfig.quickAbandonWhitelist) or {}
        local copy = {}
        for _, entry in ipairs(list) do
            if entry ~= title then table.insert(copy, entry) end
        end
        SetSettingWithoutRefresh("quest", "quickAbandonWhitelist", copy)
        Refresh()
        RefreshWhitelist()
    end, BUTTON_H)
    AddTooltip(removeButton, "Remove from whitelist",
        "Removes the highlighted quest from the whitelist. It will be considered for abandoning again.")

    Refresh()
    RefreshWhitelist()
end
MultiChoiceEditor = function(parent, label, x, y, width, choices, initial, emptyText, exclusiveValue)
    label = TitleCase(label)
    local selected = {}
    if type(initial) == "table" then for _, value in ipairs(initial) do selected[value] = true end
    elseif initial ~= nil then selected[initial] = true end
    local button, onSelectionChanged
    local function CurrentChoices()
        return type(choices) == "function" and choices(selected) or choices
    end
    local function Caption()
        local current = CurrentChoices()
        local count = 0; local only
        for _, choice in ipairs(current) do if selected[choice.value] then count = count + 1; only = choice.text end end
        local caption
        if #current == 0 then
            caption = label .. ": Select item type"
        else
            caption = label .. ": " .. (count == 0 and (emptyText or "Any") or (count == 1 and only or (count .. " selected")))
        end
        -- Some 3.3.5 skins fail to invalidate the old glyphs when button text
        -- changes. Clear both the template font string and button text first.
        local font = button:GetFontString()
        if font then font:SetText("") end
        button:SetText("")
        button:SetText(caption)
    end
    local function Changed()
        Caption()
        if onSelectionChanged then onSelectionChanged() end
    end
    button = Track(CreateFrame("Button", nil, parent, "UIPanelButtonTemplate"))
    button:SetSize(width, 22); button:SetPoint("TOPLEFT", x, y); SkinButton(button)
    AddDropdownIndicator(button)
    local captionFont = button:GetFontString()
    if captionFont then captionFont:SetWidth(math.max(40, width - 30)) end
    -- The menu is rebuilt after every click rather than relying on
    -- keepShownOnClick alone: Blizzard only refreshes the row you clicked, so
    -- picking a specific type would otherwise leave "Any" still marked until
    -- the menu was closed and reopened.
    local BuildEntries, Reopen
    BuildEntries = function()
        local current = CurrentChoices()
        local entries = {
            {
                text = MenuLabel(emptyText or "Any", next(selected) == nil),
                notCheckable = true, keepShownOnClick = true,
                func = function() wipe(selected); Changed(); Reopen() end,
            },
        }
        if #current == 0 then
            table.insert(entries, { text = "Select an item type first", disabled = true, notCheckable = true })
        end
        for _, choice in ipairs(current) do
            local value = choice.value
            table.insert(entries, {
                text = MenuLabel(choice.text, selected[value] == true),
                notCheckable = true, keepShownOnClick = true,
                func = function()
                    if exclusiveValue and value == exclusiveValue then
                        wipe(selected)
                        selected[value] = true
                    else
                        if exclusiveValue then selected[exclusiveValue] = nil end
                        selected[value] = not selected[value] or nil
                    end
                    Changed()
                    Reopen()
                end,
            })
        end
        return entries
    end
    Reopen = function()
        local state = openMenuState
        OpenMenuPage(button, BuildEntries(), state and state.offset or 1)
    end

    button:SetScript("OnClick", function(self)
        ShowMenu(self, BuildEntries())
    end)
    function button:GetSelected()
        local result = {}
        -- Preserve selected values even if another field currently filters them
        -- out of the visible menu.
        for value in pairs(selected) do table.insert(result, value) end
        table.sort(result, function(a, b) return tostring(a) < tostring(b) end)
        if #result == 0 then return nil elseif #result == 1 then return result[1] else return result end
    end
    function button:SetAvailable(available)
        self.available = available and true or false
        self:SetAlpha(self.available and 1 or 0.5)
        if self.available then self:Enable() else self:Disable() end
        if not self.available and openMenuButton == self and CloseOpenMenu then CloseOpenMenu() end
    end
    function button:SetOnSelectionChanged(callback) onSelectionChanged = callback end
    function button:RefreshChoices() Caption() end
    Caption()
    return button
end

local function SectionHeading(parent, text, y)
    local heading = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    heading:SetPoint("TOPLEFT", 18, y); heading:SetText(TitleCase(text))
    heading:SetTextColor(Unpack(BRAND))
    -- Rule fades out to the right so the heading reads as the anchor rather
    -- than the line boxing the section in.
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetTexture(WHITE_TEX)
    line:SetPoint("TOPLEFT", 18, y - 17); line:SetSize(684, 1)
    line:SetGradientAlpha("HORIZONTAL", BRAND[1], BRAND[2], BRAND[3], 0.55, BRAND[1], BRAND[2], BRAND[3], 0.04)
    return y - 25
end

local function EditorEdit(parent, x, y, width, value, hint, help)
    local edit = CreateFrame("EditBox", nil, parent)
    edit:SetSize(width, 22); edit:SetPoint("TOPLEFT", x, y); edit:SetAutoFocus(false)
    edit:SetFontObject(ChatFontNormal); edit:SetTextInsets(6, 6, 0, 0); edit:SetText(tostring(value or ""))
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    edit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    edit:SetScript("OnEditFocusGained", function(self) focusedEditBox = self end)
    edit:SetScript("OnEditFocusLost", function(self) if focusedEditBox == self then focusedEditBox = nil end end)
    -- Clicking straight from one field into another must drop focus on the
    -- previous field so its placeholder hint reappears. Without this, clicking
    -- editbox-to-editbox never fires the old box's OnEditFocusLost on this
    -- client, leaving its grey hint hidden until you click empty space. The
    -- Track()-wrapped fields elsewhere get this same behavior automatically;
    -- EditorEdit is built without Track(), so it needs its own handler.
    edit:SetScript("OnMouseDown", function(self)
        if focusedEditBox and focusedEditBox ~= self then focusedEditBox:ClearFocus() end
        if openMenuButton then CloseOpenMenu() end
    end)
    SkinEdit(edit); AddEditHint(edit, hint, help)
    return edit
end

local function MoneyEditor(parent, label, x, y, copper)
    local title = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    title:SetPoint("TOPLEFT", x, y - 3); title:SetText(TitleCase(label))
    local gold, silver, remainder = "", "", ""
    if copper ~= nil then
        gold = math.floor(copper / 10000); silver = math.floor((copper % 10000) / 100); remainder = copper % 100
    end
    local goldEdit = EditorEdit(parent, x + 118, y, 52, gold, "Gold")
    local silverEdit = EditorEdit(parent, x + 190, y, 42, silver, "Silver")
    local copperEdit = EditorEdit(parent, x + 252, y, 42, remainder, "Copper")
    local g = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); g:SetPoint("LEFT", goldEdit, "RIGHT", 3, 0); g:SetText(MONEY_ICONS.gold)
    local s = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); s:SetPoint("LEFT", silverEdit, "RIGHT", 3, 0); s:SetText(MONEY_ICONS.silver)
    local c = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); c:SetPoint("LEFT", copperEdit, "RIGHT", 3, 0); c:SetText(MONEY_ICONS.copper)
    return function()
        local texts = { goldEdit:GetText(), silverEdit:GetText(), copperEdit:GetText() }
        if strtrim(texts[1] or "") == "" and strtrim(texts[2] or "") == "" and strtrim(texts[3] or "") == "" then return nil end
        local values = {}
        for index, text in ipairs(texts) do
            text = strtrim(text or "")
            if text ~= "" and not tonumber(text) then return nil, label .. " fields must contain numbers." end
            values[index] = tonumber(text) or 0
        end
        if values[1] < 0 or values[2] < 0 or values[2] > 99 or values[3] < 0 or values[3] > 99 then
            return nil, label .. " must use non-negative gold and 0-99 silver/copper."
        end
        return math.floor(values[1]) * 10000 + math.floor(values[2]) * 100 + math.floor(values[3])
    end
end

local function LegacyComparison(source, comparisonKey, legacyKey, minKey, maxKey)
    if type(source[comparisonKey]) == "table" then return Core.DeepCopy(source[comparisonKey]), false end
    if legacyKey and source[legacyKey] ~= nil then
        if type(source[legacyKey]) == "number" then return { operator = "equal", target = "value", value = source[legacyKey] }, false end
        return { operator = source[legacyKey], target = "player" }, false
    end
    if minKey and source[minKey] ~= nil and source[maxKey] == nil then return { operator = "higherOrEqual", target = "value", value = source[minKey] }, false end
    if maxKey and source[maxKey] ~= nil and source[minKey] == nil then return { operator = "lowerOrEqual", target = "value", value = source[maxKey] }, false end
    return { operator = "any", target = "player" }, minKey and source[minKey] ~= nil and source[maxKey] ~= nil
end

local function LevelComparisonEditor(parent, label, y, initial)
    local operator = initial.operator or "any"; local target = initial.target or "player"
    local valueEdit = EditorEdit(parent, 612, y, 78, initial.value or "", "Level", "Used when Compare To is Entered Level.")
    ChoiceButton(parent, label, 18, y, 265, LEVEL_OPERATORS, operator, function(value) operator = value end)
    ChoiceButton(parent, "Compare to", 291, y, 310, LEVEL_TARGETS, target, function(value) target = value end)
    return function()
        if operator == "any" then return nil end
        local comparison = { operator = operator, target = target }
        if target == "value" then
            comparison.value = tonumber(valueEdit:GetText())
            if not comparison.value or comparison.value < 0 or comparison.value ~= math.floor(comparison.value) then
                return nil, label .. " needs a non-negative whole entered level."
            end
        end
        return comparison
    end
end

local function OpenRuleEditor(spec, existing, onSave, exceptionMode, parentEditor)
    -- Keep the editor inside the module pane. Each nested editor gets its own
    -- blocker, allowing Exception -> Rule -> rule list navigation on close/save.
    local blocker = CreateFrame("Frame", nil, pageHost)
    table.insert(ruleEditorBlockers, blocker)
    blocker:SetAllPoints(pageHost); blocker:SetFrameStrata("DIALOG"); blocker:SetFrameLevel(90); blocker:EnableMouse(true)
    blocker:SetScript("OnMouseDown", function() end)
    local editor = CreateFrame("Frame", nil, blocker)
    editor:SetAllPoints(blocker)
    editor:SetFrameStrata("DIALOG"); editor:SetFrameLevel(100)
    editor:EnableMouse(true)
    editor:SetScript("OnMouseDown", function()
        if focusedEditBox then focusedEditBox:ClearFocus() end
        CloseOpenMenu()
    end)
    ModalSurface(editor)
    local heading = editor:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    heading:SetPoint("TOPLEFT", 18, -16)
    heading:SetText((existing and "Edit " or "Add ") .. (exceptionMode and "Exception" or spec.title))
    heading:SetTextColor(Unpack(BRAND))
    local function CloseEditor()
        CloseOpenMenu()
        blocker:Hide()
        ForgetRuleEditor(blocker)
        if parentEditor then parentEditor:Show() end
    end
    StyledCloseButton(editor, CloseEditor)

    local source = Core.DeepCopy(existing or {})
    local edits = {}
    local y = SectionHeading(editor, exceptionMode and "Exception Conditions" or "Identity", -48)
    -- In exception mode the first field is the top of the form (no title row
    -- above it), so give it extra clearance below the heading's divider line -
    -- otherwise the Item IDs row sits right against the bar and reads as merged.
    if exceptionMode then y = y - 10 end
    local titleEdit
    if not exceptionMode then
        local label = editor:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        label:SetPoint("TOPLEFT", 18, y - 4); label:SetText(TitleCase("Rule title (required)"))
        titleEdit = EditorEdit(editor, 245, y, 445, source.title or "", "Sell Junk", "A short human-readable name shown in the rules list.")
        y = y - 30
    end
    for _, field in ipairs(RULE_FIELDS) do
        local label = editor:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        label:SetPoint("TOPLEFT", 18, y - 4); label:SetText(TitleCase(field[2]))
        local old = source[field[1]]
        local edit = EditorEdit(editor, 245, y, 445, type(old) == "table" and table.concat(old, ", ") or old, field[4], field[5])
        edits[field[1]] = { edit = edit, kind = field[3] }
        y = y - 30
    end

    y = SectionHeading(editor, "Classification", y - 2)
    LoadAuctionClassifications()
    local typeChoices = {}; for _, value in ipairs(ITEM_TYPES) do table.insert(typeChoices, { text = value, value = value }) end
    local subtypeChoices, knownSubtypes = {}, {}
    for _, value in ipairs(ITEM_SUBTYPES) do table.insert(subtypeChoices, { text = value, value = value }); knownSubtypes[value] = true end
    local savedSubtypes = type(source.subType) == "table" and source.subType or { source.subType }
    for _, value in ipairs(savedSubtypes) do
        if value and not knownSubtypes[value] then table.insert(subtypeChoices, { text = value .. " (saved)", value = value }) end
    end
    local qualityChoices = QualityChoices()
    local bindingChoices = {}; for _, value in ipairs(BINDING_STATES) do table.insert(bindingChoices, { text = BINDING_NAMES[value] or value, value = value }) end
    local equipChoices = {}; for _, value in ipairs(EQUIP_SLOTS) do table.insert(equipChoices, { text = EQUIP_SLOT_NAMES[value] or value, value = value }) end
    local itemTypes = MultiChoiceEditor(editor, "Item types", 18, y, 215, typeChoices, source.itemType)
    local function FilteredSubtypeChoices(selectedSubtypes)
        local selectedTypes = itemTypes:GetSelected()
        if selectedTypes == nil then
            local retained = {}
            for _, choice in ipairs(subtypeChoices) do
                if selectedSubtypes[choice.value] then table.insert(retained, choice) end
            end
            return retained
        end
        if type(selectedTypes) ~= "table" then selectedTypes = { selectedTypes } end
        local allowed = {}
        for _, itemType in ipairs(selectedTypes) do
            for _, subtype in ipairs(SUBTYPES_BY_TYPE[itemType] or {}) do allowed[subtype] = true end
        end
        local filtered = {}
        for _, choice in ipairs(subtypeChoices) do
            -- Always retain custom/saved values so editing an older rule cannot
            -- silently discard a server-specific subtype.
            if allowed[choice.value] or selectedSubtypes[choice.value] or not knownSubtypes[choice.value] then
                table.insert(filtered, choice)
            end
        end
        return filtered
    end
    local subtypes = MultiChoiceEditor(editor, "Subtypes", 242, y, 215, FilteredSubtypeChoices, source.subType)
    itemTypes:SetOnSelectionChanged(function() subtypes:RefreshChoices() end)
    local qualities = MultiChoiceEditor(editor, "Qualities", 466, y, 224, qualityChoices, source.quality)
    y = y - 30
    local bindings = MultiChoiceEditor(editor, "Binding", 18, y, 215, bindingChoices, source.bound)
    local equipSlots = MultiChoiceEditor(editor, "Equip slots", 242, y, 448, equipChoices, source.equipSlot)
    y = y - 38

    y = SectionHeading(editor, "Level Conditions", y)
    local reqInitial = LegacyComparison(source, "reqLevelCompare", "reqLevel")
    local itemInitial, preserveLegacyItemRange = LegacyComparison(source, "itemLevelCompare", nil, "minItemLevel", "maxItemLevel")
    local getReqComparison = LevelComparisonEditor(editor, "Required level", y, reqInitial); y = y - 30
    local getItemComparison = LevelComparisonEditor(editor, "Item level", y, itemInitial); y = y - 38

    y = SectionHeading(editor, "Vendor Value", y)
    local getMinimumMoney = MoneyEditor(editor, "Minimum value", 18, y, source.minVendorPrice)
    local getMaximumMoney = MoneyEditor(editor, "Maximum value", 370, y, source.maxVendorPrice)
    y = y - 38

    y = SectionHeading(editor, "State and Action", y)
    -- Plain Any/Yes/No instead of true/false. "Usable by player" reads the
    -- natural way round, so its selection is stored inverted into the rule's
    -- `unusable` flag on save (Yes usable -> unusable = false).
    local yesNo = { { text = "Any", value = "any" }, { text = "Yes", value = true }, { text = "No", value = false } }
    local usable = source.unusable == nil and "any" or (not source.unusable)
    local isUpgrade = source.isUpgrade == nil and "any" or source.isUpgrade
    ChoiceButton(editor, "Usable by player", 18, y, 210, yesNo, usable, function(value) usable = value end)
    if spec.moduleName == "sell" or spec.moduleName == "roll" then
        ChoiceButton(editor, "Item is an upgrade", 238, y, 210, yesNo, isUpgrade, function(value) isUpgrade = value end)
    end
    y = y - 38
    local priorityValues
    if not exceptionMode and spec.moduleName == "roll" then
        priorityValues = Core.DeepCopy(source.rollPriority or {})
        local rollChoices = { { text = "None", value = "none" }, { text = "Need", value = "need" }, { text = "Greed", value = "greed" }, { text = "Disenchant", value = "disenchant" }, { text = "Pass", value = "pass" } }
        for slot = 1, 4 do
            local slotIndex = slot
            ChoiceButton(editor, "Roll " .. slot, 18 + (slot - 1) * 170, y, 160, rollChoices, priorityValues[slot] or "none", function(value) priorityValues[slotIndex] = value ~= "none" and value or nil end)
        end
        y = y - 30
    end

    local exceptions = Core.DeepCopy(source.exceptions or {})
    if not exceptionMode then
        y = SectionHeading(editor, "Exceptions", y)
        -- The row's buttons render at y + 6 (to center them on the label), so
        -- pull y up by 6 first. That lands the buttons' top edge at the same
        -- offset below the divider as every section's controls above, keeping
        -- the spacing from the bar even throughout the editor.
        y = y - 6
        local exceptionLabel = editor:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        exceptionLabel:SetPoint("TOPLEFT", 18, y); exceptionLabel:SetText("Exceptions: " .. #exceptions)
        exceptionLabel:SetTextColor(Unpack(TEXT))
        SkinnedButton(editor, "Add Exception", 205, y + 6, 115, function()
            blocker:Hide()
            OpenRuleEditor(spec, nil, function(rule)
                table.insert(exceptions, rule); exceptionLabel:SetText("Exceptions: " .. #exceptions)
            end, true, blocker)
        end, 22)

        local editException = SkinnedButton(editor, "Edit Exception", 328, y + 6, 115, function(self)
            local entries = {}
            for index, exception in ipairs(exceptions) do
                local exceptionIndex = index
                table.insert(entries, { text = exceptionIndex .. ". " .. RuleTitle(exception, exceptionIndex), func = function()
                    blocker:Hide()
                    OpenRuleEditor(spec, exceptions[exceptionIndex], function(rule)
                        exceptions[exceptionIndex] = rule
                    end, true, blocker)
                end })
            end
            if #entries == 0 then table.insert(entries, { text = "No exceptions", disabled = true, notCheckable = true }) end
            ShowMenu(self, entries)
        end, 22)
        AddDropdownIndicator(editException)

        local deleteException = SkinnedButton(editor, "Delete Exception", 451, y + 6, 115, function(self)
            local entries = {}
            for index, exception in ipairs(exceptions) do
                local exceptionIndex = index
                table.insert(entries, { text = exceptionIndex .. ". " .. RuleTitle(exception, exceptionIndex), func = function()
                    table.remove(exceptions, exceptionIndex)
                    exceptionLabel:SetText("Exceptions: " .. #exceptions)
                end })
            end
            if #entries == 0 then table.insert(entries, { text = "No exceptions", disabled = true, notCheckable = true }) end
            ShowMenu(self, entries)
        end, 22)
        AddDropdownIndicator(deleteException)

        SkinnedButton(editor, "Clear All", 574, y + 6, 115, function()
            wipe(exceptions); exceptionLabel:SetText("Exceptions: 0")
        end, 22)
    end

    local errorText = editor:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    errorText:SetPoint("BOTTOMLEFT", 18, 48); errorText:SetWidth(520); errorText:SetJustifyH("LEFT")
    errorText:SetTextColor(1, 0.35, 0.25)
    local save = CreateFrame("Button", nil, editor, "UIPanelButtonTemplate")
    save:SetSize(120, 26); save:SetPoint("BOTTOMRIGHT", -18, 16); save:SetText("Save")
    SkinButton(save)
    EmphasizeButton(save, BRAND)
    local cancel = CreateFrame("Button", nil, editor, "UIPanelButtonTemplate")
    cancel:SetSize(120, 26); cancel:SetPoint("RIGHT", save, "LEFT", -8, 0); cancel:SetText("Cancel")
    SkinButton(cancel); cancel:SetScript("OnClick", CloseEditor)
    save:SetScript("OnClick", function()
        local rule = {}
        if titleEdit then
            local title = strtrim(titleEdit:GetText() or "")
            if title == "" then errorText:SetText("A rule title is required."); return end
            rule.title = title
        end
        for key, info in pairs(edits) do
            local text = strtrim(info.edit:GetText() or "")
            if text ~= "" then
                local value, err
                if info.kind == "number" then value = tonumber(text); if not value then err = "Expected a number for " .. key end
                elseif info.kind == "numberList" then value, err = ParseList(text, true)
                elseif info.kind == "stringList" then value, err = ParseList(text, false)
                elseif info.kind == "numberOrString" then value = tonumber(text) or text
                else value = text end
                if err then errorText:SetText(err); return end
                rule[key] = value
            end
        end
        rule.itemType = itemTypes:GetSelected()
        rule.subType = subtypes:GetSelected()
        rule.quality = qualities:GetSelected()
        rule.bound = bindings:GetSelected()
        rule.equipSlot = equipSlots:GetSelected()
        local comparisonError
        rule.reqLevelCompare, comparisonError = getReqComparison()
        if comparisonError then errorText:SetText(comparisonError); return end
        rule.itemLevelCompare, comparisonError = getItemComparison()
        if comparisonError then errorText:SetText(comparisonError); return end
        if preserveLegacyItemRange and not rule.itemLevelCompare then
            rule.minItemLevel, rule.maxItemLevel = source.minItemLevel, source.maxItemLevel
        end
        rule.minVendorPrice, comparisonError = getMinimumMoney()
        if comparisonError then errorText:SetText(comparisonError); return end
        rule.maxVendorPrice, comparisonError = getMaximumMoney()
        if comparisonError then errorText:SetText(comparisonError); return end
        if rule.minVendorPrice and rule.maxVendorPrice and rule.minVendorPrice > rule.maxVendorPrice then
            errorText:SetText("Minimum vendor value cannot be greater than maximum vendor value."); return
        end
        if usable ~= "any" then rule.unusable = not usable end
        if isUpgrade ~= "any" then rule.isUpgrade = isUpgrade end
        if priorityValues then
            local compact = {}; for slot = 1, 4 do if priorityValues[slot] then table.insert(compact, priorityValues[slot]) end end
            if #compact > 0 then rule.rollPriority = compact end
        end
        if #exceptions > 0 then rule.exceptions = exceptions end
        local valid, issues = Core.ValidateRule(rule, spec.moduleName, false)
        if not valid then errorText:SetText(table.concat(issues, "\n")); return end
        onSave(rule); CloseEditor()
    end)
end

-- A fixed-height, scrollable container for a list of rows, so a long rule list
-- scrolls inside its own area instead of pushing the detail panel and action
-- buttons off the bottom of the pane. Rows are added by the caller onto the
-- returned scrollChild (at x=0, stepping downward); call SetContentHeight once
-- the rows are placed so the shared pill scrollbar knows the available range.
BuildScrollList = function(parent, x, y, width, height)
    local scrollFrame = Track(CreateFrame("ScrollFrame", nil, parent))
    scrollFrame:SetPoint("TOPLEFT", x, y); scrollFrame:SetSize(width, height)
    scrollFrame:EnableMouseWheel(true)
    -- Backdrop flush with the scroll frame (no outset), so the box lines up
    -- exactly with the detail panel below it, which is anchored the same way.
    local backdrop = Track(CreateFrame("Frame", nil, parent))
    backdrop:SetPoint("TOPLEFT", scrollFrame, "TOPLEFT", 0, 0)
    backdrop:SetPoint("BOTTOMRIGHT", scrollFrame, "BOTTOMRIGHT", 0, 0)
    UI.Backdrop(backdrop, COLORS.surface, 1)
    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(width - 6, 1)
    scrollFrame:SetScrollChild(scrollChild)

    local SCROLL_STEP = 75
    local contentHeight = 1
    local scrollbar = Track(UI.CreateVerticalScrollbar(parent, height - 4, function(value)
        scrollFrame:SetVerticalScroll(value)
    end, SCROLL_STEP))
    scrollbar:SetPoint("TOPRIGHT", scrollFrame, "TOPRIGHT", -2, -2)
    local function UpdateScrollbar()
        local maxScroll = math.max(0, contentHeight - height)
        scrollbar:SetScrollRange(maxScroll, scrollFrame:GetVerticalScroll() or 0)
    end
    local function ScrollBy(delta)
        local maxScroll = math.max(0, contentHeight - height)
        local value = (scrollFrame:GetVerticalScroll() or 0) + delta
        if value < 0 then value = 0 elseif value > maxScroll then value = maxScroll end
        scrollbar:SetScrollRange(maxScroll, value)
    end
    scrollFrame:SetScript("OnMouseWheel", function(_, delta) ScrollBy(delta > 0 and -SCROLL_STEP or SCROLL_STEP) end)

    -- Set the total row height, then optionally scroll so a given downward
    -- offset (e.g. the selected row's top) is inside the visible window.
    local function SetContentHeight(totalHeight, revealOffset)
        contentHeight = math.max(1, totalHeight)
        scrollChild:SetHeight(contentHeight)
        if revealOffset then
            local maxScroll = math.max(0, contentHeight - height)
            local target = math.min(maxScroll, math.max(0, revealOffset - height + 25))
            scrollFrame:SetVerticalScroll(target)
        end
        UpdateScrollbar()
    end

    return scrollChild, SetContentHeight
end

-- Fixed-row virtual list. Only enough buttons to cover the viewport are ever
-- created; scrolling rebinds that small pool to different data indices. This
-- keeps large imported rule sets from permanently allocating hundreds of
-- frames, font strings, and textures.
local function BuildVirtualList(parent, x, y, width, height, rowHeight, createRow, bindRow)
    local scrollFrame = Track(CreateFrame("ScrollFrame", nil, parent))
    scrollFrame:SetPoint("TOPLEFT", x, y)
    scrollFrame:SetSize(width, height)
    scrollFrame:EnableMouseWheel(true)

    local backdrop = Track(CreateFrame("Frame", nil, parent))
    backdrop:SetPoint("TOPLEFT", scrollFrame)
    backdrop:SetPoint("BOTTOMRIGHT", scrollFrame)
    UI.Backdrop(backdrop, COLORS.surface, 1)

    local child = CreateFrame("Frame", nil, scrollFrame)
    child:SetSize(width - 14, height)
    scrollFrame:SetScrollChild(child)

    local visibleRows = math.max(1, math.floor(height / rowHeight))
    local rows = {}
    for poolIndex = 1, visibleRows do
        local row = createRow(child, poolIndex)
        row:ClearAllPoints()
        -- Keep the selection wash inside the list's 1px outline and leave a
        -- small breathing gap above the first row.
        row:SetPoint("TOPLEFT", 2, -(3 + (poolIndex - 1) * rowHeight))
        rows[poolIndex] = row
    end

    local items, first = {}, 1
    local Render
    local syncingScrollbar = false
    local scrollbar = Track(UI.CreateVerticalScrollbar(parent, height - 4, function(value)
        if syncingScrollbar then return end
        first = math.floor(value + 0.5) + 1
        if Render then Render() end
    end, 1))
    scrollbar:SetPoint("TOPRIGHT", scrollFrame, "TOPRIGHT", -2, -2)
    Render = function()
        local maximumFirst = math.max(1, #items - visibleRows + 1)
        if first > maximumFirst then first = maximumFirst end
        if first < 1 then first = 1 end
        for poolIndex, row in ipairs(rows) do
            local item = items[first + poolIndex - 1]
            if item ~= nil then bindRow(row, item); row:Show() else row:Hide() end
        end
        local scrollable = #items > visibleRows
        if scrollable then
            syncingScrollbar = true
            scrollbar:SetScrollRange(maximumFirst - 1, first - 1)
            syncingScrollbar = false
        else
            syncingScrollbar = true
            scrollbar:SetScrollRange(0, 0)
            syncingScrollbar = false
        end
    end
    local function ScrollBy(delta)
        first = first + delta
        Render()
    end
    scrollFrame:SetScript("OnMouseWheel", function(_, delta) ScrollBy(delta > 0 and -3 or 3) end)

    local function SetItems(newItems, revealItem)
        items = newItems or {}
        if revealItem ~= nil then
            for position, item in ipairs(items) do
                if item == revealItem then
                    if position < first then first = position
                    elseif position >= first + visibleRows then first = position - visibleRows + 1 end
                    break
                end
            end
        end
        Render()
    end

    return rows, SetItems, Render
end

local function RulePage(spec)
    return function(parent)
        Label(parent, spec.title, 20, -20, 18)
        local section = Core.GetProfileSection(spec.moduleName, true)
        if spec.moduleName == "sell" then
            -- The old regular/safety tabs occupied the first settings row.
            -- Keep every replacement control below the title and align toggles
            -- to the vertical center of the adjacent 25px dropdown.
            ScalarCheck(parent, "sell", AutoSellConfig, "printMessages", "Announce sales", 360, -54, true,
                "Prints a chat message when AutoSell sells matching items.")
            ScalarCheck(parent, "sell", AutoSellConfig, "learnVanity", "Learn vanity items", 530, -54, true,
                "Learns eligible mounts, pets, and vanity items before selling.")

            local repairDefaults = ResolvedDefault(AutoSellConfig, "autoRepair", AutoSellConfig.autoRepair or {})
            local repair = Core.DeepCopy(Core.GetSetting("sell", "autoRepair", repairDefaults)) or {}
            local function RepairToggle(key, label, x, fallback, tooltip)
                local control = Check(parent, label, x, -86, repair[key] ~= nil and repair[key] or fallback, function(value)
                    repair[key] = value
                    SetSettingWithoutRefresh("sell", "autoRepair", repair)
                end)
                AddTooltip(control, label, tooltip)
                return control
            end
            local repairEnabled = RepairToggle("enabled", "Auto repair", 20, true, "Repairs equipped and bagged gear when a merchant opens.")
            local guildRepair = RepairToggle("useGuildBank", "Use guild funds", 190, true, "Uses guild repair funds when available, then falls back to personal gold.")
            local repairMessages = RepairToggle("printMessages", "Announce repairs", 360, true, "Prints repair cost and funding source in chat.")
            ScalarCheck(parent, "sell", AutoSellConfig, "protectWeaponBench", "Protect weapon upgrades", 530, -86, true,
                "Keeps individually better hand-slot items from being sold automatically.")
            BindToggleDependency(repairEnabled, guildRepair, repairMessages)
            local maximumSellQuality = Core.GetSetting("sell", "maxQuality", ResolvedDefault(AutoSellConfig, "maxQuality", 0))
            local qualityButton = ChoiceButton(parent, "Max sell quality", 20, -48, 330, QualityChoices(), maximumSellQuality, function(value)
                section.maxQuality = value
                NotifyWithoutRefresh("sell")
            end)
            AddTooltip(qualityButton, "Sell quality safety ceiling", "AutoSell will never sell an item above this quality, even when a rule matches it.")
        elseif spec.moduleName == "roll" then
            ScalarCheck(parent, "roll", AutoRollConfig, "notifyOnly", "Notify only", 360, -54, false,
                "Reports the recommended roll without submitting it automatically.")
            local maximumRollQuality = Core.GetSetting("roll", "maxQuality", ResolvedDefault(AutoRollConfig, "maxQuality", 6))
            local qualityButton = ChoiceButton(parent, "Max roll quality", 20, -48, 330, QualityChoices(), maximumRollQuality, function(value)
                section.maxQuality = value
                NotifyWithoutRefresh("roll")
            end)
            AddTooltip(qualityButton, "Roll quality safety ceiling", "AutoRoll will never submit a roll above this quality, even when a rule matches it.")
        elseif spec.moduleName == "junk" then
            ScalarCheck(parent, "junk", AutoJunkConfig, "printMessages", "Announce deletions", 390, -25, true,
                "Prints a chat message when AutoJunk deletes matching items.")
            local modeChoices = {
                { text = "Maintain free slots", value = "target" },
                { text = "Delete matches immediately", value = "immediate" },
            }
            local deleteMode = Core.GetSetting("junk", "deleteMode", ResolvedDefault(AutoJunkConfig, "deleteMode", "target"))
            local modeButton = ChoiceButton(parent, "Mode", 20, -48, 330, modeChoices, deleteMode, function(value)
                section.deleteMode = value
                NotifyWithoutRefresh("junk")
            end)
            AddTooltip(modeButton, "Deletion mode", "Maintain free slots deletes only when bag space is low. Immediate mode deletes every matching item after bag updates.")
            local maximumJunkQuality = Core.GetSetting("junk", "maxQuality", ResolvedDefault(AutoJunkConfig, "maxQuality", 0))
            local qualityButton = ChoiceButton(parent, "Max junk quality", 360, -48, 340, QualityChoices(), maximumJunkQuality, function(value)
                section.maxQuality = value
                NotifyWithoutRefresh("junk")
            end)
            AddTooltip(qualityButton, "Junk quality safety ceiling", "AutoJunk will never delete an item above this quality, even when a rule matches it.")
            ScalarSlider(parent, "junk", AutoJunkConfig, "targetFreeSlots", "Target free slots", 20, -80, 3, 0, 100,
                "In Maintain free slots mode, AutoJunk deletes the least valuable matching stacks until this many normal-bag slots are free. 0 disables target-based deletion.",
                nil, 680)
        elseif spec.moduleName == "auction" then
            ScalarCheck(parent, "auction", AutoAuctionConfig, "showTooltipPrices", "Tooltip prices", 20, -54, true,
                    "Shows the scanned per-item and stack market value on item tooltips. Green is well-supported; orange is sparse, stale, or historical.")
                local postingMode = Core.GetSetting("auction", "postingMode", ResolvedDefault(AutoAuctionConfig, "postingMode", "queue"))
                local modeChoices = {
                    { text = "Preview queue", value = "queue" },
                    { text = "Post automatically after scan", value = "auto" },
                }
                local modeButton = ChoiceButton(parent, "Posting mode", 20, -86, 330, modeChoices, postingMode, function(value)
                    section.postingMode = value
                    NotifyWithoutRefresh("auction")
                end)
                AddTooltip(modeButton, "Auction posting mode", "Preview Queue requires a click before deposits are spent. Auto Post begins listing matched stacks as soon as a successful scan finishes.")
                local duration = Core.GetSetting("auction", "duration", ResolvedDefault(AutoAuctionConfig, "duration", 2))
                local durationButton = ChoiceButton(parent, "Duration", 360, -86, 340, {
                    { text = "12 hours", value = 1 }, { text = "24 hours", value = 2 }, { text = "48 hours", value = 3 },
                }, duration, function(value)
                    section.duration = value
                    NotifyWithoutRefresh("auction")
                end)
                AddTooltip(durationButton, "Auction duration", "The duration used for every automatically posted stack.")
                Label(parent, "Undercut %", 20, -125)
                local undercutValue = tonumber(Core.GetSetting("auction", "undercutPercent",
                    ResolvedDefault(AutoAuctionConfig, "undercutPercent", 1))) or 1
                local undercutEdit = Edit(parent, 20, -145, 220, undercutValue)
                local function SaveUndercut()
                    local value = tonumber(strtrim(undercutEdit:GetText() or ""))
                    if not value then value = undercutValue end
                    value = math.max(0, math.min(25, math.floor(value * 1000 + 0.5) / 1000))
                    undercutValue = value
                    undercutEdit:SetText(tostring(value))
                    SetSettingWithoutRefresh("auction", "undercutPercent", value)
                end
                undercutEdit:HookScript("OnEditFocusLost", SaveUndercut)
                undercutEdit:SetScript("OnEnterPressed", function(self) SaveUndercut(); self:ClearFocus() end)
                AddTooltip(undercutEdit, "Auction undercut percentage",
                    "Decimals are allowed from 0 to 25. Every positive undercut lowers the unit price by at least one copper unless the competing listing is already one copper.")
                ScalarSlider(parent, "auction", AutoAuctionConfig, "maxPriceDropPercent", "Price-drop safety", 250, -122, 40, 10, 80,
                    "Skip automatic listings when the live market falls unusually far below trusted recent observations.", nil, 220, "%")
                ScalarSlider(parent, "auction", AutoAuctionConfig, "shoppingMaxSpend", "Shopping spend cap", 480, -122, 100000, 0, 1000000,
                    "Maximum copper that assisted shopping may spend during one login session. Every purchase still requires a click.", nil, 220, "c")
        elseif spec.moduleName == "loot" then
            local function LootToggle(key, label, x, y, fallback, title, help)
                local value = Core.GetSetting("loot", key, ResolvedDefault(AutoLootConfig, key, fallback))
                local button = Check(parent, label, x, y, value, function(checked)
                    section[key] = checked
                    NotifyWithoutRefresh("loot")
                end)
                AddTooltip(button, title, help)
                return button
            end
            LootToggle("fasterLooting", "Faster looting", 20, -50, false, "Faster looting",
                "Immediately loots item slots that match an active rule. Money and currency are always looted.")
            LootToggle("disableBlizzardAutoLoot", "Disable Blizzard auto-loot", 250, -50, false,
                "Disable Blizzard auto-loot", "Turns off Blizzard's built-in auto-loot so this addon controls which items are taken.")
            LootToggle("disableAutoLootKey", "Disable auto-loot key", 480, -50, false,
                "Disable Blizzard's auto-loot key", "Disables Blizzard's modifier key so Shift cannot bypass the items-to-loot rules.")
            LootToggle("disableOnShift", "Hold Shift to pause", 20, -78, true,
                "Hold Shift to pause AutoLoot", "While Shift is held when loot opens, this addon takes nothing and leaves the window for manual looting.")
            LootToggle("printMessages", "Announce unlisted items", 250, -78, false,
                "Announce unlisted items", "Prints how many items were left because they did not match an active items-to-loot rule.")
        end
        if spec.moduleName == "loot" then
            local allowListNote = Label(parent, "Only items matching a rule are looted. Unmatched items stay; money and currency are always taken.", 20, -108)
            allowListNote:SetTextColor(0.95, 0.68, 0.24)
        end
        section[spec.profileKey] = type(section[spec.profileKey]) == "table" and section[spec.profileKey] or {}
        local profileRules = section[spec.profileKey]
        local disabledProfileKey = "disabledProfileRules"
        section[disabledProfileKey] = type(section[disabledProfileKey]) == "table" and section[disabledProfileKey] or {}
        local disabledProfile = section[disabledProfileKey]
        local selectionKey = spec.moduleName .. ":" .. spec.profileKey
        local selected
        local rows = {}
        local detailTitle, detailText, detailSource, activityButton
        local function Select(source, index)
            local selectedRule = profileRules[index]
            if type(selectedRule) ~= "table" or not detailTitle or not detailText or not detailSource then return end
            selected = { source = source, index = index }
            ruleSelections[selectionKey] = { source = source, index = index }

            -- Update and explicitly show the readable fields before repainting
            -- buttons. A skin error while repainting must never prevent the
            -- selected rule's conditions from being displayed.
            detailTitle:SetText(RuleTitle(selectedRule, index))
            local inactive = disabledProfile[index] == true
            detailSource:SetText(inactive and "Profile rule - Deactivated" or "Profile rule - Active and editable")
            if activityButton then activityButton:SetText(inactive and "Activate" or "Deactivate") end
            local ok, readable = pcall(RuleDetails, selectedRule)
            detailText:SetText(ok and readable or ("Unable to format this rule: " .. tostring(readable)))
            detailTitle:Show(); detailSource:Show(); detailText:Show()

            for _, row in ipairs(rows) do
                row.selected = row.source == source and row.index == index
                pcall(row.Paint, row, false)
            end
        end

        -- Split-pane layout: searchable rules stay on the left while readable
        -- details remain visible on the right. Actions are pinned below both.
        local ROW_STEP = 44
        -- One uniform vertical margin between the dropdown row, the list box,
        -- the detail box, and the button row, so all the gaps read the same.
        -- List top clears the controls above it by BOX_GAP. Pages with one
        -- settings row stay compact; Sell and Auction reserve their extra rows.
        local BOX_GAP = 12
        local searchTop
        if spec.moduleName == "junk" then searchTop = -134
        elseif spec.moduleName == "loot" then searchTop = -134
        elseif spec.moduleName == "auction" then searchTop = -190
        elseif spec.moduleName == "sell" then searchTop = -116
        elseif spec.moduleName == "roll" then searchTop = -86
        else searchTop = -84 end
        local listTop = searchTop - 32
        local hostHeight = parent:GetHeight()
        if not hostHeight or hostHeight < 200 then hostHeight = 624 end
        local shareTop = -(hostHeight - 14 - 24)              -- top of the Export/Import row
        local actionTop = shareTop + 24 + 8                   -- top of the main action row
        local listHeight = math.max(180, listTop - (actionTop + BOX_GAP))

        local searchBox = Edit(parent, 20, searchTop, 315, "")
        AddEditHint(searchBox, "Search rules...", "Filter by rule name, condition, item type, quality, or any other readable rule detail.")
        local matchCount = Label(parent, "", 245, searchTop - 4)
        matchCount:SetWidth(90)
        matchCount:SetJustifyH("RIGHT")
        matchCount:SetTextColor(Unpack(TEXT_MUTED))

        local details = Track(CreateFrame("Frame", nil, parent))
        details:SetPoint("TOPLEFT", 347, listTop); details:SetSize(353, listHeight); UI.Backdrop(details, COLORS.surface, 1)
        detailTitle = Track(details:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")); detailTitle:SetPoint("TOPLEFT", 14, -12); detailTitle:SetWidth(323); detailTitle:SetText("Select a rule")
        detailTitle:SetTextColor(Unpack(BRAND))
        detailSource = Track(details:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")); detailSource:SetPoint("BOTTOMRIGHT", -14, 10); detailSource:SetJustifyH("RIGHT"); detailSource:SetText("Its readable conditions will appear here.")
        detailText = Track(details:CreateFontString(nil, "OVERLAY", "GameFontHighlight")); detailText:SetPoint("TOPLEFT", 14, -38); detailText:SetWidth(323); detailText:SetJustifyH("LEFT"); detailText:SetText("")
        ApplyUIFont(detailTitle, 17); ApplyUIFont(detailText, 11); ApplyUIFont(detailSource, 10)

        local ruleMeta = {}
        local function RebuildRuleMeta()
            wipe(ruleMeta)
            for index, rule in ipairs(profileRules) do
                local readableOK, readableText = pcall(RuleDetails, rule)
                local title = RuleTitle(rule, index)
                ruleMeta[index] = {
                    title = title,
                    details = readableOK and readableText or "Unable to read this rule",
                    search = string.lower(title .. " " .. (readableOK and readableText or "")),
                }
            end
        end
        RebuildRuleMeta()

        local function CreateRuleRow(host)
            -- Fill edge-to-edge inside the list border. The slim scrollbar is
            -- drawn above the wash instead of shortening the selected row.
            local row = SelectionButton(host, "", 0, 0, 311, function(self) Select("profile", self.index) end)
            row:SetHeight(42)
            local rowTitle = row.fontString
            rowTitle:ClearAllPoints()
            rowTitle:SetPoint("TOPLEFT", row, "TOPLEFT", 12, -5)
            rowTitle:SetPoint("TOPRIGHT", row, "TOPRIGHT", -44, -5)
            rowTitle:SetHeight(14)
            rowTitle:SetJustifyH("LEFT")
            row.summary = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            row.summary:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 12, 5)
            row.summary:SetWidth(235); row.summary:SetHeight(11); row.summary:SetJustifyH("LEFT")
            row.summary:SetTextColor(Unpack(TEXT_MUTED)); ApplyUIFont(row.summary, 10)
            row.status = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.status:SetPoint("TOPRIGHT", row, "TOPRIGHT", -9, -7); ApplyUIFont(row.status, 10)
            row.strike = row:CreateTexture(nil, "OVERLAY")
            row.strike:SetHeight(1); row.strike:SetPoint("LEFT", rowTitle, "LEFT", 0, 0)
            row.tooltipText = "Select this rule to edit, duplicate, delete, reorder, or change its active state."
            table.insert(rows, row)
            return row
        end
        local function BindRuleRow(row, ruleIndex)
            local meta = ruleMeta[ruleIndex]
            row.source, row.index = "profile", ruleIndex
            row.inactive = disabledProfile[ruleIndex] == true
            row.selected = selected and selected.index == ruleIndex
            row.fontString:SetText(ruleIndex .. ".  " .. (meta and meta.title or "Rule"))
            row.summary:SetText(meta and meta.details:gsub("\n", "  •  ") or "")
            row.status:SetText(row.inactive and "OFF" or "ON")
            row.status:SetTextColor(Unpack(row.inactive and TEXT_MUTED or BRAND))
            row.tooltipTitle = row.inactive and "Deactivated profile rule" or "Active profile rule"
            row.strike:SetWidth(math.min(row.fontString:GetStringWidth(), 232))
            row:Paint(false)
        end
        local virtualRows, SetVirtualItems, RenderVirtualRows = BuildVirtualList(
            parent, 20, listTop, 315, listHeight, ROW_STEP, CreateRuleRow, BindRuleRow)
        rows = virtualRows

        local emptyText = Label(parent, "", 32, listTop - 10)
        emptyText:SetTextColor(Unpack(TEXT_MUTED)); emptyText:Hide()
        local function ApplyRuleFilter(revealIndex)
            local query = string.lower(strtrim(searchBox:GetText() or ""))
            local filtered = {}
            for index, meta in ipairs(ruleMeta) do
                if query == "" or string.find(meta.search, query, 1, true) then table.insert(filtered, index) end
            end
            if #filtered == 0 then
                emptyText:SetText(#profileRules == 0 and "No rules yet. Add one to get started." or "No rules match your search.")
                emptyText:Show()
            else emptyText:Hide() end
            matchCount:SetText(#filtered .. " of " .. #profileRules)
            SetVirtualItems(filtered, revealIndex)
        end
        searchBox:SetScript("OnTextChanged", function() ApplyRuleFilter(selected and selected.index) end)
        ApplyRuleFilter()

        local remembered = ruleSelections[selectionKey]
        if remembered and profileRules[remembered.index] then Select("profile", remembered.index)
        elseif profileRules[1] then Select("profile", 1)
        else ruleSelections[selectionKey] = nil end
        RenderVirtualRows()

        local function ReplaceDisabledTable(replacement)
            wipe(disabledProfile)
            for index, value in pairs(replacement) do disabledProfile[index] = value end
        end
        local function NotifyRulesChanged(revealIndex)
            NotifyWithoutRefresh(spec.moduleName)
            RebuildRuleMeta()
            if selected and not profileRules[selected.index] then selected = nil end
            if not selected and profileRules[1] then selected = { source = "profile", index = math.min(revealIndex or 1, #profileRules) } end
            if selected then
                ruleSelections[selectionKey] = { source = "profile", index = selected.index }
                Select("profile", selected.index)
            else
                ruleSelections[selectionKey] = nil
                detailTitle:SetText("No rule selected"); detailText:SetText("")
                detailSource:SetText("Add a rule to begin.")
            end
            ApplyRuleFilter(selected and selected.index)
        end
        local y = actionTop + 8

        -- Six equal columns create a predictable action grid. Primary editing
        -- lives on row one; sharing and deletion use the same columns below.
        local ACTION_WIDTH, ACTION_GAP = 105, 10
        local function ActionX(column) return 20 + (column - 1) * (ACTION_WIDTH + ACTION_GAP) end
        local addRuleButton = Button(parent, "+  Add Rule", ActionX(1), y - 8, ACTION_WIDTH, function()
            OpenRuleEditor(spec, nil, function(rule)
                table.insert(profileRules, rule)
                selected = { source = "profile", index = #profileRules }
                NotifyRulesChanged(#profileRules)
            end)
        end)
        EmphasizeButton(addRuleButton, BRAND)
        Button(parent, "Edit Rule", ActionX(2), y - 8, ACTION_WIDTH, function()
            if selected then
                local index = selected.index
                OpenRuleEditor(spec, profileRules[index], function(rule)
                    profileRules[index] = rule
                    NotifyRulesChanged(index)
                end)
            end
        end)
        Button(parent, "Duplicate", ActionX(3), y - 8, ACTION_WIDTH, function()
            if selected then
                local insertAt = selected.index + 1
                table.insert(profileRules, insertAt, Core.DeepCopy(profileRules[selected.index]))
                local shifted = {}
                for index, disabled in pairs(disabledProfile) do
                    if index < insertAt then shifted[index] = disabled
                    else shifted[index + 1] = disabled end
                end
                if disabledProfile[selected.index] then shifted[insertAt] = true end
                ReplaceDisabledTable(shifted)
                selected.index = insertAt
                NotifyRulesChanged(insertAt)
            end
        end)
        local deleteRuleButton = Button(parent, "Delete Rule", ActionX(3), y - 40, ACTION_WIDTH, function()
            if not selected then Core.Info("Settings", "Select a rule first."); return end
            local selectedIndex = selected.index
            local selectedRule = profileRules[selectedIndex]
            local selectedTitle = RuleTitle(selectedRule, selectedIndex)
            Confirm("Permanently delete rule '" .. selectedTitle .. "'?", function()
                -- Fail safely if the list changed while the confirmation was open.
                if profileRules[selectedIndex] ~= selectedRule then
                    Core.Warn("Settings", "The rule list changed; nothing was deleted.")
                    return
                end
                table.remove(profileRules, selectedIndex)
                selected = nil
                ruleSelections[selectionKey] = nil
                local shifted = {}
                for index, disabled in pairs(disabledProfile) do
                    if index < selectedIndex then shifted[index] = disabled
                    elseif index > selectedIndex then shifted[index - 1] = disabled end
                end
                ReplaceDisabledTable(shifted)
                NotifyRulesChanged(math.min(selectedIndex, #profileRules))
            end)
        end)
        EmphasizeButton(deleteRuleButton, CLOSE_RED)
        Button(parent, "Move Up", ActionX(4), y - 8, ACTION_WIDTH, function()
            if not selected then Core.Info("Settings", "Select a rule first."); return end
            if selected.index > 1 then
                local index = selected.index
                profileRules[index], profileRules[index - 1] = profileRules[index - 1], profileRules[index]
                disabledProfile[index], disabledProfile[index - 1] = disabledProfile[index - 1], disabledProfile[index]
                selected.index = index - 1
                ruleSelections[selectionKey] = { source = "profile", index = index - 1 }
                NotifyRulesChanged(index - 1)
            else Core.Info("Settings", "That rule is already first.") end
        end)
        Button(parent, "Move Down", ActionX(5), y - 8, ACTION_WIDTH, function()
            if not selected then Core.Info("Settings", "Select a rule first."); return end
            if selected.index < #profileRules then
                local index = selected.index
                profileRules[index], profileRules[index + 1] = profileRules[index + 1], profileRules[index]
                disabledProfile[index], disabledProfile[index + 1] = disabledProfile[index + 1], disabledProfile[index]
                selected.index = index + 1
                ruleSelections[selectionKey] = { source = "profile", index = index + 1 }
                NotifyRulesChanged(index + 1)
            else Core.Info("Settings", "That rule is already last.") end
        end)
        activityButton = Button(parent, "Deactivate", ActionX(6), y - 8, ACTION_WIDTH, function()
            if not selected then Core.Info("Settings", "Select a rule first."); return end
            local index = selected.index
            if disabledProfile[index] then disabledProfile[index] = nil
            else disabledProfile[index] = true end
            ruleSelections[selectionKey] = { source = "profile", index = index }
            NotifyRulesChanged(index)
        end)
        AddTooltip(activityButton, "Activate or deactivate", "Deactivated rules stay in the list and keep their position, but every module skips them during evaluation.")
        if selected and disabledProfile[selected.index] then activityButton:SetText("Activate") end

        -- Share one rule at a time on the aligned utility row.
        local exportRuleButton = Button(parent, "Export Rule", ActionX(1), y - 40, ACTION_WIDTH, function()
            if not selected then Core.Info("Settings", "Select a rule first."); return end
            local text = Core.Export(profileRules[selected.index])
            if not text then Core.Warn("Settings", "Could not export that rule."); return end
            OpenTextPopup({
                title = "Export Rule",
                subtitle = "Copy this text with Ctrl+C and send it over. The other person pastes it into Import Rule.",
                text = text,
            })
        end)
        AddTooltip(exportRuleButton, "Export this rule",
            "Opens a box with the selected rule as shareable text, already selected so Ctrl+C copies it.")

        local importRuleButton = Button(parent, "Import Rule", ActionX(2), y - 40, ACTION_WIDTH, function()
            OpenTextPopup({
                title = "Import Rule",
                subtitle = "Paste a rule someone shared, then press Import to add it to this list.",
                acceptLabel = "Import",
                onAccept = function(text)
                    local payload, err = Core.ParseImport(text)
                    if not payload then Core.Warn("Settings", err); return false end
                    if payload.kind ~= "rule" then
                        Core.Warn("Settings", "That text is a whole profile - import it from the Profiles page.")
                        return false
                    end
                    table.insert(profileRules, Core.DeepCopy(payload.data))
                    selected = { source = "profile", index = #profileRules }
                    NotifyRulesChanged(#profileRules)
                    Core.Info("Settings", "Rule added.")
                    return true
                end,
            })
        end)
        AddTooltip(importRuleButton, "Import a rule",
            "Opens a box to paste a shared rule. It is added to this list as a new rule; nothing already there changes.")
    end
end

pageBuilders["Junk Rules"] = RulePage({
    title = "AutoJunk Rules",
    moduleName = "junk", profileKey = "rules",
})

pageBuilders["Loot Rules"] = RulePage({
    title = "AutoLoot Rules - items to loot",
    moduleName = "loot", profileKey = "rules",
})

pageBuilders["Sell Rules"] = RulePage({
    title = "AutoSell Rules",
    moduleName = "sell", profileKey = "rules",
})
pageBuilders["Auction Rules"] = RulePage({
    title = "AutoAuction Rules",
    moduleName = "auction", profileKey = "rules",
})
pageBuilders["Roll Rules"] = RulePage({
    title = "AutoRoll Rules",
    moduleName = "roll", profileKey = "rules",
})

----------------------------------------------------------------------
-- Main frame and Blizzard Interface Options launcher
----------------------------------------------------------------------
local function CreateMainFrame()
    if frame and profileText and pageHost then return end
    if not frame then frame = CreateFrame("Frame", "AutoEverythingSettingsFrame", UIParent) end
    frame:SetSize(980, 720)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("HIGH")
    frame:SetMovable(true); frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetClampedToScreen(true)
    frame:SetScript("OnShow", function(self)
        -- Keep the full workspace visible on lower resolutions without making
        -- the authored layout depend on APIs introduced after Wrath.
        local screenWidth = UIParent:GetWidth() or 980
        local screenHeight = UIParent:GetHeight() or 720
        self:SetScale(math.min(1, (screenWidth - 24) / 980, (screenHeight - 24) / 720))
        Refresh(false)
    end)
    frame:SetScript("OnHide", CancelRuleEditors)
    -- UISpecialFrames provides Escape-to-close without capturing keyboard input.
    -- SetPropagateKeyboardInput is unavailable on older clients such as Ascension.
    if UISpecialFrames then
        local registered
        for _, name in ipairs(UISpecialFrames) do
            if name == "AutoEverythingSettingsFrame" then registered = true; break end
        end
        if not registered then table.insert(UISpecialFrames, "AutoEverythingSettingsFrame") end
    end
    Backdrop(frame)

    local brandIcon = frame:CreateTexture(nil, "ARTWORK")
    brandIcon:SetTexture("Interface\\AddOns\\AutoEverything\\Images\\AutoEverythingIcon.tga")
    brandIcon:SetSize(34, 34)
    brandIcon:SetPoint("TOPLEFT", 18, -12)

    titleText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleText:SetPoint("TOPLEFT", 62, -11)
    ApplyUIFont(titleText, 21)
    titleText:SetText("|cff" .. BRAND_HEX .. "Auto|r|cffe6edf3Everything|r")
    local subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", titleText, "BOTTOMLEFT", 1, -2)
    subtitle:SetText("AUTOMATION CONTROL CENTER")
    subtitle:SetTextColor(Unpack(TEXT_MUTED))
    ApplyUIFont(subtitle, 10)

    saveStatus = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    saveStatus:SetPoint("LEFT", titleText, "RIGHT", 12, 0)
    saveStatus:SetTextColor(0.30, 0.82, 0.52)
    ApplyUIFont(saveStatus, 11)
    saveStatus:Hide()
    -- The active profile is always visible and switchable from the header.
    -- This is intentionally a permanent control (not Track()ed): changing
    -- pages clears page controls, while the header must remain in place.
    profileText = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    profileText:SetSize(220, 26)
    profileText:SetPoint("TOPRIGHT", -42, -11)
    SkinButton(profileText)
    AddDropdownIndicator(profileText)
    profileText:SetScript("OnClick", function(self)
        local active = Core.GetProfileName()
        local entries = {}
        for _, profileName in ipairs(Core.GetProfileNames()) do
            local name = profileName
            table.insert(entries, {
                text = MenuLabel(name, name == active), notCheckable = true,
                func = function()
                    local ok, err = Core.SetProfile(name)
                    if not ok then Core.Warn("Settings", err) end
                end,
            })
        end
        table.insert(entries, {
            text = "|cff" .. BRAND_HEX .. "Manage profiles...|r", notCheckable = true,
            func = function() currentPage = "Profiles"; Refresh() end,
        })
        ShowMenu(self, entries)
    end)
    AddTooltip(profileText, "Active profile", "Switch profiles from any page, or open Profiles to create, copy, import, and manage them.")

    globalStatus = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    globalStatus:SetWidth(92)
    globalStatus:SetJustifyH("RIGHT")
    ApplyUIFont(globalStatus, 10)
    globalToggle = SkinnedButton(frame, "Pause all", 0, 0, 92, function()
        local moduleDefaults = {
            loot = AutoLootConfig, junk = AutoJunkConfig, sell = AutoSellConfig,
            auction = AutoAuctionConfig, roll = AutoRollConfig,
            quest = AutoQuestConfig, buff = AutoBuffConfig, upgrade = AutoUpgradeConfig,
        }
        local anyEnabled = false
        for moduleName, config in pairs(moduleDefaults) do
            if Core.GetSetting(moduleName, "enabled", config and config.enabled) ~= false then anyEnabled = true; break end
        end
        suppressRefresh = true
        for moduleName in pairs(moduleDefaults) do
            Core.GetProfileSection(moduleName, true).enabled = not anyEnabled
        end
        suppressRefresh = false
        Core.NotifyProfileChanged()
        MarkSaved()
    end, 26)
    globalToggle:ClearAllPoints()
    globalToggle:SetPoint("RIGHT", profileText, "LEFT", -10, 0)
    globalStatus:SetPoint("RIGHT", globalToggle, "LEFT", -10, 0)
    AddTooltip(globalToggle, "Global automation", "Pause or enable every automation module without changing their individual settings.")
    EmphasizeButton(globalToggle, BRAND)
    StyledCloseButton(frame, function() frame:Hide() end)

    -- Brand rule under the title bar, tying the window's accent to the title.
    local titleRule = frame:CreateTexture(nil, "ARTWORK")
    titleRule:SetTexture(WHITE_TEX)
    titleRule:SetPoint("TOPLEFT", 14, -55)
    titleRule:SetPoint("TOPRIGHT", -14, -55)
    titleRule:SetHeight(1)
    titleRule:SetGradientAlpha("HORIZONTAL", BRAND[1], BRAND[2], BRAND[3], 0.7, BRAND[1], BRAND[2], BRAND[3], 0.05)

    local nav = CreateFrame("Frame", nil, frame)
    nav:SetPoint("TOPLEFT", 14, -66); nav:SetPoint("BOTTOMLEFT", 14, 14); nav:SetWidth(180)
    UI.Backdrop(nav, COLORS.sidebar, 1)
    pageHost = CreateFrame("Frame", nil, frame)
    pageHost:SetPoint("TOPLEFT", nav, "TOPRIGHT", 12, 0)
    pageHost:SetPoint("BOTTOMRIGHT", -14, 14)
    pageHost:EnableMouse(true)
    pageHost:SetScript("OnMouseDown", function()
        if focusedEditBox then focusedEditBox:ClearFocus() end
        if openMenuButton then CloseOpenMenu() end
    end)
    UI.Backdrop(pageHost, COLORS.window, 0.99)

    -- Profiles is separated at the bottom from the normal configuration pages.
    --
    -- Nav items are plain text, not buttons: the selected page is marked by
    -- brand-blue text inside [ ] brackets, a soft blue wash, and a blue bar
    -- down the left edge. Nothing else in the sidebar carries a border, so
    -- the current page is the only thing competing for attention.
    local navModules = {
        ["Loot Rules"] = { "loot", AutoLootConfig }, ["Junk Rules"] = { "junk", AutoJunkConfig },
        ["Sell Rules"] = { "sell", AutoSellConfig }, ["Auction Rules"] = { "auction", AutoAuctionConfig },
        ["Roll Rules"] = { "roll", AutoRollConfig }, ["Quest"] = { "quest", AutoQuestConfig },
        ["Buff"] = { "buff", AutoBuffConfig },
        ["Upgrade"] = { "upgrade", AutoUpgradeConfig },
        ["Action Bars"] = { actionBars = true },
    }
    local function NavModuleEnabled(info)
        if info.actionBars then return AutoActionBars and AutoActionBars.IsEnabled and AutoActionBars.IsEnabled() end
        return Core.GetSetting(info[1], "enabled", info[2] and info[2].enabled) ~= false
    end
    local function SetNavModuleEnabled(info, enabled)
        if info.actionBars then
            if AutoActionBars and AutoActionBars.SetOption then AutoActionBars.SetOption("enabled", enabled) end
            MarkSaved()
        else
            SetSettingWithoutRefresh(info[1], "enabled", enabled)
        end
    end

    local function CreateNavButton(pageName, anchor, x, y, displayName)
        local button = CreateFrame("Button", nil, nav)
        button:SetSize(156, 26); button:SetPoint(anchor, x, y)

        local wash = button:CreateTexture(nil, "BACKGROUND")
        wash:SetTexture(WHITE_TEX)
        wash:SetAllPoints(button)
        wash:Hide()

        local accent = button:CreateTexture(nil, "ARTWORK")
        accent:SetTexture(WHITE_TEX)
        accent:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
        accent:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0)
        accent:SetWidth(2)
        accent:SetVertexColor(Unpack(BRAND))
        accent:Hide()

        local moduleInfo = navModules[pageName]
        local moduleToggle
        if moduleInfo then
            moduleToggle = CreateFrame("Button", nil, button)
            moduleToggle:SetSize(24, 12)
            moduleToggle:SetPoint("RIGHT", button, "RIGHT", -10, 0)
            if moduleToggle.SetHitRectInsets then moduleToggle:SetHitRectInsets(-5, -5, -7, -7) end
            moduleToggle:SetFrameLevel((button:GetFrameLevel() or 0) + 3)
            local toggleTrack = Capsule(moduleToggle, "ARTWORK", 12)
            toggleTrack:AnchorTo(moduleToggle)
            local toggleKnob = moduleToggle:CreateTexture(nil, "OVERLAY")
            toggleKnob:SetTexture(CIRCLE_TEX); toggleKnob:SetSize(8, 8)
            function moduleToggle:Paint(hovered)
                local enabled = NavModuleEnabled(moduleInfo)
                local color = enabled and TOGGLE_ON or TOGGLE_OFF
                local lift = hovered and 0.10 or 0
                toggleTrack:SetColor(color[1] + lift, color[2] + lift, color[3] + lift, 1)
                toggleKnob:ClearAllPoints()
                toggleKnob:SetPoint(enabled and "RIGHT" or "LEFT", self, enabled and "RIGHT" or "LEFT", enabled and -2 or 2, 0)
                toggleKnob:SetVertexColor(1, 1, 1, 1)
            end
            moduleToggle:SetScript("OnEnter", function(self) self:Paint(true) end)
            moduleToggle:SetScript("OnLeave", function(self) self:Paint(false) end)
            moduleToggle:SetScript("OnClick", function(self)
                local enabled = NavModuleEnabled(moduleInfo)
                SetNavModuleEnabled(moduleInfo, not enabled)
                self:Paint(true)
                UpdateGlobalAutomationStatus()
                if currentPage == "Overview" and overviewRefresh then overviewRefresh() end
            end)
            local toggleHelp = moduleInfo.actionBars
                and "Enable or pause automatic specialization action-bar saves and restores. Manual save and restore buttons remain available."
                or "Turn this module on or off without opening its settings page."
            AddTooltip(moduleToggle, "Enable " .. (displayName or pageName), toggleHelp)
            moduleToggle:Paint(false)
        end

        local label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        label:SetPoint("LEFT", button, "LEFT", 16, 0)
        label:SetPoint("RIGHT", button, "RIGHT", moduleInfo and -42 or -12, 0)
        label:SetText(displayName or pageName)
        label:SetJustifyH("LEFT")
        ApplyUIFont(label, 12)

        button.selected = false
        button.hovered = false
        function button:Paint()
            if moduleToggle then moduleToggle:Paint(false) end
            if self.selected then
                wash:SetVertexColor(Unpack(BRAND, 0.15)); wash:Show()
                accent:Show()
                label:SetTextColor(Unpack(BRAND))
            else
                -- Unselected entries stay white; hover is carried by the wash
                -- alone, so only the current page is ever tinted blue.
                accent:Hide()
                label:SetTextColor(Unpack(TEXT))
                if self.hovered then
                    wash:SetVertexColor(1, 1, 1, 0.06); wash:Show()
                else
                    wash:Hide()
                end
            end
        end
        button:SetScript("OnEnter", function(self) self.hovered = true; self:Paint() end)
        button:SetScript("OnLeave", function(self) self.hovered = false; self:Paint() end)
        button:SetScript("OnClick", function()
            CancelRuleEditors()
            currentPage = pageName
            Refresh()
        end)
        button:Paint()
        navButtons[pageName] = button
    end

    local function NavHeading(text, y)
        local heading = nav:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        heading:SetPoint("TOPLEFT", 14, y)
        heading:SetText(text)
        ApplyUIFont(heading, 11)
        heading:SetTextColor(Unpack(TEXT_MUTED))
        return y - 18
    end

    local y = -12
    CreateNavButton("Overview", "TOPLEFT", 12, y)
    y = y - 40

    y = NavHeading("AUTOMATION", y)
    for _, pageName in ipairs({ "General", "Convenience", "Groups & Queues" }) do
        CreateNavButton(pageName, "TOPLEFT", 12, y)
        y = y - 28
    end

    y = y - 8
    y = NavHeading("MODULES", y)
    local modulePages = {
        { "Loot Rules", "Auto Loot" }, { "Junk Rules", "Auto Junk" },
        { "Sell Rules", "Auto Sell" }, { "Auction Rules", "Auto Auction" },
        { "Roll Rules", "Auto Roll" }, { "Action Bars", "Action Bars" },
        { "Quest", "Auto Quest" }, { "Buff", "Auto Buff" }, { "Upgrade", "Auto Upgrade" },
    }
    for _, entry in ipairs(modulePages) do
        CreateNavButton(entry[1], "TOPLEFT", 12, y, entry[2])
        y = y - 28
    end

    CreateNavButton("Profiles", "BOTTOMLEFT", 12, 14)
end

function Settings.Open(page)
    if AutoAuction and AutoAuction.Hide then AutoAuction.Hide() end
    CreateMainFrame()
    if page == "Queues & PvP" then page = "Groups & Queues" end
    if page and pageBuilders[page] then
        if page ~= currentPage then CancelRuleEditors() end
        currentPage = page
    end
    frame:Show()
    Refresh()
end

function Settings.Toggle()
    CreateMainFrame()
    if frame:IsShown() then frame:Hide() else Settings.Open() end
end

local optionsPanel = CreateFrame("Frame", "AutoEverythingOptionsPanel")
optionsPanel.name = "Automation"
local optionsTitle = optionsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
optionsTitle:SetPoint("TOPLEFT", 16, -16); optionsTitle:SetText("Automation")
optionsTitle:SetTextColor(Unpack(BRAND))
local optionsDescription = optionsPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
optionsDescription:SetPoint("TOPLEFT", optionsTitle, "BOTTOMLEFT", 0, -16)
optionsDescription:SetWidth(560); optionsDescription:SetJustifyH("LEFT")
optionsDescription:SetText("This addon uses account-wide named profiles with per-character assignment. Open the full window to configure modules and structured sell/roll rules.")
local openButton = CreateFrame("Button", nil, optionsPanel, "UIPanelButtonTemplate")
openButton:SetSize(200, 28); openButton:SetPoint("TOPLEFT", optionsDescription, "BOTTOMLEFT", 0, -24)
openButton:SetText("Open Automation Settings")
openButton:SetScript("OnClick", function() Settings.Open() end)
SkinButton(openButton)
EmphasizeButton(openButton, BRAND)
if InterfaceOptions_AddCategory then InterfaceOptions_AddCategory(optionsPanel) end
