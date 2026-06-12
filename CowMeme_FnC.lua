local ADDON_NAME, ns = ...

ns.fnc = {}
local fnc = ns.fnc

-- Default FnC settings
ns.defaults.fnc = {
    active = false,
    batch  = false, -- batch milestone announcements (always on in raid)
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

-- Map current party/raid member names to their unit tokens
local function GetGroupMembers()
    local members = {}
    members[UnitName("player")] = "player"
    local prefix = IsInRaid() and "raid" or "party"
    local count  = IsInRaid() and GetNumGroupMembers() or GetNumSubgroupMembers()
    for i = 1, count do
        local unit = prefix .. i
        local name = UnitName(unit)
        if name then members[name] = unit end
    end
    return members
end

-- Per-character death milestone announcements.
-- %s is the subject including verb, e.g. "Bob is" or "Bob and Alice are".
local MILESTONES = {
    [3]  = "%s on a dying spree!",
    [5]  = "%s afterlifing!",
    [7]  = "%s on a mega dead streak!",
    [10] = "%s unBOPable!",
    [12] = "%s wicked dead!",
    [14] = "%s on a monster floor streak!",
    [15] = "%s FLOORMAXXING!",
}

-- "A is" / "A and B are" / "A, B and C are"
local function FormatSubject(names)
    if #names == 1 then
        return names[1] .. " is"
    end
    return table.concat(names, ", ", 1, #names - 1) .. " and " .. names[#names] .. " are"
end

local function AnnounceMilestone(names, count)
    local msg = string.format(MILESTONES[count], FormatSubject(names))
    ns.copypasta.SendToCanonicalChannel(msg .. " " .. count .. " {rt8}")
end

-- Batch mode: collect names per milestone for 1s, then announce together.
-- Explicit setting, or forced on in raid.
local pendingMilestones = {} -- { [count] = { name1, name2, ... } }

local function IsBatching()
    return ns.db.fnc.batch or IsInRaid()
end

local function QueueMilestone(name, count)
    if not pendingMilestones[count] then
        pendingMilestones[count] = {}
        C_Timer.After(1, function()
            local names = pendingMilestones[count]
            pendingMilestones[count] = nil
            if names and #names > 0 then
                AnnounceMilestone(names, count)
            end
        end)
    end
    table.insert(pendingMilestones[count], name)
end

local function AnnounceDeath(name, count)
    -- First blood = first recorded death of the run (never batched)
    local total = 0
    for _, c in pairs(ns.db.fnc.deaths) do
        total = total + c
    end
    if total == 1 then
        ns.copypasta.SendToCanonicalChannel("First blood! " .. name .. " BloodTrail  " .. count .. " {rt8}")
        return
    end

    if MILESTONES[count] then
        if IsBatching() then
            QueueMilestone(name, count)
        else
            AnnounceMilestone({ name }, count)
        end
    end
end

-- Record a player death
local function OnUnitDied(destName, destFlags)
    if bit.band(destFlags, COMBATLOG_OBJECT_TYPE_PLAYER) == 0 then return end
    if not destName then return end
    local unit = GetGroupMembers()[destName]
    if not unit then return end
    -- Feign Death fires UNIT_DIED too; a feigned hunter is still alive
    if UnitIsFeignDeath(unit) or UnitHealth(unit) > 0 then return end
    local deaths = ns.db.fnc.deaths
    deaths[destName] = (deaths[destName] or 0) + 1
    ns.Print("|cffFFD700[FnC]|r " .. destName .. " died. (" .. deaths[destName] .. ")")
    AnnounceDeath(destName, deaths[destName])
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
        ns.db.fnc = { active = false, batch = false, deaths = {} }
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

fncCommands["batch"] = function(arg)
    local mode = arg and arg:lower() or ""
    if mode == "on" then
        ns.db.fnc.batch = true
    elseif mode == "off" then
        ns.db.fnc.batch = false
    else
        ns.db.fnc.batch = not ns.db.fnc.batch
    end
    local state = ns.db.fnc.batch and "|cff00ff00ON|r" or "|cffff0000OFF|r"
    ns.Print("|cffFFD700[FnC]|r Batch mode " .. state .. " (always on in raid).")
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
    print("  |cffffff00/fnc batch [on|off]|r - batch milestone announcements (auto-on in raid)")
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
