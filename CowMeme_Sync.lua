local ADDON_NAME, ns = ...

ns.sync = {}
local sync = ns.sync

local PREFIX = "CowMeme"
local HEARTBEAT_INTERVAL = 5  -- seconds between beacons
local ROSTER_EXPIRY = 15      -- drop peers silent for this long (3 missed beats)

-- These characters win the election outright, in list order, ahead of any
-- alphabetical comparison between non-priority characters.
local PRIORITY = {
    Cowmahn  = 1,
    Dowte    = 2,
    Offalfan = 3,
}

-- Peers heard per scope: { [scope] = { [name] = { time, version, flags } } }.
-- Scoped so a guild-wide beacon can't win an election for raid output.
local roster = {}

local syncFrame = CreateFrame("Frame", "CowMemeSyncFrame", UIParent)
local ticker
local playerName
local versionWarned = false

-- Own name, resolved lazily: UnitName can be nil at ADDON_LOADED
local function Me()
    playerName = playerName or UnitName("player")
    return playerName
end

-- Must mirror the canonical channel in CowMeme.lua: the election audience
-- has to match the channel the announcements go to.
local function CurrentScope()
    if IsInRaid() then
        return "RAID"
    elseif IsInGroup() then
        return "PARTY"
    elseif IsInGuild() then
        return "GUILD"
    end
    return nil
end

-- Capability flags this client advertises in its heartbeat:
-- G = willing to announce gamba pastas, F = FnC run active
local function MyFlags()
    local f = ""
    if ns.db and ns.db.copypasta and ns.db.copypasta.gambaMonitor then f = f .. "G" end
    if ns.db and ns.db.fnc and ns.db.fnc.active then f = f .. "F" end
    return f
end

-- True if character a outranks character b. Nil-safe: a nil name never wins,
-- so a half-initialized client degrades instead of erroring.
local function Beats(a, b)
    if not a then return false end
    if not b then return true end
    local ra, rb = PRIORITY[a], PRIORITY[b]
    if ra and rb then return ra < rb end
    if ra then return true end
    if rb then return false end
    return a < b
end

-- Deterministic election over fresh roster entries for the current scope.
-- cap filters to peers advertising that capability; the local client is
-- always a candidate (callers only announce content they're willing to).
-- Every client runs this same rule, so no negotiation is needed.
function sync.GetAnnouncer(cap)
    local me = Me()
    local scope = CurrentScope()
    if not scope then return me end -- solo and unguilded: trivially the announcer
    local best = me
    local entries = roster[scope]
    if entries then
        local now = GetTime()
        for name, e in pairs(entries) do
            if now - e.time > ROSTER_EXPIRY then
                entries[name] = nil
            elseif (not cap or (e.flags or ""):find(cap, 1, true)) and Beats(name, best) then
                best = name
            end
        end
    end
    return best
end

function sync.IsAnnouncer(cap)
    return sync.GetAnnouncer(cap) == Me()
end

-- Leader among all addon users regardless of capability (status display)
function sync.GetLeader()
    return sync.GetAnnouncer(nil)
end

function sync.IsLeader()
    return sync.GetLeader() == Me()
end

local function SendHeartbeat()
    local scope = CurrentScope()
    if not scope then return end
    C_ChatInfo.SendAddonMessage(PREFIX, "HB:" .. (sync.version or "?") .. ":" .. MyFlags(), scope)
end

-- Beacon immediately (e.g. after a willingness toggle) so elections settle fast
function sync.Ping()
    SendHeartbeat()
end

local function OnTick()
    SendHeartbeat()
    -- Leader announce is per-heartbeat spam, so it's verbose-gated
    if ns.DebugVerbose("sync") then
        local leader = sync.GetLeader()
        if leader == Me() then
            print("|cff00ff00[CowMeme sync] *** I am the leader ***|r")
        else
            ns.DebugPrint("sync", "leader: " .. tostring(leader))
        end
    end
end

syncFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "CHAT_MSG_ADDON" then
        local prefix, msg, channel, sender = ...
        if prefix ~= PREFIX then return end
        local version, flags = msg:match("^HB:([^:]*):?(.*)")
        if not version then return end
        -- Strip realm suffix so names compare with UnitName("player")
        local name = sender and sender:match("^([^%-]+)")
        if not name then return end
        roster[channel] = roster[channel] or {}
        roster[channel][name] = { time = GetTime(), version = version, flags = flags }
        -- Mismatched versions can elect different announcers (double posts);
        -- warn once per session.
        if not versionWarned and version ~= "" and sync.version and version ~= sync.version then
            versionWarned = true
            ns.Print("|cffff8800CowMeme version mismatch:|r " .. name .. " runs " .. version ..
                ", you run " .. sync.version .. ". Announcements may double-post; update to match.")
        end
    elseif event == "GROUP_ROSTER_UPDATE" then
        -- Beacon immediately so elections settle fast on group changes
        SendHeartbeat()
    end
end)

-- Run or stop the heartbeat based on the global addon enable flag
function sync.ApplyState()
    if ns.db.enabled then
        syncFrame:RegisterEvent("CHAT_MSG_ADDON")
        syncFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
        if not ticker then
            ticker = C_Timer.NewTicker(HEARTBEAT_INTERVAL, OnTick)
            OnTick()
        end
    else
        syncFrame:UnregisterEvent("CHAT_MSG_ADDON")
        syncFrame:UnregisterEvent("GROUP_ROSTER_UPDATE")
        if ticker then
            ticker:Cancel()
            ticker = nil
        end
    end
end

-- One-line status summary, pulled into the /cm main menu
function sync.PrintStatus()
    local leader = sync.GetLeader()
    local me = leader == Me() and " (me)" or ""
    local scope = CurrentScope() or "none"
    local n = 0
    local entries = roster[CurrentScope() or ""]
    if entries then
        local now = GetTime()
        for _, e in pairs(entries) do
            if now - e.time <= ROSTER_EXPIRY then n = n + 1 end
        end
    end
    print("  |cffFFD700Sync|r: leader " .. tostring(leader) .. me .. ", scope " .. scope ..
        ", " .. n .. " peer(s) heard, flags [" .. MyFlags() .. "]")
end

-- Called from OnLoad after db is ready
function sync.Init()
    Me()
    local getMeta = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
    sync.version = getMeta and getMeta(ADDON_NAME, "Version") or "?"
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    sync.ApplyState()
end
