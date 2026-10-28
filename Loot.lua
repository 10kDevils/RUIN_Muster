-- RUIN Muster: loot notes
-- Who got what at an event, and why: the event's leaders note each award
-- (item, player, main spec / off spec / bank / disenchant, and points if the
-- guild keeps them). Drops your group loots are caught from the loot lines,
-- so noting one is a click. Members say which drops they hope for ("I want
-- this"), which the leaders see while awarding. Everyone sees the notes and
-- each player's loot this season (count and points).
local ADDON, ns = ...
local R = RUIN_API
if not R or (R.apiLevel or 1) < 8 then return end
local W = R.Widgets
local C = W.COLORS

local Loot = {}
ns.Loot = Loot

local KINDS = { "Main spec", "Off spec", "Bank", "Disenchant", "Other" }
local SEASON = 90 * 86400
local MAX_RECENT = 12

local M, MC, db
local ui = { kind = "Main spec", view = "Awards" }
local recent = {}               -- { name, link, t }

local function now() return GetServerTime() end
local function short(n) return R.Util.ShortName(n or "?") end

local function store()
    db.loot = type(db.loot) == "table" and db.loot or {}
    db.loot.notes = type(db.loot.notes) == "table" and db.loot.notes or {}     -- id -> note
    db.loot.asks = type(db.loot.asks) == "table" and db.loot.asks or {}       -- eventId -> { name -> { item, note, t } }
    return db.loot
end

local function newId() return tostring(R:GetPlayerGUID() or "x"):sub(-4) .. now() % 100000 .. math.random(10, 99) end

local function clean(n)
    if type(n) ~= "table" or type(n.id) ~= "string" or type(n.item) ~= "string" or type(n.to) ~= "string" then return nil end
    local kind = "Other"
    for _, k in ipairs(KINDS) do if k == n.kind then kind = k end end
    return { id = n.id:sub(1, 24), ev = type(n.ev) == "string" and n.ev:sub(1, 32) or nil, item = n.item:sub(1, 200), to = n.to:sub(1, 48),
             kind = kind, pts = math.max(-9999, math.min(9999, tonumber(n.pts) or 0)), note = tostring(n.note or ""):gsub("|", "/"):sub(1, 80),
             by = tostring(n.by or "?"):sub(1, 48), t = tonumber(n.t) or now(), del = n.del and true or nil, title = tostring(n.title or ""):sub(1, 40) }
end

-- Note an award. ev may be nil (loot outside an event).
function Loot.Award(ev, item, to, kind, pts, note)
    if ev and not MC.canManage(ev) then return false, "Only the event's creator and officers note loot." end
    if not ev and not R:IsOfficer() then return false, "Only officers note loot outside an event." end
    item, to = R.Util.Trim(item or ""), R.Util.Trim(to or "")
    if item == "" then return false, "Which item? Shift-click it into the box, or pick a recent drop." end
    if to == "" then return false, "Who got it?" end
    local n = clean({ id = newId(), ev = ev and ev.id, title = ev and ev.title, item = item, to = to, kind = kind, pts = pts, note = note,
                      by = R:GetPlayer().name, t = now() })
    store().notes[n.id] = n
    if not (ev and ev.practice) then M:Send("LNOTE", n, "ORG") end
    Loot.Refresh()
    return true, n
end

function Loot.Remove(id)
    local n = store().notes[id]
    if not n then return false end
    local ev = n.ev and MC.db().events[n.ev]
    if not ((ev and MC.canManage(ev)) or R:IsOfficer()) then return false, "Only the event's leaders and officers can remove a note." end
    n.del, n.t = true, now()
    M:Send("LNOTE", n, "ORG")
    Loot.Refresh()
    return true
end

-- Loot notes (and their points) come from the event's leader or a moderator,
-- checked by who sent them, never by a name in the note.
local function mayNote(n, sender)
    if R.IsModeratorName and R:IsModeratorName(sender) then return true end
    local ev = n.ev and MC.db().events[n.ev]
    return ev ~= nil and R.SameName ~= nil and R:SameName(sender, ev.by)
end

local function onNote(_, d, sender)
    local n = clean(d)
    if not n then return end
    if R.SaneTime and not R:SaneTime(n.t) then return end
    if not mayNote(n, sender) then return end
    local cur = store().notes[n.id]
    if cur and (cur.t or 0) >= n.t then return end
    n.by = sender
    store().notes[n.id] = n
    Loot.Refresh()
end

-- "I want this" for an event.
function Loot.Ask(ev, item, note)
    if not ev then return false, "Pick an event first." end
    item = R.Util.Trim(item or "")
    local me = R:GetPlayer().name
    local asks = store().asks
    asks[ev.id] = asks[ev.id] or {}
    asks[ev.id][me] = item ~= "" and { item = item:sub(1, 200), note = R.Util.Trim(note or ""):gsub("|", "/"):sub(1, 60), t = now() } or nil
    if not ev.practice then M:Send("LASK", { ev = ev.id, item = item, note = note }, "ORG") end
    Loot.Refresh()
    return true
end

local function onAsk(_, d, sender)
    if type(d) ~= "table" or type(d.ev) ~= "string" then return end
    local asks = store().asks
    asks[d.ev] = asks[d.ev] or {}
    local item = type(d.item) == "string" and R.Util.Trim(d.item) or ""
    asks[d.ev][sender] = item ~= "" and { item = item:sub(1, 200), note = tostring(d.note or ""):gsub("|", "/"):sub(1, 60), t = now() } or nil
    Loot.Refresh()
end

function Loot.Notes(evId)
    local out = {}
    for _, n in pairs(store().notes) do
        if not n.del and (not evId or n.ev == evId) then out[#out + 1] = n end
    end
    table.sort(out, function(a, b) return a.t > b.t end)
    return out
end

-- This season: { name, count, pts, last }
function Loot.Totals()
    local by = {}
    for _, n in pairs(store().notes) do
        if not n.del and now() - n.t <= SEASON then
            local k = short(n.to):lower()
            local r = by[k] or { name = n.to, count = 0, pts = 0, last = 0 }
            r.count, r.pts = r.count + 1, r.pts + (n.pts or 0)
            if n.t > r.last then r.last, r.lastItem = n.t, n.item end
            by[k] = r
        end
    end
    local out = {}
    for _, r in pairs(by) do out[#out + 1] = r end
    table.sort(out, function(a, b) if a.pts ~= b.pts then return a.pts > b.pts end return a.count > b.count end)
    return out
end

function Loot.Asks(evId)
    local out = {}
    for name, a in pairs(store().asks[evId or ""] or {}) do out[#out + 1] = { name = name, item = a.item, note = a.note, t = a.t } end
    table.sort(out, function(a, b) return a.t < b.t end)
    return out
end

---------------------------------------------------------------------------
-- Recent drops from the loot lines (uncommon and better)
---------------------------------------------------------------------------
local selfPattern, otherPattern
local function toPattern(g)
    g = g:gsub("([%(%)%.%-%+%[%]%?%*%^%$])", "%%%1")
    return "^" .. g:gsub("%%s", "(.+)") .. "$"
end

local function onLoot(_, text)
    if type(text) ~= "string" or (issecretvalue and issecretvalue(text)) then return end
    if not selfPattern then
        selfPattern = toPattern(LOOT_ITEM_SELF or "You receive loot: %s.")
        otherPattern = toPattern(LOOT_ITEM or "%s receives loot: %s.")
    end
    local name, link = text:match(otherPattern)
    if not name then
        link = text:match(selfPattern)
        name = link and R:GetPlayer().name
    end
    if not (name and link) then return end
    local item = link:match("(|c%x+|Hitem:.-|h.-|h|r)") or link
    local hex = (item:match("|c%x%x(%x%x%x%x%x%x)") or ""):lower()
    local q = ({ ["1eff00"] = 2, ["0070dd"] = 3, ["a335ee"] = 4, ["ff8000"] = 5 })[hex]
    if not q and GetItemInfo then q = select(3, GetItemInfo(item)) end
    if (tonumber(q) or 0) < 2 then return end
    table.insert(recent, 1, { name = name, link = item, t = now() })
    while #recent > MAX_RECENT do table.remove(recent) end
    Loot.Refresh()
end

function Loot.Recent() return recent end

---------------------------------------------------------------------------
-- The Loot tab
---------------------------------------------------------------------------
function Loot.Build(page)
    ui.page = page
    local h = W.Header(page, "Event")
    h:SetPoint("TOPLEFT", 0, -2)
    ui.pick = MC.eventPicker(page, function() Loot.Refresh() end)
    ui.pick:SetPoint("TOPLEFT", 50, 2)
    ui.viewBtn = W.Dropdown(page, 160, { "Awards", "Wishes", "This season" }, function() return ui.view end,
        function(v) ui.view = v; Loot.Refresh() end, "Show: ")
    ui.viewBtn:SetPoint("LEFT", ui.pick, "RIGHT", 8, 0)

    -- the form: item, player, kind, points, note, and Note it / I want this
    local card = W.Card(page)
    card:SetPoint("TOPLEFT", 0, -32)
    card:SetPoint("RIGHT", page, "RIGHT", 0, 0)
    card:SetHeight(64)
    ui.item = W.EditBox(card, 220, nil, "Item (shift-click it here)")
    ui.item:SetPoint("TOPLEFT", 8, -8)
    ui.to = W.EditBox(card, 130, nil, "Player")
    ui.to:SetPoint("LEFT", ui.item, "RIGHT", 6, 0)
    ui.kindBtn = W.Dropdown(card, 120, KINDS, function() return ui.kind end, function(v) ui.kind = v end)
    ui.kindBtn:SetPoint("LEFT", ui.to, "RIGHT", 6, 0)
    ui.pts = W.EditBox(card, 50, nil, "Pts")
    ui.pts:SetPoint("LEFT", ui.kindBtn, "RIGHT", 6, 0)
    ui.note = W.EditBox(card, 330, nil, "Note (optional)")
    ui.note:SetPoint("TOPLEFT", 8, -36)
    ui.award = W.Button(card, "Note award", 100, function()
        local ok, err = Loot.Award(MC.pickedEvent(), ui.item:GetText(), ui.to:GetText(), ui.kind, tonumber(ui.pts:GetText()), ui.note:GetText())
        if ok then ui.item:SetText(""); ui.to:SetText(""); ui.pts:SetText(""); ui.note:SetText("") else M:Print(err) end
    end)
    ui.award:SetPoint("LEFT", ui.note, "RIGHT", 6, 0)
    ui.want = W.Button(card, "I want this", 100, function()
        local ok, err = Loot.Ask(MC.pickedEvent(), ui.item:GetText(), ui.note:GetText())
        M:Print(ok and "Noted: the event's leaders see what you hope for." or err)
    end)
    ui.want:SetPoint("LEFT", ui.award, "RIGHT", 4, 0)
    ui.want.tip = "Tell the event's leaders which drop you hope for (one per event; empty item clears it)."

    -- recent drops (managers): click to fill the form
    ui.recent = W.List(page, 20, function(row)
        row.a = W.Label(row, "", "GameFontHighlightSmall")
        row.a:SetPoint("LEFT", 4, 0); row.a:SetPoint("RIGHT", row, "RIGHT", -4, 0); row.a:SetWordWrap(false)
        row:SetScript("OnMouseUp", function(self) if self.e then ui.item:SetText(self.e.link); ui.to:SetText(self.e.name) end end)
    end, function(row, e)
        row.e = e
        row.a:SetText(e.link .. C.dim .. "  " .. short(e.name) .. "|r")
        row.link = e.link:match("|H(item:[^|]+)|h")
    end)
    ui.recent:SetEmptyText("Drops your group loots show here.")
    ui.recentHead = W.Label(page, C.gold .. "Recent drops|r " .. C.dim .. "(click to fill)|r", "GameFontNormalSmall")
    ui.recentHead:SetPoint("TOPRIGHT", page, "TOPRIGHT", -150, -104)
    ui.recent.frame:SetPoint("TOPLEFT", page, "TOPRIGHT", -240, -120)
    ui.recent.frame:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -24, 0)

    ui.list = W.List(page, 22, function(row)
        row.a = W.Label(row, "")
        row.a:SetPoint("LEFT", 4, 0); row.a:SetWidth(210); row.a:SetWordWrap(false)
        row.b = W.Label(row, "", "GameFontHighlightSmall")
        row.b:SetPoint("LEFT", 218, 0); row.b:SetPoint("RIGHT", row, "RIGHT", -60, 0); row.b:SetWordWrap(false)
        row.del = W.Button(row, "X", 24)
        row.del:SetPoint("RIGHT", -2, 0)
    end, function(row, e)
        row.del:Hide()
        if e.note then
            local n = e.note
            row.a:SetText(n.item)
            row.link = n.item:match("|H(item:[^|]+)|h")
            row.b:SetText(("%s  %s%s%s|r"):format(W.ClassName(n.to), C.dim, n.kind, (n.pts ~= 0 and ("  ·  " .. n.pts .. " pts") or "")
                .. (n.note ~= "" and ("  ·  " .. n.note) or "")))
            row.del:SetScript("OnClick", function() local ok, err = Loot.Remove(n.id); if ok == false and err then M:Print(err) end end)
            row.del:SetShown(e.can and true or false)
        elseif e.ask then
            row.a:SetText(e.ask.item)
            row.link = e.ask.item:match("|H(item:[^|]+)|h")
            row.b:SetText(W.ClassName(e.ask.name) .. C.dim .. (e.ask.note ~= "" and ("  ·  " .. e.ask.note) or "") .. "|r")
        else
            local r = e.total
            row.a:SetText(W.ClassName(r.name))
            row.link = nil
            row.b:SetText(("%s%d|r item%s  ·  %s%d|r pts  ·  %slast: %s|r"):format(C.white, r.count, r.count == 1 and "" or "s", C.gold, r.pts, C.dim, r.lastItem or ""))
        end
    end)
    ui.list.frame:SetPoint("TOPLEFT", 0, -104)
    ui.list.frame:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -270, 0)

    local function insert(link)
        if ui.item and ui.item:HasFocus() and type(link) == "string" then ui.item:SetText(link) end
    end
    if ChatEdit_InsertLink then pcall(hooksecurefunc, "ChatEdit_InsertLink", insert) end
    if ChatFrameUtil and ChatFrameUtil.InsertLink then pcall(hooksecurefunc, ChatFrameUtil, "InsertLink", insert) end
    page:SetScript("OnShow", Loot.Refresh)
end

function Loot.Refresh()
    if not (ui.page and ui.page:IsVisible()) then return end
    ui.pick.Refresh()
    ui.viewBtn:Refresh()
    local ev = MC.pickedEvent()
    local can = (ev and MC.canManage(ev)) or (not ev and R:IsOfficer())
    ui.award:SetShown(can and true or false)
    ui.to:SetShown(can and true or false); ui.kindBtn:SetShown(can and true or false); ui.pts:SetShown(can and true or false)
    ui.want:SetShown(ev ~= nil)
    ui.recent.frame:SetShown(can and true or false); ui.recentHead:SetShown(can and true or false)
    if can then ui.recent:SetItems(recent) end
    local items = {}
    if ui.view == "Wishes" then
        for _, a in ipairs(Loot.Asks(ev and ev.id)) do items[#items + 1] = { ask = a } end
        ui.list:SetEmptyText(ev and "Nobody has said what they hope for yet." or "Pick an event.")
    elseif ui.view == "This season" then
        for _, r in ipairs(Loot.Totals()) do items[#items + 1] = { total = r } end
        ui.list:SetEmptyText("No loot noted in the last 90 days.")
    else
        for _, n in ipairs(Loot.Notes(ev and ev.id)) do items[#items + 1] = { note = n, can = can } end
        ui.list:SetEmptyText(ev and "No loot noted for this event yet." or "No loot noted yet.")
    end
    ui.list:SetItems(items)
end

-- Someone connected (Muster's ASK): one member shares this season's notes.
local lastHeard, sharePending = -999, false
function Loot.Share()
    if sharePending then return end
    sharePending = true
    local asked = GetTime()
    C_Timer.After(5 + math.random() * 10, function()
        sharePending = false
        if lastHeard >= asked then return end
        local n = 0
        local me, officer = R:GetPlayer().name, R:IsOfficer()
        for _, note in pairs(store().notes) do
            -- only notes others will accept from you
            local ev = note.ev and MC.db().events[note.ev]
            local mine = ev and R.SameName and R:SameName(ev.by, me)
            if (officer or mine) and now() - note.t <= 14 * 86400 and n < 80 then n = n + 1; M:Send("LNOTE", note, "ORG", nil, R.PRIORITY.BULK) end
        end
    end)
end

function Loot.Init(module, internals, mdb)
    M, MC, db = module, internals, mdb
    store()
    -- forget old notes
    for id, n in pairs(store().notes) do if now() - (n.t or 0) > SEASON + 30 * 86400 then store().notes[id] = nil end end
    for evId in pairs(store().asks) do if not MC.db().events[evId] then store().asks[evId] = nil end end
    M:Listen("LNOTE", function(mod, d, sender) lastHeard = GetTime(); onNote(mod, d, sender) end)
    M:Listen("LASK", onAsk)
    M:RegisterEvent("CHAT_MSG_LOOT", onLoot)
end
