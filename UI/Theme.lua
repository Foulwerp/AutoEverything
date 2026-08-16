----------------------------------------------------------------------
-- UI/Theme.lua - shared visual language and low-level skinning helpers.
-- WoW 3.3.5a compatible; intentionally avoids modern mixins and APIs.
----------------------------------------------------------------------
AutoCore = AutoCore or {}
AutoCore.UI = AutoCore.UI or {}
local UI = AutoCore.UI

-- Codex-inspired neutral dark palette. Surfaces differ primarily by
-- luminance, while blue is reserved for selection, focus, and primary action.
UI.Colors = {
    brand =        { 0.345, 0.651, 1.000 }, -- #58a6ff
    brandDim =     { 0.122, 0.435, 0.922 }, -- #1f6feb
    text =         { 0.902, 0.929, 0.953 }, -- #e6edf3
    textMuted =    { 0.545, 0.580, 0.620 }, -- #8b949e
    toggleOn =     { 0.184, 0.506, 0.969 }, -- #2f81f7
    toggleOff =    { 0.267, 0.302, 0.345 }, -- #444d58
    danger =       { 0.973, 0.318, 0.286 }, -- #f85149
    border =       { 0.188, 0.212, 0.239 }, -- #30363d
    control =      { 0.129, 0.149, 0.176 }, -- #21262d
    selected =     { 0.090, 0.153, 0.243 }, -- blue-black selection wash
    track =        { 0.188, 0.212, 0.239 },
    window =       { 0.051, 0.067, 0.090 }, -- #0d1117
    sidebar =      { 0.063, 0.078, 0.102 },
    surface =      { 0.086, 0.106, 0.133 }, -- #161b22
    surfaceRaised = { 0.122, 0.149, 0.188 },
    success =      { 0.247, 0.725, 0.314 },
}

UI.Textures = {
    white = "Interface\\Buttons\\WHITE8X8",
    circle = "Interface\\TALENTFRAME\\talentsmasknodecircle",
}

-- This font is optional in development builds. ApplyFont restores the font
-- object it inherited when the bundled asset is unavailable rather than
-- leaving text blank on clients that reject a missing font path.
UI.Font = "Interface\\AddOns\\AutoEverything\\Fonts\\PTSansNarrow.ttf"

function UI.Unpack(color, alpha)
    return color[1], color[2], color[3], alpha or 1
end

function UI.ApplyFont(fontString, size)
    if not fontString or not fontString.GetFont or not fontString.SetFont then return end
    local original, currentSize, flags = fontString:GetFont()
    local wantedSize = size or currentSize or 12
    local applied = fontString:SetFont(UI.Font, wantedSize, flags or "")
    if not applied and original then fontString:SetFont(original, wantedSize, flags or "") end
end

function UI.StripTemplateArt(frame)
    for _, name in ipairs({ "Normal", "Pushed", "Disabled", "Highlight" }) do
        local setter = frame["Set" .. name .. "Texture"]
        if setter then setter(frame, "") end
        local getter = frame["Get" .. name .. "Texture"]
        if getter then
            local texture = getter(frame)
            if texture then texture:SetTexture(nil); texture:SetAlpha(0) end
        end
    end
end

function UI.Backdrop(object, color, alpha)
    local fill = color or UI.Colors.window
    object:SetBackdrop({
        bgFile = UI.Textures.white,
        edgeFile = UI.Textures.white,
        edgeSize = 1,
    })
    object:SetBackdropColor(fill[1], fill[2], fill[3], alpha or fill[4] or 0.98)
    object:SetBackdropBorderColor(UI.Unpack(UI.Colors.border))
end

-- Shared compact vertical scrollbar: a thin neutral line with a draggable
-- rounded blue pill. It intentionally has no arrow buttons and does not use a
-- Blizzard scrollbar template, so every addon surface behaves consistently.
function UI.CreateVerticalScrollbar(parent, height, onValueChanged, step)
    local scrollbar = CreateFrame("Frame", nil, parent)
    scrollbar:SetSize(16, height or 100)
    scrollbar:EnableMouse(true)
    scrollbar:EnableMouseWheel(true)
    scrollbar.scrollMaximum = 0
    scrollbar.scrollValue = 0
    scrollbar.scrollStep = math.max(1, step or 1)

    local trackWidth = 4
    local trackCapHeight = trackWidth / 2
    local trackTop = scrollbar:CreateTexture(nil, "BACKGROUND")
    trackTop:SetTexture(UI.Textures.circle)
    trackTop:SetTexCoord(0, 1, 0, 0.5)
    trackTop:SetSize(trackWidth, trackCapHeight)
    trackTop:SetPoint("TOP", scrollbar, "TOP", 0, 0)
    trackTop:SetVertexColor(UI.Unpack(UI.Colors.track, 0.9))

    local trackBottom = scrollbar:CreateTexture(nil, "BACKGROUND")
    trackBottom:SetTexture(UI.Textures.circle)
    trackBottom:SetTexCoord(0, 1, 0.5, 1)
    trackBottom:SetSize(trackWidth, trackCapHeight)
    trackBottom:SetPoint("BOTTOM", scrollbar, "BOTTOM", 0, 0)
    trackBottom:SetVertexColor(UI.Unpack(UI.Colors.track, 0.9))

    local trackCenter = scrollbar:CreateTexture(nil, "BACKGROUND")
    trackCenter:SetTexture(UI.Textures.white)
    trackCenter:SetPoint("TOPLEFT", trackTop, "BOTTOMLEFT", 0, 0)
    trackCenter:SetPoint("BOTTOMRIGHT", trackBottom, "TOPRIGHT", 0, 0)
    trackCenter:SetVertexColor(UI.Unpack(UI.Colors.track, 0.9))

    local pillWidth, pillHeight = 12, 26
    local capHeight = pillWidth / 2
    local handle = CreateFrame("Button", nil, scrollbar)
    handle:SetSize(20, pillHeight + 6)
    handle:SetFrameLevel(scrollbar:GetFrameLevel() + 2)
    handle:EnableMouse(true)
    handle:EnableMouseWheel(true)

    local topCap = handle:CreateTexture(nil, "OVERLAY")
    topCap:SetTexture(UI.Textures.circle)
    topCap:SetTexCoord(0, 1, 0, 0.5)
    topCap:SetSize(pillWidth, capHeight)
    topCap:SetPoint("TOP", handle, "TOP", 0, -3)
    topCap:SetVertexColor(UI.Unpack(UI.Colors.brand, 0.95))

    local bottomCap = handle:CreateTexture(nil, "OVERLAY")
    bottomCap:SetTexture(UI.Textures.circle)
    bottomCap:SetTexCoord(0, 1, 0.5, 1)
    bottomCap:SetSize(pillWidth, capHeight)
    bottomCap:SetPoint("BOTTOM", handle, "BOTTOM", 0, 3)
    bottomCap:SetVertexColor(UI.Unpack(UI.Colors.brand, 0.95))

    local center = handle:CreateTexture(nil, "OVERLAY")
    center:SetTexture(UI.Textures.white)
    center:SetPoint("TOPLEFT", topCap, "BOTTOMLEFT", 0, 0)
    center:SetPoint("BOTTOMRIGHT", bottomCap, "TOPRIGHT", 0, 0)
    center:SetVertexColor(UI.Unpack(UI.Colors.brand, 0.95))

    local function PositionHandle()
        local travel = math.max(0, (scrollbar:GetHeight() or pillHeight) - pillHeight)
        local ratio = scrollbar.scrollMaximum > 0
            and scrollbar.scrollValue / scrollbar.scrollMaximum or 0
        handle:ClearAllPoints()
        handle:SetPoint("TOP", scrollbar, "TOP", 0, 3 - ratio * travel)
    end
    local function SetValue(value)
        local nextValue = math.max(0, math.min(value or 0, scrollbar.scrollMaximum))
        local changed = nextValue ~= scrollbar.scrollValue
        scrollbar.scrollValue = nextValue
        PositionHandle()
        if changed and onValueChanged then onValueChanged(nextValue) end
    end
    local function CursorY()
        local _, cursorY = GetCursorPosition()
        local scale = scrollbar:GetEffectiveScale() or 1
        if scale <= 0 then scale = 1 end
        return cursorY / scale
    end
    local function ValueFromCursor(offsetY)
        local frameTop, frameBottom = scrollbar:GetTop(), scrollbar:GetBottom()
        if not frameTop or not frameBottom then return end
        local travelTop = frameTop - pillHeight / 2
        local travelBottom = frameBottom + pillHeight / 2
        if travelTop <= travelBottom then return end
        local wantedY = CursorY() - (offsetY or 0)
        local ratio = math.max(0, math.min((travelTop - wantedY) / (travelTop - travelBottom), 1))
        SetValue(ratio * scrollbar.scrollMaximum)
    end
    local function StopDrag(self) self:SetScript("OnUpdate", nil) end
    local dragOffsetY = 0
    handle:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        local _, handleY = self:GetCenter()
        dragOffsetY = CursorY() - (handleY or CursorY())
        self:SetScript("OnUpdate", function() ValueFromCursor(dragOffsetY) end)
    end)
    handle:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" then StopDrag(self) end
    end)
    handle:SetScript("OnHide", StopDrag)
    handle:SetScript("OnMouseWheel", function(_, delta)
        SetValue(scrollbar.scrollValue - delta * scrollbar.scrollStep)
    end)
    scrollbar:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then ValueFromCursor(0) end
    end)
    scrollbar:SetScript("OnMouseWheel", function(_, delta)
        SetValue(scrollbar.scrollValue - delta * scrollbar.scrollStep)
    end)
    scrollbar:SetScript("OnSizeChanged", PositionHandle)

    function scrollbar:GetValue() return self.scrollValue end
    function scrollbar:SetValue(value) SetValue(value) end
    function scrollbar:SetScrollRange(maximum, value)
        self.scrollMaximum = math.max(0, maximum or 0)
        SetValue(value or self.scrollValue or 0)
        if self.scrollMaximum > 0 then self:Show() else self:Hide() end
    end
    function scrollbar:SetScrollValue(value)
        SetValue(value)
    end
    function scrollbar:BindMouseWheel(control, wheelStep)
        if not control then return end
        control:EnableMouse(true)
        control:EnableMouseWheel(true)
        control:SetScript("OnMouseWheel", function(_, delta)
            SetValue(self.scrollValue - delta * (wheelStep or self.scrollStep))
        end)
    end

    scrollbar.dragHandle = handle
    scrollbar:SetScrollRange(0, 0)
    return scrollbar
end
