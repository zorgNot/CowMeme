local ADDON_NAME, ns = ...

ns.panel = {}
local panel = ns.panel

-- Default panel settings
ns.defaults.panel = {
    shown  = true,
    locked = false, -- unlocked (movable) by default
    size   = "small", -- small | medium (right-click the panel)
    point  = { "CENTER", 0, 200 }, -- anchor point, x, y on UIParent
}

-- Size presets. Dimensions hug the image: width = image + side margins,
-- height = content top (two-line header) + image + a text line + footer. font
-- is the content text font (small uses a smaller face to fit the tighter panel).
local SIZES = {
    small  = { image = 64,  width = 150, height = 154, font = "GameFontHighlightSmall" },
    medium = { image = 128, width = 164, height = 218, font = "GameFontHighlight" },
    -- large  = { image = 256, width = 292, height = 346, font = "GameFontHighlight" },
}
local SIZE_ORDER = { "small", "medium" }

local HEADER_Y = -20    -- reserved persistent header, below the title
local CONTENT_TOP = -48 -- image/text start below the two-line header region

local function CurrentSize()
    local name = ns.db and ns.db.panel and ns.db.panel.size
    return SIZES[name] or SIZES.small
end

local frame = CreateFrame("Frame", "CowMemePanel", UIParent, "BackdropTemplate")
frame:SetSize(SIZES.small.width, SIZES.small.height)
frame:SetBackdrop({
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
})
frame:SetBackdropColor(0, 0, 0, 0.7)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetClampedToScreen(true)
frame:Hide()

local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
title:SetPoint("TOP", 0, -5)
title:SetText("|cff00ff00CowMeme|r")

-- Reserved persistent header at the top (below the title). Managed separately
-- from Display content, so roll updates and pasta cards don't disturb it.
-- Wraps to two lines so a long gamba "owes" result isn't truncated; the
-- content region below reserves space for both lines.
local header = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
header:SetPoint("TOPLEFT", 5, HEADER_Y)
header:SetPoint("TOPRIGHT", -5, HEADER_Y)
header:SetJustifyH("CENTER")
header:SetWordWrap(true)
if header.SetMaxLines then header:SetMaxLines(2) end -- cap so it can't push into content

local image = frame:CreateTexture(nil, "ARTWORK")
image:SetSize(SIZES.small.image, SIZES.small.image)
image:SetPoint("TOP", 0, CONTENT_TOP)
image:Hide()

local text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
text:SetJustifyH("CENTER")
text:SetJustifyV("TOP") -- anchor content to the top line so the eye stays put

-- Smaller line pinned to the bottom, for secondary/flavor text
local footer = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
footer:SetPoint("BOTTOMLEFT", 4, 3)
footer:SetPoint("BOTTOMRIGHT", -4, 3)
footer:SetJustifyH("CENTER")

-- Anchor the content region below the header (and below the image when one is
-- shown); the bottom always leaves room for the footer. Stateful so a size
-- change can re-layout whatever is currently displayed.
local hasImage = false
local function LayoutText()
    local s = CurrentSize()
    text:ClearAllPoints()
    text:SetPoint("TOPLEFT", 5, hasImage and (CONTENT_TOP - s.image - 2) or CONTENT_TOP)
    text:SetPoint("BOTTOMRIGHT", -5, 16)
end
LayoutText()

frame:SetScript("OnDragStart", function(self)
    if not ns.db.panel.locked then
        self:StartMoving()
    end
end)

frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, _, x, y = self:GetPoint(1)
    ns.db.panel.point = { point, x, y }
end)

-- Right-click menu: size presets and close
local menuFrame = CreateFrame("Frame", "CowMemePanelMenu", UIParent, "UIDropDownMenuTemplate")

local function InitMenu(self, level)
    local info = UIDropDownMenu_CreateInfo()
    info.text = "CowMeme Panel"
    info.isTitle = true
    info.notCheckable = true
    UIDropDownMenu_AddButton(info, level)

    for _, name in ipairs(SIZE_ORDER) do
        info = UIDropDownMenu_CreateInfo()
        info.text = name:gsub("^%l", string.upper)
        info.checked = (ns.db.panel.size or "small") == name
        info.func = function()
            panel.SetSize(name)
        end
        UIDropDownMenu_AddButton(info, level)
    end

    info = UIDropDownMenu_CreateInfo()
    info.text = "Close panel"
    info.notCheckable = true
    info.func = function()
        panel.SetShown(false)
        ns.Print("Panel closed. |cffffff00/cm panel show|r brings it back.")
    end
    UIDropDownMenu_AddButton(info, level)
end

frame:SetScript("OnMouseUp", function(self, button)
    if button == "RightButton" then
        UIDropDownMenu_Initialize(menuFrame, InitMenu, "MENU")
        ToggleDropDownMenu(1, nil, menuFrame, "cursor", 3, -3)
    end
end)

-- Optional action button hanging just below the panel. Generic: other modules
-- wire its behavior via SetNudgeHandler and toggle it via SetNudge. Parented
-- to the panel, so it moves, hides, and disables along with it.
local nudgeButton = CreateFrame("Button", "CowMemeNudgeButton", frame, "UIPanelButtonTemplate")
nudgeButton:SetHeight(20)
nudgeButton:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 0, -2)
nudgeButton:SetPoint("TOPRIGHT", frame, "BOTTOMRIGHT", 0, -2)
nudgeButton:SetText("Nudge a roller")
nudgeButton:Hide()

local nudgeCount = 0 -- last count passed to SetNudge, remembered for ApplyState

function panel.SetNudgeHandler(fn)
    nudgeButton:SetScript("OnClick", function() fn() end)
end

-- Show/hide the nudge button and label it with how many are still pending.
-- count: 0/nil hides it; a positive number shows "Nudge a roller (#)".
-- Actual visibility also requires the panel to be enabled and shown.
-- Remembered so ApplyState can re-evaluate on enable/disable.
function panel.SetNudge(count)
    nudgeCount = count or 0
    local wanted = nudgeCount > 0
    if wanted then
        nudgeButton:SetText("Nudge a roller (" .. nudgeCount .. ")")
    end
    if wanted and ns.db.enabled and ns.db.panel.shown then
        nudgeButton:Show()
    else
        nudgeButton:Hide()
    end
end

-- Grey out (or restore) the button, e.g. while a caller-owned throttle is
-- active. Independent of Show/Hide -- WoW buttons keep their enabled state
-- across visibility changes, so this survives the button hiding/reappearing.
function panel.SetNudgeEnabled(enabled)
    if enabled then
        nudgeButton:Enable()
    else
        nudgeButton:Disable()
    end
end

local clearTimer
local footerTimer

-- Pixel-art overlay. Block-element text glyphs don't render in the game font,
-- so art is drawn as a grid of small square textures in the content region.
-- Cells are pooled and reused across calls.
local artTextures = {}
local function HideArt()
    for _, tex in ipairs(artTextures) do tex:Hide() end
end

-- Draw pixel art in the content region. rows is a list of equal-length strings;
-- any character other than " " or "." is a filled pixel. Cells are sized to fit
-- and centered. opts.duration auto-clears (via panel.Clear) like Display.
function panel.ShowArt(rows, opts)
    if not (ns.db.enabled and ns.db.panel.shown) then return end
    opts = opts or {}
    -- Art owns the whole content region: drop any text/image first.
    image:Hide()
    hasImage = false
    text:SetText("")
    footer:SetText("")

    local nRows = #rows
    local nCols = 0
    for _, line in ipairs(rows) do nCols = math.max(nCols, #line) end
    HideArt()
    if nRows == 0 or nCols == 0 then return end

    -- Content box: matches the text insets (5px sides, CONTENT_TOP down to 16px
    -- above the bottom). Square cells, sized to fit, centered in the box.
    local cw = frame:GetWidth() - 10
    local ch = frame:GetHeight() + CONTENT_TOP - 16
    local cell = math.floor(math.min(cw / nCols, ch / nRows))
    if cell < 1 then cell = 1 end
    local x0 = 5 + (cw - cell * nCols) / 2
    local y0 = CONTENT_TOP - (ch - cell * nRows) / 2

    local n = 0
    for r = 1, nRows do
        local line = rows[r]
        for c = 1, #line do
            local ch_ = line:sub(c, c)
            if ch_ ~= " " and ch_ ~= "." then
                n = n + 1
                local tex = artTextures[n]
                if not tex then
                    tex = frame:CreateTexture(nil, "ARTWORK")
                    artTextures[n] = tex
                end
                tex:SetColorTexture(0.92, 0.92, 0.85, 1) -- bone white
                tex:SetSize(cell, cell)
                tex:ClearAllPoints()
                tex:SetPoint("TOPLEFT", frame, "TOPLEFT",
                    x0 + (c - 1) * cell, y0 - (r - 1) * cell)
                tex:Show()
            end
        end
    end

    frame:Show()
    if clearTimer then clearTimer:Cancel(); clearTimer = nil end
    if opts.duration then
        clearTimer = C_Timer.NewTimer(opts.duration, function()
            clearTimer = nil
            panel.Clear()
        end)
    end
end

-- Show content on the panel. opts:
--   text           - string to display
--   image          - texture path (e.g. "Interface\\AddOns\\CowMeme\\images\\image")
--   footer         - smaller secondary line pinned to the bottom
--   footerDuration - seconds until the footer alone clears (omit to persist)
--   duration       - seconds until all content auto-clears (omit to persist)
-- Respects the panel's shown setting: content is dropped while hidden.
function panel.Display(opts)
    if not (ns.db.enabled and ns.db.panel.shown) then return end
    opts = opts or {}
    HideArt() -- normal content replaces any pixel art
    hasImage = opts.image and true or false
    if opts.image then
        image:SetTexture(opts.image)
        image:Show()
    else
        image:Hide()
    end
    LayoutText()
    text:SetText(opts.text or "")
    footer:SetText(opts.footer or "")
    if footerTimer then
        footerTimer:Cancel()
        footerTimer = nil
    end
    if opts.footer and opts.footerDuration then
        footerTimer = C_Timer.NewTimer(opts.footerDuration, function()
            footerTimer = nil
            footer:SetText("")
        end)
    end
    frame:Show()
    if clearTimer then
        clearTimer:Cancel()
        clearTimer = nil
    end
    if opts.duration then
        clearTimer = C_Timer.NewTimer(opts.duration, function()
            clearTimer = nil
            panel.Clear()
        end)
    end
end

-- Clear content, keeping the panel itself (and the header) where it is
function panel.Clear()
    text:SetText("")
    footer:SetText("")
    if footerTimer then
        footerTimer:Cancel()
        footerTimer = nil
    end
    image:Hide()
    hasImage = false
    HideArt()
    LayoutText()
end

-- Apply the configured size preset to the frame, image, and text layout
function panel.ApplySize()
    local s = CurrentSize()
    frame:SetSize(s.width, s.height)
    image:SetSize(s.image, s.image)
    text:SetFontObject(_G[s.font] or GameFontHighlight)
    LayoutText()
end

function panel.SetSize(name)
    if not SIZES[name] then return end
    ns.db.panel.size = name
    panel.ApplySize()
end

-- Set (or clear, with nil/"") the reserved top line. It persists independently
-- of Display content; duration is seconds until it auto-clears (omit to keep).
local headerTimer
function panel.SetHeader(msg, duration)
    if not (ns.db.enabled and ns.db.panel.shown) then return end
    header:SetText(msg or "")
    if headerTimer then
        headerTimer:Cancel()
        headerTimer = nil
    end
    if msg and msg ~= "" then
        frame:Show()
        if duration then
            headerTimer = C_Timer.NewTimer(duration, function()
                headerTimer = nil
                header:SetText("")
            end)
        end
    end
end

-- The panel is visible only while the addon is enabled AND the user wants it
-- shown. Disabling the addon hides the frame without touching the preference.
function panel.ApplyState()
    panel.ApplySize()
    if ns.db.enabled and ns.db.panel.shown then
        frame:Show()
    else
        frame:Hide()
    end
    panel.SetNudge(nudgeCount) -- re-evaluate button visibility for the new state
end

function panel.SetShown(shown)
    ns.db.panel.shown = shown
    panel.ApplyState()
    if shown and not ns.db.enabled then
        ns.Print("Panel will appear when the addon is enabled (/cm enable).")
    end
end

function panel.SetLocked(locked)
    ns.db.panel.locked = locked
end

-- Restore the saved position
function panel.ApplyPosition()
    local p = ns.db.panel.point
    frame:ClearAllPoints()
    frame:SetPoint(p[1] or "CENTER", UIParent, p[1] or "CENTER", p[2] or 0, p[3] or 0)
end

function panel.ResetPosition()
    ns.db.panel.point = { "CENTER", 0, 200 }
    panel.ApplyPosition()
end

-- One-line status summary, pulled into the /cm main menu
function panel.PrintStatus()
    local shown  = ns.db.panel.shown  and "|cff00ff00ON|r" or "|cffff0000OFF|r"
    local locked = ns.db.panel.locked and "|cff00ff00ON|r" or "|cffff0000OFF|r"
    print("  |cffFFD700Panel|r: shown " .. shown .. ", locked " .. locked ..
        ", size " .. (ns.db.panel.size or "small"))
end

-- Called from OnLoad after db is ready
function panel.Init()
    if not ns.db.panel then
        ns.db.panel = { shown = true, locked = false, size = "small", point = { "CENTER", 0, 200 } }
    end
    if not SIZES[ns.db.panel.size] then
        ns.db.panel.size = "small" -- saves predating the size setting, or a removed size
    end
    panel.ApplyPosition()
    panel.ApplyState()
end
