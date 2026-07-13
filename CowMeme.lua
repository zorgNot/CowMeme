local ADDON_NAME, ns = ...

-- Default settings — merged with SavedVariables on load
ns.defaults = {
    enabled = true,
    sound   = true,       -- master toggle for addon sound effects
    soundVolume = 1,      -- 0..1 volume for addon sound effects
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
    ns.panel.Init()
    ns.fnc.Init()
    ns.copypasta.Init()
    ns.gambaRoster.Init()
    ns.options.Init()
end

function ns.OnLogin()
    print("|cff00ff00CowMeme|r loaded. Type |cffffff00/cowmeme help|r for commands.")
end

function ns.Print(msg)
    print("|cff00ff00CowMeme|r: " .. tostring(msg))
end

-- Master sound. Plays a sound bundled with the addon, gated by the master
-- sound toggle (and the addon enable). `file` is a name in the sounds\ folder
-- ("cm_firstblood.ogg") or a full "Interface\\AddOns\\..." path. Returns
-- true if it started playing.
--
-- Volume: PlaySoundFile has no per-sound volume; sounds only scale by channel
-- volume. At full volume clips play on Master (heard even with game SFX
-- muted). Below full, they ride the rarely-used Dialog channel with its
-- volume CVar pinned to the slider value while the clip plays, restored a few
-- seconds later. Overlapping clips extend the restore window; the saved user
-- value is only captured while no restore is pending, so our own pin is never
-- mistaken for the user's setting.
local SOUND_PATH = "Interface\\AddOns\\" .. ADDON_NAME .. "\\sounds\\"
local volumeRestoreTimer, savedDialogVolume
function ns.PlaySound(file)
    if not (ns.db and ns.db.enabled and ns.db.sound) then return false end
    if not file or file == "" then return false end
    local volume = ns.db.soundVolume or 1
    if volume <= 0 then return false end
    local path = file:find("\\", 1, true) and file or (SOUND_PATH .. file)

    if volume >= 1 then
        return PlaySoundFile(path, "Master") and true or false
    end

    if volumeRestoreTimer then
        volumeRestoreTimer:Cancel()
    else
        savedDialogVolume = tonumber(GetCVar("Sound_DialogVolume")) or 1
    end
    SetCVar("Sound_DialogVolume", volume)
    local willPlay = PlaySoundFile(path, "Dialog")
    volumeRestoreTimer = C_Timer.NewTimer(4, function()
        volumeRestoreTimer = nil
        SetCVar("Sound_DialogVolume", savedDialogVolume)
    end)
    return willPlay and true or false
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

-- The canonical channel: the best non-protected channel available.
-- SAY/YELL are protected outside hardware events, so the order is
-- instance > group > guild > nil (nil = print locally instead).
-- Battlegrounds/arenas are instanced groups where IsInRaid()/IsInGroup()
-- report true but only "INSTANCE_CHAT" is a valid target, so it comes first.
-- Shared by ns.Announce and the sync heartbeat, so the two never diverge.
function ns.CanonicalChannel()
    if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
        return "INSTANCE_CHAT"
    elseif IsInRaid() then
        return "RAID"
    elseif IsInGroup() then
        return "PARTY"
    elseif IsInGuild() then
        return "GUILD"
    end
    return nil
end

-- Re-apply every module's event registrations and visibility from current
-- settings. The single aggregate: new modules get added here, nowhere else.
function ns.ApplyAllStates()
    ns.sync.ApplyState()
    ns.panel.ApplyState()
    ns.fnc.ApplyState()
    ns.copypasta.ApplyState()
    ns.gambaRoster.ApplyState()
end

-- Announce a line to the canonical channel. This is the only leader-gated
-- path in the addon: one elected announcer speaks for everyone running it.
-- cap is the capability the content belongs to ("G" = gamba pasta,
-- "F" = FnC), so the election only considers peers willing to announce it.
-- Local display (panel) must never route through here.
function ns.Announce(line, cap)
    local channel = ns.CanonicalChannel()
    if ns.SandboxActive() then
        local note = ""
        if not ns.sync.IsAnnouncer(cap) then
            note = " |cff00ccff(live: suppressed, announcer = " .. tostring(ns.sync.GetAnnouncer(cap)) .. ")|r"
        end
        ns.Print("|cff00ccff[SANDBOX -> " .. (channel or "no channel") .. "]|r " .. line .. note)
        return
    end
    if not ns.sync.IsAnnouncer(cap) then
        ns.DebugPrint("announce", "suppressed (announcer: " .. tostring(ns.sync.GetAnnouncer(cap)) .. "): " .. line)
        return
    end
    if channel then
        ns.DebugPrint("announce", "-> " .. channel .. ": " .. line)
        SendChatMessage(line, channel)
    else
        ns.Print("(no valid channel) " .. line)
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
    options = {
        "|cffffff00/cm options|r",
        "Open the CowMeme options panel (also under ESC > Options > AddOns).",
        "Every setting organized by module, with Default Settings and Clear All",
        "Addon Data buttons.",
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
        "CopyPasta gamba announcing, sync leader, and panel state.",
    },
    version = {
        "|cffffff00/cm version|r (alias /cm v)",
        "Print the installed CowMeme version (from the .toc).",
    },
    roster = {
        "|cffffff00/cm roster [status|demo|simtie|start|add|remove|close|roll|remind]|r",
        "The gamba signup roster (built from CrossGambling's own broadcasts) and",
        "the roll-nudge button. /cm roster status lists who signed up but hasn't",
        "rolled. The rest are debug sims (need /cm debug on); /cm roster demo runs",
        "the whole lifecycle, /cm roster simtie [high|low] exercises a tie breaker.",
        "/cm roster finish rolls out everyone still pending and closes the game.",
    },
    panel = {
        "|cffffff00/cm panel [show|hide|size|lock|unlock|reset|clear|test]|r",
        "The CowMeme content panel: a movable frame for images and text",
        "(copypasta art, gamba top rolls, etc). Unlocked by default -- drag it",
        "anywhere; its position is saved. Two sizes: /cm panel size small|medium,",
        "or right-click the panel for a menu with sizes and close. Bare /cm panel",
        "shows the menu and state.",
    },
}

commands["help"] = function()
    ns.Print("Available commands:")
    print("  |cffffff00/cm help [command]|r - show this message, or details for a command")
    print("  |cffffff00/cm enable|r      - enable the addon")
    print("  |cffffff00/cm disable|r     - disable the addon")
    print("  |cffffff00/cm options|r     - open the options panel")
    print("  |cffffff00/cm debug|r       - debug menu (tracing, sandbox, sim commands)")
    print("  |cffffff00/cm panel|r       - content panel menu (show/hide/lock/move)")
    if ns.db.debug then
        print("  |cffffff00/cm roster|r      - (debug) gamba roster and roll-nudge sims")
    end
    print("  |cffffff00/cm status|r      - show current settings")
    print("  |cffffff00/cm version|r     - show the addon version")
    print("  |cffffff00/fnc help|r       - Fast and Clean death tracker (see for details)")
    print("  |cffffff00/cp help|r        - CopyPasta (see for details)")
    commands.status()
end

commands["enable"] = function()
    ns.db.enabled = true
    ns.ApplyAllStates()
    ns.Print("Enabled.")
end

commands["disable"] = function()
    ns.db.enabled = false
    ns.ApplyAllStates()
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
        print("  Sim commands (require debug on; sandboxed, except FnC sims run live with a trailing \"nobox\"):")
        print("  |cffffff00/fnc simdamage <name> <cause>|r - record fake damage against <name>")
        print("  |cffffff00/fnc simdeath <name> [nobox]|r  - simulate a death (pair with simdamage)")
        print("  |cffffff00/fnc simbatch <m> <n> [nobox]|r - simulate n deaths hitting a milestone")
        print("  |cffffff00/fnc simsound [milestone]|r     - play a sound via a fake chat line (no arg = first blood)")
        print("  |cffffff00/fnc simreset|r                 - simulate receiving a group FnC reset")
        print("  |cffffff00/fnc longsim [nobox]|r          - 30 deaths / 3 characters / 30s, topping out the milestones")
        print("  |cffffff00/cp simgamba <chat line>|r      - feed a fake line to the gamba monitor")
        print("  |cffffff00/cp simroll <name> <n>|r        - feed a fake /roll to the top-roll tracker")
        print("  |cffffff00/cp simdemo [name]|r            - run the gamba demo, optionally targeting a player")
        print("  |cffffff00/cp simtie [high|low]|r         - run the CopyPasta tie-breaker demo")
        print("  |cffffff00/cp simnowin|r                  - run the no-winners (tombstone) demo")
        print("  |cffffff00/cm roster simtie [high|low]|r  - run the GambaRoster tie-breaker demo")
    end
end

commands["options"] = function()
    ns.options.Open()
end

commands["panel"] = function(arg)
    local sub, val = (arg or ""):lower():match("^(%S*)%s*(%S*)")
    if sub == "size" then
        if val == "small" or val == "medium" then
            ns.panel.SetSize(val)
            ns.Print("Panel size: " .. val .. ".")
        else
            ns.Print("Usage: /cm panel size small|medium")
        end
        return
    end
    if sub == "show" then
        ns.panel.SetShown(true)
        ns.Print("Panel shown.")
    elseif sub == "hide" then
        ns.panel.SetShown(false)
        ns.Print("Panel hidden.")
    elseif sub == "lock" then
        ns.panel.SetLocked(true)
        ns.Print("Panel locked.")
    elseif sub == "unlock" then
        ns.panel.SetLocked(false)
        ns.Print("Panel unlocked (drag to move).")
    elseif sub == "reset" then
        ns.panel.ResetPosition()
        ns.Print("Panel position reset.")
    elseif sub == "clear" then
        ns.panel.Clear()
        ns.Print("Panel cleared.")
    elseif sub == "test" then
        ns.panel.Display({
            text = "Moo! This clears in 5s.",
            image = "Interface\\AddOns\\CowMeme\\images\\image",
            duration = 5,
        })
    else
        ns.Print("Panel menu:")
        ns.panel.PrintStatus()
        print("  |cffffff00/cm panel show|hide|r   - show or hide the panel")
        print("  |cffffff00/cm panel size <small|medium>|r - set panel size")
        print("  |cffffff00/cm panel lock|unlock|r - lock or unlock dragging")
        print("  |cffffff00/cm panel reset|r       - reset position to center")
        print("  |cffffff00/cm panel clear|r       - clear current content")
        print("  |cffffff00/cm panel test|r        - show sample content for 5s")
        print("  Right-click the panel for sizes and close.")
    end
end

commands["roster"] = function(arg)
    if not ns.db.debug then
        ns.Print("Roster commands are debug-only: /cm debug on")
        return
    end

    local sub, rest = (arg or ""):match("^(%S*)%s*(.*)")
    sub = sub:lower()

    if sub == "status" then
        ns.gambaRoster.PrintStatus()
        return
    end
    if sub == "" then
        ns.Print("Gamba roster commands (debug):")
        ns.gambaRoster.PrintStatus()
        print("  |cffffff00/cm roster status|r        - show signups and who is pending")
        print("  |cffffff00/cm roster demo|r          - run the full lifecycle sim")
        print("  |cffffff00/cm roster simtie [high|low]|r - run the tie-breaker sim")
        print("  |cffffff00/cm roster start [wager]|r - sim a new game (default 100)")
        print("  |cffffff00/cm roster add <name>|r    - sim a signup")
        print("  |cffffff00/cm roster remove <name>|r - sim a withdrawal")
        print("  |cffffff00/cm roster close|r         - sim entries closed (roll phase)")
        print("  |cffffff00/cm roster roll <name> [v]|r - sim a roll")
        print("  |cffffff00/cm roster finish|r        - roll out all pending and close the game")
        print("  |cffffff00/cm roster remind|r        - fire the reminder now")
        return
    end

    if sub == "demo" then
        ns.gambaRoster.SimDemo()
    elseif sub == "simtie" then
        ns.gambaRoster.SimTie(rest:match("^(%S*)"):lower())
    elseif sub == "start" then
        ns.gambaRoster.SimStart(tonumber(rest))
        ns.Print("Roster sim: new game" .. (tonumber(rest) and (" (1-" .. tonumber(rest) .. ")") or " (1-100)") .. ".")
    elseif sub == "add" then
        local name = rest:match("^(%S+)")
        if name then ns.gambaRoster.SimAdd(name); ns.Print("Roster sim: signed up " .. name .. ".")
        else ns.Print("Usage: /cm roster add <name>") end
    elseif sub == "remove" then
        local name = rest:match("^(%S+)")
        if name then ns.gambaRoster.SimRemove(name); ns.Print("Roster sim: removed " .. name .. ".")
        else ns.Print("Usage: /cm roster remove <name>") end
    elseif sub == "close" then
        ns.gambaRoster.SimClose()
        ns.Print("Roster sim: entries closed.")
    elseif sub == "roll" then
        local name, val = rest:match("^(%S+)%s*(%d*)")
        if name then ns.gambaRoster.SimRoll(name, tonumber(val)); ns.Print("Roster sim: " .. name .. " rolled.")
        else ns.Print("Usage: /cm roster roll <name> [value]") end
    elseif sub == "finish" then
        ns.gambaRoster.SimFinish()
    elseif sub == "remind" then
        ns.gambaRoster.SendReminder()
    else
        ns.Print("Unknown roster command \"" .. sub .. "\". Try /cm roster.")
    end
end

commands["version"] = function()
    local getMeta = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
    ns.Print("version " .. ((getMeta and getMeta(ADDON_NAME, "Version")) or "?"))
end
commands["v"] = commands["version"]

commands["status"] = function()
    ns.Print("Status:")
    local getMeta = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
    local version = (getMeta and getMeta(ADDON_NAME, "Version")) or "?"
    local line = "  |cffFFD700CowMeme|r v" .. version .. ": enabled " .. OnOff(ns.db.enabled) .. ", sound " .. OnOff(ns.db.sound) .. ", debug " .. OnOff(ns.db.debug)
    if ns.db.debug then
        line = line .. ", sandbox " .. OnOff(ns.db.debugSandbox) .. ", verbose " .. OnOff(ns.db.debugVerbose)
    end
    print(line)
    ns.fnc.PrintStatus()
    ns.copypasta.PrintStatus()
    if ns.db.debug then
        ns.sync.PrintStatus()
    end
    ns.panel.PrintStatus()
end

local function HandleSlash(input)
    local cmd, arg = strtrim(input):match("^(%S*)%s*(.*)")
    cmd = cmd:lower()
    -- "/cm help <command>" shows detailed help for that command
    if cmd == "help" and arg ~= "" then
        local key = arg:lower()
        local lines = helpDetails[key]
        if key == "roster" and not ns.db.debug then lines = nil end -- roster is debug-only
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
