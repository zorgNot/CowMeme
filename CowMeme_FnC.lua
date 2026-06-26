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
    [3]  = "%s ON A DYING SPREE!",
    [5]  = "%s AFTERLIFING!",
    [7]  = "%s ON A MEGA DEAD STREAK!",
    [10] = "%s UNBOPABLE!",
    [12] = "%s WICKED DEAD!",
    [14] = "%s ON A MONSTER FLOOR STREAK!",
    [15] = "%s FLOORMAXXING!",
}

-- entries: { { name = "Bob", cause = "slain by ... (fire)" }, ... }
-- "Bob, cause is" / "Bob, cause and Alice, cause are"
local function FormatSubject(entries)
    local parts = {}
    for i, e in ipairs(entries) do
        parts[i] = e.name .. ", " .. e.cause
    end
    if #parts == 1 then
        return parts[1] .. " is"
    end
    return table.concat(parts, ", ", 1, #parts - 1) .. " and " .. parts[#parts] .. " are"
end

local function AnnounceMilestone(entries, count)
    local msg = string.format(MILESTONES[count], FormatSubject(entries))
    ns.copypasta.SendToCanonicalChannel(msg .. " " .. count .. " {rt8}")
end

-- Cause-of-death tracking: UNIT_DIED carries no killing blow, so remember
-- the last damaging event against each group member (keyed by GUID).
local lastDamage = {} -- { [destGUID] = { cause = "...", time = GetTime() } }
-- Spirit of Redemption defers UNIT_DIED by 15s, so the window must outlast
-- the angel form; instakills recording a fresh cause keep this safe.
local CAUSE_FRESHNESS = 16 -- seconds; ignore stale damage

-- Falling deaths fire UNIT_DIED twice (impact + the Spirit of Redemption fade
-- ~15s later); collapse those into one. Only falling deaths are armed here --
-- mob/player deaths fire once, so they're never deduped.
local recentDeaths = {} -- { [destGUID] = GetTime() }
local DEATH_DEDUP_WINDOW = 16 -- seconds

local ENVIRONMENT_CAUSE = {
    FALLING  = "fell to their death",
    DROWNING = "drowned",
    FATIGUE  = "succumbed to fatigue",
    FIRE     = "burned to death",
    LAVA     = "took a lava bath",
    SLIME    = "dissolved in slime",
}

-- Spell school bitmask -> damage type name
local SCHOOL_NAME = {
    [1]  = "physical",
    [2]  = "holy",
    [4]  = "fire",
    [8]  = "nature",
    [16] = "frost",
    [32] = "shadow",
    [64] = "arcane",
}

local function SchoolName(school)
    return SCHOOL_NAME[school] or "magic"
end

-- Build a "cause" string from a combat-log damage subevent
local function ParseCause(subevent, sourceName, ...)
    if subevent == "ENVIRONMENTAL_DAMAGE" then
        local envType = ...
        return ENVIRONMENT_CAUSE[envType] or ("died to " .. (envType or "the environment"):lower())
    elseif subevent == "SWING_DAMAGE" then
        if sourceName then
            return "slain by " .. sourceName .. "'s melee (physical)"
        end
        return "slain by melee (physical)"
    elseif subevent == "SPELL_INSTAKILL" then
        -- Instant kills (boss mechanics, etc.); fires at the moment of death
        local _, spellName = ...
        if sourceName and spellName then
            return "instantly slain by " .. sourceName .. "'s " .. spellName
        elseif spellName then
            return "obliterated by " .. spellName
        elseif sourceName then
            return "instantly slain by " .. sourceName
        end
        return "instantly killed"
    elseif subevent == "SPELL_DAMAGE" or subevent == "SPELL_PERIODIC_DAMAGE"
        or subevent == "RANGE_DAMAGE" then
        local _, spellName, spellSchool = ...
        local school = " (" .. SchoolName(spellSchool) .. ")"
        if sourceName and spellName then
            return "slain by " .. sourceName .. "'s " .. spellName .. school
        elseif spellName then
            return "killed by " .. spellName .. school
        elseif sourceName then
            return "slain by " .. sourceName .. school
        end
    end
    return nil
end

local function RecordDamage(destGUID, cause)
    if destGUID and cause then
        lastDamage[destGUID] = { cause = cause, time = GetTime() }
    end
end

-- Look up (and consume) a fresh cause of death for a GUID
local function GetCause(destGUID)
    local entry = lastDamage[destGUID]
    lastDamage[destGUID] = nil
    if entry and (GetTime() - entry.time) <= CAUSE_FRESHNESS then
        return entry.cause
    end
    return nil
end

-- Batch mode: collect entries per milestone for 1s, then announce together.
-- Explicit setting, or forced on in raid.
local pendingMilestones = {} -- { [count] = { {name=,cause=}, ... } }

local function IsBatching()
    return ns.db.fnc.batch or IsInRaid()
end

local function QueueMilestone(entry, count)
    if not pendingMilestones[count] then
        pendingMilestones[count] = {}
        C_Timer.After(1, function()
            local entries = pendingMilestones[count]
            pendingMilestones[count] = nil
            if entries and #entries > 0 then
                AnnounceMilestone(entries, count)
            end
        end)
    end
    table.insert(pendingMilestones[count], entry)
end

local function AnnounceDeath(name, count, cause)
    local entry = { name = name, cause = cause }

    -- First blood = first recorded death of the run (never batched)
    local total = 0
    for _, c in pairs(ns.db.fnc.deaths) do
        total = total + c
    end
    if total == 1 then
        ns.copypasta.SendToCanonicalChannel(
            "First blood! " .. name .. ", " .. cause .. " BloodTrail  " .. count .. " {rt8}")
        return
    end

    if MILESTONES[count] then
        if IsBatching() then
            QueueMilestone(entry, count)
        else
            AnnounceMilestone({ entry }, count)
        end
    end
end

-- Record a player death
local function OnUnitDied(destGUID, destName, destFlags)
    if bit.band(destFlags, COMBATLOG_OBJECT_TYPE_PLAYER) == 0 then return end
    if not destName then return end
    local unit = GetGroupMembers()[destName]
    if not unit then return end
    -- Feign Death fires UNIT_DIED too; a feigned hunter is still alive
    if UnitIsFeignDeath(unit) or UnitHealth(unit) > 0 then return end
    -- A prior falling death armed dedup; this is the SoR-fade re-death, drop it
    local now = GetTime()
    if recentDeaths[destGUID] and (now - recentDeaths[destGUID]) < DEATH_DEDUP_WINDOW then
        recentDeaths[destGUID] = nil
        return
    end
    local cause = GetCause(destGUID) or "unknown causes"
    -- Only falling deaths fire UNIT_DIED twice, so only they arm the dedup
    if cause == ENVIRONMENT_CAUSE.FALLING then
        recentDeaths[destGUID] = now
    end
    local deaths = ns.db.fnc.deaths
    deaths[destName] = (deaths[destName] or 0) + 1
    ns.Print("|cffFFD700[FnC]|r " .. destName .. " died — " .. cause .. ". (" .. deaths[destName] .. ")")
    AnnounceDeath(destName, deaths[destName], cause)
end

fncFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        local timestamp, subevent, hideCaster,
              sourceGUID, sourceName, sourceFlags, sourceRaidFlags,
              destGUID, destName, destFlags, destRaidFlags = CombatLogGetCurrentEventInfo()
        if subevent == "UNIT_DIED" then
            OnUnitDied(destGUID, destName, destFlags)
        elseif subevent:find("_DAMAGE", 1, true) or subevent == "SPELL_INSTAKILL" then
            RecordDamage(destGUID, ParseCause(subevent, sourceName, select(12, CombatLogGetCurrentEventInfo())))
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
