local ADDON_NAME, ns = ...

-- Default settings — merged with SavedVariables on load
ns.defaults = {
    enabled = true,
    debug   = false,
    debugSandbox = false, -- route announcements to local print instead of chat
    debugVerbose = false, -- extra-noisy tracing (per damage event)
    debugFnc = true,      -- FnC tracing (when debug is on)
    debugCp  = true,      -- CopyPasta tracing (when debug is on)
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
    ns.sync.Init()
    ns.fnc.Init()
    ns.copypasta.Init()
end

function ns.OnLogin()
    print("|cff00ff00CowMeme|r loaded. Type |cffffff00/cowmeme help|r for commands.")
end

function ns.Print(msg)
    print("|cff00ff00CowMeme|r: " .. tostring(msg))
end

-- True when tracing for a module scope ("fnc" / "cp") should print
function ns.DebugOn(scope)
    if not (ns.db and ns.db.debug) then return false end
    if scope == "fnc" then return ns.db.debugFnc end
    if scope == "cp" then return ns.db.debugCp end
    return true
end

-- Verbose tracing: per-event spam, gated separately from decision tracing
function ns.DebugVerbose(scope)
    return ns.DebugOn(scope) and ns.db.debugVerbose
end

function ns.DebugPrint(scope, msg)
    if ns.DebugOn(scope) then
        print("|cffaaaaaa[CowMeme " .. scope .. "]|r " .. tostring(msg))
    end
end

-- Sim commands force sandbox routing for a few seconds so fake events can
-- never reach real chat, regardless of the sandbox toggle.
local simSandboxUntil = 0
function ns.ForceSandbox(seconds)
    simSandboxUntil = GetTime() + (seconds or 3)
end

-- True when announcements should print locally instead of going to chat.
-- The sandbox toggle only applies while master debug is on; the sim force
-- window stands alone (sim commands are already debug-gated).
function ns.SandboxActive()
    return (ns.db and ns.db.debug and ns.db.debugSandbox) or GetTime() < simSandboxUntil
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
        "|cffffff00/cm debug [option] [on|off]|r",
        "Bare /cm debug opens the debug menu: master switch, sandbox (announcements",
        "print locally instead of chat), verbose tracing, per-module tracing, and",
        "sim commands for testing FnC deaths, batching, and the gamba monitor.",
        "/cm debug on|off flips the master switch; sim output is always sandboxed.",
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
    print("  |cffffff00/cm debug|r       - debug menu (tracing, sandbox, sim commands)")
    print("  |cffffff00/cm status|r      - show current settings")
    print("  |cffffff00/fnc help|r       - Fast and Clean death tracker (see for details)")
    print("  |cffffff00/cp help|r        - CopyPasta (see for details)")
    commands.status()
end

commands["enable"] = function()
    ns.db.enabled = true
    ns.sync.ApplyState()
    ns.fnc.ApplyState()
    ns.copypasta.ApplyState()
    ns.Print("Enabled.")
end

commands["disable"] = function()
    ns.db.enabled = false
    ns.sync.ApplyState()
    ns.fnc.ApplyState()
    ns.copypasta.ApplyState()
    ns.Print("Disabled.")
end

commands["debug"] = function(arg)
    local sub, val = (arg or ""):match("^(%S*)%s*(%S*)")
    sub, val = sub:lower(), val:lower()

    -- on/off/toggle a debug flag and report the new state
    local function SetFlag(key, label)
        if val == "on" then
            ns.db[key] = true
        elseif val == "off" then
            ns.db[key] = false
        else
            ns.db[key] = not ns.db[key]
        end
        ns.Print(label .. " " .. OnOff(ns.db[key]) .. ".")
    end

    if sub == "on" or sub == "off" then
        ns.db.debug = (sub == "on")
        ns.Print("Debug " .. OnOff(ns.db.debug) .. ".")
    elseif sub == "sandbox" then
        SetFlag("debugSandbox", "Sandbox")
    elseif sub == "verbose" then
        SetFlag("debugVerbose", "Verbose tracing")
    elseif sub == "fnc" then
        SetFlag("debugFnc", "FnC tracing")
    elseif sub == "cp" then
        SetFlag("debugCp", "CopyPasta tracing")
    else
        -- Bare /cm debug: show the debug menu
        ns.Print("Debug menu:")
        print("  master " .. OnOff(ns.db.debug) .. " | sandbox " .. OnOff(ns.db.debugSandbox) ..
            " | verbose " .. OnOff(ns.db.debugVerbose) ..
            " | fnc trace " .. OnOff(ns.db.debugFnc) .. " | cp trace " .. OnOff(ns.db.debugCp))
        print("  |cffffff00/cm debug on|off|r          - master switch (gates tracing + sim commands)")
        print("  |cffffff00/cm debug sandbox [on|off]|r - print announcements locally (needs master on)")
        print("  |cffffff00/cm debug verbose [on|off]|r - extra-noisy tracing (every damage event)")
        print("  |cffffff00/cm debug fnc [on|off]|r     - FnC decision tracing")
        print("  |cffffff00/cm debug cp [on|off]|r      - CopyPasta decision tracing")
        print("  Sim commands (require debug on; output is always sandboxed):")
        print("  |cffffff00/fnc simdamage <name> <cause>|r - record fake damage against <name>")
        print("  |cffffff00/fnc simdeath <name>|r          - simulate a death (pair with simdamage)")
        print("  |cffffff00/fnc simbatch <milestone> <n>|r - simulate n deaths hitting a milestone")
        print("  |cffffff00/cp simgamba <chat line>|r      - feed a fake line to the gamba monitor")
    end
end

commands["status"] = function()
    ns.Print("Status:")
    local line = "  |cffFFD700CowMeme|r: enabled " .. OnOff(ns.db.enabled) .. ", debug " .. OnOff(ns.db.debug)
    if ns.db.debug then
        line = line .. ", sandbox " .. OnOff(ns.db.debugSandbox)
    end
    print(line)
    ns.fnc.PrintStatus()
    ns.copypasta.PrintStatus()
    ns.sync.PrintStatus()
end

local function HandleSlash(input)
    local cmd, arg = strtrim(input):match("^(%S*)%s*(.*)")
    cmd = cmd:lower()
    -- "/cm help <command>" shows detailed help for that command
    if cmd == "help" and arg ~= "" then
        local lines = helpDetails[arg:lower()]
        if lines then
            for _, line in ipairs(lines) do print(line) end
        else
            ns.Print("No detailed help for \"" .. arg .. "\". Try /cm help.")
        end
        return
    end
    local handler = commands[cmd] or commands["help"]
    handler(arg ~= "" and arg or nil)
end

SLASH_COWMEME1 = "/cowmeme"
SLASH_COWMEME2 = "/cm"
SlashCmdList["COWMEME"] = HandleSlash
