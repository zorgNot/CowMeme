local ADDON_NAME, ns = ...

ns.copypasta = {}
local cp = ns.copypasta

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

-- Resolve an input name (any char) to a registry entry
local function Resolve(input)
    local key = cp.charIndex[input:lower()]
    return key and cp.registry[key], key
end

-- Pick a random line and send to chat
function cp.Send(input, channel)
    local entry, key = Resolve(input)

    if not entry or #entry.lines == 0 then
        ns.Print("|cffFFD700[CopyPasta]|r Unknown character \"" .. input .. "\".")
        ns.Print("Registered players: " .. cp.ListPlayers())
        return
    end

    local line = entry.lines[math.random(1, #entry.lines)]

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

-- Return a formatted list of players and their known characters
function cp.ListPlayers()
    local names = {}
    for k in pairs(cp.registry) do
        table.insert(names, k)
    end
    table.sort(names)
    return #names > 0 and table.concat(names, ", ") or "(none)"
end

-- Slash command: /copypasta <charname> [channel]
local function HandleSlash(input)
    local name, channel = input:match("^(%S+)%s*(%S*)")

    if not name or name == "" or name:lower() == "help" then
        ns.Print("|cffFFD700[CopyPasta]|r commands:")
        print("  |cffffff00/copypasta <name>|r         - send a random pasta (party/raid/say)")
        print("  |cffffff00/copypasta <name> g|r       - send to guild chat")
        print("  |cffffff00/copypasta <name> <1-9>|r   - send to a numbered channel")
        print("  |cffffff00/copypasta list|r            - list registered players and chars")
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
        local msg = "pastaThat " .. entry.lines[math.random(1, #entry.lines)] .. " {rt7}"
        SendChatMessage(msg, "CHANNEL", nil, num)
        return
    end

    cp.Send(name, channel ~= "" and channel or nil)
end

SLASH_COPYPASTA1 = "/copypasta"
SLASH_COPYPASTA2 = "/cp"
SlashCmdList["COPYPASTA"] = HandleSlash
