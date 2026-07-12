local ADDON_NAME, ns = ...

ns.copypasta = {}
local cp = ns.copypasta

-- Default CopyPasta settings — merged into CowMemeDB on load
-- gambaMonitor = willing to announce gamba pastas to chat. Detection and
-- panel display are always on; this only gates speech, and the elected
-- announcer among willing peers prevents multi-client spam.
ns.defaults.copypasta = {
    gambaMonitor = true,
}

-- Registry: populated by individual content files
-- {
--   [playerKey] = {
--     chars = { "MainName", "Alt1", "Alt2", ... },
--     lines = { "line1", "line2", ... },
--   }
-- }
cp.registry = {}

-- Reverse lookup: char name (lowercase) -> playerKey
cp.charIndex = {}

-- Register a player with their characters and lines
function cp.Register(playerKey, data)
    cp.registry[playerKey] = data
    cp.charIndex[playerKey:lower()] = playerKey
    for _, charName in ipairs(data.chars) do
        cp.charIndex[charName:lower()] = playerKey
    end
end

-- Build the final chat message from a raw line
local function BuildMessage(line)
    return "pastaThat " .. line .. " {rt7}"
end

-- Chat announcing lives in core: ns.Announce(line, "G") — leader-gated
-- among willing announcers. Panel display never routes through it.

-- Resolve an input name (any char) to a registry entry
local function Resolve(input)
    local key = cp.charIndex[input:lower()]
    return key and cp.registry[key], key
end

-- Panel display when a pasta fires. Registry entries may carry an optional
-- per-player image field; the addon icon is the fallback.
local DEFAULT_PASTA_IMAGE = "Interface\\AddOns\\CowMeme\\images\\image"
local PASTA_PANEL_DURATION = 15

-- Loss phrases shown after the player's name on the panel; one picked at
-- random per pasta. Add more entries here.
local LOSS_PHRASES = {
    "donated to the guild economy",
    "financially outplayed",
    "gold entered the shadow realm",
    "wallet diff",
    "got EV'd",
    "expected value claimed another victim",
    "performed liquidity transfer",
    "converted gold into vibes",
    "became raid-funded",
    "got casino'd",
    "lost to probability mechanics",
    "gold parsed gray",
    "invested aggressively",
    "executed negative ROI rotation",
    "gamba claimed another soul",
    "lost the 50/50 (it was 90/10)",
    "funded the jackpot",
    "became someone else's payout",
    "performed charitable donations to Moist",
    "bankroll entered execute phase",
    "rolled for bankruptcy",
    "gold evaporated on contact",
    "economically griefed himself",
    "sent his gold to college",
    "hit the reverse jackpot",
    "got statistically dismantled",
    "financially crowd controlled",
    "lost the GDP check",
    "gold got redistributed",
    "wealth transferred to stronger hands",
}

-- Pick a loss phrase. Seeded with the host's owes line + server date so
-- every client computes the same phrase for the same loss, but the pick
-- still varies day to day and loss to loss.
local function LossPhrase(seed)
    if #LOSS_PHRASES == 0 then return "got pasta'd!" end
    if not seed then
        return LOSS_PHRASES[math.random(#LOSS_PHRASES)]
    end
    local s = seed .. date("!%Y-%m-%d", GetServerTime())
    local h = 5381
    for i = 1, #s do
        h = (h * 33 + s:byte(i)) % 2147483647
    end
    return LOSS_PHRASES[(h % #LOSS_PHRASES) + 1]
end

-- Local-only display: every client renders this itself; never leader-gated.
-- entry may be nil for an unregistered ower; the addon icon is the fallback.
local function ShowPastaOnPanel(key, entry, seed)
    ns.panel.Display({
        image = (entry and entry.image) or DEFAULT_PASTA_IMAGE,
        text = "|cffFFD700" .. key .. "|r " .. LossPhrase(seed),
        duration = PASTA_PANEL_DURATION,
    })
end

-- Pick a random line and send to chat. Manual sends are a personal act:
-- they go to the requested destination only, with no panel display.
function cp.Send(input, channel)
    local entry = Resolve(input)

    if not entry or #entry.lines == 0 then
        ns.Print("|cffFFD700[CopyPasta]|r Unknown character \"" .. input .. "\".")
        ns.Print("Registered players: " .. cp.ListPlayers())
        return
    end

    local line = BuildMessage(entry.lines[math.random(1, #entry.lines)])

    if not channel or channel == "" then
        -- Auto-detect; instanced groups (BG/arena) only accept INSTANCE_CHAT
        if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
            channel = "INSTANCE_CHAT"
        elseif IsInRaid() then
            channel = "RAID"
        elseif IsInGroup() then
            channel = "PARTY"
        else
            channel = "SAY"
        end
    elseif channel == "g" then
        channel = "GUILD"
    end

    SendChatMessage(line, channel)
end

-- Gamba monitor: watch chat for "<character> owes ..." and fire a
-- copypasta for the matching registered player
local GAMBA_CHAT_EVENTS = {
    "CHAT_MSG_SAY",
    "CHAT_MSG_YELL",
    "CHAT_MSG_PARTY",
    "CHAT_MSG_PARTY_LEADER",
    "CHAT_MSG_RAID",
    "CHAT_MSG_RAID_LEADER",
    "CHAT_MSG_GUILD",
    "CHAT_MSG_CHANNEL",
    "CHAT_MSG_SYSTEM", -- /roll results, for top-roll tracking
}

-- The CrossGambling addon announces this when a game opens; its sender is
-- the game host, the only player whose "owes" lines we trust.
local GAMBA_START_MSG = "CrossGambling: A new game has been started!"
-- The host announces this when entries close; only then do rolls count.
local GAMBA_ROLL_MSG = "Entries have closed. Roll now!"

local gambaFrame = CreateFrame("Frame", "CowMemeGambaFrame", UIParent)
local activeHost = nil -- sender of the current game's start message, or nil
local rollsOpen = false -- true once the host closes entries and calls to roll
local gambaStake = nil -- max roll of the current game, parsed from the start line

-- Roll tracking for the active gamba game: first /roll per player counts
local gambaRolls = {} -- { [playerName] = roll }
local FOOTER_DURATION = 1.5 -- seconds the "get fucked" callout stays visible

-- footer: optional one-shot callout that auto-clears after FOOTER_DURATION
local function UpdateRollPanel(footer)
    local topName, topRoll, botName, botRoll
    for name, roll in pairs(gambaRolls) do
        if not topRoll or roll > topRoll then topName, topRoll = name, roll end
        if not botRoll or roll < botRoll then botName, botRoll = name, roll end
    end
    local lines = { "|cffFFD700Gamba|r" .. (gambaStake and (" (1-" .. gambaStake .. ")") or "") }
    if not topRoll then
        table.insert(lines, rollsOpen and "Waiting for rolls..." or "Waiting for entries...")
    else
        table.insert(lines, "Top: " .. topName .. " - " .. topRoll)
        table.insert(lines, "Bottom: " .. botName .. " - " .. botRoll)
        table.insert(lines, "Amount: " .. (topRoll - botRoll))
    end
    ns.panel.Display({
        text = table.concat(lines, "\n"),
        footer = footer,
        footerDuration = footer and FOOTER_DURATION or nil,
    })
end

-- System messages: track "/roll" results, but only after entries have closed
-- and only rolls made for the game's stake
local function OnSystemMsg(msg)
    if not activeHost then return end
    if not rollsOpen then return end
    local name, roll, low, high = msg:match("^(%S+) rolls (%d+) %((%d+)%-(%d+)%)$")
    if not name or low ~= "1" then return end
    if gambaStake and tonumber(high) ~= gambaStake then
        ns.DebugPrint("cp", "gamba: roll ignored (1-" .. high .. ", game is 1-" .. gambaStake .. "): " .. name)
        return
    end
    if gambaRolls[name] ~= nil then -- first roll counts; rerolls ignored
        ns.DebugPrint("cp", "gamba: reroll ignored: " .. name)
        return
    end
    local value = tonumber(roll)
    -- Find the current top before adding this roll; a strictly higher roll
    -- dethrones it and the old top-holder gets the footer callout.
    local oldTopName, oldTopRoll
    for n, r in pairs(gambaRolls) do
        if not oldTopRoll or r > oldTopRoll then oldTopName, oldTopRoll = n, r end
    end
    gambaRolls[name] = value
    local footer
    if oldTopRoll and value > oldTopRoll then
        footer = oldTopName .. " get fucked"
        ns.DebugPrint("cp", "gamba: new top " .. name .. " (" .. value .. "), " .. oldTopName .. " dethroned")
    end
    ns.DebugPrint("cp", "gamba: roll recorded: " .. name .. " = " .. roll)
    UpdateRollPanel(footer)
end

local function OnGambaChat(msg, sender)
    -- A new game announces itself; remember its host
    if msg:find(GAMBA_START_MSG, 1, true) then
        activeHost = sender
        rollsOpen = false
        gambaStake = nil -- unknown until the host's "Wager - Ng" line arrives
        wipe(gambaRolls)
        ns.panel.SetHeader(nil) -- clear last game's owes echo
        ns.DebugPrint("cp", "gamba: new game started, host = " .. tostring(sender) ..
            ", stake = " .. (gambaStake and ("1-" .. gambaStake) or "unknown"))
        UpdateRollPanel()
        return
    end

    -- Entries close: from here on, rolls count
    if msg:find(GAMBA_ROLL_MSG, 1, true) then
        if sender == activeHost then
            rollsOpen = true
            ns.DebugPrint("cp", "gamba: entries closed, rolls now counting")
            UpdateRollPanel() -- flip the panel to "Waiting for rolls..."
        end
        return
    end

    -- The host announces the stake right after the start line, e.g.
    -- "Game Mode - Classic - Wager - 1,000g". Capture it so only rolls at that
    -- stake count; addCommas may comma-group the amount, so strip commas.
    if sender == activeHost then
        local wager = msg:match("Wager %- ([%d,]+)g")
        if wager then
            gambaStake = tonumber((wager:gsub(",", "")))
            ns.DebugPrint("cp", "gamba: stake set to 1-" .. tostring(gambaStake))
            UpdateRollPanel() -- show the stake in the panel title
            return
        end
    end

    local name = msg:match("(%S+) owes ")
    if not name then return end

    -- Only the current game's host can trigger a pasta
    if not activeHost then
        ns.DebugPrint("cp", "gamba: \"" .. name .. " owes\" ignored (no active game)")
        return
    end
    if sender ~= activeHost then
        ns.DebugPrint("cp", "gamba: \"owes\" from " .. tostring(sender) ..
            " ignored (host is " .. activeHost .. ")")
        return
    end

    -- Echo the host's owes line at the top of the panel for up to a minute,
    -- regardless of whether the ower is a registered pasta target.
    ns.panel.SetHeader(msg, 60)
    ns.DebugPrint("cp", "gamba: header set to host owes line")

    -- Strip realm suffix if present (Name-Realm)
    name = name:match("^([^%-]+)") or name
    local entry, key = Resolve(name)

    -- Local display first, on every client, independent of announcing. Show a
    -- loss card whether or not the ower is registered: a registered player uses
    -- their key + optional image, an unregistered ower falls back to their raw
    -- name and the default image. Either way this gives the card a duration so
    -- the panel self-clears instead of sitting on the roll tracker.
    ShowPastaOnPanel(key or name, entry, msg)

    -- Chat only when there's a registered pasta to send and this client is
    -- willing; the election among willing announcers ensures exactly one speaks.
    if entry and #entry.lines > 0 then
        ns.DebugPrint("cp", "gamba: \"" .. name .. "\" resolved to " .. key ..
            ", firing pasta; game ends")
        if ns.db.copypasta.gambaMonitor then
            ns.Announce(BuildMessage(entry.lines[math.random(1, #entry.lines)]), "G")
        else
            ns.DebugPrint("cp", "gamba: announcing off locally; pasta not sent")
        end
    else
        ns.DebugPrint("cp", "gamba: \"" .. name .. "\" not registered; default card only, game ends")
    end

    -- Game over: forget the host until the next game starts
    activeHost = nil
    rollsOpen = false
    gambaStake = nil
end

gambaFrame:SetScript("OnEvent", function(self, event, msg, sender)
    if event == "CHAT_MSG_SYSTEM" then
        OnSystemMsg(msg)
    else
        OnGambaChat(msg, sender)
    end
end)

local function RegisterGambaEvents()
    for _, event in ipairs(GAMBA_CHAT_EVENTS) do
        gambaFrame:RegisterEvent(event)
    end
end

local function UnregisterGambaEvents()
    for _, event in ipairs(GAMBA_CHAT_EVENTS) do
        gambaFrame:UnregisterEvent(event)
    end
end

-- Gamba detection is always on while the addon is enabled: every client
-- tracks games and renders the panel locally by default. The gambaMonitor
-- setting only gates announcing to chat, checked at the Announce call site.
function cp.ApplyState()
    if ns.db.enabled then
        RegisterGambaEvents()
    else
        UnregisterGambaEvents()
    end
end

-- The one writer for announce-willingness: stores the setting and advertises
-- the changed G flag promptly. Slash wrappers add chat feedback; the options
-- panel calls this directly.
function cp.SetAnnouncing(v)
    ns.db.copypasta.gambaMonitor = v
    ns.sync.Ping()
end

function cp.EnableGamba()
    cp.SetAnnouncing(true)
    ns.Print("|cffFFD700[CopyPasta]|r Gamba announcing |cff00ff00ON|r.")
end

function cp.DisableGamba()
    cp.SetAnnouncing(false)
    ns.Print("|cffFFD700[CopyPasta]|r Gamba announcing |cffff0000OFF|r (panel display stays on).")
end

-- Called from OnLoad after db is ready
function cp.Init()
    if not ns.db.copypasta then
        ns.db.copypasta = { gambaMonitor = false }
    end
    cp.ApplyState()
end

-- Return a formatted list of players and their known characters
function cp.ListPlayers()
    local names = {}
    for k in pairs(cp.registry) do
        table.insert(names, k)
    end
    table.sort(names)
    return #names > 0 and table.concat(names, ", ") or "(none)"
end

-- Printed by /cp help and pulled into the /cm main menu
function cp.PrintCommands()
    ns.Print("|cffFFD700[CopyPasta]|r commands:")
    print("  |cffffff00/cp <name>|r         - send a random pasta (party/raid/say)")
    print("  |cffffff00/cp <name> g|r       - send to guild chat")
    print("  |cffffff00/cp <name> <1-9>|r   - send to a numbered channel")
    print("  |cffffff00/cp list|r            - list registered players and chars")
    print("  |cffffff00/cp gamba [on|off]|r  - toggle announcing gamba pastas to chat (panel display is always on)")
    if ns.db.debug then
        print("  |cffffff00/cp simgamba <chat line>|r - (debug) feed a fake line to the gamba monitor")
        print("  |cffffff00/cp simroll <name> <n>|r   - (debug) feed a fake /roll to the top-roll tracker")
        print("  |cffffff00/cp simdemo [name]|r       - (debug) run the gamba demo, optionally targeting a player")
    end
end

-- One-line status summary, pulled into the /cm main menu
function cp.PrintStatus()
    local gamba = ns.db.copypasta.gambaMonitor and "|cff00ff00ON|r" or "|cffff0000OFF|r"
    local n = 0
    for _ in pairs(cp.registry) do n = n + 1 end
    print("  |cffFFD700CopyPasta|r: gamba announcing " .. gamba .. ", " .. n .. " players")
end

-- Slash command: /copypasta <charname> [channel]
local function HandleSlash(input)
    -- "/cp simgamba <chat line>" needs the raw remainder, so handle it first
    local lowerInput = input:lower()
    if lowerInput == "simgamba" or lowerInput:match("^simgamba%s") then
        if not (ns.db and ns.db.debug) then
            ns.Print("|cffFFD700[CopyPasta]|r Debug mode required: /cm debug on")
            return
        end
        local line = strtrim(input:sub(#"simgamba" + 1))
        if line == "" then
            ns.Print("|cffFFD700[CopyPasta]|r Usage: /cp simgamba <chat line>  (fed as sender 'SimHost')")
            print("  Start a game, close entries, then rolls/owes -- all same sender, e.g.:")
            print("    |cffffff00/cp simgamba CrossGambling: A new game has been started!|r")
            print("    |cffffff00/cp simgamba Entries have closed. Roll now!|r")
            print("    |cffffff00/cp simgamba Moistorcs owes 50g|r")
            return
        end
        ns.ForceSandbox(3)
        ns.Print("|cffFFD700[CopyPasta]|r sim: feeding line to gamba monitor (as SimHost): " .. line)
        OnGambaChat(line, "SimHost")
        return
    end

    -- "/cp simdemo [name]" runs the full gamba flow: game start, a few rolls,
    -- then the host's "owes" line firing a pasta -- staggered so it's watchable.
    -- An optional target name makes that player the loser who gets pasta'd.
    if lowerInput == "simdemo" or lowerInput:match("^simdemo%s") then
        if not (ns.db and ns.db.debug) then
            ns.Print("|cffFFD700[CopyPasta]|r Debug mode required: /cm debug on")
            return
        end
        local target = strtrim(input:sub(#"simdemo" + 1))
        if target == "" then target = "Moistorcs" end
        local entry, key = Resolve(target)
        if not entry then
            ns.Print("|cffFFD700[CopyPasta]|r simdemo: unknown target \"" .. target .. "\".")
            ns.Print("Registered players: " .. cp.ListPlayers())
            return
        end
        ns.Print("|cffFFD700[CopyPasta]|r sim: running gamba demo targeting " .. key .. " (sandboxed, ~6s)...")
        ns.ForceSandbox(9)
        OnGambaChat(GAMBA_START_MSG .. " (1-100)", "SimHost")
        OnGambaChat(GAMBA_ROLL_MSG, "SimHost") -- close entries so rolls count
        -- Fixed high rollers, skipping any that collide with the target so the
        -- target's low roll below isn't dropped as a reroll.
        local t = 1
        for _, r in ipairs({ { "Beaglz", 42 }, { "Bagelbob", 43 }, { "Soffty", 87 } }) do
            if r[1]:lower() ~= target:lower() then
                local nm, rv = r[1], r[2]
                C_Timer.After(t, function() OnSystemMsg(nm .. " rolls " .. rv .. " (1-100)") end)
                t = t + 1
            end
        end
        -- Target is the low roller / loser, then owes and gets pasta'd
        C_Timer.After(t, function() OnSystemMsg(target .. " rolls 3 (1-100)") end)
        C_Timer.After(t + 1, function()
            ns.ForceSandbox(3)
            OnGambaChat(target .. " owes 84g to a very long name", "SimHost")
        end)
        return
    end

    -- "/cp simroll <name> <n>" feeds a fake /roll to the top-roll tracker
    if lowerInput:match("^simroll") then
        if not (ns.db and ns.db.debug) then
            ns.Print("|cffFFD700[CopyPasta]|r Debug mode required: /cm debug on")
            return
        end
        local rollName, rollValue = input:match("^%S+%s+(%S+)%s+(%d+)")
        if not rollName then
            ns.Print("|cffFFD700[CopyPasta]|r Usage: /cp simroll <name> <number>  (needs an active game; see /cp simgamba)")
            return
        end
        ns.Print("|cffFFD700[CopyPasta]|r sim: roll " .. rollName .. " = " .. rollValue)
        OnSystemMsg(rollName .. " rolls " .. rollValue .. " (1-100)")
        return
    end

    local name, channel = input:match("^(%S+)%s*(%S*)")

    if not name or name == "" or name:lower() == "help" then
        cp.PrintCommands()
        return
    end

    if name:lower() == "status" then
        cp.PrintStatus()
        return
    end

    if name:lower() == "gamba" then
        local mode = channel:lower()
        if mode == "on" then
            cp.EnableGamba()
        elseif mode == "off" then
            cp.DisableGamba()
        elseif ns.db.copypasta.gambaMonitor then
            cp.DisableGamba()
        else
            cp.EnableGamba()
        end
        return
    end

    if name:lower() == "list" then
        ns.Print("|cffFFD700[CopyPasta]|r Registered players:")
        local keys = {}
        for k in pairs(cp.registry) do table.insert(keys, k) end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local entry = cp.registry[k]
            print("  |cffffff00" .. k .. "|r -> " .. table.concat(entry.chars, ", "))
        end
        return
    end

    if channel ~= "" and tonumber(channel) then
        local num = tonumber(channel)
        local entry = Resolve(name)
        if not entry then
            ns.Print("|cffFFD700[CopyPasta]|r Unknown character \"" .. name .. "\".")
            return
        end
        local msg = BuildMessage(entry.lines[math.random(1, #entry.lines)])
        SendChatMessage(msg, "CHANNEL", nil, num)
        return
    end

    cp.Send(name, channel ~= "" and channel or nil)
end

SLASH_COPYPASTA1 = "/copypasta"
SLASH_COPYPASTA2 = "/cp"
SlashCmdList["COPYPASTA"] = HandleSlash
