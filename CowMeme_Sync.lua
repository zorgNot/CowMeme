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

-- Peers heard per scope: { [scope] = { [name] = { time, version } } }.
-- Scoped so a guild-wide beacon can't win an election for raid output.
local roster = {}

local syncFrame = CreateFrame("Frame", "CowMemeSyncFrame", UIParent)
local ticker
local playerName

-- Must mirror GetCanonicalChannel in CowMeme_CopyPasta.lua: the election
-- audience has to match the channel the announcements go to.
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

-- True if character a outranks character b for leadership
local function Beats(a, b)
    local ra, rb = PRIORITY[a], PRIORITY[b]
    if ra and rb then return ra < rb end
    if ra then return true end
    if rb then return false end
    return a < b
end

-- Deterministic election over fresh roster entries for the current scope.
-- Every client runs this same rule, so no negotiation is needed.
function sync.GetLeader()
    local scope = CurrentScope()
    if not scope then return playerName end -- solo and unguilded: trivially leader
    local best = playerName
    local entries = roster[scope]
    if entries then
        local now = GetTime()
        for name, e in pairs(entries) do
            if now - e.time > ROSTER_EXPIRY then
                entries[name] = nil
            elseif Beats(name, best) then
                best = name
            end
        end
    end
    return best
end

function sync.IsLeader()
    return sync.GetLeader() == playerName
end

local function SendHeartbeat()
    local scope = CurrentScope()
    if not scope then return end
    C_ChatInfo.SendAddonMessage(PREFIX, "HB:" .. (sync.version or "?"), scope)
end

local function OnTick()
    SendHeartbeat()
    if ns.DebugOn("sync") then
        local leader = sync.GetLeader()
        if leader == playerName then
            print("|cff00ff00[CowMeme sync] *** I am the leader ***|r")
        else
            ns.DebugPrint("sync", "leader: " .. leader)
        end
    end
end

syncFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "CHAT_MSG_ADDON" then
        local prefix, msg, channel, sender = ...
        if prefix ~= PREFIX then return end
        local version = msg:match("^HB:(.*)")
        if not version then return end
        -- Strip realm suffix so names compare with UnitName("player")
        local name = sender and sender:match("^([^%-]+)")
        if not name then return end
        roster[channel] = roster[channel] or {}
        roster[channel][name] = { time = GetTime(), version = version }
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
    local me = leader == playerName and " (me)" or ""
    local scope = CurrentScope() or "none"
    local n = 0
    local entries = roster[CurrentScope() or ""]
    if entries then
        local now = GetTime()
        for _, e in pairs(entries) do
            if now - e.time <= ROSTER_EXPIRY then n = n + 1 end
        end
    end
    print("  |cffFFD700Sync|r: leader " .. leader .. me .. ", scope " .. scope ..
        ", " .. n .. " peer(s) heard")
end

-- Called from OnLoad after db is ready
function sync.Init()
    playerName = UnitName("player")
    local getMeta = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
    sync.version = getMeta and getMeta(ADDON_NAME, "Version") or "?"
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    sync.ApplyState()
end
