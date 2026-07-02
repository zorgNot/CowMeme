local ADDON_NAME, ns = ...

ns.copypasta = {}
local cp = ns.copypasta

-- Default CopyPasta settings — merged into CowMemeDB on load
ns.defaults.copypasta = {
    gambaMonitor = false,
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

-- The canonical channel: the best non-protected channel available.
-- SAY/YELL are protected outside hardware events, so the order is
-- group > guild > nil (nil = print locally instead).
local function GetCanonicalChannel()
    if IsInRaid() then
        return "RAID"
    elseif IsInGroup() then
        return "PARTY"
    elseif IsInGuild() then
        return "GUILD"
    end
    return nil
end

-- Send a finished message to the canonical channel, or print it
-- locally if none is available. Sandbox mode prints locally instead.
-- Only the elected sync leader speaks, so guildies running the addon
-- don't all announce the same event.
function cp.SendToCanonicalChannel(line)
    local channel = GetCanonicalChannel()
    if ns.SandboxActive() then
        ns.Print("|cff00ccff[SANDBOX -> " .. (channel or "no channel") .. "]|r " .. line)
        return
    end
    if not ns.sync.IsLeader() then
        ns.DebugPrint("cp", "suppressed (leader is " .. ns.sync.GetLeader() .. "): " .. line)
        return
    end
    if channel then
        ns.DebugPrint("cp", "canonical channel " .. channel .. ": " .. line)
        SendChatMessage(line, channel)
    else
        ns.Print("|cffFFD700[CopyPasta]|r (no valid channel) " .. line)
    end
end

-- Resolve an input name (any char) to a registry entry
local function Resolve(input)
    local key = cp.charIndex[input:lower()]
    return key and cp.registry[key], key
end

-- Panel display when a pasta fires. Registry entries may carry an optional
-- per-player image field; the addon icon is the fallback.
local DEFAULT_PASTA_IMAGE = "Interface\\AddOns\\CowMeme\\images\\image"
local PASTA_PANEL_DURATION = 8

local function ShowPastaOnPanel(key, entry)
    ns.panel.Display({
        image = entry.image or DEFAULT_PASTA_IMAGE,
        text = "|cffFFD700" .. key .. "|r got pasta'd!",
        duration = PASTA_PANEL_DURATION,
    })
end

-- Pick a random line and send to chat
function cp.Send(input, channel)
    local entry, key = Resolve(input)

    if not entry or #entry.lines == 0 then
        ns.Print("|cffFFD700[CopyPasta]|r Unknown character \"" .. input .. "\".")
        ns.Print("Registered players: " .. cp.ListPlayers())
        return
    end

    local line = BuildMessage(entry.lines[math.random(1, #entry.lines)])

    if not channel or channel == "" then
        if IsInRaid() then
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
    ShowPastaOnPanel(key, entry)
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

local gambaFrame = CreateFrame("Frame", "CowMemeGambaFrame", UIParent)
local activeHost = nil -- sender of the current game's start message, or nil

-- Top rolls for the active gamba game: first /roll per player counts
local gambaRolls = {} -- { [playerName] = roll }
local TOP_ROLLS_SHOWN = 3

local function UpdateRollPanel()
    local list = {}
    for name, roll in pairs(gambaRolls) do
        table.insert(list, { name = name, roll = roll })
    end
    table.sort(list, function(a, b) return a.roll > b.roll end)
    local lines = { "|cffFFD700Gamba top rolls|r" }
    if #list == 0 then
        table.insert(lines, "waiting for rolls...")
    end
    for i = 1, math.min(TOP_ROLLS_SHOWN, #list) do
        table.insert(lines, i .. ". " .. list[i].name .. " - " .. list[i].roll)
    end
    ns.panel.Display({ text = table.concat(lines, "\n") })
end

-- System messages: track "/roll" results while a game is active
local function OnSystemMsg(msg)
    if not activeHost then return end
    local name, roll, low = msg:match("^(%S+) rolls (%d+) %((%d+)%-%d+%)$")
    if not name or low ~= "1" then return end
    if gambaRolls[name] == nil then -- first roll counts; rerolls ignored
        gambaRolls[name] = tonumber(roll)
        ns.DebugPrint("cp", "gamba: roll recorded: " .. name .. " = " .. roll)
        UpdateRollPanel()
    else
        ns.DebugPrint("cp", "gamba: reroll ignored: " .. name)
    end
end

local function OnGambaChat(msg, sender)
    -- A new game announces itself; remember its host
    if msg:find(GAMBA_START_MSG, 1, true) then
        activeHost = sender
        wipe(gambaRolls)
        ns.DebugPrint("cp", "gamba: new game started, host = " .. tostring(sender))
        UpdateRollPanel()
        return
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

    -- Strip realm suffix if present (Name-Realm)
    name = name:match("^([^%-]+)") or name
    local entry, key = Resolve(name)
    if not entry or #entry.lines == 0 then
        ns.DebugPrint("cp", "gamba: matched \"" .. name .. "\" but no registered player")
        return
    end

    ns.DebugPrint("cp", "gamba: \"" .. name .. "\" resolved to " .. key ..
        ", firing pasta; game ends")
    local line = BuildMessage(entry.lines[math.random(1, #entry.lines)])
    cp.SendToCanonicalChannel(line)
    ShowPastaOnPanel(key, entry)

    -- Game over: forget the host until the next game starts
    activeHost = nil
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

-- Register/unregister the gamba monitor based on the global addon enable flag
-- and the gambaMonitor setting. Does not change ns.db.copypasta.gambaMonitor.
function cp.ApplyState()
    if ns.db.enabled and ns.db.copypasta.gambaMonitor then
        RegisterGambaEvents()
    else
        UnregisterGambaEvents()
    end
end

function cp.EnableGamba()
    ns.db.copypasta.gambaMonitor = true
    cp.ApplyState()
    ns.Print("|cffFFD700[CopyPasta]|r Gamba monitor |cff00ff00ON|r.")
end

function cp.DisableGamba()
    ns.db.copypasta.gambaMonitor = false
    cp.ApplyState()
    ns.Print("|cffFFD700[CopyPasta]|r Gamba monitor |cffff0000OFF|r.")
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
    print("  |cffffff00/cp gamba [on|off]|r  - toggle the 'owes' chat monitor")
    if ns.db.debug then
        print("  |cffffff00/cp simgamba <chat line>|r - (debug) feed a fake line to the gamba monitor")
        print("  |cffffff00/cp simroll <name> <n>|r   - (debug) feed a fake /roll to the top-roll tracker")
    end
end

-- One-line status summary, pulled into the /cm main menu
function cp.PrintStatus()
    local gamba = ns.db.copypasta.gambaMonitor and "|cff00ff00ON|r" or "|cffff0000OFF|r"
    local n = 0
    for _ in pairs(cp.registry) do n = n + 1 end
    print("  |cffFFD700CopyPasta|r: gamba monitor " .. gamba .. ", " .. n .. " players")
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
            print("  Start a game first, then an owes line from the same sender, e.g.:")
            print("    |cffffff00/cp simgamba CrossGambling: A new game has been started!|r")
            print("    |cffffff00/cp simgamba Moistorcs owes 50g|r")
            return
        end
        ns.ForceSandbox(3)
        ns.Print("|cffFFD700[CopyPasta]|r sim: feeding line to gamba monitor (as SimHost): " .. line)
        OnGambaChat(line, "SimHost")
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
        local entry, key = Resolve(name)
        if not entry then
            ns.Print("|cffFFD700[CopyPasta]|r Unknown character \"" .. name .. "\".")
            return
        end
        local msg = BuildMessage(entry.lines[math.random(1, #entry.lines)])
        SendChatMessage(msg, "CHANNEL", nil, num)
        ShowPastaOnPanel(key, entry)
        return
    end

    cp.Send(name, channel ~= "" and channel or nil)
end

SLASH_COPYPASTA1 = "/copypasta"
SLASH_COPYPASTA2 = "/cp"
SlashCmdList["COPYPASTA"] = HandleSlash
