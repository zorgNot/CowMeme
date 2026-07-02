local ADDON_NAME, ns = ...

ns.panel = {}
local panel = ns.panel

-- Default panel settings
ns.defaults.panel = {
    shown  = true,
    locked = false, -- unlocked (movable) by default
    point  = { "CENTER", 0, 200 }, -- anchor point, x, y on UIParent
}

local PANEL_WIDTH, PANEL_HEIGHT = 220, 140
local IMAGE_SIZE = 64

local frame = CreateFrame("Frame", "CowMemePanel", UIParent, "BackdropTemplate")
frame:SetSize(PANEL_WIDTH, PANEL_HEIGHT)
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

local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOP", 0, -8)
title:SetText("|cff00ff00CowMeme|r")

local image = frame:CreateTexture(nil, "ARTWORK")
image:SetSize(IMAGE_SIZE, IMAGE_SIZE)
image:SetPoint("TOP", 0, -24)
image:Hide()

local text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
text:SetJustifyH("CENTER")
text:SetJustifyV("MIDDLE")

-- Smaller line pinned to the bottom, for secondary/flavor text
local footer = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
footer:SetPoint("BOTTOMLEFT", 6, 6)
footer:SetPoint("BOTTOMRIGHT", -6, 6)
footer:SetJustifyH("CENTER")

-- Anchor the text region below the image when one is shown, otherwise
-- let it fill the panel; the bottom always leaves room for the footer.
local function LayoutText(hasImage)
    text:ClearAllPoints()
    text:SetPoint("TOPLEFT", 10, hasImage and -(24 + IMAGE_SIZE + 4) or -24)
    text:SetPoint("BOTTOMRIGHT", -10, 20)
end
LayoutText(false)

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

-- Show content on the panel. opts:
--   text           - string to display
--   image          - texture path (e.g. "Interface\\AddOns\\CowMeme\\images\\image")
--   footer         - smaller secondary line pinned to the bottom
--   footerDuration - seconds until the footer alone clears (omit to persist)
--   duration       - seconds until all content auto-clears (omit to persist)
-- Respects the panel's shown setting: content is dropped while hidden.
local clearTimer
local footerTimer
function panel.Display(opts)
    if not ns.db.panel.shown then return end
    opts = opts or {}
    if opts.image then
        image:SetTexture(opts.image)
        image:Show()
        LayoutText(true)
    else
        image:Hide()
        LayoutText(false)
    end
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

-- Clear content, keeping the panel itself where it is
function panel.Clear()
    text:SetText("")
    footer:SetText("")
    if footerTimer then
        footerTimer:Cancel()
        footerTimer = nil
    end
    image:Hide()
    LayoutText(false)
end

function panel.SetShown(shown)
    ns.db.panel.shown = shown
    if shown then
        frame:Show()
    else
        frame:Hide()
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
    print("  |cffFFD700Panel|r: shown " .. shown .. ", locked " .. locked)
end

-- Called from OnLoad after db is ready
function panel.Init()
    if not ns.db.panel then
        ns.db.panel = { shown = true, locked = false, point = { "CENTER", 0, 200 } }
    end
    panel.ApplyPosition()
    if ns.db.panel.shown then
        frame:Show()
    end
end
