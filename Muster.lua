-- RUIN Muster
-- Officers (and the ranks their guild allows) post events (raids, PvP nights, leveling groups) for all of RUIN,
-- with a description, a size and how many tanks, healers and DPS are needed.
-- Members sign up by role and get a reminder 15 minutes before the start.
-- Weekly events post their next week by themselves. Officers arrange the
-- raid into groups and a bench, and raids take one soft reserve per player.
-- Open slots are offered to RUIN Finder when it is installed.
--
-- Since 0.3.3 Muster also carries what RUIN Warfront did that Overlord
-- Forever doesn't: rally points (an event's meeting place, pinned on the map
-- and marked contested when RUIN Intel sees enemies nearby) and bounties on
-- rival guilds or players, confirmed by a RUIN witness. The faction-wide
-- campaign, keeps and captures are left to Overlord. Since 0.4.1 Muster
-- keeps its own automatic Most Wanted list (Wanted.lua), plans operations
-- in the War Room (WarRoom.lua) and keeps loot notes (Loot.lua).
local ADDON, ns = ...
local R = RUIN_API
if not R or (R.apiLevel or 1) < 8 then
    print("|cff54b7d9[RUIN]|r Muster needs a newer RUIN Core (0.3.15 or later).")
    return
end
local W = R.Widgets
local C = W.COLORS

local M = R:RegisterModule("Muster", { version = "0.4.1" })

local KINDS = { "Raid", "Dungeon", "PvP", "Leveling", "Social" }
local SIZES = { "Open", "5", "10", "20", "40" }
-- Default tanks / healers / DPS for each size; officers can change them.
local NEED_FOR = { ["5"] = { 1, 1, 3 }, ["10"] = { 2, 3, 5 }, ["20"] = { 3, 5, 12 }, ["40"] = { 5, 10, 25 } }
local REMIND_BEFORE = 15 * 60
local KEEP_AFTER = 6 * 3600
local WEEK = 7 * 86400
local SLOTS_AHEAD = 48 * 3600          -- events this close offer open slots to Finder
local RALLY_BEFORE, RALLY_AFTER = 3 * 3600, 2 * 3600   -- rally pins show this long around the start
local CONTEST_YARDS, CONTEST_SECONDS = 300, 10 * 60     -- an enemy sighting this close contests a rally
local BOUNTY_DAYS = 7
local CLAIM_SECONDS = 5 * 60                            -- witnesses have this long to confirm a kill
local WITNESS_YARDS = 200
local RALLY_ICON = "Interface\\Icons\\Ability_Warrior_BattleShout"
local DEFAULTS = { events = {}, reminded = {}, practice = false, bounties = {}, claims = {}, pins = true }

ns.Muster = M

local db
local ui = { kind = "Raid", size = "Open", need = { 0, 0, 0 }, weekly = false, rally = false, bKind = "Guild" }
ns.MusterUI = ui      -- for tests

local ROLE_NAMES = { T = "Tank", H = "Healer", D = "DPS" }
local ROLE_ORDER = { "T", "H", "D" }

local function newId()
    return tostring(R:GetPlayerGUID() or "x"):sub(-5) .. GetServerTime() % 100000 .. math.random(10, 99)
end

-- "2026-10-24 20:00", or epoch seconds from the form's time picker
local function parseWhen(text)
    if type(text) == "number" then return math.floor(text) end
    local y, mo, d, h, mi = (text or ""):match("(%d+)%-(%d+)%-(%d+)%s+(%d+):(%d+)")
    if not y then return nil end
    return time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h), min = tonumber(mi) })
end

local function counts(ev)
    local n = { T = 0, H = 0, D = 0 }
    for _, s in pairs(ev.signups or {}) do
        if n[s.role] then n[s.role] = n[s.role] + 1 end
    end
    return n
end

-- How many of each role are still wanted (nil when the event has no limits).
local function openSlots(ev)
    if type(ev.need) ~= "table" then return nil end
    local n, open, any = counts(ev), {}, false
    for i, r in ipairs(ROLE_ORDER) do
        open[r] = math.max(0, (tonumber(ev.need[i]) or 0) - n[r])
        if open[r] > 0 then any = true end
    end
    return open, any
end

local function validEvent(e)
    return type(e) == "table" and type(e.id) == "string" and type(e.title) == "string" and type(e.at) == "number"
end

local function whenText(at) return W.WhenText(at) end

local refreshPage = function() end
local changed
local updatePins = function() end

---------------------------------------------------------------------------
-- Rally points: where an event meets, from the officer's position
---------------------------------------------------------------------------
local function here()
    local map, x, y = R.Map:PlayerPos()
    if not map then return nil end
    local zone = (GetZoneText and GetZoneText()) or ""
    local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(map)
    return { map = map, x = x, y = y, zone = (info and info.name) or zone }
end

local function cleanRally(r)
    if type(r) ~= "table" or type(r.map) ~= "number" or type(r.x) ~= "number" or type(r.y) ~= "number" then return nil end
    return { map = r.map, x = r.x, y = r.y, zone = type(r.zone) == "string" and r.zone:sub(1, 40) or "" }
end

local function rallyActive(ev, now)
    now = now or GetServerTime()
    return ev.rally and ev.at - RALLY_BEFORE <= now and now <= ev.at + RALLY_AFTER
end

local function rallyText(ev)
    if not ev.rally then return "" end
    local dist = R.Map.DistanceText and R.Map:DistanceText(ev.rally.map, ev.rally.x, ev.rally.y)
    local contested = ev.contested and (GetServerTime() - (ev.contested.t or 0) <= CONTEST_SECONDS)
    return (contested and (C.bad .. "  CONTESTED|r") or "") .. C.dim .. "  @ " .. (ev.rally.zone ~= "" and ev.rally.zone or "rally point")
        .. (dist and (" " .. dist) or "") .. "|r"
end

---------------------------------------------------------------------------
-- Events and sign-ups
---------------------------------------------------------------------------
-- Officers post for the org. In practice mode (page checkbox or /muster
-- practice, and automatically while not connected to RUIN) anyone can post;
-- practice events and their sign-ups stay on your own screen.
local function practicing() return (db and db.practice) or not R:IsConnected() end
-- Who may create events (rallies included): officers, plus the ranks their
-- guild's officers allow under Settings > Org > Guild settings (RUIN Core
-- 0.3.17). Bounties stay with officers.
local function canCreate()
    if R.CanCreateEvents then return R:CanCreateEvents() end
    return R:IsOfficer()
end
local function canPost() return canCreate() or practicing() end
local function canBounty() return R:IsOfficer() or practicing() end
-- Officers manage every event; other ranks allowed to create manage their own.
local function canManage(ev)
    if not ev then return false end
    if R:IsOfficer() or practicing() or ev.practice then return true end
    local me = R:GetPlayer()
    return canCreate() and me ~= nil and ev.by == me.name
end

-- opts: { kind, desc, size, need = { t, h, d }, weekly }
function M:Create(title, whenText_, opts)
    if type(opts) == "string" then opts = { kind = opts } end
    opts = opts or {}
    if not canPost() then return self:Print("Your guild rank can't create events. Your guild's officers choose who can, under Settings > Org.") end
    title = (title or ""):sub(1, 40)
    local at = parseWhen(whenText_)
    if title == "" or not at then return self:Print("Need a title and a time like 2026-10-24 20:00.") end
    local p = R:GetPlayer()
    local ev = { id = newId(), title = title, kind = opts.kind or "Raid", at = at, by = p.name, gu = p.guild,
                 signups = {}, t = GetServerTime(), desc = (opts.desc or ""):sub(1, 120) }
    if opts.size and opts.size ~= "Open" then ev.size = tonumber(opts.size) end
    if type(opts.need) == "table" and ((opts.need[1] or 0) + (opts.need[2] or 0) + (opts.need[3] or 0)) > 0 then
        ev.need = { tonumber(opts.need[1]) or 0, tonumber(opts.need[2]) or 0, tonumber(opts.need[3]) or 0 }
    end
    if opts.weekly then ev.weekly, ev.series, ev.week = true, ev.id, 0 end
    if opts.rally then
        ev.rally = cleanRally(type(opts.rally) == "table" and opts.rally or here())
        if not ev.rally then self:Print("Couldn't read your position for the rally point; posted without one.") end
    end
    if practicing() then ev.practice = true end
    db.events[ev.id] = ev
    if ev.practice then
        self:Toast(("Practice event posted: %s, %s (only you can see it)"):format(title, whenText(at)))
    else
        self:Send("EVENT", ev, "ORG")
        self:Toast(("Event posted: %s, %s"):format(title, whenText(at)))
    end
    changed()
    return ev
end

function M:Delete(id)
    local ev = db.events[id]
    if not ev or not canManage(ev) then return end
    db.events[id] = nil
    if not ev.practice then self:Send("DELETE", { id = id }, "ORG") end
    changed()
end

-- Stop a weekly event from posting further weeks (this week stays).
function M:StopRepeating(id)
    local ev = db.events[id]
    if not ev or not canManage(ev) or not ev.weekly then return end
    ev.weekly, ev.t = false, GetServerTime()
    if not ev.practice then self:Send("EVENT", ev, "ORG") end
    self:Print(ev.title .. " will not repeat after this week.")
    changed()
end

-- role: "T" | "H" | "D" | nil (withdraw). Keeps your soft reserve.
function M:SignUp(id, role)
    local ev = db.events[id]
    if not ev then return end
    local p = R:GetPlayer()
    local old = ev.signups[p.guid]
    local s = { n = p.name, gu = p.guild, c = p.class, role = role, t = GetServerTime(), sr = old and old.sr }
    ev.signups[p.guid] = role and s or nil
    if not ev.practice then self:Send("SIGN", { id = id, g = p.guid, s = s }, "ORG") end
    changed()
end

-- Soft reserve: an item link or name, one per player per event.
function M:Reserve(id, item)
    local ev = db.events[id]
    local me = R:GetPlayerGUID()
    if not ev or not me then return end
    local s = ev.signups[me]
    if not s then return self:Print("Sign up for " .. ev.title .. " first, then reserve an item.") end
    item = R.Util.Trim(item or "")
    s.sr = item ~= "" and item:sub(1, 120) or nil
    s.t = GetServerTime()
    if not ev.practice then self:Send("SIGN", { id = id, g = me, s = s }, "ORG") end
    self:Print(s.sr and ("Reserved " .. s.sr .. " for " .. ev.title .. ".") or "Reserve cleared.")
    changed()
end

function M:OnEvent(ev, sender)
    if not validEvent(ev) then return end
    ev.rally = cleanRally(ev.rally)
    if ns.WarRoom then ns.WarRoom.Clean(ev) end
    local cur = db.events[ev.id]
    if cur and (cur.t or 0) >= (ev.t or 0) then
        -- keep our version, but merge any sign-ups we have not seen
        for g, s in pairs(ev.signups or {}) do
            if not cur.signups[g] or (cur.signups[g].t or 0) < (s.t or 0) then cur.signups[g] = s end
        end
        if ev.roster and (ev.rosterT or 0) > (cur.rosterT or 0) then cur.roster, cur.rosterT = ev.roster, ev.rosterT end
    else
        if cur then
            for g, s in pairs(cur.signups or {}) do
                ev.signups = ev.signups or {}
                if not ev.signups[g] or (ev.signups[g].t or 0) < (s.t or 0) then ev.signups[g] = s end
            end
            if cur.roster and (cur.rosterT or 0) > (ev.rosterT or 0) then ev.roster, ev.rosterT = cur.roster, cur.rosterT end
        end
        ev.signups = ev.signups or {}
        db.events[ev.id] = ev
        if not cur and ev.rally and ev.at <= GetServerTime() and rallyActive(ev) then
            self:Toast(("Rally now: %s%s, pinned on your map (%s)"):format(ev.title,
                ev.rally.zone ~= "" and (" in " .. ev.rally.zone) or "", W.ClassName(sender)), { sound = true })
        elseif not cur and ev.at > GetServerTime() then
            self:Toast(("New %s: %s, %s"):format(ev.kind or "event", ev.title, whenText(ev.at)))
        end
    end
    changed()
end

function M:OnSign(d)
    local ev = type(d.id) == "string" and db.events[d.id]
    if not ev or type(d.g) ~= "string" or type(d.s) ~= "table" then return end
    local cur = ev.signups[d.g]
    if cur and (cur.t or 0) > (d.s.t or 0) then return end
    ev.signups[d.g] = d.s.role and d.s or nil
    changed()
end

function M:OnDelete(d)
    if type(d.id) == "string" and db.events[d.id] then
        db.events[d.id] = nil
        changed()
    end
end

-- Someone just connected: share the upcoming events we know.
function M:OnAsk()
    if ns.Wanted then ns.Wanted.Share() end
    if ns.Loot then ns.Loot.Share() end
    C_Timer.After(2 + math.random() * 8, function()
        local now = GetServerTime()
        for _, ev in pairs(db.events) do
            if ev.at + KEEP_AFTER > now and not ev.practice then self:Send("EVENT", ev, "ORG", nil, R.PRIORITY.BULK) end
        end

        if R:IsOfficer() then
            for _, b in ipairs(M.ActiveBounties()) do
                if not b.practice then self:Send("BOUNTY", b, "ORG", nil, R.PRIORITY.BULK) end
            end
        end
    end)
end

---------------------------------------------------------------------------
-- Raid roster: groups of five and a bench
---------------------------------------------------------------------------
local function groupCount(ev)
    local size = ev.size or 0
    if size <= 0 then
        local n = 0
        for _ in pairs(ev.signups) do n = n + 1 end
        size = math.max(5, n)
    end
    return math.min(8, math.ceil(size / 5))
end

local function sortedSignups(ev)
    local list = {}
    for g, s in pairs(ev.signups) do list[#list + 1] = { g = g, s = s } end
    table.sort(list, function(a, b)
        if (a.s.t or 0) ~= (b.s.t or 0) then return (a.s.t or 0) < (b.s.t or 0) end
        return a.g < b.g
    end)
    return list
end

-- Fill groups in sign-up order: tanks spread first, one healer per group,
-- then DPS into the free places. Anyone past the size goes to the bench.
function M:AutoRoster(id)
    local ev = db.events[id]
    if not ev or not canManage(ev) then return end
    local groups, cap = groupCount(ev), ev.size or 999
    local fill, roster, placed = {}, {}, 0
    for i = 1, groups do fill[i] = 0 end
    local function place(g, preferSpread)
        if placed >= cap then roster[g] = 0; return end
        local best
        for i = 1, groups do
            if fill[i] < 5 and (not best or (preferSpread and fill[i] < fill[best])) then best = i end
        end
        if not best then roster[g] = 0; return end
        roster[g] = best
        fill[best] = fill[best] + 1
        placed = placed + 1
    end
    local list = sortedSignups(ev)
    for _, role in ipairs(ROLE_ORDER) do
        for _, e in ipairs(list) do
            if e.s.role == role then place(e.g, role ~= "D") end
        end
    end
    ev.roster, ev.rosterT = roster, GetServerTime()
    changed()
end

-- Move one player to the next group, then the bench, then group 1 again.
function M:CycleGroup(id, guid)
    local ev = db.events[id]
    if not ev or not canManage(ev) or not ev.signups[guid] then return end
    ev.roster = ev.roster or {}
    local groups = groupCount(ev)
    local cur = ev.roster[guid] or 0
    ev.roster[guid] = (cur >= groups) and 0 or cur + 1
    ev.rosterT = GetServerTime()
    changed()
end

function M:PublishRoster(id)
    local ev = db.events[id]
    if not ev or not canManage(ev) or not ev.roster then return end
    ev.rosterT = GetServerTime()
    if not ev.practice then
        self:Send("ROSTER", { id = id, r = ev.roster, t = ev.rosterT }, "ORG")
    end
    self:Toast("Roster for " .. ev.title .. " sent to RUIN.")
    changed()
end

function M:OnRoster(d)
    local ev = type(d.id) == "string" and db.events[d.id]
    if not ev or type(d.r) ~= "table" or (tonumber(d.t) or 0) <= (ev.rosterT or 0) then return end
    ev.roster, ev.rosterT = d.r, tonumber(d.t)
    local me = R:GetPlayerGUID()
    local g = me and d.r[me]
    if g then
        self:Toast(("%s: you are in %s."):format(ev.title, g == 0 and "the bench" or ("group " .. g)))
    end
    changed()
end

local function myGroupText(ev)
    local me = R:GetPlayerGUID()
    local g = me and ev.roster and ev.roster[me]
    if g == nil then return "" end
    return g == 0 and " (bench)" or (" (group " .. g .. ")")
end

---------------------------------------------------------------------------
-- Weekly events and open slots for Finder
---------------------------------------------------------------------------
-- When a weekly event has started, the next week is posted with an id made
-- from the series, so two officers doing it at once post the same event.
local function rollWeekly(now)
    for _, ev in pairs(db.events) do
        if ev.weekly and ev.at <= now and canManage(ev) and (ev.practice or not practicing() or R:IsOfficer()) then
            local week = (ev.week or 0) + 1
            local nid = (ev.series or ev.id) .. "w" .. week
            if not db.events[nid] then
                local nxt = { id = nid, title = ev.title, kind = ev.kind, at = ev.at + WEEK, by = ev.by, gu = ev.gu,
                              signups = {}, t = GetServerTime(), desc = ev.desc, size = ev.size, need = ev.need,
                              weekly = true, series = ev.series or ev.id, week = week, practice = ev.practice,
                              rally = ev.rally }
                db.events[nid] = nxt
                if not nxt.practice then M:Send("EVENT", nxt, "ORG", nil, R.PRIORITY.BULK) end
            end
            ev.weekly = false            -- this week's copy no longer drives the series
        end
    end
end

-- For RUIN Finder: upcoming events that still want players, soonest first.
-- Each: { id, title, kind, at, open = { T = n, H = n, D = n } }
function M:GetOpenSlots()
    local list, now = {}, GetServerTime()
    if not db then return list end
    for _, ev in pairs(db.events) do
        if ev.at > now and ev.at - now <= SLOTS_AHEAD and not ev.practice then
            local open, any = openSlots(ev)
            if any then
                list[#list + 1] = { id = ev.id, title = ev.title, kind = ev.kind, at = ev.at, open = open, by = ev.by }
            end
        end
    end
    table.sort(list, function(a, b) return a.at < b.at end)
    return list
end

-- For other modules (Codex raid planning): upcoming events, soonest first.
-- Each: { id, title, kind, at, size, signed = number signed up }
function M:GetUpcoming()
    local list, now = {}, GetServerTime()
    if not db then return list end
    for _, ev in pairs(db.events) do
        if ev.at > now and not ev.practice then
            local n = 0
            for _ in pairs(ev.signups) do n = n + 1 end
            list[#list + 1] = { id = ev.id, title = ev.title, kind = ev.kind, at = ev.at, size = ev.size, signed = n }
        end
    end
    table.sort(list, function(a, b) return a.at < b.at end)
    return list
end

-- Officers can post from other modules (Codex's raid planner) through this.
function M:CanPost() return canPost() end

-- A rally right now, where you stand (what Warfront's "Mark objective here"
-- became): a PvP event starting this minute with a map pin for the org.
function M:Rally(title)
    if not canPost() then return self:Print("Your guild rank can't call rallies (or switch on practice mode). Your guild's officers choose who can.") end
    local pos = here()
    if not pos then return self:Print("Couldn't read your position here.") end
    title = R.Util.Trim(title or "")
    if title == "" then title = "Rally: " .. (pos.zone ~= "" and pos.zone or "here") end
    return self:Create(title, date("%Y-%m-%d %H:%M", time()), { kind = "PvP", rally = pos,
        desc = "Rally point set by " .. tostring(UnitName("player")) .. "." })
end

---------------------------------------------------------------------------
-- Bounties: officers name a rival guild or player; a claimed kill counts
-- once another RUIN member confirms it (moved here from RUIN Warfront).
---------------------------------------------------------------------------
local function activeBounties()
    local list, now = {}, GetServerTime()
    for id, b in pairs(db.bounties) do
        if (b.exp or 0) < now then db.bounties[id] = nil else list[#list + 1] = b end
    end
    table.sort(list, function(a, b) return (a.t or 0) > (b.t or 0) end)
    return list
end
M.ActiveBounties = function() return activeBounties() end

function M:PostBounty(target, kind, reward)
    if not canBounty() then return self:Print("Only officers can post bounties.") end
    target = R.Util.Trim(target or ""):sub(1, 40)
    if target == "" then return self:Print("Name the guild or player for the bounty.") end
    local now = GetServerTime()
    local b = { id = newId(), target = target, kind = kind == "Player" and "Player" or "Guild",
                reward = R.Util.Trim(reward or ""):sub(1, 40), by = UnitName("player"), t = now,
                exp = now + BOUNTY_DAYS * 86400 }
    if practicing() then b.practice = true end
    db.bounties[b.id] = b
    if not b.practice then self:Send("BOUNTY", b, "ORG") end
    self:Toast(("Bounty posted on %s %s%s"):format(b.kind == "Guild" and "guild" or "player", b.target,
        b.reward ~= "" and (" (" .. b.reward .. ")") or ""))
    refreshPage()
    return b
end

function M:RemoveBounty(id)
    local b = db.bounties[id]
    if not b or not canBounty() then return end
    db.bounties[id] = nil
    if not b.practice then self:Send("BDEL", { id = id }, "ORG") end
    refreshPage()
end

function M:OnBounty(b, sender)
    if type(b) ~= "table" or type(b.id) ~= "string" or type(b.target) ~= "string" or type(b.exp) ~= "number" then return end
    b.target = b.target:sub(1, 40)
    b.reward = type(b.reward) == "string" and b.reward:sub(1, 40) or ""
    b.kind = b.kind == "Player" and "Player" or "Guild"
    local known = db.bounties[b.id]
    db.bounties[b.id] = b
    if not known and b.exp > GetServerTime() then
        self:Toast(("Bounty on %s %s%s, posted by %s"):format(b.kind == "Player" and "player" or "guild", b.target,
            b.reward ~= "" and (" (" .. b.reward .. ")") or "", W.ClassName(sender)))
    end
    refreshPage()
end

function M:OnBountyDelete(d)
    if type(d.id) == "string" and db.bounties[d.id] then db.bounties[d.id] = nil; refreshPage() end
end

local function secret(v) return issecretvalue and issecretvalue(v) end

local function matchBounty(name, guild)
    for _, b in ipairs(activeBounties()) do
        if b.kind == "Player" and name and b.target:lower() == R.Util.ShortName(name):lower() then return b end
        if b.kind == "Guild" and guild and b.target:lower() == guild:lower() then return b end
    end
end

-- Target the body of an enemy player you killed, then claim.
function M:ClaimKill()
    if not (UnitExists and UnitExists("target") and UnitIsPlayer and UnitIsPlayer("target")) then
        return self:Print("Target the enemy player you killed (their body), then claim the bounty.")
    end
    if UnitIsFriend and UnitIsFriend("player", "target") then return self:Print("That's not an enemy player.") end
    if UnitIsDeadOrGhost and not UnitIsDeadOrGhost("target") then return self:Print("They're still alive!") end
    local name = UnitName("target")
    local guild = GetGuildInfo and GetGuildInfo("target")
    if secret(name) or secret(guild) then return self:Print("The game is hiding that player's details right now; try again out of combat.") end
    local b = matchBounty(name, guild)
    if not b then
        return self:Print(("No bounty on %s%s."):format(tostring(name), guild and (" <" .. guild .. ">") or ""))
    end
    local map, x, y = R.Map:PlayerPos()
    local p = R:GetPlayer()
    local c = { id = newId(), b = b.id, v = R.Util.ShortName(name), vg = guild, by = p.name, gu = p.guild,
                t = GetServerTime(), map = map, x = x, y = y }
    if b.practice then
        c.practice, c.confirmed = true, "practice"
        db.claims[c.id] = c
        self:Toast(("Practice bounty: you killed %s. Confirmed (practice needs no witness)."):format(c.v))
        refreshPage()
        return c
    end
    db.claims[c.id] = c
    self:Send("CLAIM", c, "ORG", nil, R.PRIORITY.ALERT)
    self:Toast(("Bounty claim sent: %s%s. A RUIN member who saw it must confirm."):format(c.v, guild and (" <" .. guild .. ">") or ""))
    refreshPage()
    return c
end

function M:OnClaim(c, sender)
    if type(c) ~= "table" or type(c.id) ~= "string" or type(c.b) ~= "string" or type(c.v) ~= "string" then return end
    if db.claims[c.id] then return end
    c.by, c.confirmed = sender, nil
    db.claims[c.id] = c
    local near = type(c.map) == "number" and select(3, R.Map:Offset(c.map, c.x, c.y))
    if near and near <= WITNESS_YARDS then
        self:Toast(("Did you see %s kill %s? Confirm on the Muster Bounties page or /muster confirm."):format(
            W.ClassName(sender), c.v), { sound = true })
    end
    refreshPage()
end

-- Confirm the newest open claim (or a given one) as a witness.
function M:Confirm(id)
    local now, best = GetServerTime(), nil
    for cid, c in pairs(db.claims) do
        local open = not c.confirmed and now - (c.t or 0) <= CLAIM_SECONDS and c.by ~= UnitName("player")
        if open and (cid == id or (not id and (not best or c.t > best.t))) then best = c end
    end
    if not best then return self:Print("No bounty claim waiting for a witness.") end
    self:Send("CONFIRM", { c = best.id }, "ORG", nil, R.PRIORITY.ALERT)
    self:OnConfirm({ c = best.id }, UnitName("player"))
end

function M:OnConfirm(d, sender)
    local c = type(d.c) == "string" and db.claims[d.c]
    if not c or c.confirmed or R.Util.ShortName(sender) == R.Util.ShortName(c.by or "") then return end
    c.confirmed = sender
    self:Toast(("Bounty confirmed: %s killed %s%s, witnessed by %s."):format(W.ClassName(c.by), c.v,
        c.vg and (" <" .. c.vg .. ">") or "", W.ClassName(sender)), { sound = true })
    refreshPage()
end

local function openClaims()
    local list, now = {}, GetServerTime()
    for id, c in pairs(db.claims) do
        if now - (c.t or 0) > 86400 then
            db.claims[id] = nil
        elseif now - (c.t or 0) <= CLAIM_SECONDS or c.confirmed then
            list[#list + 1] = c
        end
    end
    table.sort(list, function(a, b) return (a.t or 0) > (b.t or 0) end)
    return list
end

---------------------------------------------------------------------------
-- Rally pins on the map, and RUIN Intel sightings that contest them
---------------------------------------------------------------------------
updatePins = function()
    if not db then return end
    local keep, now = {}, GetServerTime()
    if db.pins then
        for id, ev in pairs(db.events) do
            if rallyActive(ev, now) then
                local contested = ev.contested and now - (ev.contested.t or 0) <= CONTEST_SECONDS
                R.Map:SetPin("Muster", id, { map = ev.rally.map, x = ev.rally.x, y = ev.rally.y, icon = RALLY_ICON,
                    color = contested and W.MARKERS.enemy or W.MARKERS.event,
                    title = ev.title .. (contested and "  (contested)" or ""),
                    text = whenText(ev.at) .. "  ·  " .. (ev.kind or "Event") })
                keep[id] = true
            end
        end
    end
    for id in pairs(R.Map:GetPins("Muster")) do
        if not keep[id] then R.Map:RemovePin("Muster", id) end
    end
end

local function yardsBetween(map, x1, y1, x2, y2)
    if not (C_Map and C_Map.GetMapWorldSize) then return nil end
    local w, h = C_Map.GetMapWorldSize(map)
    if not w or w <= 0 then return nil end
    local dx, dy = (x2 - x1) * w, (y2 - y1) * h
    return math.sqrt(dx * dx + dy * dy)
end

local function onSighting(sp)
    if type(sp) ~= "table" or sp.kind ~= "enemy" or type(sp.map) ~= "number" or not db then return end
    local now = GetServerTime()
    for _, ev in pairs(db.events) do
        if rallyActive(ev, now) then
            local tx, ty = R.Map:Translate(sp.map, sp.x, sp.y, ev.rally.map)
            local yards = tx and yardsBetween(ev.rally.map, ev.rally.x, ev.rally.y, tx, ty)
            if yards and yards <= CONTEST_YARDS then
                local fresh = not (ev.contested and now - (ev.contested.t or 0) <= CONTEST_SECONDS)
                ev.contested = { t = now, text = sp.text or "", by = sp.by }
                if fresh then
                    M:Toast(("%s rally point is contested%s (%s)"):format(ev.title,
                        (sp.text or "") ~= "" and (": " .. sp.text) or "", W.ClassName(sp.by)), { sound = true })
                end
            end
        end
    end
    updatePins()
    refreshPage()
end

M.OnSighting = onSighting

changed = function()
    refreshPage()
    updatePins()
    M:Publish("EVENTS")
end

---------------------------------------------------------------------------
-- Reminders and cleanup
---------------------------------------------------------------------------
local function tick()
    local now, me = GetServerTime(), R:GetPlayerGUID()
    rollWeekly(now)
    updatePins()
    for id, ev in pairs(db.events) do
        if ev.at + (ev.aar and 7 * 86400 or KEEP_AFTER) < now and not ev.weekly then
            db.events[id] = nil
            db.reminded[id] = nil
        elseif me and ev.signups[me] and not db.reminded[id] and ev.at - now <= REMIND_BEFORE and ev.at > now then
            db.reminded[id] = true
            M:Toast(("%s starts in %d minutes%s.%s"):format(ev.title, math.ceil((ev.at - now) / 60), myGroupText(ev),
                ns.WarRoom and ns.WarRoom.ReminderText(ev) or ""), { sound = true })
        end
    end
end

function M:SetPractice(on)
    db.practice = on and true or false
    if not db.practice then
        for id, ev in pairs(db.events) do if ev.practice then db.events[id] = nil end end
        for id, b in pairs(db.bounties) do if b.practice then db.bounties[id] = nil end end
        for id, c in pairs(db.claims) do if c.practice then db.claims[id] = nil end end
    end
    if ui.practiceCheck then ui.practiceCheck:Refresh() end
    self:Print(db.practice and "Practice mode on: post events, rallies and bounties to try Muster. Only you see practice items."
        or "Practice mode off. Practice events cleared.")
    changed()
end

---------------------------------------------------------------------------
-- Page
---------------------------------------------------------------------------
local function upcoming()
    local items, now = {}, GetServerTime()
    for _, ev in pairs(db.events) do
        if ev.at + 3600 > now then items[#items + 1] = ev end
    end
    table.sort(items, function(a, b) return a.at < b.at end)
    return items
end

local function needText(ev)
    local n = counts(ev)
    local out = {}
    for i, r in ipairs(ROLE_ORDER) do
        local want = ev.need and tonumber(ev.need[i]) or nil
        local have = n[r]
        local col = (want and have >= want) and C.good or C.white
        out[#out + 1] = W.RoleIcon(r) .. col .. (want and (have .. "/" .. want) or tostring(have)) .. "|r"
    end
    return table.concat(out, " ")
end

local function eventTooltip(ev)
    return function(tip)
        tip:AddLine(ev.title, 1, 0.82, 0)
        tip:AddLine(("%s  ·  %s%s"):format(whenText(ev.at), ev.kind or "?", ev.size and ("  ·  " .. ev.size .. " players") or ""), 1, 1, 1)
        if ev.desc and ev.desc ~= "" then tip:AddLine(ev.desc, 0.9, 0.9, 0.9, true) end
        if ev.weekly or ev.series then tip:AddLine(ev.weekly and "Repeats weekly" or "Part of a weekly series", 0.6, 0.8, 1) end
        if ev.rally then
            tip:AddLine(("Rally point: %s %.1f, %.1f (pinned on your map near the start)"):format(ev.rally.zone, ev.rally.x * 100, ev.rally.y * 100), 1, 0.6, 0.2)
            if ev.contested and GetServerTime() - (ev.contested.t or 0) <= CONTEST_SECONDS then
                tip:AddLine("Contested: " .. (ev.contested.text ~= "" and ev.contested.text or "enemies reported nearby") .. " (" .. tostring(ev.contested.by) .. ")", 1, 0.3, 0.3)
            end
        end
        tip:AddLine("Posted by " .. tostring(ev.by) .. (ev.gu and (", " .. ev.gu) or ""), 0.6, 0.6, 0.6)
        local list = sortedSignups(ev)
        if #list > 0 then tip:AddLine(" ") end
        for _, e in ipairs(list) do
            local g = ev.roster and ev.roster[e.g]
            local where = g == nil and "" or (g == 0 and "  bench" or ("  g" .. g))
            tip:AddLine(W.RoleIcon(e.s.role) .. " " .. W.ClassName(e.s.n, e.s.c) .. C.dim .. where .. "|r"
                .. (e.s.sr and (C.dim .. "  SR: |r" .. e.s.sr) or ""))
        end
    end
end

-- Events sub-page: post form (officers) and the list with sign-up buttons.
local function buildEvents(page)
    -- Top line: the list's title, practice mode, and (for whoever can post) New event.
    ui.listHeader = W.Header(page, "Upcoming events")
    ui.listHeader:SetPoint("TOPLEFT", 0, -4)
    ui.newBtn = W.Button(page, "New event", 96, function()
        ui.formOpen = not ui.formOpen
        refreshPage()
    end)
    ui.newBtn:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, 0)
    ui.practiceCheck = W.Check(page, "Practice mode", function() return db.practice end,
        function(v) M:SetPractice(v); refreshPage() end)
    ui.practiceCheck.label:SetFontObject(GameFontHighlightSmall)
    ui.practiceCheck:SetPoint("RIGHT", ui.newBtn, "LEFT", -96, 0)
    ui.practiceCheck:SetScript("OnEnter", function(self)
        W.SetBorder(self.box, "glow")
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Practice mode", 1, 1, 1)
        GameTooltip:AddLine("Try posting events, rallies and bounties. Practice items stay on your screen only.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    ui.practiceCheck:SetScript("OnLeave", function(self) W.SetBorder(self.box, "border"); if GameTooltip then GameTooltip:Hide() end end)

    -- The form, shown under the top line while New event is open:
    --   title, type, size / day, time, weekly, rally / description, needs, Post
    ui.officer = W.Card(page)
    ui.officer:SetPoint("TOPLEFT", 0, -28)
    ui.officer:SetPoint("RIGHT", page, "RIGHT", -4, 0)
    ui.officer:SetHeight(122)
    local f = ui.officer
    local h = W.Header(f, "New event")
    h:SetPoint("TOPLEFT", 8, -6)
    local title = W.EditBox(f, 250, nil, "Event title, e.g. Molten Core")
    title:SetPoint("TOPLEFT", 64, -28)
    local tl = W.Label(f, C.dim .. "Title|r", "GameFontHighlightSmall")
    tl:SetPoint("RIGHT", title, "LEFT", -8, 0)
    local kind = W.Cycle(f, 108, KINDS, function() return ui.kind end, function(v) ui.kind = v end, "Type: ")
    kind:SetPoint("LEFT", title, "RIGHT", 10, 0)
    local needBoxes = {}
    local size = W.Cycle(f, 100, SIZES, function() return ui.size end, function(v)
        ui.size = v
        local d = NEED_FOR[v] or { 0, 0, 0 }
        for i = 1, 3 do ui.need[i] = d[i]; needBoxes[i]:SetText(d[i] > 0 and tostring(d[i]) or "") end
    end, "Size: ")
    size:SetPoint("LEFT", kind, "RIGHT", 6, 0)
    size.tipTitle = "Group size; fills in how many tanks, healers and DPS are needed"

    -- when: a day list and hour : minute AM/PM boxes (your local time)
    local when = W.WhenPicker(f)
    when:SetPoint("TOPLEFT", 64, -58)
    ui.when = when
    local wl = W.Label(f, C.dim .. "Starts|r", "GameFontHighlightSmall")
    wl:SetPoint("RIGHT", when, "LEFT", -8, 0)
    local tz = W.Label(f, C.dim .. "your time|r", "GameFontHighlightSmall")
    tz:SetPoint("LEFT", when, "RIGHT", 8, 0)

    local desc = W.EditBox(f, 250, nil, "Description (optional)")
    desc:SetPoint("TOPLEFT", 64, -88)
    local dl = W.Label(f, C.dim .. "About|r", "GameFontHighlightSmall")
    dl:SetPoint("RIGHT", desc, "LEFT", -8, 0)
    local nl = W.Label(f, C.dim .. "Needs|r", "GameFontHighlightSmall")
    nl:SetPoint("LEFT", desc, "RIGHT", 10, 0)
    local prev = nl
    for i, role in ipairs({ "T", "H", "D" }) do
        local icon = W.Label(f, W.RoleIcon(role, 14))
        icon:SetPoint("LEFT", prev, "RIGHT", i == 1 and 6 or 8, 0)
        local b = W.EditBox(f, 30, function(t) ui.need[i] = tonumber(t) or 0 end)
        b:SetPoint("LEFT", icon, "RIGHT", 3, 0)
        if b.SetNumeric then b:SetNumeric(true) end
        if b.SetMaxLetters then b:SetMaxLetters(2) end
        needBoxes[i] = b
        prev = b
    end
    local weekly = W.Check(f, "Weekly", function() return ui.weekly end, function(v) ui.weekly = v end)
    weekly:SetPoint("LEFT", tz, "RIGHT", 18, 0)
    weekly.tip = "Post it again for the same day and time every week."
    local rally = W.Check(f, "Rally here", function() return ui.rally end, function(v) ui.rally = v end)
    rally:SetPoint("LEFT", weekly, "RIGHT", 58, 0)
    rally.tip = "Put a rally point on everyone's map where you stand now."
    local post = W.Button(f, "Post", 72, function()
        for i = 1, 3 do ui.need[i] = tonumber(needBoxes[i]:GetText()) or 0 end
        local at, err = when:GetTime()
        if not at then return M:Print("Check the start time: " .. tostring(err) .. ".") end
        if at < GetServerTime() - 60 then return M:Print("That start time has already passed. Pick a later day or time.") end
        local ev = M:Create(title:GetText(), at, { kind = ui.kind, desc = desc:GetText(), size = ui.size,
                                                   need = ui.need, weekly = ui.weekly, rally = ui.rally })
        if ev then
            title:SetText(""); desc:SetText("")
            ui.formOpen = false
            refreshPage()
        end
    end)
    post:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 8)
    ui.postBtn, ui.titleBox = post, title

    ui.list = W.List(page, 30, function(row)
        row.text = W.Label(row, "")
        row.text:SetPoint("LEFT", 4, 0)
        row.text:SetPoint("RIGHT", row, "RIGHT", -222, 0)
        row.text:SetWordWrap(false)
        row.del = W.Button(row, "Delete", 56)
        row.del:SetPoint("RIGHT", 0, 0)
        row.no = W.Button(row, "Leave", 48)
        row.no:SetPoint("RIGHT", row.del, "LEFT", -4, 0)
        local prevBtn = row.no
        for _, role in ipairs({ "D", "H", "T" }) do
            local key = role:lower()
            row[key] = W.Button(row, W.RoleIcon(role, 16), 34)
            row[key]:SetPoint("RIGHT", prevBtn, "LEFT", -2, 0)
            row[key]:HookScript("OnEnter", function(self)
                if not GameTooltip then return end
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:AddLine("Sign up as " .. ROLE_NAMES[role], 1, 1, 1)
                GameTooltip:Show()
            end)
            row[key]:HookScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
            prevBtn = row[key]
        end
    end, function(row, ev)
        local mine = ev.signups[R:GetPlayerGUID() or ""]
        local status = mine and (C.good .. "  you: " .. ROLE_NAMES[mine.role] .. myGroupText(ev) .. "|r") or ""
        local rep = (ev.weekly or ev.series) and (C.dim .. " (weekly)|r") or ""
        local prac = ev.practice and (C.dim .. " [practice]|r") or ""
        row.text:SetText(("%s%s|r  %s%s%s  %s%s%s"):format(C.gold, whenText(ev.at), ev.title, rep, prac, needText(ev), status, rallyText(ev)))
        row.tip = eventTooltip(ev)
        row.t:SetScript("OnClick", function() M:SignUp(ev.id, "T") end)
        row.h:SetScript("OnClick", function() M:SignUp(ev.id, "H") end)
        row.d:SetScript("OnClick", function() M:SignUp(ev.id, "D") end)
        row.no:SetScript("OnClick", function() M:SignUp(ev.id, nil) end)
        -- line the buttons up from the right, without gaps for hidden ones
        local right = nil
        for _, b in ipairs({ row.del, row.no, row.d, row.h, row.t }) do
            local show = (b ~= row.del or canManage(ev)) and (b ~= row.no or mine ~= nil)
            b:SetShown(show)
            if show then
                b:ClearAllPoints()
                if right then b:SetPoint("RIGHT", right, "LEFT", b == row.no and -4 or -2, 0) else b:SetPoint("RIGHT", row, "RIGHT", 0, 0) end
                right = b
            end
        end
        row.del:SetScript("OnClick", function() M:Delete(ev.id) end)
    end)
    ui.list:SetEmptyText("No upcoming events yet. Officers (and the ranks they allow) post raid nights, PvP pushes and leveling groups here, for every RUIN guild.")

    local foot = W.Label(page, C.dim .. "Press a role to sign up. Hover an event for details and who's coming. Times are your local time.|r", "GameFontHighlightSmall")
    foot:SetPoint("BOTTOMLEFT", 0, 2)
    foot:SetPoint("RIGHT", page, "RIGHT", -6, 0)
end

local function layoutEvents()
    local can = canPost()
    if not can then ui.formOpen = false end
    ui.newBtn:SetShown(can)
    ui.newBtn:SetText(ui.formOpen and "Close" or "New event")
    ui.practiceCheck:ClearAllPoints()
    if can then
        ui.practiceCheck:SetPoint("RIGHT", ui.newBtn, "LEFT", -96, 0)
    else
        ui.practiceCheck:SetPoint("TOPRIGHT", ui.eventsPage, "TOPRIGHT", -96, 0)
    end
    ui.practiceCheck:SetShown(not R:IsOfficer() or db.practice)
    ui.officer:SetShown(ui.formOpen)
    ui.list.frame:ClearAllPoints()
    ui.list.frame:SetPoint("TOPLEFT", 0, ui.formOpen and -160 or -30)
    ui.list.frame:SetPoint("BOTTOMRIGHT", ui.eventsPage, "BOTTOMRIGHT", -24, 22)
end

-- Events the Roster, Reserves, War Room and Loot pages can show: upcoming,
-- and those that started in the last hours (loot notes and reports come after).
local function pickable()
    local items, now = {}, GetServerTime()
    for _, ev in pairs(db.events) do
        if ev.at + KEEP_AFTER > now or (ev.aar and ev.at + 7 * 86400 > now) then items[#items + 1] = ev end
    end
    table.sort(items, function(a, b) return a.at < b.at end)
    return items
end

-- Pick which event the Roster, Reserves, War Room and Loot pages show.
local function pickedEvent()
    local items = pickable()
    if #items == 0 then return nil, items end
    for _, ev in ipairs(items) do if ev.id == ui.picked then return ev, items end end
    ui.picked = items[1].id
    return items[1], items
end

local function eventPicker(page, onChange)
    local b = W.MarkChoice(W.Button(page, "", 300, nil))
    b.tipTitle = "Which event"
    b:SetScript("OnClick", function(_, mouse)
        local _, items = pickedEvent()
        if #items == 0 then return end
        local idx = 1
        for i, ev in ipairs(items) do if ev.id == ui.picked then idx = i end end
        idx = (mouse == "RightButton") and ((idx - 2) % #items + 1) or (idx % #items + 1)
        ui.picked = items[idx].id
        onChange()
    end)
    b.Refresh = function()
        local ev = pickedEvent()
        b:SetText(ev and (ev.title .. "  ·  " .. date("%a %H:%M", ev.at)) or "No upcoming events")
    end
    return b
end

-- Roster sub-page: up to eight groups of five plus the bench.
local function buildRoster(page)
    local h = W.Header(page, "Event")
    h:SetPoint("TOPLEFT", 0, -2)
    ui.rosterPick = eventPicker(page, function() refreshPage() end)
    ui.rosterPick:SetPoint("TOPLEFT", 50, 2)
    ui.autoBtn = W.Button(page, "Auto-fill", 90, function() if ui.picked then M:AutoRoster(ui.picked) end end)
    ui.autoBtn:SetPoint("LEFT", ui.rosterPick, "RIGHT", 8, 0)
    ui.sendBtn = W.Button(page, "Send roster", 100, function() if ui.picked then M:PublishRoster(ui.picked) end end)
    ui.sendBtn:SetPoint("LEFT", ui.autoBtn, "RIGHT", 4, 0)

    ui.groups = {}
    for i = 1, 8 do
        local card = W.Card(page)
        card:SetSize(166, 112)
        local col, rowN = (i - 1) % 4, math.floor((i - 1) / 4)
        card:SetPoint("TOPLEFT", col * 172, -34 - rowN * 118)
        card.title = W.Label(card, C.gold .. "Group " .. i .. "|r", "GameFontNormalSmall")
        card.title:SetPoint("TOPLEFT", 6, -4)
        card.slots = {}
        for j = 1, 5 do
            local b = CreateFrame("Button", nil, card)
            b:SetSize(156, 17)
            b:SetPoint("TOPLEFT", 5, -4 - j * 18)
            b.text = W.Label(b, "", "GameFontHighlightSmall")
            b.text:SetPoint("LEFT", 2, 0)
            b.text:SetPoint("RIGHT", b, "RIGHT", 0, 0)
            b.text:SetWordWrap(false)
            card.slots[j] = b
        end
        ui.groups[i] = card
    end
    local bh = W.Header(page, "Bench")
    bh:SetPoint("TOPLEFT", 0, -276)
    ui.bench = W.Label(page, "", "GameFontHighlightSmall")
    ui.bench:SetPoint("TOPLEFT", 0, -300)
    ui.bench:SetPoint("RIGHT", page, "RIGHT", -6, 0)
    ui.bench:SetJustifyV("TOP")
    ui.rosterHint = W.Label(page, "", "GameFontHighlightSmall")
    ui.rosterHint:SetPoint("BOTTOMLEFT", 0, 2)
    ui.rosterHint:SetPoint("RIGHT", page, "RIGHT", -6, 0)
end

local function refreshRoster()
    local ev = pickedEvent()
    ui.rosterPick.Refresh()
    local officer = canManage(ev)
    ui.autoBtn:SetShown(officer and ev ~= nil)
    ui.sendBtn:SetShown(officer and ev ~= nil and ev.roster ~= nil)
    for i, card in ipairs(ui.groups) do
        card:SetShown(ev ~= nil and i <= groupCount(ev))
        for _, b in ipairs(card.slots) do b.text:SetText(""); b:SetScript("OnClick", nil) end
    end
    if not ev then
        ui.bench:SetText("")
        ui.rosterHint:SetText(C.dim .. "No upcoming events.|r")
        return
    end
    local used, bench, unplaced = {}, {}, {}
    for _, e in ipairs(sortedSignups(ev)) do
        local g = ev.roster and ev.roster[e.g]
        local label = W.RoleIcon(e.s.role) .. " " .. W.ClassName(e.s.n, e.s.c)
        if g and g > 0 and ui.groups[g] then
            used[g] = (used[g] or 0) + 1
            local b = ui.groups[g].slots[used[g]]
            if b then
                b.text:SetText(label)
                if officer then b:SetScript("OnClick", function() M:CycleGroup(ev.id, e.g) end) end
            end
        elseif g == 0 then
            bench[#bench + 1] = label
        else
            unplaced[#unplaced + 1] = label
        end
    end
    local benchText = #bench > 0 and table.concat(bench, "   ") or (C.dim .. "Nobody on the bench.|r")
    if #unplaced > 0 then benchText = benchText .. "\n" .. C.dim .. "Not placed yet: |r" .. table.concat(unplaced, "   ") end
    ui.bench:SetText(benchText)
    ui.rosterHint:SetText(C.dim .. (officer and "Auto-fill places sign-ups by role; click a name to move it to the next group or the bench, then Send roster."
        or "Officers arrange the groups. You get an alert with your group when they send the roster.") .. "|r")
end

-- Reserves sub-page: your soft reserve and everyone's, with clashes counted.
local function buildReserves(page)
    local h = W.Header(page, "Event")
    h:SetPoint("TOPLEFT", 0, -2)
    ui.srPick = eventPicker(page, function() refreshPage() end)
    ui.srPick:SetPoint("TOPLEFT", 50, 2)

    local card = W.Card(page)
    card:SetPoint("TOPLEFT", 0, -34)
    card:SetPoint("RIGHT", page, "RIGHT", -4, 0)
    card:SetHeight(52)
    local lbl = W.Label(card, C.gold .. "Your soft reserve|r", "GameFontNormalSmall")
    lbl:SetPoint("TOPLEFT", 8, -6)
    ui.srBox = W.EditBox(card, 300)
    ui.srBox:SetPoint("TOPLEFT", 12, -24)
    local save = W.Button(card, "Reserve", 80, function() if ui.picked then M:Reserve(ui.picked, ui.srBox:GetText()) end end)
    save:SetPoint("LEFT", ui.srBox, "RIGHT", 8, 0)
    local clear = W.Button(card, "Clear", 60, function() if ui.picked then ui.srBox:SetText(""); M:Reserve(ui.picked, "") end end)
    clear:SetPoint("LEFT", save, "RIGHT", 4, 0)
    local hint = W.Label(card, C.dim .. "Shift-click an item, or type its name|r", "GameFontHighlightSmall")
    hint:SetPoint("LEFT", clear, "RIGHT", 8, 0)

    local h2 = W.Header(page, "Reserved by RUIN")
    h2:SetPoint("TOPLEFT", 0, -96)
    ui.srList = W.List(page, 22, function(row)
        row.text = W.Label(row, "")
        row.text:SetPoint("LEFT", 4, 0)
        row.text:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.text:SetWordWrap(false)
    end, function(row, e)
        local clash = e.clash > 1 and (C.bad .. "  ·  " .. e.clash .. " reserves|r") or ""
        row.text:SetText(e.item .. "  " .. W.RoleIcon(e.role) .. " " .. W.ClassName(e.name, e.class) .. clash)
        row.link = e.item:match("|H(item:[^|]+)|h")
    end)
    ui.srList:SetEmptyText("No reserves yet for this event.")
    ui.srList.frame:SetPoint("TOPLEFT", 0, -114)
    ui.srList.frame:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -24, 0)

    -- Shift-clicking an item while the reserve box has focus drops its link in.
    local function insert(link)
        if ui.srBox and ui.srBox:HasFocus() and type(link) == "string" then ui.srBox:SetText(link) end
    end
    if ChatEdit_InsertLink then pcall(hooksecurefunc, "ChatEdit_InsertLink", insert) end
    if ChatFrameUtil and ChatFrameUtil.InsertLink then pcall(hooksecurefunc, ChatFrameUtil, "InsertLink", insert) end
end

local function refreshReserves()
    local ev = pickedEvent()
    ui.srPick.Refresh()
    local items = {}
    if ev then
        local byItem = {}
        for _, e in ipairs(sortedSignups(ev)) do
            if e.s.sr then
                local key = (e.s.sr:match("item:(%d+)") or e.s.sr:lower())
                byItem[key] = (byItem[key] or 0) + 1
                items[#items + 1] = { item = e.s.sr, key = key, name = e.s.n, class = e.s.c, role = e.s.role }
            end
        end
        for _, it in ipairs(items) do it.clash = byItem[it.key] end
        table.sort(items, function(a, b) if a.key ~= b.key then return a.key < b.key end return a.name < b.name end)
        local mine = ev.signups[R:GetPlayerGUID() or ""]
        if ui.srBox and not ui.srBox:HasFocus() then ui.srBox:SetText(mine and mine.sr or "") end
    end
    ui.srList:SetItems(items)
end

-- Bounties sub-page (from RUIN Warfront): post, claim, witness.
local function buildBounties(page)
    ui.bountyPage = page
    ui.bountyCard = W.Card(page)
    ui.bountyCard:SetPoint("TOPLEFT", 0, 0)
    ui.bountyCard:SetPoint("RIGHT", page, "RIGHT", -4, 0)
    ui.bountyCard:SetHeight(58)
    local f = ui.bountyCard
    local h = W.Header(f, "Post a bounty")
    h:SetPoint("TOPLEFT", 8, -6)
    local kind = W.Cycle(f, 118, { "Guild", "Player" }, function() return ui.bKind end, function(v) ui.bKind = v end, "On a: ")
    kind:SetPoint("TOPLEFT", 8, -26)
    kind.tipTitle = "Put the bounty on a whole guild or one player"
    local target = W.EditBox(f, 200, nil, "Guild or player name")
    target:SetPoint("LEFT", kind, "RIGHT", 8, 0)
    local reward = W.EditBox(f, 150, nil, "Reward (optional)")
    reward:SetPoint("LEFT", target, "RIGHT", 8, 0)
    local post = W.Button(f, "Post", 64, function()
        M:PostBounty(target:GetText(), ui.bKind, reward:GetText())
        target:SetText(""); reward:SetText("")
    end)
    post:SetPoint("LEFT", reward, "RIGHT", 8, 0)

    ui.bountyHeader = W.Header(page, "Open bounties")
    ui.bountyList = W.List(page, 24, function(row)
        row.text = W.Label(row, "")
        row.text:SetPoint("LEFT", 4, 0)
        row.text:SetPoint("RIGHT", row, "RIGHT", -70, 0)
        row.text:SetWordWrap(false)
        row.del = W.Button(row, "Remove", 66)
        row.del:SetPoint("RIGHT", 0, 0)
    end, function(row, b)
        local kills = 0
        for _, c in pairs(db.claims) do if c.b == b.id and c.confirmed then kills = kills + 1 end end
        row.text:SetText(("%s%s|r %s%s|r%s  %s· by %s · %s left|r%s%s"):format(C.dim, b.kind == "Player" and "player" or "guild",
            C.gold, b.target, (b.reward or "") ~= "" and ("  " .. C.good .. b.reward .. "|r") or "", C.dim, tostring(b.by),
            W.Duration((b.exp or 0) - GetServerTime()), kills > 0 and ("  ·  " .. kills .. " confirmed kill" .. (kills == 1 and "" or "s")) or "",
            b.practice and (C.dim .. " [practice]|r") or ""))
        row.del:SetShown(canBounty())
        row.del:SetScript("OnClick", function() M:RemoveBounty(b.id) end)
    end)
    ui.bountyList:SetEmptyText("No bounties posted. Officers can put a price on a rival guild or player.")

    ui.claimBtn = W.Button(page, "Claim kill on target", 170, function() M:ClaimKill() end)
    ui.claimHeader = W.Header(page, "Claims")
    ui.claimList = W.List(page, 24, function(row)
        row.text = W.Label(row, "")
        row.text:SetPoint("LEFT", 4, 0)
        row.text:SetPoint("RIGHT", row, "RIGHT", -84, 0)
        row.text:SetWordWrap(false)
        row.ok = W.Button(row, "Confirm", 80)
        row.ok:SetPoint("RIGHT", 0, 0)
    end, function(row, c)
        local state = c.confirmed and (C.good .. "confirmed by " .. R.Util.ShortName(c.confirmed) .. "|r")
            or (C.gold .. "needs a witness · " .. W.Duration(CLAIM_SECONDS - (GetServerTime() - (c.t or 0))) .. " left|r")
        row.text:SetText(("%s killed %s%s|r%s  %s"):format(W.ClassName(c.by), C.white, c.v,
            c.vg and (C.dim .. " <" .. c.vg .. ">|r") or "", state))
        local mine = R.Util.ShortName(c.by or "") == R.Util.ShortName(UnitName("player") or "")
        row.ok:SetShown(not c.confirmed and not mine)
        row.ok:SetScript("OnClick", function() M:Confirm(c.id) end)
    end)
    ui.claimList:SetEmptyText("Kill a bountied enemy, target the body and press Claim. Another RUIN member who saw it confirms.")

    -- The faction-wide war lives in Overlord Forever.
    ui.ovLine = W.Label(page, "", "GameFontHighlightSmall")
    ui.ovLine:SetPoint("BOTTOMLEFT", 0, 4)
    ui.ovLine:SetPoint("RIGHT", page, "RIGHT", -110, 0)
    ui.ovLine:SetWordWrap(false)
    ui.ovBtn = W.Button(page, "Open Overlord", 104, function() R:OpenOverlord() end)
    ui.ovBtn:SetPoint("BOTTOMRIGHT", 0, 0)
end

local function layoutBounties()
    local officer = canBounty()
    ui.bountyCard:SetShown(officer)
    local top = officer and -66 or 0
    ui.bountyHeader:ClearAllPoints()
    ui.bountyHeader:SetPoint("TOPLEFT", 0, top - 2)
    ui.bountyList.frame:ClearAllPoints()
    ui.bountyList.frame:SetPoint("TOPLEFT", 0, top - 20)
    ui.bountyList.frame:SetPoint("RIGHT", ui.bountyPage, "RIGHT", -24, 0)
    ui.bountyList.frame:SetHeight(officer and 110 or 160)
    ui.claimBtn:ClearAllPoints()
    ui.claimBtn:SetPoint("TOPRIGHT", ui.bountyList.frame, "BOTTOMRIGHT", 24, -8)
    ui.claimHeader:ClearAllPoints()
    ui.claimHeader:SetPoint("TOPLEFT", ui.bountyList.frame, "BOTTOMLEFT", 0, -12)
    ui.claimList.frame:ClearAllPoints()
    ui.claimList.frame:SetPoint("TOPLEFT", ui.claimHeader, "BOTTOMLEFT", 0, -10)
    ui.claimList.frame:SetPoint("BOTTOMRIGHT", ui.bountyPage, "BOTTOMRIGHT", -24, 30)
    local hasOv = R:HasOverlord()
    ui.ovLine:SetText(C.dim .. (hasOv and "Faction-wide campaign, keeps and captures: Overlord Forever. RUIN's own Most Wanted is on its tab."
        or "For the faction-wide world PvP campaign, RUIN works alongside Overlord Forever (not installed).") .. "|r")
    ui.ovBtn:SetShown(hasOv)
end

-- For the War Room, Loot and Most Wanted tabs (WarRoom.lua, Loot.lua, Wanted.lua).
local internals = {
    db = function() return db end,
    canManage = function(ev) return canManage(ev) end,
    changed = function() changed() end,
    eventPicker = function(page, onChange) return eventPicker(page, onChange) end,
    pickedEvent = function() return pickedEvent() end,
    sortedSignups = function(ev) return sortedSignups(ev) end,
}
ns.MusterInternals = internals

local TABS = { "Events", "Roster", "Reserves", "War Room", "Loot", "Bounties", "Wanted", "Sightings" }
local function tabIndex(name) for i, n in ipairs(TABS) do if n == name then return i end end end

local function buildPage(panel)
    ui.panel = panel
    ui.tabs = W.SubTabs(panel, TABS, function() refreshPage() end)
    ui.eventsPage = ui.tabs.pages[1]
    buildEvents(ui.tabs.pages[1])
    buildRoster(ui.tabs.pages[2])
    buildReserves(ui.tabs.pages[3])
    ns.WarRoom.Build(ui.tabs.pages[4])
    ns.Loot.Build(ui.tabs.pages[5])
    buildBounties(ui.tabs.pages[6])
    ns.Wanted.Build(ui.tabs.pages[7])
    ns.World.BuildSightings(ui.tabs.pages[8])

    refreshPage = function()
        if not ui.panel:IsVisible() then return end
        local items = upcoming()
        ui.tabs:SetLabel(1, #items > 0 and ("Events (" .. #items .. ")") or "Events")
        local name = TABS[ui.tabs.selected]
        if name == "Events" then
            layoutEvents()
            ui.list:SetItems(items)
        elseif name == "Roster" then
            refreshRoster()
        elseif name == "Reserves" then
            refreshReserves()
        elseif name == "War Room" then
            ns.WarRoom.Refresh()
        elseif name == "Loot" then
            ns.Loot.Refresh()
        elseif name == "Bounties" then
            layoutBounties()
            ui.bountyList:SetItems(activeBounties())
            ui.claimList:SetItems(openClaims())
        elseif name == "Wanted" then
            ns.Wanted.Refresh()
        elseif name == "Sightings" then
            ns.World.Refresh("sightings")
        end
        local nSight = #ns.World.Active()
        ui.tabs:SetLabel(tabIndex("Sightings"), nSight > 0 and ("Sightings (" .. nSight .. ")") or "Sightings")
        local nb = #activeBounties()
        ui.tabs:SetLabel(tabIndex("Bounties"), nb > 0 and ("Bounties (" .. nb .. ")") or "Bounties")
        local nw = ns.Wanted.Count()
        ui.tabs:SetLabel(tabIndex("Wanted"), nw > 0 and ("Wanted (" .. nw .. ")") or "Wanted")
    end
    panel:SetScript("OnShow", function() refreshPage() end)
    ui.tabs:Select(1)
end

function M:SelectSubTab(name)
    local i = tabIndex(name)
    if ui.tabs and i then ui.tabs:Select(i) end
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------
function M:OnEnable()
    if type(RUIN_MusterDB) ~= "table" then RUIN_MusterDB = {} end
    db = RUIN_MusterDB
    for k, v in pairs(DEFAULTS) do if db[k] == nil then db[k] = v end end

    self:Listen("EVENT", "OnEvent")
    self:Listen("SIGN", "OnSign")
    self:Listen("DELETE", "OnDelete")
    self:Listen("ROSTER", "OnRoster")
    self:Listen("ASK", "OnAsk")
    self:Listen("BOUNTY", "OnBounty")
    self:Listen("BDEL", "OnBountyDelete")
    self:Listen("CLAIM", "OnClaim")
    self:Listen("CONFIRM", "OnConfirm")
    self:AddTab("Muster", buildPage)
    ns.World.Init(self, db, function() refreshPage() end)
    ns.Wanted.Init(self, db)
    ns.WarRoom.Init(self, internals)
    ns.Loot.Init(self, internals, db)

    R:Subscribe("CHANNELS_CHANGED", function()
        C_Timer.After(6, function() if R:IsConnected() then self:Send("ASK", {}, "ORG") end end)
    end)
    C_Timer.NewTicker(30, tick)
end

function RUIN_Muster_Open() M:OpenTab() end
function RUIN_Muster_Claim() M:ClaimKill() end
BINDING_HEADER_RUIN_MUSTER = "RUIN Muster"
BINDING_NAME_RUIN_MUSTER_OPEN = "Open Muster"
BINDING_NAME_RUIN_MUSTER_CLAIM = "Muster: claim bounty kill on target"

-- /muster [spot <kind> [detail] | wanted | war | loot | practice | rally <name> | bounty guild|player <name> (reward) | claim | confirm | pins]
SLASH_RUINMUSTER1 = "/muster"
SlashCmdList.RUINMUSTER = function(input)
    input = input or ""
    local cmd, rest = input:match("^%s*(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()
    if cmd == "practice" then
        M:SetPractice(not db.practice)
    elseif cmd == "rally" then
        M:Rally(rest)
    elseif cmd == "bounty" then
        local kind, target = rest:match("^(%S+)%s+(.+)$")
        kind = kind and kind:lower()
        if kind ~= "guild" and kind ~= "player" then return M:Print("Usage: /muster bounty guild|player <name> (reward)") end
        local name, reward = target:match("^(.-)%s*%((.-)%)%s*$")
        M:PostBounty(name or target, kind == "player" and "Player" or "Guild", reward)
    elseif cmd == "claim" then
        M:ClaimKill()
    elseif cmd == "confirm" then
        M:Confirm()
    elseif cmd == "spot" then
        ns.World.Slash(rest)
    elseif cmd == "timer" or cmd == "timers" then
        if SlashCmdList.RUINFINDER then
            SlashCmdList.RUINFINDER("timer " .. rest)
        else
            M:Print("World boss and buff timers moved to RUIN Finder (Finder > Timers). Install RUIN Finder 0.4.1 or later.")
        end
    elseif cmd == "wanted" or cmd == "war" or cmd == "warroom" or cmd == "loot" then
        M:OpenTab()
        M:SelectSubTab(cmd == "wanted" and "Wanted" or cmd == "loot" and "Loot" or "War Room")
    elseif cmd == "pins" then
        db.pins = not db.pins
        updatePins()
        M:Print("Rally pins " .. (db.pins and "on." or "off."))
    else
        M:OpenTab()
    end
end
