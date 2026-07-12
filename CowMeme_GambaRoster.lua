local ADDON_NAME, ns = ...

-- Authoritative signup roster for the active CrossGambling game, built from
-- CrossGambling's own addon-comm broadcasts (prefix "CrossGambling"). This is
-- separate from CopyPasta's loose chat-observed roll tracking on purpose: rolls
-- stay fakeable/visible, while this list reflects only real signups so we can
-- tell exactly who signed up but hasn't rolled yet.
ns.gambaRoster = {}
local roster = ns.gambaRoster

local CG_PREFIX = "CrossGambling"
local REMINDER_THROTTLE = 3 -- seconds between reminders this client can send
local REMINDER_TEXTS = {
"forgot to roll ICANT",
"bro missed the only mechanic",
"queued for gamba, forgot the gamba",
"rolled AFK",
"gamba participation parse: gray",
"couldn't even hit /roll",
"missed roll timer KEKW",
"roll on GCD",
"reaction time parsed gray",
"forgot the assignment",
"rollless behavior",
"negative gambling awareness",
"financial absenteeism",
"gold wanted in, fingers said no",
"wallet queued, player declined",
"bro signed up for spectator mode",
"gamba tourist",
"NPC gambling behavior",
"professionally unrolled",
"certified non-roller",
"roll evasion spec",
"mechanically incapable of /roll",
"outplayed by the timer",
"lost to the countdown",
"rolled spiritually",
"thoughts and prayers rolled",
"roll.exe has stopped responding",
"404 roll not found",
"roll still buffering",
"loading... still loading...",
"AFK until payout",
"missed free money somehow",
"wallet wasn't locked in",
"gold had stage fright",
"forgot to press the money button",
"roll fear debuff",
"gamba anxiety proc",
"intimidated by RNG",
"RNG waited. you didn't.",
"rolled in another timeline",
"roll sent via carrier pigeon",
"waiting for addon update",
"performing pre-roll calculations",
"spreadsheet took too long",
"hesitation diff",
"slowroll IRL",
"bro's roll is in the mail",
"still reading the rules",
"signed up for vibes",
"rollless maxxing",
"financial skill issue",
"bankroll asleep at the wheel",
"too busy inspecting character pane",
"couldn't find the / key",
"one job btw",
"missed the freest EV of all time",
"roll escaped containment",
"gamba observer mode",
"participation trophy gambler",
"rolled after the drawing ICANT",
}

-- players[name] = { rolled = bool }; name is realm-stripped, lowercase-safe via
-- exact match against realm-stripped roll names.
local players = {}
local stake = nil        -- wager (max roll) from SET_WAGER, or nil if unseen
local rolling = false    -- true once entries close (Disable_Join)
local gameChannel = nil  -- channel CG comm arrived on = where to send reminders
local lastReminder = 0

local frame = CreateFrame("Frame", "CowMemeGambaRosterFrame", UIParent)

local function Strip(name)
    return name and (name:match("^([^%-]+)") or name)
end

local function ClearRoster()
    wipe(players)
    stake = nil
    rolling = false
end

-- Pending = signed up but not yet rolled
function roster.Pending()
    local list = {}
    for name, p in pairs(players) do
        if not p.rolled then table.insert(list, name) end
    end
    return list
end

function roster.PickRandomPending()
    local list = roster.Pending()
    if #list == 0 then return nil end
    return list[math.random(#list)]
end

-- Only meaningful during the roll phase (after entries close)
function roster.HasPending()
    if not rolling then return false end
    for _, p in pairs(players) do
        if not p.rolled then return true end
    end
    return false
end

local function RefreshButton()
    -- Pending count is only meaningful during the roll phase
    ns.panel.SetNudge(rolling and #roster.Pending() or 0)
end

-- CrossGambling comm: event or event:arg under the CrossGambling prefix
local function OnAddonMsg(prefix, msg, channel)
    if prefix ~= CG_PREFIX then return end
    gameChannel = channel -- remember where this game lives for reminders
    local event, arg = strsplit(":", msg)
    if event == "New_Game" or event == "R_NewGame" then
        ClearRoster()
    elseif event == "SET_WAGER" then
        stake = tonumber(arg)
    elseif event == "ADD_PLAYER" then
        local name = Strip(arg)
        if name and not players[name] then
            players[name] = { rolled = false }
            ns.DebugPrint("roster", "signup: " .. name .. " (" .. #roster.Pending() .. " total)")
        end
    elseif event == "Remove_Player" then
        local name = Strip(arg)
        if name and players[name] then
            players[name] = nil
            ns.DebugPrint("roster", "withdrew: " .. name .. " (" .. #roster.Pending() .. " total)")
        end
    elseif event == "Disable_Join" then
        rolling = true
        ns.DebugPrint("roster", "entries closed; roll phase, " .. #roster.Pending() .. " signed up")
    else
        return -- unrelated CG event, no button refresh needed
    end
    RefreshButton()
end

-- Mark a signup as rolled once we see their /roll for the stake
local function OnSystemMsg(text)
    if not rolling then return end
    local name, roll, low, high = text:match("^(%S+) rolls (%d+) %((%d+)%-(%d+)%)$")
    if not name or low ~= "1" then return end
    if stake and tonumber(high) ~= stake then return end
    name = Strip(name)
    local p = players[name]
    if p and not p.rolled then
        p.rolled = true
        ns.DebugPrint("roster", "rolled: " .. name .. " (" .. #roster.Pending() .. " still pending)")
        RefreshButton()
    end
end

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "CHAT_MSG_ADDON" then
        local prefix, msg, channel = ...
        OnAddonMsg(prefix, msg, channel)
    elseif event == "CHAT_MSG_SYSTEM" then
        local text = ...
        OnSystemMsg(text)
    end
end)

-- Button action: remind a random pending player to roll. Manual (button is a
-- hardware event), so not leader-gated; throttled so one client can't spam.
function roster.SendReminder()
    if not roster.HasPending() then
        ns.Print("|cffFFD700[Gamba]|r No one is pending a roll right now.")
        return
    end
    local now = GetTime()
    local wait = REMINDER_THROTTLE - (now - lastReminder)
    if wait > 0 then
        -- The button should already be disabled for this window; this is a
        -- backstop for callers that bypass it (e.g. the /cm roster remind sim).
        ns.Print(string.format("|cffFFD700[Gamba]|r Reminder throttled (%.0fs).", wait))
        return
    end
    lastReminder = now

    local name = roster.PickRandomPending()
    local msg = stake and (name .. ": " .. REMINDER_TEXTS[math.random(#REMINDER_TEXTS)] .. " ( /roll " .. stake .. " )")
        or (name .. ": " .. REMINDER_TEXTS[math.random(#REMINDER_TEXTS)] .. " ( /roll )")
    local channel = gameChannel or ns.CanonicalChannel() or "SAY"
    if ns.SandboxActive() then
        ns.Print("|cff00ccff[SANDBOX -> " .. channel .. "]|r " .. msg)
    else
        SendChatMessage(msg, channel)
    end
    ns.DebugPrint("roster", "reminded " .. name .. " on " .. channel)

    -- Grey the button out for the throttle window, then restore it
    ns.panel.SetNudgeEnabled(false)
    C_Timer.After(REMINDER_THROTTLE, function()
        ns.panel.SetNudgeEnabled(true)
    end)
end

-- One-line status (safe to call anytime; usually empty outside a game)
function roster.PrintStatus()
    local pending = roster.Pending()
    local total = 0
    for _ in pairs(players) do total = total + 1 end
    print("  |cffFFD700Roster|r: " .. total .. " signed up, " .. #pending .. " pending"
        .. (rolling and " (rolling)" or " (entries open)")
        .. (stake and (", stake 1-" .. stake) or "")
        .. (#pending > 0 and (" [" .. table.concat(pending, ", ") .. "]") or ""))
end

-- Register/unregister based on the global enable flag
function roster.ApplyState()
    if ns.db.enabled then
        frame:RegisterEvent("CHAT_MSG_ADDON")
        frame:RegisterEvent("CHAT_MSG_SYSTEM")
    else
        frame:UnregisterEvent("CHAT_MSG_ADDON")
        frame:UnregisterEvent("CHAT_MSG_SYSTEM")
        ClearRoster()
        RefreshButton()
    end
end

-- Debug sims: feed the real internal handlers so the actual tracking logic
-- runs. A fake channel stands in for the game's channel; reminders are
-- sandbox-safe, and SimDemo forces the sandbox so button clicks stay local.
local SIM_CHANNEL = "PARTY"

function roster.SimStart(wager)
    OnAddonMsg(CG_PREFIX, "New_Game", SIM_CHANNEL)
    OnAddonMsg(CG_PREFIX, "SET_WAGER:" .. (wager or 100), SIM_CHANNEL)
end

function roster.SimAdd(name)
    OnAddonMsg(CG_PREFIX, "ADD_PLAYER:" .. name, SIM_CHANNEL)
end

function roster.SimRemove(name)
    OnAddonMsg(CG_PREFIX, "Remove_Player:" .. name, SIM_CHANNEL)
end

function roster.SimClose()
    OnAddonMsg(CG_PREFIX, "Disable_Join", SIM_CHANNEL)
end

function roster.SimRoll(name, value)
    value = value or math.random(1, stake or 100)
    OnSystemMsg(name .. " rolls " .. value .. " (1-" .. (stake or 100) .. ")")
end

-- Roll out everyone still pending (random values), then close the game out.
-- Uses the real handlers, so this exercises the same completion path a live
-- game hits when the last straggler finally rolls.
function roster.SimFinish()
    local pending = roster.Pending()
    if #pending == 0 then
        ns.Print("|cffFFD700[Gamba]|r No one pending; nothing to finish.")
    else
        for _, name in ipairs(pending) do
            roster.SimRoll(name)
        end
        ns.Print("|cffFFD700[Gamba]|r Rolled remaining: " .. table.concat(pending, ", ") .. ".")
    end
    ClearRoster()
    RefreshButton()
    ns.Print("|cffFFD700[Gamba]|r Game closed.")
end

-- Full lifecycle, staggered so the panel button appearing/updating is watchable
function roster.SimDemo()
    ns.ForceSandbox(60) -- keep any reminder clicks local during the test window
    roster.SimStart(100)
    ns.Print("|cffFFD700[Gamba]|r roster demo: game (1-100), adding signups...")
    C_Timer.After(1, function() roster.SimAdd("Beaglz") end)
    C_Timer.After(2, function() roster.SimAdd("Soffty") end)
    C_Timer.After(3, function() roster.SimAdd("Moistorcs") end)
    C_Timer.After(4, function()
        roster.SimClose()
        ns.Print("|cffFFD700[Gamba]|r entries closed -- the Nudge button should now show (3 pending).")
    end)
    C_Timer.After(5, function()
        roster.SimRoll("Moistorcs", 50)
        ns.Print("|cffFFD700[Gamba]|r Moistorcs rolled; Beaglz & Soffty still pending. Click Nudge (sandboxed ~60s) or /cm roster roll <name> to finish.")
    end)
end

-- Called from OnLoad after db is ready
function roster.Init()
    C_ChatInfo.RegisterAddonMessagePrefix(CG_PREFIX)
    ns.panel.SetNudgeHandler(function() roster.SendReminder() end)
    roster.ApplyState()
end
