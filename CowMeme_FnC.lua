local ADDON_NAME, ns = ...

ns.fnc = {}
local fnc = ns.fnc

-- Default FnC settings
ns.defaults.fnc = {
    active = false,
    deaths = {}, -- { [playerName] = count }
}

local fncFrame = CreateFrame("Frame", "CowMemeFnCFrame", UIParent)

-- Start a new FnC run
function fnc.New()
    ns.db.fnc.active = true
    ns.db.fnc.deaths = {}
    ns.Print("|cffFFD700[Fast and Clean]|r Run started. Good luck!")
    fncFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
end

-- Resume tracking without clearing deaths
function fnc.Start()
    ns.db.fnc.active = true
    fncFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    ns.Print("|cffFFD700[Fast and Clean]|r Tracking resumed.")
end

-- Reset deaths without stopping
function fnc.Reset()
    ns.db.fnc.deaths = {}
    ns.Print("|cffFFD700[Fast and Clean]|r Deaths reset.")
end

-- Stop tracking
function fnc.Stop()
    ns.db.fnc.active = false
    fncFrame:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    ns.Print("|cffFFD700[Fast and Clean]|r Run stopped.")
end

-- Announce report to group/raid/say, guild, or a numbered channel
-- target: nil = auto, "g" = guild, "1"-"9" = channel number
function fnc.Report(target)
    local deaths = ns.db.fnc.deaths
    local list = {}
    for name, count in pairs(deaths) do
        table.insert(list, { name = name, count = count })
    end
    table.sort(list, function(a, b) return a.count > b.count end)

    local channel, channelNum
    local t = target and strtrim(target):lower() or ""

    if t == "g" then
        channel = "GUILD"
    elseif t ~= "" and tonumber(t) then
        channel = "CHANNEL"
        channelNum = tonumber(t)
    else
        -- Auto-detect
        if IsInRaid() then
            channel = "RAID"
        elseif IsInGroup() then
            channel = "PARTY"
        else
            channel = "SAY"
        end
    end

    local function Send(msg)
        if channelNum then
            SendChatMessage(msg, channel, nil, channelNum)
        else
            SendChatMessage(msg, channel)
        end
    end

    local lines = {}
    if #list == 0 then
        table.insert(lines, "[FnC] No deaths recorded. Clean run!")
    else
        table.insert(lines, "[FnC] Death Report:")
        for i, entry in ipairs(list) do
            table.insert(lines, string.format("  %d. %s - %d death%s",
                i, entry.name, entry.count, entry.count == 1 and "" or "s"))
        end
    end

    if channel == "GUILD" then
        local i = 1
        local function SendNext()
            if i > #lines then return end
            Send(lines[i])
            i = i + 1
            if i <= #lines then
                C_Timer.After(0.15, SendNext)
            end
        end
        SendNext()
    else
        for _, msg in ipairs(lines) do Send(msg) end
    end
end

-- Build a set of current party/raid member names
local function GetGroupMembers()
    local members = {}
    members[UnitName("player")] = true
    local prefix = IsInRaid() and "raid" or "party"
    local count  = IsInRaid() and GetNumGroupMembers() or GetNumSubgroupMembers()
    for i = 1, count do
        local name = UnitName(prefix .. i)
        if name then members[name] = true end
    end
    return members
end

-- Record a player death
local function OnUnitDied(destName, destFlags)
    if bit.band(destFlags, COMBATLOG_OBJECT_TYPE_PLAYER) == 0 then return end
    if not destName then return end
    if not GetGroupMembers()[destName] then return end
    local deaths = ns.db.fnc.deaths
    deaths[destName] = (deaths[destName] or 0) + 1
    ns.Print("|cffFFD700[FnC]|r " .. destName .. " died. (" .. deaths[destName] .. ")")
end

fncFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        local timestamp, subevent, hideCaster,
              sourceGUID, sourceName, sourceFlags, sourceRaidFlags,
              destGUID, destName, destFlags = CombatLogGetCurrentEventInfo()
        if subevent == "UNIT_DIED" then
            OnUnitDied(destName, destFlags)
        end
    end
end)

-- Resume tracking if it was active before logout
function fnc.Init()
    if not ns.db.fnc then
        ns.db.fnc = { active = false, deaths = {} }
    end
    if ns.db.fnc.active then
        fncFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
        ns.Print("|cffFFD700[Fast and Clean]|r Resuming active run.")
    end
end

-- Slash command handler: /fnc <cmd>
local fncCommands = {}

fncCommands["delete"] = function(arg)
    if not arg or arg == "" then
        ns.Print("|cffFFD700[FnC]|r Usage: /fnc delete <name>")
        return
    end
    local name = arg:gsub("^%l", string.upper) -- normalize capitalization
    if ns.db.fnc.deaths[name] then
        ns.db.fnc.deaths[name] = nil
        ns.Print("|cffFFD700[FnC]|r Removed " .. name .. " from the death list.")
    else
        ns.Print("|cffFFD700[FnC]|r " .. name .. " not found in the death list.")
    end
end

fncCommands["new"] = function() fnc.New() end
fncCommands["start"] = function() fnc.Start() end
fncCommands["reset"] = function() fnc.Reset() end
fncCommands["stop"] = function() fnc.Stop() end
fncCommands["report"] = function(arg) fnc.Report(arg) end

fncCommands["help"] = function()
    ns.Print("|cffFFD700[Fast and Clean]|r commands:")
    print("  |cffffff00/fnc new|r     - start a new run (clears deaths)")
    print("  |cffffff00/fnc start|r   - resume tracking without resetting")
    print("  |cffffff00/fnc reset|r   - reset death counts")
    print("  |cffffff00/fnc report|r    - announce to party/raid/say (auto)")
    print("  |cffffff00/fnc report g|r  - announce to guild chat")
    print("  |cffffff00/fnc report 1|r  - announce to channel number")
    print("  |cffffff00/fnc delete <name>|r - remove a player from the list")
    print("  |cffffff00/fnc stop|r    - stop tracking")
    print("  |cffffff00/fnc help|r    - show this message")
end

local function HandleFnCSlash(input)
    local cmd, arg = strtrim(input):match("^(%S*)%s*(.*)")
    cmd = cmd:lower()
    local handler = fncCommands[cmd] or fncCommands["help"]
    handler(arg ~= "" and arg or nil)
end

SLASH_COWMEMEFNC1 = "/fnc"
SlashCmdList["COWMEMEFNC"] = HandleFnCSlash
