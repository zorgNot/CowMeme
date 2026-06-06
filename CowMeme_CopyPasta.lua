local ADDON_NAME, ns = ...

ns.copypasta = {}
local cp = ns.copypasta

-- Registry: populated by individual content files
-- { [playerName] = { "line1", "line2", ... } }
cp.registry = {}

-- Register a player's content (called from each content file)
function cp.Register(playerName, lines)
    cp.registry[playerName] = lines
end

-- Pick a random line and send to chat
function cp.Send(playerName, channel)
    local name = playerName and playerName:gsub("^%l", string.upper) or ""
    local lines = cp.registry[name]

    if not lines or #lines == 0 then
        ns.Print("|cffFFD700[CopyPasta]|r No content registered for \"" .. name .. "\".")
        ns.Print("Available players: " .. cp.ListPlayers())
        return
    end

    local line = lines[math.random(1, #lines)]

    -- Auto-detect channel if not specified
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
end

-- Return a comma-separated list of registered player names
function cp.ListPlayers()
    local names = {}
    for k in pairs(cp.registry) do
        table.insert(names, k)
    end
    table.sort(names)
    return #names > 0 and table.concat(names, ", ") or "(none)"
end

-- Slash command: /copypasta <name> [channel]
local function HandleSlash(input)
    local name, channel = input:match("^(%S+)%s*(%S*)")

    if not name or name == "" or name:lower() == "help" then
        ns.Print("|cffFFD700[CopyPasta]|r commands:")
        print("  |cffffff00/copypasta <name>|r         - send a random pasta to party/raid/say")
        print("  |cffffff00/copypasta <name> g|r       - send to guild chat")
        print("  |cffffff00/copypasta <name> <1-9>|r   - send to a numbered channel")
        print("  |cffffff00/copypasta list|r            - list registered players")
        return
    end

    if name:lower() == "list" then
        ns.Print("|cffFFD700[CopyPasta]|r Registered players: " .. cp.ListPlayers())
        return
    end

    -- Numbered channel support
    if channel ~= "" and tonumber(channel) then
        local num = tonumber(channel)
        local line = cp.registry[name:gsub("^%l", string.upper)]
        if not line then
            ns.Print("|cffFFD700[CopyPasta]|r Unknown player \"" .. name .. "\".")
            return
        end
        local lines = line
        local msg = lines[math.random(1, #lines)]
        SendChatMessage(msg, "CHANNEL", nil, num)
        return
    end

    cp.Send(name, channel ~= "" and channel or nil)
end

SLASH_COPYPASTA1 = "/copypasta"
SLASH_COPYPASTA2 = "/cp"
SlashCmdList["COPYPASTA"] = HandleSlash
