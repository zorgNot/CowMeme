local ADDON_NAME, ns = ...

-- Authoritative signup roster for the active CrossGambling game, built from
-- CrossGambling's own addon-comm broadcasts (prefix "CrossGambling"). This is
-- separate from CopyPasta's loose chat-observed roll tracking on purpose: rolls
-- stay fakeable/visible, while this list reflects only real signups so we can
-- tell exactly who signed up but hasn't rolled yet.
ns.gambaRoster = {}
local roster = ns.gambaRoster

local CG_PREFIX = "CrossGambling"
local REMINDER_THROTTLE = 5 -- seconds between reminders this client can send
local HOST_NUDGE_DELAY = 20 -- seconds into registration before offering the host nudge

-- Public callouts for when the host has left entries open too long. Sent to the
-- game channel (not a whisper) since we don't reliably know who the host is.
local HOST_NUDGE_TEXTS = {
"host fell asleep at the wheel, close entries!",
"entries have been open a hot minute, start the rolls",
"gamba host went AFK mid-hosting KEKW",
"we're all signed up over here, whenever you're ready",
"close it up and let's roll already",
"host buffering... start the rolls",
"the money's getting cold, start the rolls",
"registration lasting longer than the raid, close entries",
"host forgot they were hosting ICANT",
"someone poke the host, entries still open",
}
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
local host = nil         -- realm-stripped name of the game's host (the comm sender)
local gameChannel = nil  -- channel CG comm arrived on = where to send reminders
local lastReminder = 0
local tie = nil          -- { type = "High"/"Low", names = {...} } while a tie is live
local hostNudgeReady = false -- true once registration has dragged past HOST_NUDGE_DELAY
local regTimer = nil     -- C_Timer counting down the host-nudge offer

local frame = CreateFrame("Frame", "CowMemeGambaRosterFrame", UIParent)

local function Strip(name)
    return name and (name:match("^([^%-]+)") or name)
end

-- The host nudge is offered only while entries stay open too long. Cancel it the
-- moment the phase changes (rolls open, game clears) so a stale timer can't flip
-- the button back on. Declared before ClearRoster since it calls this.
local function CancelHostNudge()
    hostNudgeReady = false
    if regTimer then
        regTimer:Cancel()
        regTimer = nil
    end
end

local function ClearRoster()
    wipe(players)
    stake = nil
    rolling = false
    host = nil
    tie = nil
    CancelHostNudge()
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

-- The single panel nudge button serves both phases: nudge a straggling roller
-- once rolls are open, or nudge the host to start rolls if registration drags.
local function RefreshButton()
    if rolling then
        local pending = #roster.Pending()
        ns.panel.SetNudge(pending > 0 and ("Nudge a roller (" .. pending .. ")") or nil)
    elseif hostNudgeReady then
        ns.panel.SetNudge("Gamba host start rolls!")
    else
        ns.panel.SetNudge(nil)
    end
end

-- Start the countdown that offers the host nudge if entries are still open when
-- it fires. Re-armed from scratch on every new game.
local function ArmHostNudge()
    CancelHostNudge()
    regTimer = C_Timer.NewTimer(HOST_NUDGE_DELAY, function()
        regTimer = nil
        if not rolling then
            hostNudgeReady = true
            RefreshButton()
        end
    end)
end

-- CrossGambling broadcasts no tie-breaker event on the addon-comm plane, so we
-- detect it ourselves once every signup has rolled: a shared top (High) or
-- bottom (Low) roll forces those players to re-roll. We re-open the tied players
-- as pending (which brings the Nudge button back with their count) and announce
-- the tie locally. Mirrors CrossGambling's High-priority tie resolution.
local function CheckForTie()
    if not rolling then return end
    for _, p in pairs(players) do
        if not p.rolled then return end -- someone still owes a roll; wait for them
    end

    local hi, lo
    for _, p in pairs(players) do
        if not hi or p.roll > hi then hi = p.roll end
        if not lo or p.roll < lo then lo = p.roll end
    end
    if not hi then return end -- no rolls recorded

    local highs, lows = {}, {}
    for name, p in pairs(players) do
        if p.roll == hi then table.insert(highs, name) end
        if p.roll == lo then table.insert(lows, name) end
    end

    local tieType, tied
    if #highs > 1 then
        tieType, tied = "High", highs
    elseif #lows > 1 then
        tieType, tied = "Low", lows
    end

    if not tieType then
        tie = nil -- unique winner and loser: resolved
        return
    end

    tie = { type = tieType, names = tied }
    for _, name in ipairs(tied) do
        players[name].rolled = false -- re-open for the re-roll
        players[name].roll = nil
    end
    ns.DebugPrint("roster", tieType .. " tie breaker among " .. table.concat(tied, ", "))
    ns.Print("|cffFFD700[Gamba]|r " .. tieType .. " tie breaker: " ..
        table.concat(tied, ", ") .. " must re-roll.")
    RefreshButton()
end

-- CrossGambling comm: event or event:arg under the CrossGambling prefix. The
-- host is the only sender of these events, so the message sender is the host.
local function OnAddonMsg(prefix, msg, channel, sender)
    if prefix ~= CG_PREFIX then return end
    gameChannel = channel -- remember where this game lives for reminders
    local event, arg = strsplit(":", msg)
    if event == "New_Game" or event == "R_NewGame" then
        ClearRoster()
        host = Strip(sender) -- ClearRoster wiped it; the game-open sender is the host
        ArmHostNudge() -- registration just started; offer the host nudge if it stalls
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
        CancelHostNudge() -- rolls are open now; the host-nudge offer is moot
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
        p.roll = tonumber(roll) -- kept so we can detect high/low ties locally
        ns.DebugPrint("roster", "rolled: " .. name .. " = " .. roll ..
            " (" .. #roster.Pending() .. " still pending)")
        RefreshButton()
        CheckForTie()
    end
end

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "CHAT_MSG_ADDON" then
        local prefix, msg, channel, sender = ...
        OnAddonMsg(prefix, msg, channel, sender)
    elseif event == "CHAT_MSG_SYSTEM" then
        local text = ...
        OnSystemMsg(text)
    end
end)

-- Shared throttle gate for the manual nudge actions below. Returns true (and
-- greys the button for the throttle window) when the caller may proceed.
local function ThrottleNudge()
    local now = GetTime()
    local wait = REMINDER_THROTTLE - (now - lastReminder)
    if wait > 0 then
        -- The button should already be disabled for this window; this is a
        -- backstop for callers that bypass it (e.g. the /cm roster remind sim).
        ns.Print(string.format("|cffFFD700[Gamba]|r Nudge throttled (%.0fs).", wait))
        return false
    end
    lastReminder = now
    ns.panel.SetNudgeEnabled(false)
    C_Timer.After(REMINDER_THROTTLE, function()
        ns.panel.SetNudgeEnabled(true)
    end)
    return true
end

-- Button action during the roll phase: whisper a random pending player to roll.
-- A private nudge rather than a channel callout so we don't spam the raid with
-- one straggler's name. Manual (button is a hardware event), so not leader-gated.
function roster.SendReminder()
    if not roster.HasPending() then
        ns.Print("|cffFFD700[Gamba]|r No one is pending a roll right now.")
        return
    end
    if not ThrottleNudge() then return end

    local name = roster.PickRandomPending()
    local msg = REMINDER_TEXTS[math.random(#REMINDER_TEXTS)]
        .. (stake and (" ( /roll " .. stake .. " )") or " ( /roll )")
    if ns.SandboxActive() then
        ns.Print("|cff00ccff[SANDBOX -> WHISPER " .. name .. "]|r " .. msg)
    else
        SendChatMessage(msg, "WHISPER", nil, name)
    end
    ns.DebugPrint("roster", "whispered reminder to " .. name)
end

-- Button action during registration: publicly nudge the host to start rolls.
-- Goes to the group channel (the social pressure is the point), addressing the
-- host by name since we captured them as the game's comm sender.
function roster.NudgeHost()
    if rolling then
        ns.Print("|cffFFD700[Gamba]|r Rolls are already open.")
        return
    end
    if not ThrottleNudge() then return end

    local text = HOST_NUDGE_TEXTS[math.random(#HOST_NUDGE_TEXTS)]
    local msg = host and (host .. ": " .. text) or text
    local channel = ns.CanonicalChannel() or gameChannel or "SAY"
    if ns.SandboxActive() then
        ns.Print("|cff00ccff[SANDBOX -> " .. channel .. "]|r " .. msg)
    else
        SendChatMessage(msg, channel)
    end
    ns.DebugPrint("roster", "nudged host " .. (host or "?") .. " on " .. channel)
end

-- Panel button dispatcher: which nudge fires depends on the current phase.
function roster.OnNudge()
    if rolling then
        roster.SendReminder()
    else
        roster.NudgeHost()
    end
end

-- One-line status (safe to call anytime; usually empty outside a game)
function roster.PrintStatus()
    local pending = roster.Pending()
    local total = 0
    for _ in pairs(players) do total = total + 1 end
    print("  |cffFFD700Roster|r: " .. total .. " signed up, " .. #pending .. " pending"
        .. (rolling and " (rolling)" or (hostNudgeReady and " (entries open, host nudge ready)" or " (entries open)"))
        .. (stake and (", stake 1-" .. stake) or "")
        .. (tie and (", " .. tie.type .. " tie: " .. table.concat(tie.names, ", ")) or "")
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
-- runs. A fake channel/host stand in for the real game's; reminders are
-- sandbox-safe, and SimDemo forces the sandbox so button clicks stay local.
local SIM_CHANNEL = "PARTY"
local SIM_HOST = "Hostcow"

function roster.SimStart(wager)
    OnAddonMsg(CG_PREFIX, "New_Game", SIM_CHANNEL, SIM_HOST)
    OnAddonMsg(CG_PREFIX, "SET_WAGER:" .. (wager or 100), SIM_CHANNEL, SIM_HOST)
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

-- Tie-breaker demo: signups all roll, two of them tie for the top (high) or
-- bottom (low), which re-opens the tied pair as pending; then they re-roll to
-- resolve. Watch the Nudge button reappear with the tied count.
function roster.SimTie(kind)
    kind = (kind == "low") and "low" or "high"
    ns.ForceSandbox(60)
    roster.SimStart(100)
    ns.Print("|cffFFD700[Gamba]|r roster " .. kind .. "-tie demo: game (1-100), adding signups...")
    C_Timer.After(1, function() roster.SimAdd("Beaglz") end)
    C_Timer.After(2, function() roster.SimAdd("Soffty") end)
    C_Timer.After(3, function() roster.SimAdd("Moistorcs") end)
    C_Timer.After(4, function()
        roster.SimClose()
        ns.Print("|cffFFD700[Gamba]|r entries closed; rolling into a " .. kind .. " tie...")
    end)
    if kind == "high" then
        C_Timer.After(5, function() roster.SimRoll("Moistorcs", 12) end)
        C_Timer.After(6, function() roster.SimRoll("Beaglz", 87) end)
        C_Timer.After(7, function() roster.SimRoll("Soffty", 87) end) -- ties the top -> re-opens both
        C_Timer.After(9, function() roster.SimRoll("Beaglz", 55) end)
        C_Timer.After(10, function() roster.SimRoll("Soffty", 91) end) -- resolves
    else
        C_Timer.After(5, function() roster.SimRoll("Beaglz", 87) end)
        C_Timer.After(6, function() roster.SimRoll("Soffty", 12) end)
        C_Timer.After(7, function() roster.SimRoll("Moistorcs", 12) end) -- ties the bottom -> re-opens both
        C_Timer.After(9, function() roster.SimRoll("Soffty", 33) end)
        C_Timer.After(10, function() roster.SimRoll("Moistorcs", 8) end) -- resolves
    end
    C_Timer.After(11, function()
        ns.Print("|cffFFD700[Gamba]|r tie resolved. /cm roster status to inspect.")
    end)
end

-- Host-nudge demo: start a game, add signups, and deliberately leave entries
-- open. The real HOST_NUDGE_DELAY timer fires and the button relabels to "Nudge
-- gamba host to start rolls"; clicking it calls the host out in channel (sandboxed).
function roster.SimHostNudge()
    ns.ForceSandbox(HOST_NUDGE_DELAY + 40) -- cover the wait plus a click or two
    roster.SimStart(100)
    roster.SimAdd("Beaglz")
    roster.SimAdd("Soffty")
    ns.Print("|cffFFD700[Gamba]|r host-nudge demo: entries left open (host " ..
        SIM_HOST .. "). In " .. HOST_NUDGE_DELAY .. "s the button becomes \"Nudge gamba" ..
        " host to start rolls\" -- click it (sandboxed) to call the host out in channel.")
end

-- Called from OnLoad after db is ready
function roster.Init()
    C_ChatInfo.RegisterAddonMessagePrefix(CG_PREFIX)
    ns.panel.SetNudgeHandler(function() roster.OnNudge() end)
    roster.ApplyState()
end
