-- RUIN Muster: World sightings and timers (formerly the RUIN Intel addon)
-- See something, say something: one button reports what you see and where,
-- and every RUIN member gets an alert, an entry in the Sightings feed and a
-- pin on the world map and minimap that fades as the report ages. "Under
-- attack" calls for help with your position. Enemy sightings near a rally
-- point mark it contested (see Muster.lua). Boss, rare and enemy sightings
-- have a "Find group" button that starts a Finder listing. The Timers page
-- tracks world bosses and world buff drops.
local ADDON, ns = ...
local R = RUIN_API
if not R or (R.apiLevel or 1) < 5 then return end
local W = R.Widgets
local C = W.COLORS

local World = {}
ns.World = World

local KINDS = {
    { key = "enemy",  label = "Enemy group",   color = "|cffff4040", rgb = { 1, 0.25, 0.25 }, sound = true,
      icon = "Interface\\Icons\\Ability_DualWield",                find = { "PvP", "Enemy group", 1, 1, 3 } },
    { key = "attack", label = "Under attack!", color = "|cffff2020", rgb = { 1, 0.1, 0.1 }, sound = true,
      icon = "Interface\\Icons\\Ability_Warrior_BattleShout",      find = { "PvP", "Under attack", 0, 1, 4 } },
    { key = "boss",   label = "World boss",    color = "|cffff8000", rgb = { 1, 0.5, 0 }, sound = true,
      icon = "Interface\\Icons\\INV_Misc_Head_Dragon_01",          find = { "Raid", "World boss", 4, 8, 28 } },
    { key = "rare",   label = "Rare",          color = "|cffa335ee", rgb = { 0.64, 0.21, 0.93 }, sound = false,
      icon = "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01",      find = { "Questing", "Rare", 0, 0, 2 } },
    { key = "buff",   label = "Buff drop",     color = "|cff40c0ff", rgb = { 0.25, 0.75, 1 }, sound = true,
      icon = "Interface\\Icons\\Spell_Holy_GreaterBlessingofKings" },
    { key = "other",  label = "Other",         color = "|cffffd100", rgb = { 1, 0.82, 0 }, sound = false,
      icon = "Interface\\Icons\\INV_Misc_Spyglass_03" },
}
local KIND = {}
for _, k in ipairs(KINDS) do KIND[k.key] = k end
World.KINDS, World.KIND = KINDS, KIND

-- Respawn windows are WoW Classic's; Forever may differ, so they are a guide only.
local TIMERS = {
    { key = "azuregos", label = "Azuregos",          kind = "boss", where = "Azshara",              window = { 3 * 86400, 7 * 86400 } },
    { key = "kazzak",   label = "Lord Kazzak",       kind = "boss", where = "Blasted Lands",        window = { 3 * 86400, 7 * 86400 } },
    { key = "nightmare",  label = "Dragons of Nightmare", kind = "boss", where = "Duskwood, Ashenvale, Feralas, Hinterlands", window = { 3 * 86400, 7 * 86400 } },
    { key = "dragonslayer",     label = "Rallying Cry (Onyxia / Nefarian head)", kind = "buff", where = "Stormwind" },
    { key = "zg",       label = "Spirit of Zandalar (Hakkar's heart)",   kind = "buff", where = "Yojamba Isle, Stranglethorn" },
    { key = "songflower", label = "Songflower Serenade", kind = "buff", where = "Felwood",             window = { 25 * 60, 25 * 60 } },
}
local TIMER = {}
for _, t in ipairs(TIMERS) do TIMER[t.key] = t end
World.TIMERS = TIMERS

local EXPIRE = 30 * 60
local REPORT_COOLDOWN = 10
local ATTACK_COOLDOWN = 60
local PIN_OWNER = "MusterWorld"
local DEFAULTS = { alerts = { enemy = true, attack = true, boss = true, rare = true, buff = true, other = true },
                   pins = true, timers = {} }

local M, db
local feed = {}         -- newest first
local lastReport, lastAttack = -999, -999
local ui = {}
local refresh = function() end

local function where()
    local zone = GetZoneText and GetZoneText() or "?"
    local sub = GetSubZoneText and GetSubZoneText() or ""
    local coords = ""
    local map, x, y = R.Map:PlayerPos()
    if map then coords = (" %d,%d"):format(x * 100, y * 100) end
    return (sub ~= "" and (sub .. ", ") or "") .. zone .. coords, map, x, y
end

---------------------------------------------------------------------------
-- Sightings
---------------------------------------------------------------------------
function World.Report(kind, text)
    if not KIND[kind] then kind = "other" end
    if kind == "attack" and GetTime() - lastAttack < ATTACK_COOLDOWN then
        return M:Print("You already called for help in the last minute.")
    end
    if GetTime() - lastReport < REPORT_COOLDOWN then return M:Print("Wait a few seconds between reports.") end
    lastReport = GetTime()
    if kind == "attack" then lastAttack = GetTime() end
    local w, map, x, y = where()
    local d = { k = kind, x = (text or ""):sub(1, 80), w = w, t = GetServerTime() }
    if map then d.m, d.px, d.py = map, math.floor(x * 10000 + 0.5), math.floor(y * 10000 + 0.5) end
    M:Send("SPOT", d, "ORG", nil, R.PRIORITY.ALERT)
    World.AddSpot(d, UnitName("player"), true)
end

local function spotId(e) return tostring(e.by) .. ":" .. tostring(e.t) end
local function short(name) return R.Util.ShortName(name or "?") end

local function pinFor(e)
    if not db.world.pins or not e.map then return end
    local k = KIND[e.kind]
    local age = GetServerTime() - e.t
    if age > EXPIRE then
        R.Map:RemovePin(PIN_OWNER, spotId(e))
        return
    end
    R.Map:SetPin(PIN_OWNER, spotId(e), {
        map = e.map, x = e.x, y = e.y, icon = k.icon, color = k.rgb,
        title = k.label .. (e.text ~= "" and (": " .. e.text) or ""),
        text = ("%s  ·  %s  ·  %s"):format(e.where, short(e.by), W.Ago(age)),
        alpha = math.max(0.3, 1 - age / EXPIRE),     -- fades as the report ages
    })
end

function World.AddSpot(d, sender, mine)
    if type(d) ~= "table" then return end
    local k = KIND[d.k]
    if not k or type(d.w) ~= "string" then return end
    local e = { kind = d.k, text = type(d.x) == "string" and d.x or "", where = d.w, by = sender,
                t = tonumber(d.t) or GetServerTime() }
    if type(d.m) == "number" and tonumber(d.px) and tonumber(d.py) then
        e.map, e.x, e.y = d.m, tonumber(d.px) / 10000, tonumber(d.py) / 10000
    end
    table.insert(feed, 1, e)
    while #feed > 100 do table.remove(feed) end
    pinFor(e)
    if not mine and db.world.alerts[d.k] then
        local extra = (e.text ~= "") and (": " .. e.text) or ""
        if d.k == "attack" then
            M:Toast(("%sUNDER ATTACK:|r %s at %s%s"):format(k.color, W.ClassName(sender), d.w, extra), { sound = true })
        else
            M:Toast(("%s%s|r%s at %s (%s)"):format(k.color, k.label, extra, d.w, W.ClassName(sender)), { sound = k.sound })
        end
    elseif mine then
        M:Print("Reported " .. k.label .. " at " .. d.w .. ".")
    end
    local sp = { kind = e.kind, text = e.text, where = e.where, by = sender, t = e.t,
                 map = e.map, x = e.x, y = e.y, mine = mine }
    if M.OnSighting then M.OnSighting(sp) end      -- rally points react to enemy sightings
    M:Publish("SPOT", sp)
    refresh()
end

local function refreshPins()
    if not db.world.pins then R.Map:ClearPins(PIN_OWNER); return end
    for _, e in ipairs(feed) do pinFor(e) end
end

---------------------------------------------------------------------------
-- Timers: world bosses and world buffs
---------------------------------------------------------------------------
function World.SetTimer(key, minutesFromNow)
    local t = TIMER[key]
    if not t then return end
    local now = GetServerTime()
    local rec = db.world.timers[key] or {}
    if minutesFromNow and minutesFromNow > 0 then
        rec.plan = now + math.floor(minutesFromNow * 60)
    else
        rec.last, rec.plan = now, nil
    end
    rec.by, rec.t = UnitName("player"), now
    rec.warned = nil
    db.world.timers[key] = rec
    M:Send("TIMER", { k = key, l = rec.last, p = rec.plan, t = rec.t }, "ORG", nil, R.PRIORITY.ALERT)
    M:Print(rec.plan and ("%s dropping in %d min, RUIN told."):format(t.label, minutesFromNow)
        or ("%s marked %s now."):format(t.label, t.kind == "boss" and "killed" or "dropped"))
    refresh()
end

function World.OnTimer(d, sender)
    if type(d) ~= "table" then return end
    local t = type(d.k) == "string" and TIMER[d.k]
    if not t or not tonumber(d.t) then return end
    local rec = db.world.timers[d.k] or {}
    if (rec.t or 0) >= tonumber(d.t) then return end
    local newPlan = tonumber(d.p)
    local wasPlan = rec.plan
    rec.last, rec.plan, rec.by, rec.t = tonumber(d.l) or rec.last, newPlan, sender, tonumber(d.t)
    rec.warned = nil
    db.world.timers[d.k] = rec
    if db.world.alerts[t.kind] then
        if newPlan and newPlan ~= wasPlan then
            M:Toast(("%s%s|r drops in %s (%s)"):format(KIND.buff.color, t.label, W.Duration(newPlan - GetServerTime()),
                W.ClassName(sender)), { sound = true })
        elseif not newPlan then
            M:Toast(("%s%s|r %s (%s)"):format(KIND[t.kind].color, t.label, t.kind == "boss" and "killed" or "dropped",
                W.ClassName(sender)))
        end
    end
    refresh()
end

-- Share timers with someone who just connected (called from Muster's OnAsk).
function World.Ask()
    for key, rec in pairs(db.world.timers) do
        if rec.t then
            M:Send("TIMER", { k = key, l = rec.last, p = rec.plan, t = rec.t }, "ORG", nil, R.PRIORITY.BULK)
        end
    end
end

local function timerStatus(t, rec)
    local now = GetServerTime()
    if rec and rec.plan and rec.plan > now then
        return C.good .. "drops in " .. W.Duration(rec.plan - now) .. "|r"
    end
    if not rec or not rec.last then return C.dim .. "no report yet|r" end
    local ago = now - rec.last
    local verb = t.kind == "boss" and "killed " or "dropped "
    local s = C.white .. verb .. W.Ago(ago) .. "|r"
    if t.window then
        local lo, hi = t.window[1], t.window[2]
        if ago < lo then
            s = s .. C.dim .. "  ·  back in " .. W.Duration(lo - ago) .. (hi > lo and "+" or "") .. "|r"
        elseif ago < hi then
            s = s .. C.gold .. "  ·  may be up now|r"
        else
            s = s .. C.good .. "  ·  should be up|r"
        end
    end
    return s
end
World.TimerStatus = timerStatus

local function timerTick()
    local now = GetServerTime()
    for key, rec in pairs(db.world.timers) do
        local t = TIMER[key]
        if t and rec.plan and not rec.warned and rec.plan - now <= 60 and rec.plan > now then
            rec.warned = true
            if db.world.alerts.buff then M:Toast(("%s%s|r drops in under a minute!"):format(KIND.buff.color, t.label), { sound = true }) end
        end
        if rec.plan and rec.plan <= now then rec.last, rec.plan = rec.plan, nil end
    end
end

---------------------------------------------------------------------------
-- Find group: the one part of a sighting that belongs to Finder
---------------------------------------------------------------------------
function World.FindGroup(kindKey, text)
    local k = KIND[kindKey]
    local Finder = R:GetModule("Finder")
    if not (k and k.find) then return end
    if not (Finder and Finder.QuickList) then
        return M:Print("Install RUIN Finder (0.3.2 or later) to start a group from a sighting.")
    end
    local activity, label, t, h, d = unpack(k.find)
    local detail = (text and text ~= "") and text or label
    Finder:QuickList(activity, detail, t, h, d)
    M:Print(("Listed in Finder: %s, %s."):format(activity, detail))
end

---------------------------------------------------------------------------
-- Pages
---------------------------------------------------------------------------
function World.BuildSightings(page)
    local card = W.Card(page)
    card:SetPoint("TOPLEFT", 0, 0)
    card:SetPoint("RIGHT", page, "RIGHT", -4, 0)
    card:SetHeight(108)
    local h = W.Header(card, "Report what you see (your location is added)")
    h:SetPoint("TOPLEFT", 8, -6)
    local note = W.EditBox(card, 260)
    note:SetPoint("TOPLEFT", 12, -26)
    local hint = W.Label(card, C.dim .. "optional detail, e.g. \"8 Horde, heading north\"|r", "GameFontHighlightSmall")
    hint:SetPoint("LEFT", note, "RIGHT", 10, 0)

    local prev
    for i, k in ipairs(KINDS) do
        local b = W.Button(card, "|T" .. k.icon .. ":16:16|t " .. k.label, i == 2 and 122 or 106, function()
            World.Report(k.key, note:GetText())
            note:SetText("")
        end)
        if prev then b:SetPoint("LEFT", prev, "RIGHT", 3, 0) else b:SetPoint("TOPLEFT", 8, -52) end
        prev = b
    end

    local al = W.Label(card, C.gold .. "Alerts for|r", "GameFontNormalSmall")
    al:SetPoint("TOPLEFT", 8, -86)
    local x = 70
    for _, k in ipairs(KINDS) do
        local key = k.key
        local c = W.Check(card, k.label, function() return db.world.alerts[key] end, function(v) db.world.alerts[key] = v end)
        c:SetScale(0.9)
        c:SetPoint("TOPLEFT", x / 0.9, -80 / 0.9)
        x = x + 98
    end

    local h3 = W.Header(page, "Sightings (last 30 minutes)")
    h3:SetPoint("TOPLEFT", 0, -118)
    local pins = W.Check(page, "Map pins", function() return db.world.pins end,
        function(v) db.world.pins = v; refreshPins() end)
    pins:SetPoint("TOPRIGHT", page, "TOPRIGHT", -90, -112)
    ui.list = W.List(page, 22, function(row)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(16, 16)
        row.icon:SetPoint("LEFT", 4, 0)
        row.find = W.Button(row, "Find group", 80)
        row.find:SetPoint("RIGHT", -2, 0)
        row.text = W.Label(row, "")
        row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
        row.text:SetPoint("RIGHT", row.find, "LEFT", -4, 0)
        row.text:SetWordWrap(false)
    end, function(row, e)
        local k = KIND[e.kind]
        row.icon:SetTexture(k.icon)
        row.text:SetText(("%s%s|r  %s%s|r  %s%s  %s%s · %s|r"):format(C.dim, W.Ago(GetServerTime() - e.t),
            k.color, k.label, C.white, e.where, e.text ~= "" and (C.gold .. e.text .. "|r  ") or "", C.dim,
            W.ClassName(e.by)))
        row.find:SetShown(k.find ~= nil)
        row.find:SetScript("OnClick", function() World.FindGroup(e.kind, e.text) end)
        row.tip = function(tip)
            tip:AddLine(k.label, k.rgb[1], k.rgb[2], k.rgb[3])
            if e.text ~= "" then tip:AddLine(e.text, 1, 1, 1, true) end
            tip:AddLine(e.where, 0.9, 0.9, 0.9)
            local dist = e.map and R.Map:DistanceText(e.map, e.x, e.y)
            if dist then tip:AddLine(dist .. " from you", 0.7, 0.7, 0.7) end
            tip:AddLine("Reported by " .. short(e.by) .. ", " .. W.Ago(GetServerTime() - e.t), 0.6, 0.6, 0.6)
            if k.find then tip:AddLine("Find group lists you in RUIN Finder.", 0.5, 0.8, 0.5) end
        end
    end)
    ui.list:SetEmptyText("All quiet. Reports from any RUIN member show up here, on your map and minimap.")
    ui.list.frame:SetPoint("TOPLEFT", 0, -136)
    ui.list.frame:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -24, 0)
end

function World.BuildTimers(page)
    local h = W.Header(page, "World bosses and world buffs")
    h:SetPoint("TOPLEFT", 0, -2)
    local sub = W.Label(page, C.dim .. "Press Now when a boss dies or a buff drops, or announce a buff drop ahead of time. Respawn windows are WoW Classic's, as a guide.|r", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", 0, -20)
    sub:SetPoint("RIGHT", page, "RIGHT", -6, 0)
    ui.timers = W.List(page, 40, function(row)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(28, 28)
        row.icon:SetPoint("LEFT", 6, 0)
        row.name = W.Label(row, "", "GameFontNormal")
        row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, 2)
        row.name:SetPoint("RIGHT", row, "RIGHT", -190, 0)
        row.name:SetWordWrap(false)
        row.status = W.Label(row, "", "GameFontHighlightSmall")
        row.status:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -3)
        row.status:SetPoint("RIGHT", row, "RIGHT", -190, 0)
        row.status:SetWordWrap(false)
        row.now = W.Button(row, "Now", 50)
        row.now:SetPoint("RIGHT", -4, 0)
        row.go = W.Button(row, "In", 34)
        row.go:SetPoint("RIGHT", row.now, "LEFT", -6, 0)
        row.mins = W.EditBox(row, 34)
        row.mins:SetPoint("RIGHT", row.go, "LEFT", -6, 0)
        if row.mins.SetNumeric then row.mins:SetNumeric(true) end
        row.minsLabel = W.Label(row, C.dim .. "min|r", "GameFontHighlightSmall")
        row.minsLabel:SetPoint("LEFT", row.mins, "RIGHT", 1, 0)
    end, function(row, t)
        row.icon:SetTexture(KIND[t.kind].icon)
        row.name:SetText(t.label .. "  " .. C.dim .. t.where .. "|r")
        row.status:SetText(timerStatus(t, db.world.timers[t.key]))
        local buff = t.kind == "buff"
        row.go:SetShown(buff)
        row.mins:SetShown(buff)
        row.minsLabel:SetShown(buff)
        row.now:SetScript("OnClick", function() World.SetTimer(t.key) end)
        row.go:SetScript("OnClick", function()
            local m = tonumber(row.mins:GetText())
            if m and m > 0 then World.SetTimer(t.key, m); row.mins:SetText("") end
        end)
        local rec = db.world.timers[t.key]
        row.tip = function(tip)
            tip:AddLine(t.label, 1, 0.82, 0)
            tip:AddLine(t.where, 1, 1, 1)
            if rec and rec.by then tip:AddLine("Last report by " .. short(rec.by), 0.7, 0.7, 0.7) end
        end
    end)
    ui.timers.frame:SetPoint("TOPLEFT", 0, -52)
    ui.timers.frame:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -24, 0)
end

function World.Active()
    local now, items = GetServerTime(), {}
    for _, e in ipairs(feed) do if now - e.t <= EXPIRE then items[#items + 1] = e end end
    return items
end

-- Called by Muster's page refresh for the Sightings (which = "sightings") and Timers pages.
function World.Refresh(which)
    if which == "sightings" and ui.list then ui.list:SetItems(World.Active())
    elseif which == "timers" and ui.timers then ui.timers:SetItems(TIMERS) end
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------
-- Intel's saved reports and timers come along once.
local function migrate(mdb)
    if mdb.world then return end
    mdb.world = {}
    local old = type(RUIN_IntelDB) == "table" and RUIN_IntelDB or nil
    if old then
        if type(old.alerts) == "table" then mdb.world.alerts = old.alerts end
        if old.pins ~= nil then mdb.world.pins = old.pins end
        if type(old.timers) == "table" then mdb.world.timers = old.timers end
    end
end

function World.Init(module, mdb, refreshFn)
    M = module
    refresh = refreshFn or refresh
    migrate(mdb)
    db = mdb
    for k, v in pairs(DEFAULTS) do
        if db.world[k] == nil then
            if type(v) == "table" then
                db.world[k] = {}
                for a, b in pairs(v) do db.world[k][a] = b end
            else
                db.world[k] = v
            end
        end
    end
    for k in pairs(KIND) do if db.world.alerts[k] == nil then db.world.alerts[k] = true end end

    M:Listen("SPOT", function(_, d, sender) World.AddSpot(d, sender, false) end)
    M:Listen("TIMER", function(_, d, sender) World.OnTimer(d, sender) end)
    -- Members still running the old RUIN Intel addon send under its name.
    if M.ListenRaw then
        M:ListenRaw("Intel:SPOT", function(_, d, sender) World.AddSpot(d, sender, false) end)
        M:ListenRaw("Intel:TIMER", function(_, d, sender) World.OnTimer(d, sender) end)
    end
    C_Timer.NewTicker(30, function() refreshPins(); refresh() end)
    C_Timer.NewTicker(5, timerTick)
end

function RUIN_Muster_ReportEnemy() World.Report("enemy", "") end
function RUIN_Muster_UnderAttack() World.Report("attack", "") end
BINDING_NAME_RUIN_MUSTER_ENEMY = "Muster: report enemy group here"
BINDING_NAME_RUIN_MUSTER_ATTACK = "Muster: I'm under attack"

-- /muster spot enemy|attack|boss|rare|buff|other [detail]   (also /intel ...)
-- /muster timer <name> [minutes]     e.g. /muster timer songflower, /muster timer dragonslayer 5
function World.Slash(msg)
    local cmd, rest = (msg or ""):match("^(%S*)%s*(.*)$")
    cmd = cmd:lower()
    if cmd == "timer" then
        local key, mins = rest:lower():match("^(%S+)%s*(%d*)")
        if key and TIMER[key] then
            World.SetTimer(key, tonumber(mins))
        else
            local keys = {}
            for _, t in ipairs(TIMERS) do keys[#keys + 1] = t.key end
            M:Print("Timers: " .. table.concat(keys, ", "))
        end
    elseif KIND[cmd] then
        World.Report(cmd, rest)
    elseif cmd ~= "" then
        World.Report("other", msg)
    else
        M:OpenTab()
    end
end

SLASH_RUINMUSTERINTEL1 = "/intel"
SlashCmdList.RUINMUSTERINTEL = World.Slash
