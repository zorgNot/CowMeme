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
    ns.fnc.Init()
    ns.copypasta.Init()
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

-- Colored ON/OFF label
local function OnOff(v)
    return v and "|cff00ff00ON|r" or "|cffff0000OFF|r"
end

-- Slash commands
local commands = {}

-- Per-command detailed help, shown by "/cm help <command>"
local helpDetails = {
    help = {
        "|cffffff00/cm help [command]|r",
        "List all commands, or show details for one (e.g. /cm help enable).",
    },
    enable = {
        "|cffffff00/cm enable|r",
        "Globally enable the addon. Resumes FnC death tracking and the CopyPasta",
        "gamba monitor if they were previously on.",
        "Note: manual commands (/cp <name>, /fnc report, etc.) still work even while",
        "disabled -- enable/disable only gates the automated event-driven features.",
    },
    disable = {
        "|cffffff00/cm disable|r",
        "Globally disable the addon. Suspends FnC death tracking and the gamba",
        "monitor without clearing their settings, so they restore on re-enable.",
    },
    debug = {
        "|cffffff00/cm debug|r",
        "Toggle debug output on or off.",
    },
    status = {
        "|cffffff00/cm status|r",
        "Show current settings: addon enabled/debug, FnC tracking and batch mode,",
        "and the CopyPasta gamba monitor state.",
    },
}

commands["help"] = function()
    ns.Print("Available commands:")
    print("  |cffffff00/cm help [command]|r - show this message, or details for a command")
    print("  |cffffff00/cm enable|r      - enable the addon")
    print("  |cffffff00/cm disable|r     - disable the addon")
    print("  |cffffff00/cm debug|r       - toggle debug output")
    print("  |cffffff00/cm status|r      - show current settings")
    print("  |cffffff00/fnc help|r       - Fast and Clean death tracker (see for details)")
    print("  |cffffff00/cp help|r        - CopyPasta (see for details)")
    commands.status()
end

commands["enable"] = function()
    ns.db.enabled = true
    ns.fnc.ApplyState()
    ns.copypasta.ApplyState()
    ns.Print("Enabled.")
end

commands["disable"] = function()
    ns.db.enabled = false
    ns.fnc.ApplyState()
    ns.copypasta.ApplyState()
    ns.Print("Disabled.")
end

commands["debug"] = function()
    ns.db.debug = not ns.db.debug
    ns.Print("Debug " .. (ns.db.debug and "on" or "off") .. ".")
end

commands["status"] = function()
    ns.Print("Status:")
    print("  |cffFFD700CowMeme|r: enabled " .. OnOff(ns.db.enabled) .. ", debug " .. OnOff(ns.db.debug))
    ns.fnc.PrintStatus()
    ns.copypasta.PrintStatus()
end

local function HandleSlash(input)
    local cmd, arg = strtrim(input):lower():match("^(%S*)%s*(%S*)")
    -- "/cm help <command>" shows detailed help for that command
    if cmd == "help" and arg ~= "" then
        local lines = helpDetails[arg]
        if lines then
            for _, line in ipairs(lines) do print(line) end
        else
            ns.Print("No detailed help for \"" .. arg .. "\". Try /cm help.")
        end
        return
    end
    local handler = commands[cmd] or commands["help"]
    handler()
end

SLASH_COWMEME1 = "/cowmeme"
SLASH_COWMEME2 = "/cm"
SlashCmdList["COWMEME"] = HandleSlash
