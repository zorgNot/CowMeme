local ADDON_NAME, ns = ...

-- Default settings — merged with SavedVariables on load
ns.defaults = {
    enabled = true,
    debug   = false,
}

local frame = CreateFrame("Frame", ADDON_NAME .. "Frame", UIParent)

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name == ADDON_NAME then
            ns.OnLoad()
        end
    elseif event == "PLAYER_LOGIN" then
        ns.OnLogin()
    end
end)

-- Merge saved variables with defaults, preserving saved values
local function ApplyDefaults(saved, defaults)
    local db = saved or {}
    for k, v in pairs(defaults) do
        if db[k] == nil then
            db[k] = v
        end
    end
    return db
end

function ns.OnLoad()
    CowMemeDB = ApplyDefaults(CowMemeDB, ns.defaults)
    ns.db = CowMemeDB
end

function ns.OnLogin()
    print("|cff00ff00CowMeme|r loaded. Type |cffffff00/cowmeme help|r for commands.")
end

function ns.Print(msg)
    print("|cff00ff00CowMeme|r: " .. tostring(msg))
end

function ns.DebugPrint(msg)
    if ns.db and ns.db.debug then
        print("|cffaaaaaa[CowMeme debug]|r " .. tostring(msg))
    end
end

-- Slash commands
local commands = {}

commands["help"] = function()
    ns.Print("Available commands:")
    print("  |cffffff00/cowmeme help|r        - show this message")
    print("  |cffffff00/cowmeme enable|r      - enable the addon")
    print("  |cffffff00/cowmeme disable|r     - disable the addon")
    print("  |cffffff00/cowmeme debug|r       - toggle debug output")
    print("  |cffffff00/cowmeme status|r      - show current settings")
end

commands["enable"] = function()
    ns.db.enabled = true
    ns.Print("Enabled.")
end

commands["disable"] = function()
    ns.db.enabled = false
    ns.Print("Disabled.")
end

commands["debug"] = function()
    ns.db.debug = not ns.db.debug
    ns.Print("Debug " .. (ns.db.debug and "on" or "off") .. ".")
end

commands["status"] = function()
    ns.Print("enabled=" .. tostring(ns.db.enabled) .. "  debug=" .. tostring(ns.db.debug))
end

local function HandleSlash(input)
    local cmd = strtrim(input):lower()
    local handler = commands[cmd] or commands["help"]
    handler()
end

SLASH_COWMEME1 = "/cowmeme"
SLASH_COWMEME2 = "/cm"
SlashCmdList["COWMEME"] = HandleSlash
