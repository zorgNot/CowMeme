local ADDON_NAME, ns = ...

ns.options = {}
local options = ns.options

-- Canvas frame shown inside the game's AddOns options list
local panel = CreateFrame("Frame", "CowMemeOptionsPanel")
panel.name = "CowMeme"

-- All checkboxes, refreshed on show, after any click, and after resets.
-- A checkbox with a depends() that returns false is greyed out: the setting
-- is preserved but currently has no effect.
local checkboxes = {}
local checkCount = 0
local extraRefreshers = {} -- non-checkbox widgets (sliders, ...) register here

local function RefreshAll()
    for _, cb in ipairs(checkboxes) do
        cb:SetChecked(cb.get())
        if not cb.depends or cb.depends() then
            cb:Enable()
            cb.labelFS:SetFontObject(GameFontHighlight)
        else
            cb:Disable()
            cb.labelFS:SetFontObject(GameFontDisable)
        end
    end
    for _, refresh in ipairs(extraRefreshers) do
        refresh()
    end
end

panel:SetScript("OnShow", RefreshAll)

local function AddTooltip(widget, title, text)
    widget:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(title, 1, 1, 1)
        GameTooltip:AddLine(text, nil, nil, nil, true)
        GameTooltip:Show()
    end)
    widget:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
end

-- Vertical layout cursor
local y = -16

local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 16, y)
title:SetText("CowMeme")
y = y - 24

local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
subtitle:SetPoint("TOPLEFT", 16, y)
subtitle:SetText("Changes apply immediately.")
y = y - 28

local function AddHeader(text)
    local h = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    h:SetPoint("TOPLEFT", 16, y)
    h:SetText(text)
    y = y - 22
end

local function AddCheckbox(label, tooltip, get, set, depends)
    checkCount = checkCount + 1
    local cb = CreateFrame("CheckButton", "CowMemeOptionsCheck" .. checkCount, panel, "UICheckButtonTemplate")
    cb:SetSize(26, 26)
    cb:SetPoint("TOPLEFT", 24, y)
    cb.labelFS = _G[cb:GetName() .. "Text"]
    cb.labelFS:SetFontObject(GameFontHighlight)
    cb.labelFS:SetText(label)
    cb.get = get
    cb.depends = depends
    cb:SetScript("OnClick", function(self)
        set(self:GetChecked() and true or false)
        RefreshAll() -- dependents may need to grey/ungrey
    end)
    AddTooltip(cb, label, tooltip)
    table.insert(checkboxes, cb)
    y = y - 28
    return cb
end

-- Dependency predicates for greying
local function AddonEnabled() return ns.db.enabled end
local function DebugOn() return ns.db.debug end
local function PanelVisible() return ns.db.enabled and ns.db.panel.shown end

-- ===== General =====
AddHeader("General")

AddCheckbox("Enable CowMeme",
    "Master switch. When off, death tracking, the gamba monitor, the sync heartbeat, the panel, and all automated announcements are suspended. Slash commands still work.",
    function() return ns.db.enabled end,
    function(v)
        ns.db.enabled = v
        ns.ApplyAllStates()
    end)

local soundCB = AddCheckbox("Play sound effects",
    "Master toggle for CowMeme's sound effects (e.g. the First Blood sound when the first death of a Fast and Clean run is recorded). Heard even if game sound effects are muted.",
    function() return ns.db.sound end,
    function(v) ns.db.sound = v end,
    AddonEnabled)

-- Volume slider, on the same row as the sound checkbox. Releasing the handle
-- plays a test clip at the new volume.
local volumeSlider = CreateFrame("Slider", "CowMemeOptionsVolumeSlider", panel, "OptionsSliderTemplate")
volumeSlider:SetPoint("LEFT", soundCB.labelFS, "RIGHT", 30, 0)
volumeSlider:SetSize(140, 16)
volumeSlider:SetMinMaxValues(0, 1)
volumeSlider:SetValueStep(0.05)
volumeSlider:SetObeyStepOnDrag(true)
_G[volumeSlider:GetName() .. "Low"]:SetText("0%")
_G[volumeSlider:GetName() .. "High"]:SetText("100%")
local volumeLabel = _G[volumeSlider:GetName() .. "Text"]
volumeSlider:SetScript("OnValueChanged", function(self, value)
    -- Slider values are step-snapped 32-bit floats: "100%" can arrive as
    -- 0.99999994, which would silently fail ns.PlaySound's full-volume check
    -- and reroute sounds to the Dialog channel. Round to the displayed value.
    value = math.floor(value * 100 + 0.5) / 100
    ns.db.soundVolume = value
    volumeLabel:SetText(string.format("Volume: %.0f%%", value * 100))
end)
volumeSlider:SetScript("OnMouseUp", function()
    ns.PlaySound("cm_firstblood.ogg") -- instant feedback at the new volume
end)
AddTooltip(volumeSlider, "Sound volume",
    "Volume for CowMeme's sound effects. At 100% clips play on the Master channel; below that they play through the rarely-used Dialog channel at this volume. 0% silences them. Release the handle to hear a test clip.")
table.insert(extraRefreshers, function()
    volumeSlider:SetValue(ns.db.soundVolume or 1)
    if ns.db.enabled and ns.db.sound then
        volumeSlider:Enable()
        volumeLabel:SetFontObject(GameFontHighlightSmall)
    else
        volumeSlider:Disable()
        volumeLabel:SetFontObject(GameFontDisableSmall)
    end
end)

-- ===== Fast and Clean =====
AddHeader("Fast and Clean")

AddCheckbox("Batch milestone announcements",
    "Collect deaths that hit the same milestone within 1.5 seconds and announce them together (e.g. \"A and B ARE ON A DYING SPREE!\"). Always on while in a raid, regardless of this setting.",
    function() return ns.db.fnc.batch end,
    function(v) ns.db.fnc.batch = v end,
    AddonEnabled)

AddCheckbox("Allow group FnC reset",
    "Let your group's leader or assist (or the addon's priority characters) start a fresh Fast and Clean run for everyone at once with /fnc reset group, so death counts stay aligned. You always get a chat message naming who reset you.",
    function() return ns.db.fnc.allowGroupReset end,
    function(v) ns.db.fnc.allowGroupReset = v end,
    AddonEnabled)

-- ===== CopyPasta =====
AddHeader("CopyPasta")

AddCheckbox("Announce gamba pastas to chat",
    "Be willing to announce a registered loser's copypasta when a CrossGambling game ends. One elected announcer among willing clients actually speaks, so this causes no double-posting. Panel display is unaffected by this setting.",
    function() return ns.db.copypasta.gambaMonitor end,
    function(v) ns.copypasta.SetAnnouncing(v) end,
    AddonEnabled)

-- ===== Panel =====
AddHeader("Panel")

AddCheckbox("Show panel",
    "Show the CowMeme on-screen panel (gamba rolls, the host's owes line, pasta cards). While hidden, incoming content is dropped.",
    function() return ns.db.panel.shown end,
    function(v) ns.panel.SetShown(v) end,
    AddonEnabled)

AddCheckbox("Lock panel position",
    "Prevent the panel from being dragged. Unlock to move it; its position is saved between sessions. Only applies while the panel is shown.",
    function() return ns.db.panel.locked end,
    function(v) ns.panel.SetLocked(v) end,
    PanelVisible)

-- ===== Debug (always last) =====
AddHeader("Debug")

AddCheckbox("Debug mode",
    "Master debug switch: enables decision tracing and the sim commands (/fnc simdeath, /cp simdemo, ...). See /cm debug for the full menu.",
    function() return ns.db.debug end,
    function(v) ns.db.debug = v end)

AddCheckbox("Sandbox mode",
    "Print would-be chat announcements locally instead of sending them. Only takes effect while debug mode is on.",
    function() return ns.db.debugSandbox end,
    function(v) ns.db.debugSandbox = v end,
    DebugOn)

AddCheckbox("Verbose tracing",
    "Extra-noisy tracing: per-damage-event logging and the heartbeat leader announce. Only takes effect while debug mode is on.",
    function() return ns.db.debugVerbose end,
    function(v) ns.db.debugVerbose = v end,
    DebugOn)

AddCheckbox("FnC tracing",
    "Show Fast and Clean decision tracing (ignored deaths, cause lookups, batching) while debug mode is on.",
    function() return ns.db.debugFnc end,
    function(v) ns.db.debugFnc = v end,
    DebugOn)

AddCheckbox("CopyPasta tracing",
    "Show CopyPasta decision tracing (gamba matches, roll tracking, announce decisions) while debug mode is on.",
    function() return ns.db.debugCp end,
    function(v) ns.db.debugCp = v end,
    DebugOn)

-- ===== Danger zone buttons =====
y = y - 10

-- Reset settings to defaults, preserving run state (death counts, panel position)
local function ResetToDefaults()
    ns.db.enabled      = ns.defaults.enabled
    ns.db.sound        = ns.defaults.sound
    ns.db.soundVolume  = ns.defaults.soundVolume
    ns.db.debug        = ns.defaults.debug
    ns.db.debugSandbox = ns.defaults.debugSandbox
    ns.db.debugVerbose = ns.defaults.debugVerbose
    ns.db.debugFnc     = ns.defaults.debugFnc
    ns.db.debugCp      = ns.defaults.debugCp
    ns.db.fnc.batch    = ns.defaults.fnc.batch
    ns.db.fnc.allowGroupReset = ns.defaults.fnc.allowGroupReset
    ns.db.copypasta.gambaMonitor = ns.defaults.copypasta.gambaMonitor
    ns.db.panel.shown  = ns.defaults.panel.shown
    ns.db.panel.locked = ns.defaults.panel.locked
    ns.db.panel.size   = ns.defaults.panel.size
    ns.ApplyAllStates()
    ns.sync.Ping() -- willingness flags may have changed
    RefreshAll()
    ns.Print("Settings reset to defaults.")
end

StaticPopupDialogs["COWMEME_CONFIRM_DEFAULTS"] = {
    text = "Reset all CowMeme settings to their defaults?\n\nDeath counts and the panel position are kept.",
    button1 = "Reset",
    button2 = CANCEL,
    OnAccept = ResetToDefaults,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["COWMEME_CONFIRM_CLEAR"] = {
    text = "Delete ALL CowMeme saved data?\n\nThis permanently clears every setting, death count, and the panel position, then reloads the UI.",
    button1 = "Delete and Reload",
    button2 = CANCEL,
    OnAccept = function()
        CowMemeDB = nil
        ReloadUI()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local defaultsBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
defaultsBtn:SetSize(150, 22)
defaultsBtn:SetPoint("TOPLEFT", 24, y)
defaultsBtn:SetText("Default Settings")
defaultsBtn:SetScript("OnClick", function()
    StaticPopup_Show("COWMEME_CONFIRM_DEFAULTS")
end)
AddTooltip(defaultsBtn, "Default Settings",
    "Reset all settings above to their default values. Death counts and the panel position are kept. Asks for confirmation.")

local clearBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
clearBtn:SetSize(150, 22)
clearBtn:SetPoint("LEFT", defaultsBtn, "RIGHT", 10, 0)
clearBtn:SetText("Clear All Addon Data")
clearBtn:SetScript("OnClick", function()
    StaticPopup_Show("COWMEME_CONFIRM_CLEAR")
end)
AddTooltip(clearBtn, "Clear All Addon Data",
    "Permanently delete everything CowMeme has saved (settings, death counts, panel position) and reload the UI. Asks for confirmation.")

-- Open the options panel (used by /cm options)
function options.Open()
    if Settings and Settings.OpenToCategory and options.category then
        Settings.OpenToCategory(options.category:GetID())
    elseif InterfaceOptionsFrame_OpenToCategory then
        -- Legacy API: call twice to work around a Blizzard focus bug
        InterfaceOptionsFrame_OpenToCategory(panel)
        InterfaceOptionsFrame_OpenToCategory(panel)
    else
        ns.Print("Options panel unavailable on this client.")
    end
end

-- Called from OnLoad. Registers with the modern Settings API when available,
-- falling back to the legacy Interface Options API.
function options.Init()
    if Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
        Settings.RegisterAddOnCategory(category)
        options.category = category
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end
