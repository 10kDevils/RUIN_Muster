-- RUIN Muster: the automatic Most Wanted list
-- When an enemy player kills a RUIN member, that member's RUIN tells the org
-- who did it (from the game's death recap, or failing that the enemy player
-- near you who had you targeted). The killers of RUIN members, most kills
-- first over the last week, are the Most Wanted. When RUIN members kill
-- enemy players (honorable kills), that counts on the Slayers list, and
-- killing someone on the Most Wanted list is announced. A Most Wanted
-- player's nameplate showing up near you raises a warning.
local ADDON, ns = ...
local R = RUIN_API
if not R or (R.apiLevel or 1) < 8 then return end
local W = R.Widgets
local C = W.COLORS

local Wanted = {}
ns.Wanted = Wanted

local WEEK = 7 * 86400
local KEEP = 30 * 86400
local DEDUPE = 20                -- the same kill reported twice within this many seconds counts once
local NEAR_REPEAT = 300          -- warn about the same wanted player nearby every 5 minutes at most
local HOSTILE_PLAYER = 0x440     -- COMBATLOG_OBJECT_TYPE_PLAYER | COMBATLOG_OBJECT_REACTION_HOSTILE

local M, db
local ui = { view = "Most Wanted" }
local nearWarned = {}

local function now() return GetServerTime() end
local function short(n) return R.Util.ShortName(n or "?") end
local function secret(v) return issecretvalue and issecretvalue(v) end
local function key(n) return short(n):lower() end
local function band(a, b) return (bit and bit.band and bit.band(a, b)) or (a % (b * 2) >= b and b or 0) end

local function store()
    db.wanted = type(db.wanted) == "table" and db.wanted or {}
    db.wanted.deaths = type(db.wanted.deaths) == "table" and db.wanted.deaths or {}   -- { k = killer, kg, v = victim, vg, z, t }
    db.wanted.kills = type(db.wanted.kills) == "table" and db.wanted.kills or {}     -- { k = RUIN member, v = enemy, vg, z, t }
    return db.wanted
end

local function prune(list)
    for i = #list, 1, -1 do if now() - (list[i].t or 0) > KEEP then table.remove(list, i) end end
end

local function seen(list, a, b, t)
    for i = #list, math.max(1, #list - 50), -1 do
        local e = list[i]
        if key(e.k) == key(a) and key(e.v) == key(b) and math.abs((e.t or 0) - t) <= DEDUPE then return true end
    end
    return false
end

---------------------------------------------------------------------------
-- Who killed you
---------------------------------------------------------------------------
-- From the death recap: the killing blow is the newest row with overkill.
function Wanted.KillerFromRecap()
    if not (C_DeathRecap and C_DeathRecap.HasRecapEvents and C_DeathRecap.GetRecapEvents) then return nil end
    local ok, has = pcall(C_DeathRecap.HasRecapEvents)
    if not ok or not has then return nil end
    local ok2, rows = pcall(C_DeathRecap.GetRecapEvents)
    if not ok2 or type(rows) ~= "table" then return nil end
    for _, r in ipairs(rows) do
        if type(r) == "table" and (tonumber(r.overkill) or -1) >= 0 then
            local flags = tonumber(r.sourceFlags) or 0
            local name = r.sourceName
            if type(name) == "string" and not secret(name) and band(flags, HOSTILE_PLAYER) == HOSTILE_PLAYER then
                return name
            end
            return nil
        end
    end
    return nil
end

-- Failing that: an enemy player near you who had you targeted.
function Wanted.KillerNearby()
    for i = 1, 40 do
        local unit = "nameplate" .. i
        if UnitExists(unit) and UnitIsPlayer(unit) and UnitIsEnemy and UnitIsEnemy("player", unit)
            and UnitExists(unit .. "target") and UnitIsUnit(unit .. "target", "player") then
            local name, realm = UnitName(unit)
            if name and not secret(name) then
                local g = GetGuildInfo and GetGuildInfo(unit)
                return (realm and realm ~= "") and (name .. "-" .. realm) or name, (not secret(g)) and g or nil
            end
        end
    end
    return nil
end

local function myZone() return (GetRealZoneText and GetRealZoneText()) or "" end

local function onDeath()
    C_Timer.After(0.5, function()
        local killer, guild = Wanted.KillerFromRecap()
        if not killer then killer, guild = Wanted.KillerNearby() end
        if not killer then return end
        local p = R:GetPlayer()
        local d = { k = killer, kg = guild, v = p.name, vg = p.guild, z = myZone(), t = now() }
        Wanted.AddDeath(d, p.name)
        M:Send("WANTED", d, "ORG", nil, R.PRIORITY.NORMAL)
    end)
end

function Wanted.AddDeath(d, sender)
    if type(d) ~= "table" or type(d.k) ~= "string" then return end
    local w = store()
    local t = tonumber(d.t) or now()
    local victim = type(d.v) == "string" and d.v or sender
    if seen(w.deaths, d.k, victim, t) then return end
    local e = { k = d.k:sub(1, 48), kg = type(d.kg) == "string" and d.kg:sub(1, 48) or nil, v = victim:sub(1, 48),
                vg = type(d.vg) == "string" and d.vg:sub(1, 48) or nil, z = type(d.z) == "string" and d.z:sub(1, 40) or "", t = t }
    w.deaths[#w.deaths + 1] = e
    prune(w.deaths)
    local row = Wanted.Row(e.k)
    if row and row.week >= 3 and row.week % 3 == 0 then
        M:Toast(("%s%s|r has killed %d RUIN members this week (last: %s in %s)."):format(C.bad, short(e.k), row.week, short(e.v), e.z), { sound = true })
    end
    Wanted.Refresh()
end

---------------------------------------------------------------------------
-- Your kills (honorable kills, and the combat log's party kills when the game gives them)
---------------------------------------------------------------------------
local lastKill = {}

local function reportKill(victim, guild)
    if type(victim) ~= "string" or victim == "" or secret(victim) then return end
    if lastKill[key(victim)] and GetTime() - lastKill[key(victim)] < DEDUPE then return end
    lastKill[key(victim)] = GetTime()
    local p = R:GetPlayer()
    local d = { k = p.name, v = victim, vg = guild, z = myZone(), t = now() }
    Wanted.AddKill(d, p.name)
    M:Send("SLAY", d, "ORG", nil, R.PRIORITY.NORMAL)
end

function Wanted.AddKill(d, sender)
    if type(d) ~= "table" or type(d.v) ~= "string" then return end
    local w = store()
    local t = tonumber(d.t) or now()
    local slayer = type(d.k) == "string" and d.k or sender
    if seen(w.kills, slayer, d.v, t) then return end
    local e = { k = slayer:sub(1, 48), v = d.v:sub(1, 48), vg = type(d.vg) == "string" and d.vg:sub(1, 48) or nil,
                z = type(d.z) == "string" and d.z:sub(1, 40) or "", t = t }
    w.kills[#w.kills + 1] = e
    prune(w.kills)
    local row = Wanted.Row(e.v)
    if row and row.week > 0 then
        M:Toast(("Revenge! %s killed Most Wanted %s%s|r."):format(W.ClassName(e.k), C.bad, short(e.v)), { sound = true })
    end
    Wanted.Refresh()
end

-- "Grimtusk dies, honorable kill Rank: Sergeant (Estimated Honor Points: 12)"
local honorPattern
local function onHonor(_, text)
    if type(text) ~= "string" or secret(text) then return end
    if not honorPattern then
        local g = COMBATLOG_HONORGAIN or "%s dies, honorable kill Rank: %s (Estimated Honor Points: %d)"
        g = g:gsub("([%(%)%.%-%+%[%]%?%*%^%$])", "%%%1")        -- escape everything magic but the %s and %d
        g = g:gsub("%%s", "(.-)"):gsub("%%d", "(%%d+)")
        honorPattern = "^" .. g .. "$"
    end
    local victim = text:match(honorPattern)
    if victim then reportKill(victim) end
end

local function onCombatLog()
    if not CombatLogGetCurrentEventInfo then return end
    local ok, _, sub, _, srcGUID, _, _, _, _, destName, destFlags = pcall(CombatLogGetCurrentEventInfo)
    if not ok or sub ~= "PARTY_KILL" or srcGUID ~= R:GetPlayerGUID() then return end
    if band(tonumber(destFlags) or 0, HOSTILE_PLAYER) == HOSTILE_PLAYER then reportKill(destName) end
end

---------------------------------------------------------------------------
-- The lists
---------------------------------------------------------------------------
-- A killer's numbers: { name, guild, week, total, last, zone, victims }
function Wanted.Row(name)
    for _, r in ipairs(Wanted.MostWanted(true)) do if key(r.name) == key(name) then return r end end
    return nil
end

function Wanted.MostWanted(all)
    local by = {}
    for _, d in ipairs(store().deaths) do
        local r = by[key(d.k)] or { name = d.k, week = 0, total = 0, last = 0, victims = {} }
        r.total = r.total + 1
        if now() - d.t <= WEEK then r.week = r.week + 1 end
        if d.t > r.last then r.last, r.zone = d.t, d.z end
        r.guild = d.kg or r.guild
        r.victims[short(d.v)] = true
        by[key(d.k)] = r
    end
    local out = {}
    for _, r in pairs(by) do
        local n = 0
        for _ in pairs(r.victims) do n = n + 1 end
        r.victimCount = n
        if all or r.week > 0 then out[#out + 1] = r end
    end
    table.sort(out, function(a, b)
        if a.week ~= b.week then return a.week > b.week end
        if a.total ~= b.total then return a.total > b.total end
        return a.last > b.last
    end)
    return out
end

function Wanted.Slayers()
    local by = {}
    for _, k in ipairs(store().kills) do
        local r = by[key(k.k)] or { name = k.k, week = 0, total = 0, last = 0, wanted = 0 }
        r.total = r.total + 1
        if now() - k.t <= WEEK then r.week = r.week + 1 end
        if k.t > r.last then r.last, r.lastVictim = k.t, k.v end
        by[key(k.k)] = r
    end
    local out = {}
    for _, r in pairs(by) do out[#out + 1] = r end
    table.sort(out, function(a, b) if a.week ~= b.week then return a.week > b.week end return a.total > b.total end)
    return out
end

-- Recent deaths and kills together, newest first.
function Wanted.Feed()
    local out = {}
    for _, d in ipairs(store().deaths) do out[#out + 1] = { death = true, e = d } end
    for _, k in ipairs(store().kills) do out[#out + 1] = { kill = true, e = k } end
    table.sort(out, function(a, b) return a.e.t > b.e.t end)
    for i = #out, 61, -1 do out[i] = nil end
    return out
end

-- A Most Wanted player's nameplate appeared.
local function onPlate(_, unit)
    if not UnitIsPlayer(unit) or not (UnitIsEnemy and UnitIsEnemy("player", unit)) then return end
    local name = UnitName(unit)
    if not name or secret(name) then return end
    local r = Wanted.Row(name)
    if r and r.week > 0 and (not nearWarned[key(name)] or GetTime() - nearWarned[key(name)] > NEAR_REPEAT) then
        nearWarned[key(name)] = GetTime()
        M:Toast(("Most Wanted nearby: %s%s|r (%d RUIN kills this week)"):format(C.bad, short(name), r.week), { sound = true })
    end
end

-- Share the last week with someone who connected (Muster's ASK). One member answers.
local lastHeard, sharePending = -999, false
function Wanted.Share()
    if sharePending then return end
    sharePending = true
    local asked = GetTime()
    C_Timer.After(4 + math.random() * 10, function()
        sharePending = false
        if lastHeard >= asked then return end
        local n = 0
        for i = #store().deaths, 1, -1 do
            local d = store().deaths[i]
            if now() - d.t > WEEK or n >= 60 then break end
            n = n + 1
            M:Send("WANTED", d, "ORG", nil, R.PRIORITY.BULK)
        end
    end)
end

---------------------------------------------------------------------------
-- The Most Wanted tab
---------------------------------------------------------------------------
function Wanted.Build(page)
    ui.page = page
    ui.viewBtn = W.Dropdown(page, 170, { "Most Wanted", "Slayers", "Recent" }, function() return ui.view end,
        function(v) ui.view = v; Wanted.Refresh() end, "Show: ")
    ui.viewBtn:SetPoint("TOPLEFT", 0, 0)
    ui.info = W.Label(page, "", "GameFontHighlightSmall")
    ui.info:SetPoint("LEFT", ui.viewBtn, "RIGHT", 10, 0)
    ui.info:SetWidth(560)
    ui.info:SetJustifyH("LEFT")
    ui.info:SetWordWrap(false)
    ui.list = W.List(page, 22, function(row)
        row.a = W.Label(row, "")
        row.a:SetPoint("LEFT", 6, 0); row.a:SetWidth(200); row.a:SetWordWrap(false)
        row.b = W.Label(row, "", "GameFontHighlightSmall")
        row.b:SetPoint("LEFT", 210, 0); row.b:SetPoint("RIGHT", row, "RIGHT", -110, 0); row.b:SetWordWrap(false)
        row.btn = W.Button(row, "Bounty", 70)
        row.btn:SetPoint("RIGHT", -2, 0)
    end, function(row, e)
        row.btn:Hide()
        if e.mw then
            local r = e.mw
            row.a:SetText(("%s%d.|r %s%s|r%s"):format(C.dim, e.i, C.bad, short(r.name), r.guild and (C.dim .. " <" .. r.guild .. ">|r") or ""))
            row.b:SetText(("%s%d|r this week  ·  %d in all  ·  %d victims  ·  %slast %s%s|r"):format(C.white, r.week, r.total, r.victimCount,
                C.dim, W.Ago(math.max(60, now() - r.last)), r.zone and r.zone ~= "" and (" in " .. r.zone) or ""))
            if M.PostBounty and R:IsOfficer() then
                row.btn:SetScript("OnClick", function() M:PostBounty(short(r.name), "Player", "Most Wanted") end)
                row.btn:Show()
            end
        elseif e.sl then
            local r = e.sl
            row.a:SetText(("%s%d.|r %s"):format(C.dim, e.i, W.ClassName(r.name)))
            row.b:SetText(("%s%d|r this week  ·  %d in all  ·  %slast: %s|r"):format(C.white, r.week, r.total, C.dim, short(r.lastVictim)))
        else
            local d = e.e
            if e.death then
                row.a:SetText(C.bad .. short(d.k) .. "|r " .. C.dim .. "killed|r " .. short(d.v))
            else
                row.a:SetText(C.good .. short(d.k) .. "|r " .. C.dim .. "killed|r " .. short(d.v))
            end
            row.b:SetText(C.dim .. (d.z ~= "" and (d.z .. "  ·  ") or "") .. W.Ago(math.max(60, now() - d.t)) .. "|r")
        end
    end)
    ui.list.frame:SetPoint("TOPLEFT", 0, -32)
    ui.list.frame:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -24, 0)
    page:SetScript("OnShow", Wanted.Refresh)
end

function Wanted.Refresh()
    if not (ui.page and ui.page:IsVisible()) then return end
    local items = {}
    if ui.view == "Slayers" then
        for i, r in ipairs(Wanted.Slayers()) do items[#items + 1] = { sl = r, i = i } end
        ui.info:SetText(C.dim .. "RUIN members' kills of enemy players (honorable kills).|r")
        ui.list:SetEmptyText("No kills recorded yet.")
    elseif ui.view == "Recent" then
        items = Wanted.Feed()
        ui.info:SetText(C.dim .. "The latest deaths and kills the org's RUIN saw.|r")
        ui.list:SetEmptyText("Nothing yet.")
    else
        for i, r in ipairs(Wanted.MostWanted(false)) do items[#items + 1] = { mw = r, i = i } end
        ui.info:SetText(C.dim .. "Enemy players who killed RUIN members this week, most kills first. Built automatically.|r")
        ui.list:SetEmptyText("Nobody has killed a RUIN member this week.")
    end
    ui.list:SetItems(items)
end

function Wanted.Count() return #Wanted.MostWanted(false) end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------
function Wanted.Init(module, mdb)
    M, db = module, mdb
    store()
    M:Listen("WANTED", function(_, d, sender) lastHeard = GetTime(); Wanted.AddDeath(d, sender) end)
    M:Listen("SLAY", function(_, d, sender) Wanted.AddKill(d, sender) end)
    M:RegisterEvent("PLAYER_DEAD", onDeath)
    M:RegisterEvent("CHAT_MSG_COMBAT_HONOR_GAIN", onHonor)
    M:RegisterEvent("NAME_PLATE_UNIT_ADDED", onPlate)
    pcall(M.RegisterEvent, M, "COMBAT_LOG_EVENT_UNFILTERED", onCombatLog)
end
