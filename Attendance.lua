-- RUIN Muster: attendance and reminders
-- Attendance: while an event runs (from its start for three hours), the
-- event's leaders note who is in their group every few minutes and share it.
-- Everyone then sees, per player this season: events attended, events they
-- signed up for, ones they signed up for and missed, and their loot (from the
-- loot notes). Loot > Attendance.
-- Reminders: 30 minutes and 5 minutes before an event you signed up for,
-- Muster tells you (Remind me, on that page, or /muster remind).
local ADDON, ns = ...
local R = RUIN_API
if not R or (R.apiLevel or 1) < 8 then return end
local W = R.Widgets
local C = W.COLORS

local A = {}
ns.Attendance = A

local SEASON = 90 * 86400
local WINDOW = 3 * 3600          -- an event counts as running for three hours from its start
local SNAP_EVERY = 300
local REMIND = { 30, 5 }          -- minutes before

local M, MC, db
local ui = {}

local function now() return GetServerTime() end
local function short(n) return R.Util.ShortName(n or "?") end
local function store()
    db.attend = db.attend or {}
    db.reminded = db.reminded or {}
    return db.attend
end

-- who is in your group now: { lowercased short name = name }
local function groupNow()
    local out = {}
    local me = UnitName and UnitName("player")
    if me then out[me:lower()] = me end
    if IsInRaid and IsInRaid() and GetRaidRosterInfo then
        for i = 1, (GetNumGroupMembers and GetNumGroupMembers() or 0) do
            local n = GetRaidRosterInfo(i)
            if n then out[short(n):lower()] = short(n) end
        end
    elseif IsInGroup and IsInGroup() then
        for i = 1, 4 do
            local n = UnitName("party" .. i)
            if n then out[short(n):lower()] = short(n) end
        end
    end
    return out
end

local function running(ev) return ev and ev.at and not ev.practice and now() >= ev.at and now() <= ev.at + WINDOW end

-- merge names into an event's record; true when something was new
local function merge(evId, title, at, names)
    local rec = store()[evId]
    if not rec then rec = { title = title, at = at, present = {} }; store()[evId] = rec end
    rec.title, rec.at = title or rec.title, at or rec.at
    local added = false
    for k, n in pairs(names) do
        if not rec.present[k] then rec.present[k] = n; added = true end
    end
    return added
end

-- a leader's client: note the group for running events you lead, and share it
function A.Snapshot()
    local events = MC.db().events
    local inGroup = (IsInGroup and IsInGroup()) or (IsInRaid and IsInRaid())
    if not inGroup then return 0 end
    local n = 0
    for id, ev in pairs(events) do
        if running(ev) and MC.canManage(ev) then
            local names = groupNow()
            if merge(id, ev.title, ev.at, names) then
                local list = {}
                for _, v in pairs(store()[id].present) do list[#list + 1] = v end
                M:Send("ATTEND", { id = id, ti = ev.title, at = ev.at, n = list }, "ORG", nil, R.PRIORITY.BULK)
            end
            n = n + 1
        end
    end
    return n
end

local function onAttend(_, d, sender)
    if type(d) ~= "table" or type(d.id) ~= "string" or type(d.n) ~= "table" then return end
    local ev = MC.db().events[d.id]
    -- from the event's author or an officer only
    local ok = (ev and short(ev.by):lower() == short(sender):lower()) or (R.IsOfficerName and R:IsOfficerName(sender))
    if not ok then return end
    local names = {}
    for i = 1, math.min(#d.n, 80) do
        local v = d.n[i]
        if type(v) == "string" and v ~= "" then names[short(v):lower()] = short(v):sub(1, 40) end
    end
    merge(d.id, ev and ev.title or (type(d.ti) == "string" and d.ti:sub(1, 40)), ev and ev.at or tonumber(d.at), names)
    -- who signed up, kept with the record once the event is gone from the list
    if ev then
        local rec = store()[d.id]
        rec.signed = rec.signed or {}
        for _, s in pairs(ev.signups or {}) do if s.n then rec.signed[short(s.n):lower()] = short(s.n) end end
    end
    A.Refresh()
end

-- remember who signed up for each running or past event (the event list forgets old ones)
local function noteSignups()
    for id, ev in pairs(MC.db().events) do
        if ev.at and now() >= ev.at and not ev.practice then
            local rec = store()[id]
            if rec then
                rec.signed = rec.signed or {}
                for _, s in pairs(ev.signups or {}) do if s.n then rec.signed[short(s.n):lower()] = short(s.n) end end
            end
        end
    end
end

-- This season, per player: { name, attended, signed, missed, rate, loot, pts, last }
function A.Stats()
    noteSignups()
    local by = {}
    local function row(k, n)
        local r = by[k]
        if not r then r = { name = n, attended = 0, signed = 0, missed = 0, loot = 0, pts = 0, last = 0 }; by[k] = r end
        return r
    end
    for _, rec in pairs(store()) do
        if rec.at and now() - rec.at <= SEASON then
            for k, n in pairs(rec.present or {}) do
                local r = row(k, n)
                r.attended = r.attended + 1
                if rec.at > r.last then r.last = rec.at end
            end
            for k, n in pairs(rec.signed or {}) do
                local r = row(k, n)
                r.signed = r.signed + 1
                if not (rec.present or {})[k] and now() > rec.at + WINDOW then r.missed = r.missed + 1 end
            end
        end
    end
    for _, t in ipairs(ns.Loot and ns.Loot.Totals and ns.Loot.Totals() or {}) do
        local r = row(short(t.name):lower(), short(t.name))
        r.loot, r.pts = t.count, t.pts
    end
    local out = {}
    for _, r in pairs(by) do
        r.rate = r.signed > 0 and math.floor((r.signed - r.missed) / r.signed * 100 + 0.5) or nil
        out[#out + 1] = r
    end
    table.sort(out, function(a, b)
        if a.attended ~= b.attended then return a.attended > b.attended end
        return (a.name or "") < (b.name or "")
    end)
    return out
end

---------------------------------------------------------------------------
-- Reminders
---------------------------------------------------------------------------
function A.CheckReminders()
    if db.remind == false then return 0 end
    local me = R:GetPlayerGUID()
    local n = 0
    for id, ev in pairs(MC.db().events) do
        local s = me and ev.signups and ev.signups[me]
        if s and ev.at and not ev.practice then
            local left = ev.at - now()
            db.reminded[id] = db.reminded[id] or {}
            for _, mins in ipairs(REMIND) do
                if left > 0 and left <= mins * 60 and not db.reminded[id][mins] then
                    -- tell only the nearest reminder due (no 30 and 5 at once after a late login)
                    for _, other in ipairs(REMIND) do if other >= mins then db.reminded[id][other] = true end end
                    local role = s.role == "T" and "tank" or s.role == "H" and "healer" or "damage"
                    M:Toast(("%s starts in %d min (you signed up as %s)."):format(ev.title, math.max(1, math.ceil(left / 60)), role), { sound = true })
                    n = n + 1
                    break
                end
            end
        end
    end
    for id in pairs(db.reminded) do if not MC.db().events[id] then db.reminded[id] = nil end end
    return n
end

---------------------------------------------------------------------------
-- Loot > Attendance
---------------------------------------------------------------------------
function A.Build(page)
    local h = W.Header(page, "Attendance this season")
    h:SetPoint("TOPLEFT", 0, -2)
    ui.sub = W.Label(page, C.dim .. "Noted by each event's leaders while it runs. Signed up and missed counts once the event is over.|r",
        "GameFontHighlightSmall")
    ui.sub:SetPoint("TOPLEFT", 0, -24)
    ui.remind = W.Check(page, "Remind me before events I've signed up for", function() return db.remind ~= false end,
        function(v) db.remind = v end)
    ui.remind:SetPoint("TOPRIGHT", page, "TOPRIGHT", -290, -2)
    ui.remind.tip = "30 minutes and 5 minutes before an event you signed up for."
    ui.heads = W.Label(page, C.dim .. "Player                                   Attended      Signed up      Missed      Loot (points)      Last event|r",
        "GameFontHighlightSmall")
    ui.heads:SetPoint("TOPLEFT", 6, -46)
    ui.list = W.List(page, 24, function(row)
        local function col(x, w)
            local l = W.Label(row, "", "GameFontHighlightSmall")
            l:SetPoint("LEFT", x, 0)
            l:SetWidth(w)
            l:SetWordWrap(false)
            return l
        end
        row.name = W.Label(row, "")
        row.name:SetPoint("LEFT", 6, 0)
        row.name:SetWidth(200)
        row.name:SetWordWrap(false)
        row.att, row.sig, row.miss, row.loot, row.last = col(222, 80), col(310, 100), col(414, 70), col(490, 120), col(620, 140)
    end, function(row, e)
        row.name:SetText(W.ClassName and W.ClassName(e.name) or e.name)
        row.att:SetText(tostring(e.attended))
        row.sig:SetText(e.signed > 0 and (e.signed .. (e.rate and (C.dim .. "  (" .. e.rate .. "% kept)|r") or "")) or (C.dim .. "-|r"))
        row.miss:SetText(e.missed > 0 and (C.bad .. e.missed .. "|r") or (C.dim .. "0|r"))
        row.loot:SetText(e.loot > 0 and (e.loot .. (e.pts > 0 and (C.dim .. "  (" .. e.pts .. ")|r") or "")) or (C.dim .. "-|r"))
        row.last:SetText(e.last > 0 and (C.dim .. W.Ago(now() - e.last) .. "|r") or (C.dim .. "-|r"))
    end)
    ui.list:SetEmptyText("No attendance yet: it's noted while an event runs, by its leaders.")
    ui.list.frame:SetPoint("TOPLEFT", 0, -62)
    ui.list.frame:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
end

function A.Refresh()
    if ui.list and ui.list.frame:IsVisible() then ui.list:SetItems(A.Stats()) end
end

function A.Init(module, internals, mdb)
    M, MC, db = module, internals, mdb
    store()
    if db.remind == nil then db.remind = true end
    for id, rec in pairs(store()) do if not rec.at or now() - rec.at > SEASON + 30 * 86400 then store()[id] = nil end end
    M:Listen("ATTEND", onAttend)
    C_Timer.NewTicker(SNAP_EVERY, function() pcall(A.Snapshot) end)
    C_Timer.NewTicker(30, function() pcall(A.CheckReminders) end)
end
