local ADDON_NAME, ns = ...

ns.fnc = {}
local fnc = ns.fnc

-- Default FnC settings
ns.defaults.fnc = {
    active = false,
    batch  = false, -- batch milestone announcements (always on in raid)
    allowGroupReset = true, -- honor /fnc reset group from the group's authority
    deaths = {}, -- { [playerName] = count }
}

local fncFrame = CreateFrame("Frame", "CowMemeFnCFrame", UIParent)

-- Chat watcher: plays sounds off announced FnC lines and receives group-reset
-- comms. Active whenever the addon is enabled -- deliberately NOT gated on
-- fnc.active, so guildies who never start a run still hear the sounds and
-- honor group resets.
local chatFrame = CreateFrame("Frame", "CowMemeFnCChatFrame", UIParent)
-- Everywhere ns.Announce can land (sounds mirror whatever chat shows)
local FNC_CHAT_EVENTS = {
    "CHAT_MSG_INSTANCE_CHAT",
    "CHAT_MSG_RAID",
    "CHAT_MSG_RAID_LEADER",
    "CHAT_MSG_PARTY",
    "CHAT_MSG_PARTY_LEADER",
    "CHAT_MSG_GUILD",
}

-- Register/unregister death tracking based on the global addon enable flag and
-- whether a run is active. Does not change ns.db.fnc.active.
function fnc.ApplyState()
    if ns.db.enabled and ns.db.fnc.active then
        fncFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    else
        fncFrame:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    end
    if ns.db.enabled then
        for _, event in ipairs(FNC_CHAT_EVENTS) do
            chatFrame:RegisterEvent(event)
        end
        chatFrame:RegisterEvent("CHAT_MSG_ADDON")
    else
        chatFrame:UnregisterAllEvents()
    end
end

-- Fresh run: clear deaths and start tracking. Callers print their own line
-- (manual /fnc new vs. a group reset name different actors).
local function BeginRun()
    ns.db.fnc.active = true
    ns.db.fnc.deaths = {}
    fnc.ApplyState()
    ns.sync.Ping() -- advertise the F flag promptly
end

-- Start a new FnC run
function fnc.New()
    BeginRun()
    ns.Print("|cffFFD700[Fast and Clean]|r Run started. Good luck!")
end

-- Resume tracking without clearing deaths
function fnc.Start()
    ns.db.fnc.active = true
    fnc.ApplyState()
    ns.sync.Ping()
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
    fnc.ApplyState()
    ns.sync.Ping()
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

local function Strip(name)
    return name and (name:match("^([^%-]+)") or name)
end

-- Sounds mirror chat: when an announced FnC line lands in a channel we can
-- see, play the matching sound. Every client that sees the text hears the
-- sound (the announcer too, via their own echoed message), so audio always
-- agrees with what the group is reading -- no cross-client state needed.
-- The {rt8} suffix requirement filters casual hand-typed spoofs.
local SOUND_LINES = {
    { match = "^First blood! ", sound = "cm_firstblood.ogg" },
    -- Milestone entries are appended below, derived from MILESTONES so a
    -- reworded milestone can't silently break its sound.
}

-- Returns true if a line matched and its sound actually played
local function OnFncChat(msg)
    for _, entry in ipairs(SOUND_LINES) do
        if msg:find(entry.match) and msg:find("{rt8}", 1, true) then
            return ns.PlaySound(entry.sound)
        end
    end
    return false
end

-- Group leader or assist counts as rank authority
local function IsGroupRank(name)
    local unit = GetGroupMembers()[name]
    if not unit then return false end
    return UnitIsGroupLeader(unit) or UnitIsGroupAssistant(unit)
end

-- Authority: who may drive group-wide FnC actions (currently the group
-- reset). An ordered list of predicates over a realm-stripped sender name,
-- so new sources slot in cleanly -- e.g. a future /fnc lead command would
-- insert a "claimed leader" check at the top, decoupling authority from
-- raid rank entirely.
local AUTHORITY_CHECKS = {
    -- function(name) return claimedLeader == name end, -- future /fnc lead
    ns.sync.IsPriority, -- the addon's priority characters
    IsGroupRank,        -- group leader or assist
}

local function IsAuthorized(name)
    for _, check in ipairs(AUTHORITY_CHECKS) do
        if check(name) then return true end
    end
    return false
end

-- Receiving a group reset: a remote /fnc new, gated on the local opt-in and
-- the sender's authority. sim=true (from /fnc simreset) bypasses the
-- authority lookup, which can't pass for a fabricated sender.
local function OnGroupReset(sender, sim)
    sender = Strip(sender)
    if not sender or sender == UnitName("player") then return end -- own echo
    if not ns.db.fnc.allowGroupReset then
        ns.Print("|cffFFD700[FnC]|r Group reset from " .. sender .. " ignored (opt-in is off).")
        return
    end
    if not sim and not IsAuthorized(sender) then
        ns.DebugPrint("fnc", "group reset from " .. sender .. " ignored (not leader/assist/priority)")
        return
    end
    BeginRun()
    ns.Print("|cffFFD700[Fast and Clean]|r Run reset by " .. sender ..
        " -- fresh run started. (Opt out in /cm options)")
end

-- Group reset, sender side: reset locally, then ask the group to do the
-- same. The comm rides the group channel only (never GUILD), which is what
-- scopes it to this raid/party.
local GROUP_CHANNELS = { INSTANCE_CHAT = true, RAID = true, PARTY = true }

function fnc.GroupReset()
    BeginRun()
    ns.Print("|cffFFD700[Fast and Clean]|r Fresh run started (group reset).")
    local channel = ns.CanonicalChannel()
    if not (channel and GROUP_CHANNELS[channel]) then
        ns.Print("|cffFFD700[FnC]|r Not in a group; the reset was local only.")
        return
    end
    if not IsAuthorized(Strip(UnitName("player"))) then
        ns.Print("|cffFFD700[FnC]|r You are not the group leader/assist, so members will ignore the reset; it was applied locally only.")
        return
    end
    if ns.SandboxActive() then
        ns.Print("|cff00ccff[SANDBOX -> " .. channel .. "]|r FNC_RESET")
        return
    end
    C_ChatInfo.SendAddonMessage("CowMeme", "FNC_RESET", channel)
end

chatFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "CHAT_MSG_ADDON" then
        local prefix, msg, _, sender = ...
        if prefix == "CowMeme" and msg == "FNC_RESET" then
            OnGroupReset(sender)
        end
    else
        local msg = ...
        OnFncChat(msg)
    end
end)

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

-- Milestone sounds, keyed by the same death counts as MILESTONES above
local MILESTONE_SOUNDS = {
    [3]  = "cm_killingspree.ogg",
    [5]  = "cm_dominating.ogg",
    [7]  = "cm_megakill.ogg",
    [10] = "cm_unstoppable.ogg",
    [12] = "cm_whickedsick.ogg",
    [14] = "cm_monsterkill.ogg",
    [15] = "cm_godlike.ogg",
}

-- Wire each milestone's sound into the chat watcher: the match string is the
-- announced phrase, i.e. the format with its "%s " subject slot stripped
-- (e.g. "%s ON A DYING SPREE!" -> "ON A DYING SPREE!").
for count, sound in pairs(MILESTONE_SOUNDS) do
    if MILESTONES[count] then
        table.insert(SOUND_LINES, { match = MILESTONES[count]:gsub("%%s%s*", ""), sound = sound })
    end
end

-- FnC's announce wrapper: live lines reach the sound watcher as real chat
-- echoes, but in sandbox the line never lands in chat -- so feed the watcher
-- directly. Pretend chat gets pretend echoes, keeping sims audible.
local function AnnounceFnc(msg)
    ns.Announce(msg, "F")
    if ns.SandboxActive() then
        OnFncChat(msg)
    end
end

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
    AnnounceFnc(msg .. " " .. count .. " {rt8}")
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

local function RecordDamage(destGUID, cause, destName)
    if destGUID and cause then
        lastDamage[destGUID] = { cause = cause, time = GetTime() }
        -- Guard before building the string: this path runs per damage event
        if ns.DebugVerbose("fnc") then
            ns.DebugPrint("fnc", "damage: " .. (destName or destGUID) .. " <- " .. cause)
        end
    end
end

-- Look up (and consume) a fresh cause of death for a GUID
local function GetCause(destGUID)
    local entry = lastDamage[destGUID]
    lastDamage[destGUID] = nil
    if not entry then
        ns.DebugPrint("fnc", "cause lookup: nothing recorded for this GUID")
        return nil
    end
    local age = GetTime() - entry.time
    if age <= CAUSE_FRESHNESS then
        if ns.DebugOn("fnc") then
            ns.DebugPrint("fnc", string.format("cause lookup: hit (%.1fs old): %s", age, entry.cause))
        end
        return entry.cause
    end
    if ns.DebugOn("fnc") then
        ns.DebugPrint("fnc", string.format("cause lookup: stale (%.1fs old, limit %ds): %s",
            age, CAUSE_FRESHNESS, entry.cause))
    end
    return nil
end

-- Batch mode: collect entries per milestone for BATCH_WINDOW, then announce
-- together. Explicit setting, or forced on in raid.
local BATCH_WINDOW = 1.5 -- seconds
local pendingMilestones = {} -- { [count] = { {name=,cause=}, ... } }

local function IsBatching()
    return ns.db.fnc.batch or IsInRaid()
end

local function QueueMilestone(entry, count)
    if not pendingMilestones[count] then
        pendingMilestones[count] = {}
        ns.DebugPrint("fnc", "batch: opened " .. BATCH_WINDOW .. "s window for milestone " .. count)
        C_Timer.After(BATCH_WINDOW, function()
            local entries = pendingMilestones[count]
            pendingMilestones[count] = nil
            if entries and #entries > 0 then
                ns.DebugPrint("fnc", "batch: flushing milestone " .. count .. " with " .. #entries .. " name(s)")
                AnnounceMilestone(entries, count)
            end
        end)
    end
    table.insert(pendingMilestones[count], entry)
    ns.DebugPrint("fnc", "batch: queued " .. entry.name .. " for milestone " .. count)
end

local function AnnounceDeath(name, count, cause)
    local entry = { name = name, cause = cause }

    -- First blood = first recorded death of the run (never batched)
    local total = 0
    for _, c in pairs(ns.db.fnc.deaths) do
        total = total + c
    end
    if total == 1 then
        -- Sound plays via the chat watcher when the line lands (own echo
        -- included), so audio stays in sync with what the group sees.
        AnnounceFnc("First blood! " .. name .. ", " .. cause .. " BloodTrail  " .. count .. " {rt8}")
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

-- Record a player death. sim=true (from /fnc simdeath) bypasses the group
-- and feign/health guards, which can't pass for a fabricated unit.
local function OnUnitDied(destGUID, destName, destFlags, sim)
    if bit.band(destFlags, COMBATLOG_OBJECT_TYPE_PLAYER) == 0 then
        -- Fires for every mob death, so verbose only
        if ns.DebugVerbose("fnc") then
            ns.DebugPrint("fnc", "UNIT_DIED ignored (not a player): " .. tostring(destName))
        end
        return
    end
    if not destName then return end
    if not sim then
        local unit = GetGroupMembers()[destName]
        if not unit then
            ns.DebugPrint("fnc", "death ignored (not in group): " .. destName)
            return
        end
        -- Feign Death fires UNIT_DIED too; a feigned hunter is still alive
        if UnitIsFeignDeath(unit) or UnitHealth(unit) > 0 then
            ns.DebugPrint("fnc", "death ignored (feign/still alive): " .. destName)
            return
        end
    end
    -- A prior falling death armed dedup; this is the SoR-fade re-death, drop it
    local now = GetTime()
    if recentDeaths[destGUID] and (now - recentDeaths[destGUID]) < DEATH_DEDUP_WINDOW then
        recentDeaths[destGUID] = nil
        ns.DebugPrint("fnc", "death deduped (SoR fade after falling): " .. destName)
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
            RecordDamage(destGUID, ParseCause(subevent, sourceName, select(12, CombatLogGetCurrentEventInfo())), destName)
        end
    end
end)

-- Resume tracking if it was active before logout
function fnc.Init()
    if not ns.db.fnc then
        ns.db.fnc = { active = false, batch = false, deaths = {} }
    end
    if ns.db.fnc.allowGroupReset == nil then
        ns.db.fnc.allowGroupReset = true -- setting added after early saves
    end
    fnc.ApplyState()
    if ns.db.enabled and ns.db.fnc.active then
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
fncCommands["reset"] = function(arg)
    if arg and arg:lower():match("^group") then
        fnc.GroupReset()
    else
        fnc.Reset()
    end
end
fncCommands["stop"] = function() fnc.Stop() end
fncCommands["report"] = function(arg) fnc.Report(arg) end

-- Sim commands: exercise the real pipeline with fake events. Debug-gated,
-- and output is forced through the sandbox so it can't reach real chat.
local function RequireDebug()
    if ns.db.debug then return true end
    ns.Print("|cffFFD700[FnC]|r Debug mode required: /cm debug on")
    return false
end

fncCommands["simdamage"] = function(arg)
    if not RequireDebug() then return end
    local name, cause = (arg or ""):match("^(%S+)%s+(.+)")
    if not name then
        ns.Print("|cffFFD700[FnC]|r Usage: /fnc simdamage <name> <cause text>")
        return
    end
    RecordDamage("Sim-" .. name, cause, name)
    ns.Print("|cffFFD700[FnC]|r sim: recorded damage on " .. name .. ": " .. cause)
end

fncCommands["simdeath"] = function(arg)
    if not RequireDebug() then return end
    local name = arg and strtrim(arg) or ""
    if name == "" then
        ns.Print("|cffFFD700[FnC]|r Usage: /fnc simdeath <name>  (run /fnc simdamage first for a cause)")
        return
    end
    ns.ForceSandbox(3)
    OnUnitDied("Sim-" .. name, name, COMBATLOG_OBJECT_TYPE_PLAYER, true)
end

fncCommands["simsound"] = function(arg)
    if not RequireDebug() then return end
    -- Feed a constructed announce line to the chat watcher; sound is local,
    -- so this is audible without touching chat. No arg = first blood; a
    -- milestone number plays that milestone's sound.
    local line, label
    local n = tonumber(arg)
    if arg and not n then
        arg = nil -- non-numeric arg: fall through to first blood
    end
    if n then
        if not (MILESTONES[n] and MILESTONE_SOUNDS[n]) then
            local keys = {}
            for k in pairs(MILESTONE_SOUNDS) do table.insert(keys, k) end
            table.sort(keys)
            ns.Print("|cffFFD700[FnC]|r Usage: /fnc simsound [milestone]  (milestones: "
                .. table.concat(keys, " ") .. "; no arg = first blood)")
            return
        end
        line = string.format(MILESTONES[n], "Simmy, slain by simulation (physical) is") .. " " .. n .. " {rt8}"
        label = "milestone " .. n .. " (" .. MILESTONE_SOUNDS[n] .. ")"
    else
        line = "First blood! Simmy, slain by simulation (physical) BloodTrail  1 {rt8}"
        label = "first blood (cm_firstblood.ogg)"
    end
    if OnFncChat(line) then
        ns.Print("|cffFFD700[FnC]|r sim: " .. label .. " -- sound played.")
    else
        ns.Print("|cffFFD700[FnC]|r sim: no sound played (is \"Play sound effects\" on and the addon enabled?).")
    end
end

fncCommands["simreset"] = function()
    if not RequireDebug() then return end
    ns.ForceSandbox(3)
    ns.Print("|cffFFD700[FnC]|r sim: receiving a group reset from SimLeader...")
    OnGroupReset("SimLeader", true)
    if not ns.db.fnc.allowGroupReset then
        ns.Print("|cffFFD700[FnC]|r (Toggle \"Allow group FnC reset\" in /cm options to see the accept path.)")
    end
end

fncCommands["simbatch"] = function(arg)
    if not RequireDebug() then return end
    local milestone, n = (arg or ""):match("^(%d+)%s+(%d+)")
    milestone, n = tonumber(milestone), tonumber(n)
    if not milestone or not MILESTONES[milestone] or not n or n < 1 then
        local keys = {}
        for k in pairs(MILESTONES) do table.insert(keys, k) end
        table.sort(keys)
        ns.Print("|cffFFD700[FnC]|r Usage: /fnc simbatch <milestone> <count>  (milestones: "
            .. table.concat(keys, " ") .. ")")
        return
    end
    ns.ForceSandbox(3)
    for i = 1, math.min(n, 10) do
        QueueMilestone({ name = "Simmy" .. i, cause = "slain by simulation (physical)" }, milestone)
    end
end

-- Full 30-second tour: 30 deaths across 3 characters through the real death
-- pipeline (causes, counts, first blood, milestone announces + sounds).
-- Simmy eats 15 -- every milestone through the top -- the others split the
-- rest. Causes avoid falling on purpose: the falling dedup would swallow
-- follow-up deaths within its 16s window.
fncCommands["longsim"] = function()
    if not RequireDebug() then return end
    if next(ns.db.fnc.deaths) then
        ns.Print("|cffFFD700[FnC]|r Note: existing deaths recorded, so first blood won't fire. /fnc reset first for the full tour.")
    end
    ns.Print("|cffFFD700[FnC]|r longsim: 30 deaths / 3 characters / ~30s (sandboxed)...")

    -- Round-robin so the streaks interleave; once the others run dry, Simmy's
    -- solo tail run hits 10/12/14/15 back to back.
    local remaining = { Simmy = 15, Bopsy = 8, Floora = 7 }
    local order = { "Simmy", "Bopsy", "Floora" }
    local schedule = {}
    while #schedule < 30 do
        for _, name in ipairs(order) do
            if remaining[name] > 0 then
                remaining[name] = remaining[name] - 1
                table.insert(schedule, name)
            end
        end
    end

    local causes = {
        "slain by Gruul's Shatter (physical)",
        "slain by High King Maulgar's melee (physical)",
        "killed by Blast Wave (fire)",
        "drowned",
        "slain by Shadow Bolt (shadow)",
    }

    for i, name in ipairs(schedule) do
        C_Timer.After(i, function()
            ns.ForceSandbox(5) -- rolling window covers batched announces too
            local cause = causes[(i - 1) % #causes + 1]
            RecordDamage("Sim-" .. name, cause, name)
            OnUnitDied("Sim-" .. name, name, COMBATLOG_OBJECT_TYPE_PLAYER, true)
        end)
    end
    C_Timer.After(#schedule + 2, function()
        ns.Print("|cffFFD700[FnC]|r longsim complete -- /fnc reset clears the sim deaths.")
    end)
end

-- Printed by /fnc help and pulled into the /cm main menu
function fnc.PrintCommands()
    ns.Print("|cffFFD700[Fast and Clean]|r commands:")
    print("  |cffffff00/fnc new|r     - start a new run (clears deaths)")
    print("  |cffffff00/fnc start|r   - resume tracking without resetting")
    print("  |cffffff00/fnc reset|r   - reset death counts")
    print("  |cffffff00/fnc reset group|r - fresh run for the whole group (leader/assist only)")
    print("  |cffffff00/fnc report|r    - announce to party/raid/say (auto)")
    print("  |cffffff00/fnc report g|r  - announce to guild chat")
    print("  |cffffff00/fnc report 1|r  - announce to channel number")
    print("  |cffffff00/fnc delete <name>|r - remove a player from the list")
    print("  |cffffff00/fnc batch [on|off]|r - batch milestone announcements (auto-on in raid)")
    print("  |cffffff00/fnc stop|r    - stop tracking")
    print("  |cffffff00/fnc help|r    - show this message")
    if ns.db.debug then
        print("  |cffffff00/fnc simdamage <name> <cause>|r - (debug) record fake damage")
        print("  |cffffff00/fnc simdeath <name>|r          - (debug) simulate a death")
        print("  |cffffff00/fnc simbatch <milestone> <n>|r - (debug) simulate batched milestones")
        print("  |cffffff00/fnc simsound [milestone]|r     - (debug) play a sound via a fake line (no arg = first blood)")
        print("  |cffffff00/fnc simreset|r                 - (debug) simulate receiving a group reset")
        print("  |cffffff00/fnc longsim|r                  - (debug) 30 deaths / 3 characters / 30s, topping out the milestones")
    end
end

-- One-line status summary, pulled into the /cm main menu
function fnc.PrintStatus()
    local tracking = ns.db.fnc.active and "|cff00ff00ON|r" or "|cffff0000OFF|r"
    local batch    = ns.db.fnc.batch  and "|cff00ff00ON|r" or "|cffff0000OFF|r"
    local n = 0
    for _ in pairs(ns.db.fnc.deaths) do n = n + 1 end
    print("  |cffFFD700FnC|r: tracking " .. tracking .. ", batch " .. batch ..
        " (auto in raid), " .. n .. " tracked")
end

fncCommands["help"]   = function() fnc.PrintCommands() end
fncCommands["status"] = function() fnc.PrintStatus() end

local function HandleFnCSlash(input)
    local cmd, arg = strtrim(input):match("^(%S*)%s*(.*)")
    cmd = cmd:lower()
    local handler = fncCommands[cmd] or fncCommands["help"]
    handler(arg ~= "" and arg or nil)
end

SLASH_COWMEMEFNC1 = "/fnc"
SlashCmdList["COWMEMEFNC"] = HandleFnCSlash
