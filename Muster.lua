-- RUIN Muster
-- Officers post events (raids, PvP nights, leveling groups) for all of RUIN,
-- with a description, a size and how many tanks, healers and DPS are needed.
-- Members sign up by role and get a reminder 15 minutes before the start.
-- Weekly events post their next week by themselves. Officers arrange the
-- raid into groups and a bench, and raids take one soft reserve per player.
-- Open slots are offered to RUIN Finder when it is installed.
local ADDON, ns = ...
local R = RUIN_API
if not R or (R.apiLevel or 1) < 3 then
    print("|cffc41e3aRUIN|r Muster needs a newer RUIN Core (0.3.0 or later).")
    return
end
local W = R.Widgets
local C = W.COLORS

local M = R:RegisterModule("Muster", { version = "0.3.0" })

local KINDS = { "Raid", "Dungeon", "PvP", "Leveling", "Social" }
local SIZES = { "Open", "5", "10", "20", "40" }
-- Default tanks / healers / DPS for each size; officers can change them.
local NEED_FOR = { ["5"] = { 1, 1, 3 }, ["10"] = { 2, 3, 5 }, ["20"] = { 3, 5, 12 }, ["40"] = { 5, 10, 25 } }
local REMIND_BEFORE = 15 * 60
local KEEP_AFTER = 6 * 3600
local WEEK = 7 * 86400
local SLOTS_AHEAD = 48 * 3600          -- events this close offer open slots to Finder
local DEFAULTS = { events = {}, reminded = {}, practice = false }

local db
local ui = { kind = "Raid", size = "Open", need = { 0, 0, 0 }, weekly = false }

local ROLE_NAMES = { T = "Tank", H = "Healer", D = "DPS" }
local ROLE_ORDER = { "T", "H", "D" }

local function newId()
    return tostring(R:GetPlayerGUID() or "x"):sub(-5) .. GetServerTime() % 100000 .. math.random(10, 99)
end

local function parseWhen(text)
    local y, mo, d, h, mi = (text or ""):match("(%d+)%-(%d+)%-(%d+)%s+(%d+):(%d+)")
    if not y then return nil end
    return time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h), min = tonumber(mi) })
end

local function defaultWhen()
    local t = date("*t", time() + 86400)
    t.hour, t.min, t.sec = 20, 0, 0
    return date("%Y-%m-%d %H:%M", time(t))
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

local function whenText(at) return date("%a %d %b %H:%M", at) end

local refreshPage = function() end
local changed

---------------------------------------------------------------------------
-- Events and sign-ups
---------------------------------------------------------------------------
-- Officers post for the org. In practice mode (page checkbox or /muster
-- practice, and automatically while not connected to RUIN) anyone can post;
-- practice events and their sign-ups stay on your own screen.
local function practicing() return (db and db.practice) or not R:IsConnected() end
local function canPost() return R:IsOfficer() or practicing() end

-- opts: { kind, desc, size, need = { t, h, d }, weekly }
function M:Create(title, whenText_, opts)
    if type(opts) == "string" then opts = { kind = opts } end
    opts = opts or {}
    if not canPost() then return self:Print("Only officers can post events.") end
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
    if not canPost() or not ev then return end
    db.events[id] = nil
    if not ev.practice then self:Send("DELETE", { id = id }, "ORG") end
    changed()
end

-- Stop a weekly event from posting further weeks (this week stays).
function M:StopRepeating(id)
    local ev = db.events[id]
    if not canPost() or not ev or not ev.weekly then return end
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
        if not cur and ev.at > GetServerTime() then
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
    C_Timer.After(2 + math.random() * 8, function()
        local now = GetServerTime()
        for _, ev in pairs(db.events) do
            if ev.at + KEEP_AFTER > now and not ev.practice then self:Send("EVENT", ev, "ORG", nil, R.PRIORITY.BULK) end
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
    if not ev or not canPost() then return end
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
    if not ev or not canPost() or not ev.signups[guid] then return end
    ev.roster = ev.roster or {}
    local groups = groupCount(ev)
    local cur = ev.roster[guid] or 0
    ev.roster[guid] = (cur >= groups) and 0 or cur + 1
    ev.rosterT = GetServerTime()
    changed()
end

function M:PublishRoster(id)
    local ev = db.events[id]
    if not ev or not canPost() or not ev.roster then return end
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
        if ev.weekly and ev.at <= now and canPost() and (ev.practice or not practicing() or R:IsOfficer()) then
            local week = (ev.week or 0) + 1
            local nid = (ev.series or ev.id) .. "w" .. week
            if not db.events[nid] then
                local nxt = { id = nid, title = ev.title, kind = ev.kind, at = ev.at + WEEK, by = ev.by, gu = ev.gu,
                              signups = {}, t = GetServerTime(), desc = ev.desc, size = ev.size, need = ev.need,
                              weekly = true, series = ev.series or ev.id, week = week, practice = ev.practice }
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

changed = function()
    refreshPage()
    M:Publish("EVENTS")
end

---------------------------------------------------------------------------
-- Reminders and cleanup
---------------------------------------------------------------------------
local function tick()
    local now, me = GetServerTime(), R:GetPlayerGUID()
    rollWeekly(now)
    for id, ev in pairs(db.events) do
        if ev.at + KEEP_AFTER < now and not ev.weekly then
            db.events[id] = nil
            db.reminded[id] = nil
        elseif me and ev.signups[me] and not db.reminded[id] and ev.at - now <= REMIND_BEFORE and ev.at > now then
            db.reminded[id] = true
            M:Toast(("%s starts in %d minutes%s."):format(ev.title, math.ceil((ev.at - now) / 60), myGroupText(ev)), { sound = true })
        end
    end
end

function M:SetPractice(on)
    db.practice = on and true or false
    if not db.practice then
        for id, ev in pairs(db.events) do if ev.practice then db.events[id] = nil end end
    end
    if ui.practiceCheck then ui.practiceCheck:Refresh() end
    self:Print(db.practice and "Practice mode on: post events and sign up to try Muster. Only you see practice events."
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
    ui.officer = W.Card(page)
    ui.officer:SetPoint("TOPLEFT", 0, 0)
    ui.officer:SetPoint("RIGHT", page, "RIGHT", -4, 0)
    ui.officer:SetHeight(84)
    local f = ui.officer
    local h = W.Header(f, "Post an event")
    h:SetPoint("TOPLEFT", 8, -6)
    local labels = { { "Title", 8 }, { "Starts (local time)", 214 }, { "Type", 352 }, { "Size", 448 }, { "Need T / H / D", 530 } }
    for _, l in ipairs(labels) do
        local fs = W.Label(f, C.dim .. l[1] .. "|r", "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", l[2], -24)
    end
    local title = W.EditBox(f, 196)
    title:SetPoint("TOPLEFT", 12, -38)
    local when = W.EditBox(f, 126)
    when:SetPoint("TOPLEFT", 218, -38)
    when:SetText(defaultWhen())
    local kind = W.Cycle(f, 88, KINDS, function() return ui.kind end, function(v) ui.kind = v end)
    kind:SetPoint("TOPLEFT", 352, -37)
    local needBoxes = {}
    local size = W.Cycle(f, 70, SIZES, function() return ui.size end, function(v)
        ui.size = v
        local d = NEED_FOR[v] or { 0, 0, 0 }
        for i = 1, 3 do ui.need[i] = d[i]; needBoxes[i]:SetText(d[i] > 0 and tostring(d[i]) or "") end
    end)
    size:SetPoint("TOPLEFT", 448, -37)
    for i = 1, 3 do
        local b = W.EditBox(f, 30, function(t) ui.need[i] = tonumber(t) or 0 end)
        b:SetPoint("TOPLEFT", 534 + (i - 1) * 38, -38)
        if b.SetNumeric then b:SetNumeric(true) end
        if b.SetMaxLetters then b:SetMaxLetters(2) end
        needBoxes[i] = b
    end
    local desc = W.EditBox(f, 330)
    desc:SetPoint("TOPLEFT", 12, -62)
    local descHint = W.Label(f, C.dim .. "description (optional)|r", "GameFontHighlightSmall")
    descHint:SetPoint("LEFT", desc, "RIGHT", 6, 0)
    local weekly = W.Check(f, "Weekly", function() return ui.weekly end, function(v) ui.weekly = v end)
    weekly:SetPoint("TOPLEFT", 480, -58)
    local post = W.Button(f, "Post", 70, function()
        for i = 1, 3 do ui.need[i] = tonumber(needBoxes[i]:GetText()) or 0 end
        local ev = M:Create(title:GetText(), when:GetText(), { kind = ui.kind, desc = desc:GetText(), size = ui.size,
                                                             need = ui.need, weekly = ui.weekly })
        if ev then title:SetText(""); desc:SetText("") end
    end)
    post:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -60)

    ui.listHeader = W.Header(page, "Upcoming events")
    ui.list = W.List(page, 30, function(row)
        row.text = W.Label(row, "")
        row.text:SetPoint("LEFT", 4, 0)
        row.text:SetPoint("RIGHT", row, "RIGHT", -196, 0)
        row.text:SetWordWrap(false)
        row.del = W.Button(row, "Del", 38)
        row.del:SetPoint("RIGHT", 0, 0)
        row.no = W.Button(row, "X", 26)
        row.no:SetPoint("RIGHT", row.del, "LEFT", -4, 0)
        row.d = W.Button(row, W.RoleIcon("D", 16), 34)
        row.d:SetPoint("RIGHT", row.no, "LEFT", -2, 0)
        row.h = W.Button(row, W.RoleIcon("H", 16), 34)
        row.h:SetPoint("RIGHT", row.d, "LEFT", -2, 0)
        row.t = W.Button(row, W.RoleIcon("T", 16), 34)
        row.t:SetPoint("RIGHT", row.h, "LEFT", -2, 0)
    end, function(row, ev)
        local mine = ev.signups[R:GetPlayerGUID() or ""]
        local status = mine and (C.good .. "  you: " .. ROLE_NAMES[mine.role] .. myGroupText(ev) .. "|r") or ""
        local rep = (ev.weekly or ev.series) and (C.dim .. " (weekly)|r") or ""
        local prac = ev.practice and (C.dim .. " [practice]|r") or ""
        row.text:SetText(("%s%s|r  %s%s%s  %s%s"):format(C.gold, whenText(ev.at), ev.title, rep, prac, needText(ev), status))
        row.tip = eventTooltip(ev)
        row.t:SetScript("OnClick", function() M:SignUp(ev.id, "T") end)
        row.h:SetScript("OnClick", function() M:SignUp(ev.id, "H") end)
        row.d:SetScript("OnClick", function() M:SignUp(ev.id, "D") end)
        row.no:SetScript("OnClick", function() M:SignUp(ev.id, nil) end)
        row.del:SetShown(canPost())
        row.del:SetScript("OnClick", function() M:Delete(ev.id) end)
    end)
    ui.list:SetEmptyText("No upcoming events. Officers post them above; they reach every RUIN guild.")
    ui.list.frame:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -24, 22)

    local foot = W.Label(page, C.dim .. "Role buttons sign you up, X withdraws. Hover an event for details and who's coming. Times are your local time.|r", "GameFontHighlightSmall")
    foot:SetPoint("BOTTOMLEFT", 0, 2)
    foot:SetPoint("RIGHT", page, "RIGHT", -6, 0)
end

local function layoutEvents()
    local officer = canPost()
    ui.officer:SetShown(officer)
    ui.listHeader:ClearAllPoints()
    ui.listHeader:SetPoint("TOPLEFT", 0, officer and -94 or -2)
    ui.list.frame:ClearAllPoints()
    ui.list.frame:SetPoint("TOPLEFT", 0, officer and -112 or -20)
    ui.list.frame:SetPoint("BOTTOMRIGHT", ui.eventsPage, "BOTTOMRIGHT", -24, 22)
end

-- Pick which event the Roster and Reserves pages show.
local function pickedEvent()
    local items = upcoming()
    if #items == 0 then return nil, items end
    for _, ev in ipairs(items) do if ev.id == ui.picked then return ev, items end end
    ui.picked = items[1].id
    return items[1], items
end

local function eventPicker(page, onChange)
    local b = W.Button(page, "", 300, nil)
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
    ui.bench:SetPoint("TOPLEFT", 0, -294)
    ui.bench:SetPoint("RIGHT", page, "RIGHT", -6, 0)
    ui.bench:SetJustifyV("TOP")
    ui.rosterHint = W.Label(page, "", "GameFontHighlightSmall")
    ui.rosterHint:SetPoint("BOTTOMLEFT", 0, 2)
    ui.rosterHint:SetPoint("RIGHT", page, "RIGHT", -6, 0)
end

local function refreshRoster()
    local ev = pickedEvent()
    ui.rosterPick.Refresh()
    local officer = canPost()
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

local function buildPage(panel)
    ui.panel = panel
    ui.practiceCheck = W.Check(panel, "Practice mode", function() return db.practice end,
        function(v) M:SetPractice(v) end)
    ui.practiceCheck:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -110, 2)
    ui.tabs = W.SubTabs(panel, { "Events", "Roster", "Reserves" }, function() refreshPage() end)
    ui.eventsPage = ui.tabs.pages[1]
    buildEvents(ui.tabs.pages[1])
    buildRoster(ui.tabs.pages[2])
    buildReserves(ui.tabs.pages[3])

    refreshPage = function()
        if not ui.panel:IsVisible() then return end
        local items = upcoming()
        ui.tabs:SetLabel(1, #items > 0 and ("Events (" .. #items .. ")") or "Events")
        local tab = ui.tabs.selected
        if tab == 1 then
            layoutEvents()
            ui.list:SetItems(items)
        elseif tab == 2 then
            refreshRoster()
        elseif tab == 3 then
            refreshReserves()
        end
    end
    panel:SetScript("OnShow", function() refreshPage() end)
    ui.tabs:Select(1)
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
    self:AddTab("Muster", buildPage)

    R:Subscribe("CHANNELS_CHANGED", function()
        C_Timer.After(6, function() if R:IsConnected() then self:Send("ASK", {}, "ORG") end end)
    end)
    C_Timer.NewTicker(30, tick)
end

function RUIN_Muster_Open() M:OpenTab() end
BINDING_HEADER_RUIN_MUSTER = "RUIN Muster"
BINDING_NAME_RUIN_MUSTER_OPEN = "Open Muster"

SLASH_RUINMUSTER1 = "/muster"
SlashCmdList.RUINMUSTER = function(msg)
    if (msg or ""):lower():match("^%s*practice") then
        M:SetPractice(not db.practice)
    else
        M:OpenTab()
    end
end
