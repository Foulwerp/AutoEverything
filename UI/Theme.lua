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
