-- RUIN Muster: the War Room
-- Plan an operation on any event: split the people who signed up into
-- squads (up to 25 squads of up to 40), each with a leader and an objective,
-- and after it's over write the after-action report: what happened, what to
-- do better. The plan travels with the event, so everyone signed up sees
-- their squad, leader and objective on this tab (and a reminder names them).
local ADDON, ns = ...
local R = RUIN_API
if not R or (R.apiLevel or 1) < 8 then return end
local W = R.Widgets
local C = W.COLORS

local WarRoom = {}
ns.WarRoom = WarRoom

local MAX_SQUADS, MAX_MEMBERS = 25, 40

local M, MC
local ui = {}

local function now() return GetServerTime() end

-- The event's squads (a list), created on first use when you can manage it.
local function squads(ev, create)
    if type(ev.squads) ~= "table" then
        if not create then return {} end
        ev.squads = {}
    end
    return ev.squads
end

local function save(ev)
    ev.t = now()
    if not ev.practice then M:Send("EVENT", ev, "ORG") end
    MC.changed()
end

function WarRoom.AddSquad(ev, name)
    if not MC.canManage(ev) then return false, "Only the event's creator and officers plan it." end
    local list = squads(ev, true)
    if #list >= MAX_SQUADS then return false, "That's the most squads an operation can have." end
    name = R.Util.Trim(name or ""):gsub("|", "/"):sub(1, 24)
    if name == "" then name = "Squad " .. (#list + 1) end
    list[#list + 1] = { n = name, obj = "", m = {} }
    save(ev)
    return true
end

function WarRoom.RemoveSquad(ev, i)
    if not MC.canManage(ev) then return false end
    table.remove(squads(ev), i)
    save(ev)
    return true
end

function WarRoom.SetObjective(ev, i, text)
    if not MC.canManage(ev) then return false end
    local sq = squads(ev)[i]
    if not sq then return false end
    sq.obj = R.Util.Trim(text or ""):gsub("|", "/"):sub(1, 120)
    save(ev)
    return true
end

-- The squad a player (guid) is in, or nil.
function WarRoom.SquadOf(ev, guid)
    for i, sq in ipairs(squads(ev)) do
        for _, g in ipairs(sq.m or {}) do if g == guid then return i, sq end end
    end
    return nil
end

-- Put a player in a squad (0 = none); the leader leaves the lead when moved.
function WarRoom.Assign(ev, guid, i)
    if not MC.canManage(ev) then return false end
    local list = squads(ev, true)
    for _, sq in ipairs(list) do
        for j = #sq.m, 1, -1 do if sq.m[j] == guid then table.remove(sq.m, j) end end
        if sq.lead == guid then sq.lead = nil end
    end
    local sq = list[i]
    if sq then
        if #sq.m >= MAX_MEMBERS then return false, "That squad is full." end
        sq.m[#sq.m + 1] = guid
    end
    save(ev)
    return true
end

function WarRoom.SetLeader(ev, guid)
    if not MC.canManage(ev) then return false end
    local i, sq = WarRoom.SquadOf(ev, guid)
    if not sq then return false, "Put them in a squad first." end
    sq.lead = guid
    save(ev)
    return true
end

-- Squads by role from the sign-ups: tanks and healers spread, DPS filled in.
function WarRoom.AutoSquads(ev, count)
    if not MC.canManage(ev) then return false end
    count = math.max(1, math.min(MAX_SQUADS, count or 2))
    local list = {}
    for i = 1, count do
        local old = squads(ev)[i]
        list[i] = { n = old and old.n or ("Squad " .. i), obj = old and old.obj or "", m = {} }
    end
    local signed = MC.sortedSignups(ev)
    local idx = 0
    for _, role in ipairs({ "T", "H", "D" }) do
        for _, e in ipairs(signed) do
            if e.s.role == role then
                idx = idx % count + 1
                if #list[idx].m < MAX_MEMBERS then table.insert(list[idx].m, e.g) end
            end
        end
    end
    for _, sq in ipairs(list) do sq.lead = sq.m[1] end
    ev.squads = list
    save(ev)
    return true
end

function WarRoom.SetReport(ev, text)
    if not MC.canManage(ev) then return false, "Only the event's creator and officers write the report." end
    text = R.Util.Trim(text or ""):gsub("|", "/"):sub(1, 600)
    ev.aar = text ~= "" and { text = text, by = R:GetPlayer().name, t = now() } or nil
    save(ev)
    return true
end

-- What a player sees: their squad, leader and objective.
function WarRoom.MyOrders(ev)
    local me = R:GetPlayerGUID()
    local i, sq = WarRoom.SquadOf(ev, me or "")
    if not sq then return nil end
    local lead = sq.lead and ev.signups[sq.lead]
    return { squad = sq.n, index = i, lead = lead and lead.n, objective = sq.obj }
end

---------------------------------------------------------------------------
-- The War Room tab
---------------------------------------------------------------------------
local function nameOf(ev, guid)
    local s = ev.signups[guid]
    return s and W.ClassName(s.n, s.c) or (C.dim .. "left the event|r"), s
end

function WarRoom.Build(page)
    ui.page = page
    local h = W.Header(page, "Operation")
    h:SetPoint("TOPLEFT", 0, -2)
    ui.pick = MC.eventPicker(page, function() ui.sel = nil; WarRoom.Refresh() end)
    ui.pick:SetPoint("TOPLEFT", 80, 2)
    ui.add = W.Button(page, "Add squad", 90, function()
        local ev = MC.pickedEvent()
        if ev then
            R:ShowText("Add squad", "The squad's name (Alpha, Defense, Flag runners...).", "", function(t)
                local ok, e = WarRoom.AddSquad(ev, t); if not ok then M:Print(e) end
            end)
        end
    end)
    ui.add:SetPoint("LEFT", ui.pick, "RIGHT", 8, 0)
    ui.auto = W.Button(page, "Auto squads", 100, function()
        local ev = MC.pickedEvent()
        if ev then
            R:ShowText("Auto squads", "How many squads? Tanks and healers are spread first, then DPS.", tostring(math.max(2, #squads(ev))), function(t)
                WarRoom.AutoSquads(ev, tonumber(t))
            end)
        end
    end)
    ui.auto:SetPoint("LEFT", ui.add, "RIGHT", 4, 0)
    ui.orders = W.Label(page, "", "GameFontHighlight")
    ui.orders:SetPoint("TOPLEFT", 0, -32)
    ui.orders:SetPoint("RIGHT", page, "RIGHT", -4, 0)
    ui.orders:SetWordWrap(false)

    -- left: squads and their people; right: the selected person or squad
    ui.list = W.List(page, 20, function(row)
        row.a = W.Label(row, "")
        row.a:SetPoint("LEFT", 6, 0); row.a:SetPoint("RIGHT", row, "RIGHT", -6, 0); row.a:SetWordWrap(false)
        row:SetScript("OnMouseUp", function(self) if self.e then ui.sel = self.e; WarRoom.Refresh() end end)
    end, function(row, e)
        row.e = e
        local on = ui.sel and ui.sel.key == e.key
        if e.squad then
            row.a:SetText((on and (C.gold .. "> |r") or "") .. C.gold .. e.sq.n .. "|r" .. C.dim .. "  " .. #e.sq.m .. (e.sq.obj ~= "" and ("  ·  " .. e.sq.obj) or "") .. "|r")
        else
            local nm, s = nameOf(e.ev, e.g)
            row.a:SetText(("   %s%s%s%s"):format(on and (C.gold .. "> |r") or "", s and W.RoleIcon(s.role) or "", " " .. nm,
                e.lead and (C.gold .. "  (leader)|r") or ""))
        end
    end)
    ui.list.frame:SetPoint("TOPLEFT", 0, -52)
    ui.list.frame:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 0, 0)
    ui.list.frame:SetWidth(330)

    local card = W.Card(page)
    card:SetPoint("TOPLEFT", ui.list.frame, "TOPRIGHT", 30, 0)
    card:SetPoint("RIGHT", page, "RIGHT", 0, 0)
    card:SetHeight(196)
    ui.card = card
    ui.cardTitle = W.Header(card, "")
    ui.cardTitle:SetPoint("TOPLEFT", 8, -6)
    ui.cardText = W.Label(card, "", "GameFontHighlightSmall")
    ui.cardText:SetPoint("TOPLEFT", 10, -28)
    ui.cardText:SetPoint("RIGHT", card, "RIGHT", -10, 0)
    ui.cardText:SetJustifyH("LEFT")
    ui.btns = {}
    local function btn(text, w, fn)
        local b = W.Button(card, text, w, fn)
        ui.btns[#ui.btns + 1] = b
        return b
    end
    ui.objBtn = btn("Objective", 90, function()
        local ev = MC.pickedEvent()
        if ev and ui.sel and ui.sel.squad then
            R:ShowText("Objective for " .. ui.sel.sq.n, "What this squad does (up to 120 characters).", ui.sel.sq.obj or "", function(t)
                WarRoom.SetObjective(ev, ui.sel.i, t)
            end)
        end
    end)
    ui.renameBtn = btn("Remove squad", 110, function()
        local ev = MC.pickedEvent()
        if ev and ui.sel and ui.sel.squad then WarRoom.RemoveSquad(ev, ui.sel.i); ui.sel = nil end
    end)
    ui.leadBtn = btn("Make leader", 100, function()
        local ev = MC.pickedEvent()
        if ev and ui.sel and ui.sel.g then local ok, e = WarRoom.SetLeader(ev, ui.sel.g); if ok == false and e then M:Print(e) end end
    end)
    ui.moveBtn = btn("Move to next squad", 140, function()
        local ev = MC.pickedEvent()
        if not (ev and ui.sel and ui.sel.g) then return end
        local i = WarRoom.SquadOf(ev, ui.sel.g) or 0
        local n = #squads(ev)
        local nxt = (i >= n) and 0 or (i + 1)
        local ok, e = WarRoom.Assign(ev, ui.sel.g, nxt)
        if ok == false and e then M:Print(e) end
        ui.sel.key = "p" .. ui.sel.g
    end)
    ui.objBtn:SetPoint("BOTTOMLEFT", 8, 8)
    ui.renameBtn:SetPoint("LEFT", ui.objBtn, "RIGHT", 4, 0)
    ui.leadBtn:SetPoint("BOTTOMLEFT", 8, 8)
    ui.moveBtn:SetPoint("LEFT", ui.leadBtn, "RIGHT", 4, 0)

    local aar = W.Card(page)
    aar:SetPoint("TOPLEFT", card, "BOTTOMLEFT", 0, -10)
    aar:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
    local ah = W.Header(aar, "After-action report")
    ah:SetPoint("TOPLEFT", 8, -6)
    ui.aarEdit = W.Button(aar, "Write", 70, function()
        local ev = MC.pickedEvent()
        if ev then
            R:ShowText("After-action report", "What happened, what went well, what to do better (up to 600 characters).",
                ev.aar and ev.aar.text or "", function(t) local ok, e = WarRoom.SetReport(ev, t); if not ok then M:Print(e) end end)
        end
    end)
    ui.aarEdit:SetPoint("TOPRIGHT", -6, -4)
    ui.aarText = W.Label(aar, "", "GameFontHighlightSmall")
    ui.aarText:SetPoint("TOPLEFT", 10, -30)
    ui.aarText:SetPoint("BOTTOMRIGHT", aar, "BOTTOMRIGHT", -10, 8)
    ui.aarText:SetJustifyH("LEFT"); ui.aarText:SetJustifyV("TOP")
    page:SetScript("OnShow", WarRoom.Refresh)
end

function WarRoom.Refresh()
    if not (ui.page and ui.page:IsVisible()) then return end
    ui.pick.Refresh()
    local ev = MC.pickedEvent()
    local can = ev and MC.canManage(ev)
    ui.add:SetShown(can and true or false); ui.auto:SetShown(can and true or false)
    for _, b in ipairs(ui.btns) do b:Hide() end
    if not ev then
        ui.orders:SetText(C.dim .. "No upcoming events. Post one on the Events tab, then plan it here.|r")
        ui.list:SetItems({})
        ui.cardTitle:SetText(""); ui.cardText:SetText(""); ui.aarText:SetText(""); ui.aarEdit:Hide()
        return
    end
    local mine = WarRoom.MyOrders(ev)
    ui.orders:SetText(mine and ("Your orders: %s%s|r%s%s"):format(C.gold, mine.squad, mine.lead and ("  ·  leader " .. R.Util.ShortName(mine.lead)) or "",
        mine.objective ~= "" and ("  ·  " .. C.white .. mine.objective .. "|r") or "")
        or (C.dim .. (ev.signups[R:GetPlayerGUID() or ""] and "You're signed up but not in a squad yet." or "Sign up on the Events tab to get your orders.") .. "|r"))
    local items, inSquad = {}, {}
    for i, sq in ipairs(squads(ev)) do
        items[#items + 1] = { squad = true, sq = sq, i = i, key = "s" .. i }
        for _, g in ipairs(sq.m) do
            inSquad[g] = true
            items[#items + 1] = { g = g, ev = ev, lead = sq.lead == g, key = "p" .. g }
        end
    end
    local free = {}
    for _, e in ipairs(MC.sortedSignups(ev)) do if not inSquad[e.g] then free[#free + 1] = e.g end end
    if #free > 0 then
        items[#items + 1] = { squad = true, sq = { n = "Not in a squad", m = free, obj = "" }, i = 0, key = "s0" }
        for _, g in ipairs(free) do items[#items + 1] = { g = g, ev = ev, key = "p" .. g } end
    end
    ui.list:SetEmptyText("Nobody signed up yet.")
    ui.list:SetItems(items)
    -- keep the selection on the same thing
    if ui.sel then
        local found
        for _, e in ipairs(items) do if e.key == ui.sel.key then found = e end end
        ui.sel = found
    end
    local sel = ui.sel
    if sel and sel.squad then
        ui.cardTitle:SetText(sel.sq.n)
        local lead = sel.sq.lead and ev.signups[sel.sq.lead]
        ui.cardText:SetText(("%d members%s\n%s"):format(#sel.sq.m, lead and ("  ·  leader " .. W.ClassName(lead.n, lead.c)) or "",
            sel.sq.obj ~= "" and (C.white .. sel.sq.obj .. "|r") or (C.dim .. "No objective yet.|r")))
        if can and sel.i > 0 then ui.objBtn:Show(); ui.renameBtn:Show() end
    elseif sel and sel.g then
        local nm, s = nameOf(ev, sel.g)
        ui.cardTitle:SetText(s and R.Util.ShortName(s.n) or "?")
        local i, sq = WarRoom.SquadOf(ev, sel.g)
        ui.cardText:SetText((s and (W.RoleIcon(s.role) .. " " .. (s.gu or "") .. "\n") or "") .. (sq and ("In " .. sq.n .. (sq.lead == sel.g and ", leading it" or "")) or "Not in a squad."))
        if can then ui.moveBtn:Show(); if sq then ui.leadBtn:Show() end end
    else
        ui.cardTitle:SetText("Squads")
        ui.cardText:SetText(C.dim .. (can and "Add squads (or Auto squads from the sign-ups), then pick a squad for its objective or a player to move them or make them leader."
            or "The event's leaders plan its squads here. Pick a squad or a player to see more.") .. "|r")
    end
    ui.aarEdit:SetShown(can and true or false)
    ui.aarText:SetText(ev.aar and (C.white .. ev.aar.text .. "|r\n" .. C.dim .. "by " .. R.Util.ShortName(ev.aar.by) .. ", " .. W.Ago(math.max(60, now() - ev.aar.t)) .. "|r")
        or (C.dim .. "No report yet. After the operation, its leaders write what happened here.|r"))
end

-- A squad leader named in the reminder (Muster's tick calls this).
function WarRoom.ReminderText(ev)
    local o = WarRoom.MyOrders(ev)
    if not o then return "" end
    return (" Squad %s%s."):format(o.squad, o.lead and (", leader " .. R.Util.ShortName(o.lead)) or "")
end

-- Squads and the report from the network: keep only what makes sense.
function WarRoom.Clean(ev)
    if type(ev.squads) == "table" then
        local list = {}
        for i, sq in ipairs(ev.squads) do
            if i > MAX_SQUADS then break end
            if type(sq) == "table" then
                local m = {}
                for j, g in ipairs(type(sq.m) == "table" and sq.m or {}) do
                    if j > MAX_MEMBERS then break end
                    if type(g) == "string" then m[#m + 1] = g end
                end
                list[#list + 1] = { n = tostring(sq.n or ("Squad " .. i)):gsub("|", "/"):sub(1, 24), obj = tostring(sq.obj or ""):gsub("|", "/"):sub(1, 120),
                                    m = m, lead = type(sq.lead) == "string" and sq.lead or nil }
            end
        end
        ev.squads = list
    else
        ev.squads = nil
    end
    if type(ev.aar) == "table" and type(ev.aar.text) == "string" then
        ev.aar = { text = ev.aar.text:gsub("|", "/"):sub(1, 600), by = tostring(ev.aar.by or "?"), t = tonumber(ev.aar.t) or now() }
    else
        ev.aar = nil
    end
end

function WarRoom.Init(module, internals)
    M, MC = module, internals
end
