-- Kebold's Shiny: the leveling route, in game
-- Plans from what the game shows right now: your real skill and cap, the recipes you know (from the collector),
-- the price ladders of the last scan, vendor prices seen at vendors, what is in your bags. Any profession can be
-- planned over any skill range, whether you have it or not. It shows, links and searches; it never crafts, buys
-- or learns anything.
--
--   /kebold                 open or close the window
--   /kebold bs              show a profession (bs, lw, tailoring, eng, alch, ench, cook, firstaid, mining)
--   /kebold from 1          plan from this skill instead of your own (/kebold from auto = your skill again)
--   /kebold to 300          plan up to this skill (/kebold to auto = your cap, or 300 once you are at it)
--   /kebold mine            back to your own skill and cap
--   /kebold recipes         which recipes the route may use: trainer only > + buyable recipe items > everything
--                           (also /kebold trainer, /kebold buyable, /kebold all)
--   /kebold sales           what the crafts sell for: best of AH and vendor > vendor only > not counted
--                           (also /kebold sales best | vendor | off)
--   /kebold fast | cheap    fewest casts, or lowest cost (default)
--   /kebold tab level       open on a page: level, craft, favor (or crates / writs), shopping, prices, sales, settings (the old names route,
--                           recipes and scan still work; /kebold page ... is the same)
--   /kebold print           the same lines in chat, in case the window misbehaves
--   /kebold strip pane      the selected recipe's figures inside the profession window's recipe pane; strip top = in a
--                           strip above the window; strip off
--   /kebold skin plain      plain coloured widgets instead of Blizzard's (if something looks broken); skin auto = back
--   /kebold ui              prints and saves which templates and functions this client has
--   /kebold ui gallery      a window with every widget in both looks
--
--   /keboldscan bs          scan only what the Blacksmithing plan on screen could buy, and what it sells
--   /keboldscan bs all      every material, part, product and recipe item of the profession
--   /keboldscan route       only the items of the route on screen (quick refresh before buying)
--   /keboldscan everything  every item any recipe of the nine professions uses, makes or is taught by

local E = KeboldsShinyEngine
local UI = KeboldsShinyUI   -- the widget kit (LedgerUI.lua)
local DAY_ZERO = 1577836800   -- the scanner's day origin
-- the window's measures: its size when nothing is saved and the limits of resizing it, the head band above the
-- page and the footer under it, the rail of pages, the gap around a page, a row of controls, the details pane,
-- and the least width a list keeps beside that pane (at the smallest window the pane is 308 wide)
-- side = where the page's box starts (the rail and the space after it), pad = the space between that box and the
-- page inside it, gapY = between a page's control rows and its list. minW is the smallest width with compact rows;
-- the larger rows of the other two densities need minWide and minRoomy (NS.minW() gives the one in force).
local WIN = { w = 1060, h = 640, minW = 920, minWide = 1010, minRoomy = 1050, minH = 480, maxW = 1600, maxH = 1200, top = 58, bottom = 28, rail = 132, side = 146,
  pad = 8, bar = 26, gapY = 6, detail = 390, detailMin = 300, list = 420 }
local ROW_H = 20
local floor, ceil, max, min, abs = math.floor, math.ceil, math.max, math.min, math.abs

local ALIAS = {
  bs = "Blacksmithing", blacksmithing = "Blacksmithing", smithing = "Blacksmithing", blacksmith = "Blacksmithing",
  lw = "Leatherworking", leatherworking = "Leatherworking", leather = "Leatherworking",
  tailoring = "Tailoring", tailor = "Tailoring", tail = "Tailoring",
  eng = "Engineering", engineering = "Engineering", engi = "Engineering",
  alch = "Alchemy", alchemy = "Alchemy",
  ench = "Enchanting", enchanting = "Enchanting",
  cook = "Cooking", cooking = "Cooking",
  fa = "First Aid", firstaid = "First Aid", ["first aid"] = "First Aid",
  mining = "Mining", smelting = "Mining",
}
local SHORT = { Alchemy = "Alchemy", Blacksmithing = "Smithing", Cooking = "Cooking", Enchanting = "Enchant", Engineering = "Engineer",
  ["First Aid"] = "First Aid", Leatherworking = "Leather", Mining = "Mining", Tailoring = "Tailoring" }
local RECIPES = { "trainer only", "+ buyable recipe items", "everything" }
-- "Sells at": where the plan counts what it makes as sold. On the button: "Sells at: best price".
local SALES = { best = "best price", vendor = "vendor", off = "not counted" }
local SALES_MENU = { best = "Best price (vendor or auction house)", vendor = "Vendor", off = "Not counted" }
-- What the two boxes of the plan bar show: short, so no value is cut at the smallest window ("Recipes [Trainer only]").
local RECIPES_BOX = { "Trainer only", "Trainer + buyable", "Everything" }
local SALES_BOX = { best = "Best price", vendor = "Vendor", off = "Not counted" }
local SALES_NEXT = { best = "vendor", vendor = "off", off = "best" }
local PICK_TEXT = { auto = "Auto", buy = "Buy", craft = "Make", have = "Have it" }
local SELL_TEXT = { auto = "Auto", vendor = "Vendor", ah = "Auction house", de = "Disenchant" }
-- Where one craft is counted as sold (the engine's info().way), written out: " vendor", " AH", " disenchant".
local WAY_SHORT = { AH = " AH", Vendor = " vendor", DE = " disenchant" }
local WAY_LONG = { AH = "auction house", Vendor = "vendor", DE = "disenchant" }
local RANKS = { 75, 150, 225 }
local COLOUR = { o = "|cffff8040", y = "|cffffff00", g = "|cff40c040", x = "|cff808080" }
local DIM, RED, GOLD, WHITE, GREEN = "|cff909090", "|cffff5050", "|cffffd100", "|cffffffff", "|cff40d040"

local db, current, frame
local priceVersion = 0   -- goes up when a scan ends or a part's buy/make choice changes, so the route is planned again
local rows = {}          -- the lines of the page showing, as the last refresh built them

-- Shared with the other Kebold files: LedgerLevel.lua (the Level page and its route), LedgerRecipes.lua (the Craft
-- page and the details pane), LedgerSettings.lua, LedgerSalesTab.lua (Prices and My sales), LedgerExtras.lua
-- (trainer locations, the strip above the profession window, item tooltip lines), LedgerEntry.lua, LedgerAH.lua.
local NS = {}
KeboldsShinyNS = NS
NS.WIN = WIN
-- The pages by key, with the name each has on the rail. The keys are the ones saved since the first version (the
-- Level page is "route", Craft is "recipes", Prices is "scan"), so old saved settings and /kebold tab route still
-- work. A page's file fills in the rest with NS.page (below).
local TAB_LABEL = { route = "Level", recipes = "Craft", shop = "Shopping", scan = "Prices", sales = "My sales", settings = "Settings" }
local PAGE_RANK = { route = 1, recipes = 2, shop = 3, scan = 4, sales = 5, settings = 6 }
local TAB_ORDER = { "route", "recipes", "shop", "scan", "sales", "settings" }

local function say(msg)
  print("|cff66ccffKebold|r " .. msg)
end

local function try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local function pass(ok, ...)
    if ok then return ... end
    return nil
  end
  return pass(pcall(fn, ...))
end

-- Vendor values the game itself gave (read during scans and when a profession window opens, saved under
-- KeboldsShinyDB.sell) replace the shipped ones; r.sell0 keeps what the addon shipped with.
local sellSeen = -1
local function applySell()
  local g = type(KeboldsShinyDB) == "table" and KeboldsShinyDB.sell or nil
  if type(g) ~= "table" then g = nil end
  for _, r in ipairs(db.recipes) do
    if not r.sellKept then r.sellKept, r.sell0 = true, r.sell end
    local v = g and r.made > 0 and g[r.made] or nil
    if type(v) == "number" then r.sell = v else r.sell = r.sell0 end
  end
end

local function data()
  if not db then db = E.load(KeboldsShinyData) end
  local v = type(KeboldsShinyScan_SellVersion) == "function" and KeboldsShinyScan_SellVersion() or 0
  if v ~= sellSeen then
    sellSeen = v
    applySell()
    priceVersion = priceVersion + 1   -- every plan counts vendor values
  end
  return db
end

local function saved()
  if type(KeboldsShinyDB) ~= "table" then KeboldsShinyDB = {} end
  return KeboldsShinyDB
end

-- The smallest width the window may have: the plan bar, a list and the details pane side by side need more room
-- with the larger rows than with compact ones.
local function minW()
  local key = UI.density().key
  return key == "compact" and WIN.minW or (key == "roomy" and WIN.minRoomy or WIN.minWide)
end

-- ---- "Plan for" profiles: whose plan this is ----------------------------------------------------------------------
-- settings().profile = nil is "Me": the character logged in, everything as the game shows it. A name is a plan for
-- somebody else, kept under settings().profiles[name]:
--   { faction = "A" | "H", known = "none" (planned as a fresh character), overtime = 0..5, chef = 0..5,
--     bartering = 0..2, note = "", plan = { [prof] = { from, to } }, pick = {}, sellPick = {}, exclude = {} }
-- The four tables of choices exist once per profile and once for the owner (settings().own). settings().plan,
-- .pick, .sellPick and .exclude always POINT AT THE ACTIVE SET, so code that reads S.pick[...] needs no change and
-- nothing set for somebody else leaks into the owner's plans (or back). The game writes a shared table out twice, so
-- after a reload the pointers are separate copies: the first settings() of a session points them at the kept set
-- again (the owner's when the saved profile no longer exists).
local CHOICE_KEYS = { "plan", "pick", "sellPick", "exclude" }
-- Text somebody typed for a profile (its name, its note), made safe to show: at most `limit` characters, never
-- cutting a character of several bytes in two, and every "|" doubled, because the game reads a single "|" as the
-- start of a colour or link code (a stray one garbles the line or the text after it). Text that already has its
-- "|" doubled comes out the same, so what an edit box hands back can be passed in again.
local function profileText(text, limit)
  text = tostring(text or ""):gsub("[%c]", " "):gsub("||", "|"):match("^%s*(.-)%s*$")
  local out, n = {}, 0
  for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    if n >= limit then break end
    n = n + 1
    out[n] = ch == "|" and "||" or ch
  end
  return (table.concat(out):match("^%s*(.-)%s*$"))
end
local boundTo, boundName = nil, nil
local function cleanProfile(p)
  if p.faction ~= "A" and p.faction ~= "H" then p.faction = "A" end
  p.known = "none"
  local function rank(k, hi)
    local v = floor((tonumber(p[k]) or 0) + 0.5)
    p[k] = max(0, min(hi, v))
  end
  rank("overtime", 5)
  rank("chef", 5)
  rank("bartering", 2)
  if type(p.note) ~= "string" then p.note = "" end
  for _, k in ipairs(CHOICE_KEYS) do
    if type(p[k]) ~= "table" then p[k] = {} end
  end
  return p
end
local function bindChoices(s)
  local P = s.profile ~= nil and s.profiles[s.profile] or nil
  if type(P) == "table" then cleanProfile(P) else P, s.profile = nil, nil end
  if boundTo ~= s or boundName ~= s.profile then   -- the first look at this saved table, or another profile
    if type(s.own) ~= "table" then
      s.own = {}
      if not P then   -- saved before there were profiles: the choices are the owner's
        for _, k in ipairs(CHOICE_KEYS) do s.own[k] = s[k] end
      end
    end
    for _, k in ipairs(CHOICE_KEYS) do
      if type(s.own[k]) ~= "table" then s.own[k] = {} end
    end
    local set = P or s.own
    for _, k in ipairs(CHOICE_KEYS) do s[k] = set[k] end
    boundTo, boundName = s, s.profile
    return
  end
  local set = P or s.own   -- while bound the pointer is the truth (a table replaced by hand is adopted)
  for _, k in ipairs(CHOICE_KEYS) do
    if type(s[k]) ~= "table" then s[k] = type(set[k]) == "table" and set[k] or {} end
    set[k] = s[k]
  end
end

local function settings()
  local s = saved().ledger
  if type(s) ~= "table" then
    s = {}
    saved().ledger = s
  end
  if not SALES[s.sales] then s.sales = (s.sell == false) and "off" or "best" end   -- best / vendor / off
  if type(s.plan) ~= "table" then s.plan = {} end
  -- [item id] = "buy" | "craft": your choice for a crafted part; "have": any material you have already (costs nothing)
  if type(s.pick) ~= "table" then s.pick = {} end
  if type(s.sellPick) ~= "table" then s.sellPick = {} end   -- [item id] = "vendor" | "ah" | "de": where one product sells
  if not TAB_LABEL[s.tab] then s.tab = "route" end
  if type(s.opts) ~= "table" then s.opts = {} end         -- engine numbers changed on the Settings page
  if type(s.exclude) ~= "table" then s.exclude = {} end   -- [recipe id] = true: skipped in routes
  if type(s.fav) ~= "table" then s.fav = {} end           -- [recipe id] = true: a favourite (Show: favourites, /keboldscan fav)
  if s.recipes ~= 1 and s.recipes ~= 2 and s.recipes ~= 3 then s.recipes = s.items and 2 or 1 end   -- 1 trainer only, 2 + buyable items, 3 everything
  -- the look (addon/UI_PLAN.md, UI_PLAN2.md): skin "auto" | "plain"; win = { x, y, w, h, scale, dock };
  -- fold = { ["route:whole"] = true }; detailOff = true when the details pane is folded away;
  -- coins / icons / profButton (false = off); minimap = { angle, hide }; ahButton "tabs" | "title" | "off";
  -- tipMode "full" | "short"; salesView "items" | "events" | "history"; salesSort, salesDesc
  if s.skin ~= "plain" then s.skin = "auto" end
  if type(s.win) ~= "table" then s.win = {} end
  if type(s.win.h) ~= "number" then s.win.h = WIN.h end
  if type(s.win.w) ~= "number" then   -- saved before the window could be widened: the new default size, once
    s.win.w = WIN.w
    s.win.h = max(s.win.h, WIN.h)
  end
  -- how roomy the lists are (Settings: Row size): the kit reads it (UI.density)
  if s.density ~= "compact" and s.density ~= "roomy" then s.density = "normal" end
  if not s.win.roomy then   -- once: a window still at the first default width gets the width the larger rows need
    s.win.roomy = true
    if s.win.w == 1000 then s.win.w = WIN.w end
  end
  s.win.w = max(minW(), min(WIN.maxW, s.win.w))
  s.win.h = max(WIN.minH, min(WIN.maxH, s.win.h))
  if type(s.win.scale) ~= "number" then s.win.scale = 1 end
  s.win.scale = max(0.8, min(1.2, s.win.scale))
  if s.win.dock == nil then s.win.dock = true end
  if type(s.fold) ~= "table" then s.fold = {} end
  if type(s.minimap) ~= "table" then s.minimap = {} end
  if type(s.minimap.angle) ~= "number" then s.minimap.angle = 215 end
  if s.ahButton ~= "title" and s.ahButton ~= "off" then s.ahButton = "tabs" end
  if s.tipMode ~= "short" then s.tipMode = "full" end
  if s.salesView ~= "events" and s.salesView ~= "history" then s.salesView = "items" end
  if type(s.profiles) ~= "table" then s.profiles = {} end   -- "Plan for" profiles; s.profile = the active one's name
  if type(s.own) ~= "table" and boundTo == s then boundTo = nil end
  bindChoices(s)
  return s
end

-- The profile being planned for and its name; nil for "Me".
local function who()
  local s = settings()
  if s.profile == nil then return nil end
  return s.profiles[s.profile], s.profile
end
-- "A" or "H": the active profile's faction, else the character's; nil when the game does not say.
local sideReal = false   -- true while the character's own side is wanted whatever the profile
local function sideOf()
  local P = not sideReal and who() or nil
  if P then return P.faction end
  local f = try(UnitFactionGroup, "player")
  return (f == "Alliance" and "A") or (f == "Horde" and "H") or nil
end

-- The range chosen by hand for a profession: { from = , to = }, either may be nil (= follow the character).
local function planOf(prof)
  local S = settings()
  if type(S.plan[prof]) ~= "table" then S.plan[prof] = {} end
  return S.plan[prof]
end

-- The saved prices of this character's auction house: its realm and faction (KeboldsShinyHouse, KeboldsShiny.lua).
local function realmItems()
  local realms = saved().realms
  local store
  if type(KeboldsShinyHouse) == "table" and KeboldsShinyHouse.peek then
    store = try(KeboldsShinyHouse.peek, realms)
  else
    store = type(realms) == "table" and realms[try(GetRealmName) or "Unknown"] or nil
  end
  return type(store) == "table" and type(store.items) == "table" and store.items or {}
end

local function collected()
  local c = saved().collect
  return type(c) == "table" and c or {}
end

-- 12g 34s. The letters carry three colours of their own (UI.MARK), used nowhere else: UI.show turns exactly those
-- into coin pictures on screen, and UI.plainText (and the tests' plain) gives "12g 34s" back.
local MG, MS, MC = UI.MARK.g, UI.MARK.s, UI.MARK.c
local function money(v)
  if v == nil then return "?" end
  v = floor(abs(v) + 0.5)
  local g, s, c = floor(v / 10000), floor(v / 100) % 100, v % 100
  if g > 0 then return g .. MG .. " " .. s .. MS end
  if s > 0 then return s .. MS .. " " .. c .. MC end
  return c .. MC
end

local function itemName(id)
  local live = C_Item and try(C_Item.GetItemNameByID, id)
  if live and live ~= "" then return live end
  local it = data().items[id]
  if it and it.name ~= "" then return it.name end
  return "item " .. id
end

-- An item's name in its quality colour (plain when the game does not say).
local function itemText(id, name)
  name = name or itemName(id)
  local q = C_Item and try(C_Item.GetItemQualityByID, id)
  local c = type(q) == "number" and type(ITEM_QUALITY_COLORS) == "table" and ITEM_QUALITY_COLORS[q] or nil
  if type(c) == "table" and type(c.hex) == "string" then return c.hex .. name .. "|r" end
  return name
end

local function bagCount(id)
  if who() then return 0 end   -- a plan for somebody else: your bags are not theirs
  local n = C_Item and try(C_Item.GetItemCount, id, true)
  if type(n) ~= "number" then n = try(GetItemCount, id, true) end
  return type(n) == "number" and n or 0
end

-- Your skill and cap in a profession and which of its recipes you know. Skill is read live; the list of known
-- recipes is the collector's, refreshed whenever the profession window is opened or a recipe is learned.
-- For a profession the character does not have, everything stays nil.
-- The collector's lists are saved for the whole account, one per profession: a list read on another character
-- is not this one's (its known recipes are not known here). A list saved before the name was kept counts as ours.
local function me()
  local n = try(UnitName, "player")
  if type(n) ~= "string" or n == "" then return nil end
  return n .. "-" .. tostring(try(GetRealmName) or "")
end
local function mine(rec)
  if type(rec) ~= "table" then return false end
  local who = me()
  return rec.who == nil or who == nil or rec.who == who
end

-- The collector saves a profession's list under the name the game gives it, which is not English on every
-- client, and under the profession's id (the skill line). The list for one of the data's professions: the one
-- under its English name, else the one whose id is the profession's skill line in the shipped data.
local function recOf(prof)
  local recs = collected().recipes
  if type(recs) ~= "table" or prof == nil then return nil end
  local rec = recs[prof]
  if type(rec) == "table" then return rec end
  local line = data().line[prof]
  if line == nil then return nil end
  for _, r in pairs(recs) do
    if type(r) == "table" and tonumber(r.id) == line then return r end
  end
  return nil
end
-- The data's (English) name of the profession a game record describes ({ professionName, professionID }): by
-- name, else by skill line id; nil when it is not one of the nine.
local function profNameOf(info)
  if type(info) ~= "table" then return nil end
  local d = data()
  if type(info.professionName) == "string" and d.byProf[info.professionName] then return info.professionName end
  local id = tonumber(info.professionID)
  if id then
    for _, p in ipairs(d.profs) do
      if d.line[p] == id then return p end
    end
  end
  return nil
end

local function profState(prof)
  local st = {}
  if who() then   -- a profile is planned as a fresh character: no skill, no known recipes
    st.profile = true
    return st
  end
  local rec = recOf(prof)
  if mine(rec) then
    st.skill, st.max, st.seen = rec.skill, rec.max, true
    st.known, st.nKnown = {}, 0
    st.skill, st.max = tonumber(st.skill), tonumber(st.max)   -- a saved file edited by hand may hold anything
    for id, line in pairs(type(rec.list) == "table" and rec.list or {}) do
      -- the fifth field of the collector's line says whether the recipe is learned
      local k = type(line) == "string" and line:match("^[^|]*|[^|]*|[^|]*|[^|]*|([^|]*)") == "1"
      st.known[id] = k
      if k then st.nKnown = st.nKnown + 1 end
    end
  end
  local T = C_TradeSkillUI
  if type(T) == "table" then
    local info = try(T.GetProfessionInfoBySkillLineID, data().line[prof])
    if type(info) == "table" and (info.skillLevel or 0) > 0 then
      st.skill, st.max = info.skillLevel, (info.maxSkillLevel or 0) > 0 and info.maxSkillLevel or st.max
    end
    local open = try(T.GetBaseProfessionInfo)
    if type(open) == "table" and profNameOf(open) == prof and (open.skillLevel or 0) > 0
        and not try(T.IsTradeSkillLinked) and not try(T.IsTradeSkillGuild) then
      st.skill, st.max = open.skillLevel, open.maxSkillLevel or st.max
    end
  end
  return st
end

-- Professions the collector has seen on this character, in the data's order.
local function myProfs()
  local out = {}
  if who() then return out end   -- a profile has no professions of its own yet
  for _, p in ipairs(data().profs) do
    if mine(recOf(p)) then out[#out + 1] = p end
  end
  return out
end

-- The skill range to plan: what was typed in, else from your skill to your cap (to 300 once you are at the cap,
-- or for a profession you do not have). The third value says whether any of it was set by hand.
local function rangeOf(prof, st)
  local p = planOf(prof)
  local pf, pt = tonumber(p.from), tonumber(p.to)   -- a saved file edited by hand may hold text
  local skill = tonumber(st.skill)
  local from = max(1, min(299, pf or skill or 1))
  local smax = tonumber(st.max)
  local to = pt or ((smax and smax > from) and smax or 300)
  to = min(300, max(to, from))
  -- at the end of the range with no start typed (skill 300): an empty range, which the pages show as such, not 299 to 300
  if pf == nil and skill and skill >= to then from = to end
  return from, to, pf ~= nil or pt ~= nil
end

-- Unit prices seen at vendors (already with this character's discounts); the cheapest wins. Two tables: what a
-- vendor sells without limit (a material's price for any quantity), and everything including limited stock (a
-- recipe item is bought once, so a vendor with two of it will do).
-- A vendor read by a character of the other faction than the side planned for is left out: this side may not be
-- able to buy there, and his prices carried that character's reputation. A record that does not say who read it
-- counts for everyone, and so does every record while the side is not known.
local function readBySide(rec, side)
  if side ~= "A" and side ~= "H" then return true end
  local who = type(rec.player) == "string" and rec.player:match("^(%a+);") or nil
  who = (who == "Alliance" and "A") or (who == "Horde" and "H") or nil
  return who == nil or who == side
end
-- E.split for text out of the saved file: anything that is not text gives no fields.
local function fieldsOf(text, sep)
  if type(text) ~= "string" then return {} end
  return E.split(text, sep)
end
local function vendorPrices()
  local out, all = {}, {}
  local side = sideOf()
  for _, m in pairs(type(collected().merchants) == "table" and collected().merchants or {}) do
    for _, line in ipairs(type(m) == "table" and type(m.list) == "table" and readBySide(m, side) and m.list or {}) do
      local f = fieldsOf(line, "|")
      local id, price, stack = tonumber(f[1]), tonumber(f[2]), tonumber(f[3]) or 1
      if id and price and price > 0 and f[6] ~= "1" then
        local unit = price / max(1, stack)
        local stock = tonumber(f[4])
        if not all[id] or unit < all[id] then all[id] = unit end
        if not (stock and stock >= 0) and (not out[id] or unit < out[id]) then out[id] = unit end
      end
    end
  end
  return out, all
end

-- The spell id of each Legacy talent the addon counts, from the Forever client's own spell table (build
-- 1.60.1.70938). The id is the same in every language; the talent's name is not.
local LEGACY_SPELL = { ["Working Overtime"] = 1225451, ["Performance Bonus"] = 1225456, ["Master Chef"] = 1225457 }

-- The collector's saved line of a Legacy talent ("tree|node id|name|rank|max rank|spell id|description") as its
-- fields, or nil. A line carrying the talent's spell id is the talent whatever its name reads; a line carrying
-- another known talent's id is never taken for it; the English name finds it only when no id settles it (a
-- client whose talent ids differ from the table above).
local function legacyLine(name)
  local leg = collected().legacy
  local want, byName = LEGACY_SPELL[name], nil
  for _, line in ipairs(type(leg) == "table" and type(leg.list) == "table" and leg.list or {}) do
    local f = fieldsOf(line, "|")
    local spell = tonumber(f[6])
    if want and spell == want then return f end
    if not byName and f[3] == name then
      local other = false
      for _, id in pairs(LEGACY_SPELL) do if spell == id then other = true end end
      if not other then byName = f end
    end
  end
  return byName
end

-- A Legacy talent's rank as the collector read it, and whether the talent was found at all. Before the talents
-- were read (or on a client that gives neither the known spell id nor the English name) the rank is 0 and the
-- second value false; the Settings page then asks for the rank.
local function legacyRank(name)
  local f = legacyLine(name)
  if f then return tonumber(f[4]) or 0, true end
  return 0, false
end

-- What a Legacy talent gives, read from its own text as the collector saved it ("... by 10%."): 0.10, or nil when
-- the talent has no rank or its text has no percentage. The game's wording beats any per-rank guess.
local function legacyBonus(name)
  local f = legacyLine(name)
  if f then
    local pct = tonumber((f[7] or ""):match("(%d+)%s*%%"))   -- some languages write "10 %"
    if (tonumber(f[4]) or 0) > 0 and pct then return pct / 100 end
  end
  return nil
end

-- The share of your own finished auctions of an item that sold (Sales.lua), once at least MIN_SALES of them have
-- finished; nil before that, and the AH sales cap setting applies.
local MIN_SALES = 5
function NS.soldShare(item)
  if type(KeboldsShinySales) ~= "table" or not item or item <= 0 then return nil end
  local ok, share, units, auctions = pcall(KeboldsShinySales.rate, item)
  if ok and share and (auctions or 0) >= MIN_SALES then return share, units, auctions end
  return nil
end

-- Engine options that have no default (nil = off) and the type each must have.
local OPT_TYPE = { maxPoint = "number", skillBonus = "number" }

-- The engine set up for one profession with everything the game knows right now.
local function context(prof, st)
  local S = settings()
  local items, d = realmItems(), data()
  local vend, vendAll = vendorPrices()
  local others = {}   -- known recipes of your other professions, for parts they make
  for _, p in ipairs(myProfs()) do
    if p ~= prof then others[p] = profState(p).known end
  end
  local exclude = {}
  for id in pairs(S.exclude) do exclude[id] = true end
  -- What learning a recipe of this profession costs, once:
  --   { cost = copper, 0 or nil (it cannot be got), how = "known" | "free" | "trainer" | "vendor" | "AH" | "unknown" | "none",
  --     vendor = a vendor's price, ah = the cheapest listing at the last scan, scanned = the recipe item was looked up,
  --     unknown = true when it can be got but nobody knows the price (counted as 0 and flagged) }
  -- A trainer recipe costs its fee. A recipe item costs the cheaper of a vendor and the auction house: the vendor
  -- price is the one seen at a vendor in game when there is one, else the original game's price of a vendor this
  -- character's faction can use (Places.lua; no discount applied, and limited stock is not known). With no vendor
  -- and none listed it cannot be got and stays out of routes at every Recipes level. A vendor's item whose price
  -- nobody recorded counts as 0 and is flagged.
  local side = sideOf()
  -- A plan for somebody else (a profile): nothing read at vendors in game is used where the shipped list has a
  -- price, because those prices carry the owner's own discounts. The shipped ones are the original game's, taken
  -- less 5% for each of the profile's Bartering ranks (no reputation discount: a fresh character has none).
  local P = who()
  local barter = P and (1 - 0.05 * P.bartering) or 1
  local shippedPat = {}   -- [recipe] = { [vendor name] = the shipped price of its recipe item }
  local function shippedPrice(r, name)
    local t = shippedPat[r]
    if not t then
      t = {}
      shippedPat[r] = t
      local PL = type(KeboldsShinyPlaces) == "table" and KeboldsShinyPlaces or nil
      local text = PL and type(PL.get) == "table" and PL.get[r.id] or nil
      for entry in (type(text) == "string" and text or ""):gmatch("[^;]+") do
        local f = E.split(entry, "~")
        if f[1] == "v" and f[2] and tonumber(f[5]) then t[f[2]] = tonumber(f[5]) end
      end
    end
    return t[name]
  end
  local linfo = {}
  local function learnInfo(r)
    local x = linfo[r]
    if x then return x end
    x = {}
    linfo[r] = x
    if r.prof ~= prof or (st.known and st.known[r.id]) then
      x.cost, x.how = 0, "known"
    elseif r.start or r.src == "A" then
      x.cost, x.how = 0, "free"
    elseif r.src ~= "R" then
      x.cost, x.how = r.fee or 0, "trainer"
    else
      local vp = (not P) and r.pat > 0 and vendAll[r.pat] or nil
      if NS.vendorPrice and not P then   -- a vendor read in game first (his own price), else the shipped one
        local p = try(NS.vendorPrice, r)
        if p and p > 0 and (not vp or p < vp) then vp = p end
      end
      local sold, listed = vp ~= nil, 0
      if (P or not vp) and NS.sourcesOf then
        for _, s in ipairs(NS.sourcesOf(r)) do
          listed = listed + 1
          if s.kind == "v" and not s.gone and (s.side == nil or s.side == "" or s.side == "B" or side == nil or s.side == side) then
            sold = true
            local p = s.price
            if P then   -- the shipped price less Bartering; a vendor only known from a visit keeps the price he showed
              local base = s.seen and shippedPrice(r, s.name) or ((not s.seen) and p) or nil
              if base then p = base * barter end
            end
            if p and p > 0 and (not vp or p < vp) then vp = p end
          end
        end
      end
      -- the data says a vendor sells it and nothing says which: taken as sold, at a price nobody knows
      if not sold and listed == 0 and r.kind:find("vendor", 1, true) then sold = true end
      local L = r.pat > 0 and E.parseLadder(items[r.pat]) or nil
      local ah = L and #L.tiers > 0 and L.tiers[1][1] or nil
      x.vendor, x.ah, x.scanned = vp, ah, L ~= nil
      if vp and (not ah or vp <= ah) then
        x.cost, x.how = vp, "vendor"
      elseif ah then
        x.cost, x.how = ah, "AH"
      elseif sold then
        -- A vendor your faction can use sells it, so it can be had for certain (owner, 2026-11-10: "Im ok with it
        -- recommending ones you can buy from a vendor guaranteed"); the price nobody recorded counts as 0, flagged.
        x.cost, x.how, x.unknown = 0, "vendor", true
      else
        -- a drop, a quest reward or a source nobody knows: only when one is on the auction house (owner, same day:
        -- "if its a random drop it wouldnt unless its on the ah"), whatever the Recipes switch says
        x.how = "none"
      end
    end
    return x
  end
  if P then   -- a recipe only the faction the profile is NOT on can learn
    for _, r in ipairs(d.byProf[prof] or {}) do
      if NS.lockedFor(r, P.faction) then exclude[r.id] = true end
    end
  elseif NS.factionLocked then   -- a recipe only the other faction can learn
    for _, r in ipairs(d.byProf[prof] or {}) do
      if not (st.known and st.known[r.id]) and NS.factionLocked(r) then exclude[r.id] = true end
    end
  end
  local ctx
  ctx = E.new(d, {
    ladder = function(id) return E.parseLadder(items[id]) end,
    vendor = function(id)
      if P then   -- the shipped (original game's) price less the profile's Bartering, when there is one
        local it = d.items[id]
        if it and it.vp then return it.vp * barter end
      end
      return vend[id]
    end,
    known = function(r) return r.prof == prof and st.known ~= nil and st.known[r.id] == true end,
    learnAt = function(r)
      if r.prof == prof and st.known and st.known[r.id] and st.skill then return min(r.learn, st.skill) end
      return nil
    end,
    canMake = function(r)
      if r.prof == prof then return ctx.allowed(r) end
      return others[r.prof] ~= nil and others[r.prof][r.id] == true
    end,
    pick = function(item) return S.pick[item] end,
    learnCost = function(r) return learnInfo(r).cost end,
    sellPick = function(r) return S.sellPick[r.made] end,
    -- what disenchanting one product gives and the seconds it takes (LedgerDisenchant.lua); the engine asks only for
    -- a product set to Disenchant, or for gear with "Count gear at disenchant value" on
    deValue = function(r)
      if NS.deFor then return NS.deFor(ctx, r) end
      return nil
    end,
    sellRate = function(r) return NS.soldShare(r.made) end,
    -- "best": a product sells where it pays more, except gear, which counts at vendor value (owner, 2026-11-10: gear
    -- does not sell reliably) unless that one product is set to AH by hand. "vendor": vendor only.
    opts = { items = S.recipes >= 2, guess = S.recipes == 3, sell = S.sales ~= "off", ahSales = S.sales == "best", gearAH = false,
      mode = S.fast and "time" or "cost", exclude = exclude,
      overtime = legacyRank("Working Overtime"), chef = legacyRank("Master Chef"),
      -- Master Chef goes by its rank alone: its text reads "30%" at every rank. A Working Overtime rank typed in on
      -- the Settings page (a plan for someone else) counts 2 points a rank, so the text of your own talent is left out.
      skillBonus = type(S.opts.overtime) ~= "number" and legacyBonus("Working Overtime") or nil },
  })
  -- the engine reads its options when it calculates, not when it is made. A saved value is used only when it is of
  -- the type the engine expects (a saved file edited by hand may hold anything); the recipes left out are not a
  -- saved option
  for k, v in pairs(S.opts) do
    local want = E.defaults[k] ~= nil and type(E.defaults[k]) or OPT_TYPE[k]
    if want ~= nil and type(v) == want and v == v and k ~= "exclude" then ctx.opts[k] = v end
  end
  if P then   -- the profile's own Legacy ranks: Working Overtime 2 points a rank, never the owner's talent text
    ctx.opts.overtime, ctx.opts.chef, ctx.opts.skillBonus = P.overtime, P.chef, nil
  end
  ctx.learnInfo = learnInfo
  return ctx
end
NS.context = context   -- a fresh engine context for a profession and its state (LedgerShop.lua)

-- What a profession scan covers: only what the plan could use. Recipes that still give points from the start of
-- the range, learnable by its end, and either known, trainer-taught, or allowed by the Recipes switch.
local function scanScope(prof, st, outputs)
  local S = settings()
  local from, to = rangeOf(prof, st)
  -- recipe items of recipes not known yet, vendor-sold ones too: the auction house can undercut the vendor
  local patterns = false
  if S.recipes >= 2 then
    patterns = function(r) return not (st.known and st.known[r.id]) end
  end
  return { skill = from, to = to, outputs = outputs, patterns = patterns,
    use = function(r)
      if st.known and st.known[r.id] then return true end
      if r.guess and S.recipes < 3 then return false end
      return r.src ~= "R" or S.recipes >= 2
    end }
end

-- Where an unlearned recipe comes from, and what learning it costs: a trainer's fee, or for a recipe item the
-- cheaper of a vendor and the cheapest listing (ctx.learnInfo, see context()). nil = nothing, or not known.
local function learnText(ctx, r)
  if r.start then return "comes with the profession", nil end
  if r.src == "R" then
    local t = (r.pat > 0 and itemName(r.pat) or "a recipe item") .. (r.kind ~= "" and (" (" .. r.kind .. ")") or "")
    local li = ctx.learnInfo and ctx.learnInfo(r) or nil
    if not li then
      local L = r.pat > 0 and ctx.ladder(r.pat) or nil
      local price = L and #L.tiers > 0 and L.tiers[1][1] or nil
      if L and not price then t = t .. ", none on the AH" end
      return t .. ", needs skill " .. r.learn, price
    end
    if li.vendor then t = t .. ", vendor " .. money(li.vendor) elseif li.how == "vendor" then t = t .. ", vendor price not known" end
    if li.ah then t = t .. ", AH " .. money(li.ah) elseif li.scanned then t = t .. ", none on the AH" else t = t .. ", AH not scanned" end
    return t .. ", needs skill " .. r.learn, (li.cost and li.cost > 0) and li.cost or nil
  end
  return "trainer" .. (r.guess and "? (not confirmed)" or "") .. " at skill " .. r.learn .. (r.est and "~" or ""), r.fee > 0 and r.fee or nil
end


-- Everything a plan depends on, as one string: when it changes, the context and the route are made again.
function NS.sigOf(prof, st, from, to)
  local S = settings()
  local nVend = 0   -- the vendors seen and when: a second visit (new stock, new price) changes it too
  for _, m in pairs(type(collected().merchants) == "table" and collected().merchants or {}) do
    nVend = nVend + 1 + (type(m) == "table" and tonumber(m.time) or 0)
  end
  local P, name = who()   -- whose plan it is, and what of the profile the sums use
  -- the side too: vendor prices are only those read by a character of that side
  local whose = P and table.concat({ "for", name, P.faction, P.overtime, P.chef, P.bartering }, ":") or ("me:" .. (sideOf() or "?"))
  if not P then   -- your own Legacy talents as the engine gets them, and when they were last read
    local leg = collected().legacy
    whose = table.concat({ whose, legacyRank("Working Overtime"), legacyRank("Master Chef"), tostring(legacyBonus("Working Overtime") or ""),
      tostring(type(leg) == "table" and tonumber(leg.time) or "") }, ":")
  end
  return table.concat({ prof, from, to, st.skill or 0, st.max or 0, st.nKnown or -1, S.recipes, S.sales,
    S.fast and 1 or 0, priceVersion, nVend, whose }, "|")
end

-- Whether a recipe can only be learned by the faction that `faction` ("A" / "H") is not: every trainer, or every
-- vendor and quest, belongs to the other side. The same rule as NS.factionLocked (LedgerExtras.lua), for a side
-- that need not be the character's own.
function NS.lockedFor(r, faction)
  if faction ~= "A" and faction ~= "H" then return false end
  local function open(s) return s == nil or s == "" or s == "B" or s == faction end
  if r.src == "R" then
    if not NS.sourcesOf then return false end
    local list = NS.sourcesOf(r)
    if #list == 0 then return false end
    for _, s in ipairs(list) do
      if (s.kind ~= "v" and s.kind ~= "q") or open(s.side) or s.sideGuess then return false end
    end
    return true
  end
  if not NS.trainersOf then return false end
  -- the trainer lists are split by the character's own side there: asked with that side, whatever the profile
  sideReal = true
  local ok, mineList, other, anyTrainer = pcall(NS.trainersOf, r)
  local own = sideOf()
  sideReal = false
  if not ok or anyTrainer then return false end
  local usable, foreign = 0, 0
  for _, n in ipairs(mineList or {}) do
    if open(n.side) then usable = usable + 1 else foreign = foreign + 1 end
  end
  other = tonumber(other) or 0
  if own ~= nil and own ~= faction then usable = usable + other else foreign = foreign + other end
  return usable == 0 and foreign > 0
end

-- ---- profiles: the calls the pages use -------------------------------------------------------------------------------
NS.who = who            -- the active profile's table and name, or nil for "Me"
NS.side = sideOf        -- "A" | "H" | nil: the side plans are made for (the profile's, else the character's)
function NS.picks() return settings().pick end           -- [item id] = "buy" | "craft" | "have", of the active set
function NS.sellPicks() return settings().sellPick end   -- [made item id] = "vendor" | "ah" | "de"
function NS.excludes() return settings().exclude end     -- [recipe id] = true
function NS.planOf(prof)                                 -- { from, to } typed in for a profession
  local S = settings()
  if type(S.plan[prof]) ~= "table" then S.plan[prof] = {} end
  return S.plan[prof]
end
local FACTION = { A = "Alliance", H = "Horde" }
NS.FACTION = FACTION
-- "Planning for Anna (Alliance, new character)", or nil for "Me".
function NS.whoText()
  local P, name = who()
  if not P then return nil end
  return "Planning for " .. name .. " (" .. FACTION[P.faction] .. ", new character)"
end
-- The profiles' names, sorted.
function NS.profiles()
  local out = {}
  for name, p in pairs(settings().profiles) do
    if type(name) == "string" and type(p) == "table" then out[#out + 1] = name end
  end
  table.sort(out, function(a, b) return a:lower() < b:lower() end)
  return out
end

-- The profession on screen (or the one asked for) with your state in it, the range and an engine context that is
-- kept until something it depends on changes. Used by the Craft page, the details pane, the strip and the tooltips.
local stateCache = {}
function NS.state(prof)
  local S = settings()
  prof = prof or S.prof
  if not prof or not data().byProf[prof] then prof = myProfs()[1] or data().profs[1] end
  local c = stateCache[prof]
  local now = try(GetTime) or 0
  if c and c.at == now and c.version == priceVersion then return c end   -- several calls in one frame: one look-up
  local st = profState(prof)
  local from, to = rangeOf(prof, st)
  local sig = NS.sigOf(prof, st, from, to)
  if not (c and c.sig == sig) then c = { sig = sig, prof = prof, ctx = context(prof, st) } end
  c.st, c.from, c.to, c.at, c.version = st, from, to, now, priceVersion
  stateCache[prof] = c
  return c
end

-- The range of a profession changed by hand: its state is read again, also within this frame.
function NS.forgetState(prof)
  if stateCache[prof] then stateCache[prof].at = nil end
end

-- Runs fn(...) as "Me" while a "Plan for" profile is shown: the character's own skill, known recipes, bags, side,
-- Legacy ranks, vendor prices and choices, whatever the window is planning. The block in the profession window,
-- the strip above it and the item tooltips use it: there he crafts as himself. The profile shown is not
-- disturbed: its choices are pointed back before this returns, and "Me" has a state cache of its own, so neither
-- side's engine contexts are thrown away.
local meCache = {}
function NS.asMe(fn, ...)
  local s = settings()
  local name = s.profile
  if name == nil then return fn(...) end
  s.profile = nil
  bindChoices(s)
  local theirs = stateCache
  stateCache = meCache
  local out = { pcall(fn, ...) }
  stateCache = theirs
  s.profile = name
  bindChoices(s)
  if not out[1] then error(out[2], 0) end
  return unpack(out, 2, table.maxn(out))
end

-- Whose plan is shown: nil (or "Me") for the character itself, else a profile's name. The four tables of choices
-- are pointed at that set by settings(), and everything planned is planned again.
local function replan()
  for k in pairs(stateCache) do stateCache[k] = nil end
  priceVersion = priceVersion + 1
end
function NS.setProfile(name)
  local S = settings()   -- keeps the set shown up to now
  if name == "Me" or type(S.profiles[name or false]) ~= "table" then name = nil end
  S.profile = name
  settings()             -- points the choices at the new set
  replan()
  if NS.resetScroll then NS.resetScroll() end
  if NS.refresh then NS.refresh() end
  return name
end
-- A new profile (the name is made unique: "Anna", "Anna 2"), not yet shown. Returns its name.
function NS.newProfile(name, fields)
  local S = settings()
  name = profileText(name, 24)
  if name == "" or name == "Me" then name = "Player" end
  local base, n = name, 1
  while S.profiles[name] ~= nil do
    n = n + 1
    name = base .. " " .. n
  end
  local p = {}
  for k, v in pairs(type(fields) == "table" and fields or {}) do p[k] = v end
  if p.faction ~= "A" and p.faction ~= "H" then p.faction = sideOf() or "A" end   -- to start with: your own side
  S.profiles[name] = cleanProfile(p)
  return name
end
-- Changes one field of a profile: faction "A" | "H", overtime, chef, bartering (ranks), note.
function NS.editProfile(name, key, value)
  local p = settings().profiles[name or false]
  if type(p) ~= "table" then return end
  if key == "faction" or key == "overtime" or key == "chef" or key == "bartering" or key == "note" then
    if key == "note" then value = profileText(value, 200) end
    p[key] = value
    cleanProfile(p)
    replan()
    if NS.refresh then NS.refresh() end
  end
end
-- Renames a profile. Returns the name it has afterwards (unchanged when the new one is empty or taken).
function NS.renameProfile(name, to)
  local S = settings()
  to = profileText(to, 24)
  local p = S.profiles[name or false]
  if type(p) ~= "table" or to == "" or to == "Me" or to == name or S.profiles[to] ~= nil then return name end
  S.profiles[to], S.profiles[name] = p, nil
  if S.profile == name then
    S.profile = to
    boundName = to   -- the same set under a new name: the pointers stay
  end
  replan()
  if NS.refresh then NS.refresh() end
  return to
end
-- Deletes a profile with its choices; when it was the one shown, the plan is the character's own again.
function NS.deleteProfile(name)
  local S = settings()
  if type(S.profiles[name or false]) ~= "table" then return end
  S.profiles[name] = nil
  settings()   -- back to "Me" when it was the one shown
  replan()
  if NS.resetScroll then NS.resetScroll() end
  if NS.refresh then NS.refresh() end
end

-- The engine context a route is planned with: the one NS.state keeps for this plan (made when it is missing), so
-- the route, the Craft page, the details pane and the profession window's block share planBest's choices.
function NS.contextFor(prof, st, from, to, sig)
  local c = stateCache[prof]
  if not (c and c.sig == sig) then
    c = { sig = sig, prof = prof, ctx = context(prof, st) }
    stateCache[prof] = c
  end
  c.st, c.from, c.to, c.at = st, from, to, nil
  return c.ctx
end

-- Leaves out the lines of folded sections. A section runs from a line with `section` to the next such line; the
-- head stays (its click folds and unfolds), and so does the gap before the next head.
function NS.fold(list, tab)
  local S = settings()
  local out, hide = {}, false
  for i, row in ipairs(list) do
    if row.section then
      local key = tab .. ":" .. row.section
      hide = S.fold[key] == true
      row.folded = hide
      if not row.action then
        row.action = function()
          S.fold[key] = (not S.fold[key]) or nil
          NS.refresh()
        end
      end
      out[#out + 1] = row
    elseif not hide then
      out[#out + 1] = row
    elseif (row.left == nil or row.left == "") and not row.cols and list[i + 1] and list[i + 1].section then
      out[#out + 1] = row
    end
  end
  return out
end


-- ---- pages ---------------------------------------------------------------------------------------------------------
-- The window is a rail of pages on the left and one page's frame beside it. A page is registered once, when its
-- file loads, and owns its frame and everything in it:
--
--   NS.page({
--     key = "route",            -- what is saved as the page shown (KeboldsShinyDB.ledger.tab) and typed after
--                               -- /kebold tab; the six keys are route, recipes, shop, scan, sales, settings
--     title = "Level",          -- the name on the rail and in the head of the window
--     icon = "Interface\\Icons\\...", order = 1, tip = { "Level", "..." },
--     plan = true,              -- the plan bar (page.planBar), two rows: Profession, From, to, My skill and Plan
--                               -- for at the right end; then Recipes and Sells at
--     bars = 1,                 -- rows of the page's own controls (page.bar, 26 pixels each; page.at places them:
--                               -- at.put from the left, at.right for Find at the row's right end). A row that
--                               -- does not fit the page wraps and the bar grows, unless the page states barH.
--                               -- A page with plan = true and no bars puts its filters on the plan bar's second
--                               -- row (page.at is then the plan bar's: Craft)
--     detail = true,            -- the list shares the page with the details pane (page.split), which can be folded
--                               -- with the Details button the shell puts at the right end of the last row of
--                               -- controls (page.bDetails; on a page with a plan: the plan bar's second row)
--     footLead / footTip        -- with footer = "plan": a count that leads the footer's line; what the page says
--                               -- about its list (lines, or a function), as the tooltip of that line and of ?
--     barKey = function(page)   -- what the rows of controls depend on besides the size (a view): placed again
--                               -- when it changes
--     (footer buttons: NS.footButton(page, {...}) in build; a row with aside = true stays out of the table)
--     columns = { ... },        -- UI.table columns: the shell makes page.table and gives it the page's rows
--     empty = { ... },          -- UI.table's empty state (or a function returning one)
--     rows = function(page) return rows, title end,   -- the model: row tables, nothing else. /kebold print and
--                               -- the tests read these (KeboldsShiny_Build), so everything a page says is here
--     view = function(page, rows) return rows end,    -- optional: which of the rows the table shows
--     build = function(page) end,                     -- once, the first time the page is shown: make the controls
--     layout = function(page, w, h, y) end,           -- after the shell placed bars, split and table: w and h are
--                               -- the page's size, y the height the bars took (a page without columns fills
--                               -- the rest itself)
--     paint = function(page, rows, title) end,        -- on every refresh, after the table has its rows
--     onSort = function(page, key, index) end, selected = function(row) return bool end,
--     onShow = function(page) end, onHide = function(page) end,
--   })
--
-- What the shell adds to the table it was given: .frame (the page, a child of the window's body), .planBar,
-- .bar, .at (NS.placer on the bar: at.put(widget, gap), at.right(widget, gap), at.label(text), at.row(n)),
-- .bDetails, .split, .table, .w, .h. Registering a key again replaces the page (the Shopping placeholder is
-- replaced that way). The shell puts Cheapest | Fastest on no page (NS.modeButtons still makes the two buttons).
local pages = {}
local PAGE_ALIAS = { level = "route", route = "route", craft = "recipes", recipes = "recipes", shopping = "shop", shop = "shop",
  prices = "scan", scan = "scan", sales = "sales", mysales = "sales", settings = "settings" }
NS.PAGE_ALIAS = PAGE_ALIAS

-- The rail has two groups with a thin rule between them: the work pages (Level, Craft, Disenchant, Merchant's
-- Favor, Shopping) and the utility pages (Prices, My sales, Settings). A page may say its own (`group = 2`).
local UTILITY = { scan = true, sales = true, settings = true }
local function navGroup(p)
  return tonumber(p.group) or (UTILITY[p.key] and 2 or 1)
end
-- What a page says about its own list, for the tooltip of the footer's line and of the ? button: page.footTip, a
-- list of lines (the first is the title) or a function returning one.
function NS.footTip(page)
  local t = page and page.footTip or nil
  if type(t) == "function" then
    local ok, v = pcall(t, page)
    t = ok and v or nil
  end
  return type(t) == "table" and t or nil
end

local function sortPages()
  for i = #TAB_ORDER, 1, -1 do TAB_ORDER[i] = nil end
  for key in pairs(TAB_LABEL) do TAB_ORDER[#TAB_ORDER + 1] = key end
  table.sort(TAB_ORDER, function(a, b)
    local oa, ob = pages[a] and pages[a].order or PAGE_RANK[a] or 99, pages[b] and pages[b].order or PAGE_RANK[b] or 99
    if oa ~= ob then return oa < ob end
    return a < b
  end)
end

function NS.page(def)
  local old = pages[def.key]
  if old and old ~= def and type(old.frame) == "table" then   -- replaced after it was built: the old frame goes
    old.frame:Hide()
    old.active = false
  end
  pages[def.key] = def
  TAB_LABEL[def.key] = def.title or def.key
  PAGE_ALIAS[def.key] = def.key
  sortPages()
  if frame and type(frame.nav) == "table" then
    if frame.nav.buttons[def.key] then frame.nav:SetLabel(def.key, def.title) else frame.nav:Add(def.key, def.title, def.icon, def.tip, navGroup(def)) end
  end
  return def
end
function NS.pageOf(key) return pages[PAGE_ALIAS[key] or key] end

local function currentPage()
  local S = settings()
  return pages[S.tab] or pages.route or pages[TAB_ORDER[1]]
end
function NS.currentPage() return currentPage() end

-- The lines of whichever page is showing.
local function buildTab()
  local page = currentPage()
  if page and page.rows then return page.rows(page) end
  return {}, page and page.title or "Kebold's Shiny"
end

local function build()
  local list, title = buildTab()
  return NS.fold(list or {}, settings().tab), title
end

-- What the plan bar describes: the route on the Level page, the cached state elsewhere.
local function shown()
  if settings().tab == "route" then return current end
  return NS.state()
end

local function plain(s)
  return UI.plainText(s)
end

local function itemLink(id)
  local _, link = try(C_Item and C_Item.GetItemInfo, id)
  return link
end

local function rowEnter(b)
  local row = rawget(b, "row")
  if not row or type(GameTooltip) ~= "table" then return end
  local text = plain(row.left or (row.cols and row.cols[1]) or "")
  if not row.item and not row.tip and text == "" then return end
  GameTooltip:SetOwner(b, UI.tipAnchor(b))
  local shown = false
  if row.item then
    shown = pcall(GameTooltip.SetItemByID, GameTooltip, row.item)
    if not shown then shown = pcall(GameTooltip.SetHyperlink, GameTooltip, "item:" .. row.item) end
  end
  if not shown then GameTooltip:SetText(text) end
  for _, line in ipairs(row.tip or {}) do GameTooltip:AddLine(UI.show(line), 1, 1, 1, true) end
  -- a cell the table had to cut short: its whole text
  local tbl = rawget(b, "table")
  if type(tbl) == "table" and type(tbl.CutTexts) == "function" then
    for _, cut in ipairs(tbl:CutTexts(b)) do
      if plain(cut) ~= text then GameTooltip:AddLine(cut, 0.8, 0.8, 0.8, true) end
    end
  end
  GameTooltip:Show()
end

local function rowLeave()
  if type(GameTooltip) == "table" then GameTooltip:Hide() end
end

local refresh   -- defined below

local function shiftDown()
  return type(IsShiftKeyDown) == "function" and IsShiftKeyDown() and true or false
end

-- The auction house window when it is open and has a search box, else nil.
local function ahSearch()
  local ah = AuctionHouseFrame
  if type(ah) == "table" and type(ah.IsShown) == "function" and ah:IsShown() and type(ah.SearchBar) == "table" and type(ah.SearchBar.SearchBox) == "table" then
    return ah
  end
  return nil
end

function NS.searchAH(item)
  local ah = ahSearch()
  if not ah then
    NS.notice("Open the auction house to search for " .. itemName(item) .. ".")
    return false
  end
  local name = itemName(item)
  -- on the Buy page, with our own page out of the way: a search anywhere else cannot be seen
  if NS.ahHide then pcall(NS.ahHide) end
  local mode = AuctionHouseFrameDisplayMode
  if type(mode) == "table" and mode.Buy ~= nil and type(ah.SetDisplayMode) == "function" then pcall(ah.SetDisplayMode, ah, mode.Buy) end
  pcall(function()
    ah.SearchBar.SearchBox:SetText(name)
    ah.SearchBar:StartSearch()
  end)
  return true
end

function NS.linkRow(row)
  local link = row.recipe and C_TradeSkillUI and try(C_TradeSkillUI.GetRecipeLink, row.recipe) or nil
  link = link or (row.item and itemLink(row.item))
  if link and ChatEdit_InsertLink then pcall(ChatEdit_InsertLink, link) end
end

-- ---- choices: setters and the menu of a line ---------------------------------------------------------------------

-- How one material or part is got: nil / "auto" (the cheaper way), "buy", "craft", "have".
function NS.setPick(item, v)
  if not item then return end
  settings().pick[item] = (v ~= nil and v ~= "auto") and v or nil
  priceVersion = priceVersion + 1
  refresh()
end

-- Where one product is counted as sold: nil / "auto" (follow Sell crafts), "vendor", "ah", "de" (disenchanted).
function NS.setSell(item, v)
  if not item then return end
  settings().sellPick[item] = (v ~= nil and v ~= "auto") and v or nil
  priceVersion = priceVersion + 1
  refresh()
end

local function atAH()
  return type(KeboldsShinyScan_AtAuctionHouse) == "function" and KeboldsShinyScan_AtAuctionHouse() and true or false
end

-- A favourite recipe: shown by "Show: favourites" and scanned by /keboldscan fav. Nothing is planned differently.
function NS.setFav(recipeID, on)
  if not recipeID then return end
  settings().fav[recipeID] = on and true or nil
  if NS.shopInvalidate then NS.shopInvalidate() end   -- the shopping list's favourites entry follows
  refresh()
end

-- Every item one recipe needs a price for: what it makes, what it uses, what its crafted parts use (all the
-- way down), and the recipe item it is learned from. `into` and `seen` let several recipes share one list.
function NS.recipeItems(r, into, seen)
  local ids, has = into or {}, seen or {}
  local function add(id)
    if type(id) == "number" and id > 0 and not has[id] then
      has[id] = true
      ids[#ids + 1] = id
      return true
    end
    return false
  end
  local function walk(x, depth)
    for _, reg in ipairs(x.regs) do
      if add(reg[1]) and depth < 8 then
        local m = data().maker[reg[1]]
        if m and m ~= x then walk(m, depth + 1) end
      end
    end
  end
  add(r.made)
  walk(r, 0)
  add(r.pat)
  return ids
end

-- Scans one recipe's items / one item at the open auction house, so a single recipe is fresh in seconds.
function NS.scanRecipe(recipeID)
  if not recipeID then return end
  if not atAH() then
    NS.notice("Open the auction house first.")
    return
  end
  SlashCmdList["KEBOLDSSHINYSCAN"]("recipe " .. recipeID)
end
function NS.scanItem(itemID)
  if not itemID then return end
  if not atAH() then
    NS.notice("Open the auction house first.")
    return
  end
  SlashCmdList["KEBOLDSSHINYSCAN"](tostring(itemID))
end

-- Whether routes leave a recipe out.
function NS.setSkip(recipeID, skip)
  if not recipeID then return end
  settings().exclude[recipeID] = skip and true or nil
  priceVersion = priceVersion + 1
  refresh()
end

function NS.showRecipe(recipeID)
  if C_TradeSkillUI and C_TradeSkillUI.OpenRecipe and type(ProfessionsFrame) == "table" and ProfessionsFrame:IsShown() then
    pcall(C_TradeSkillUI.OpenRecipe, recipeID)
    return true
  end
  local r = data().byId[recipeID]
  NS.notice("Open your " .. (r and r.prof or "profession") .. " window first.")
  return false
end

-- The menu of a line, built from what the line carries. Nothing here touches the screen, so it can be read and
-- its entries run without a window.
function NS.rowMenu(row)
  local S = settings()
  local items = {}
  local function add(it)
    items[#items + 1] = it
    return it
  end
  local function gap()
    if #items > 0 then add({ divider = true }) end
  end
  if type(row.shopMenu) == "table" then   -- a shopping line's own choices come first
    for _, it in ipairs(row.shopMenu) do add(it) end
  end
  local c = shown() or NS.state()
  local ctx = c and c.ctx or nil
  local pickItem = row.pickItem or row.haveItem
  if pickItem then
    gap()
    local part = ctx and ctx.part(pickItem) or nil
    local now = S.pick[pickItem] or "auto"
    add({ title = true, text = "Get it by" })
    local function radio(key, text, disabled, tip)
      add({ radio = true, checked = now == key, text = text, disabled = disabled or nil, tip = tip, func = function() NS.setPick(pickItem, key) end })
    end
    radio("auto", part and "Auto (cheaper)" or "Auto (buy it)", nil, part and "The cheaper of buying it and making it." or "Bought at the scanned or the vendor's price.")
    if part then
      radio("buy", "Buy", not part.buy, part.buy and "Always bought: the average of the cheapest listings." or "Not possible: none was listed at the last scan.")
      radio("craft", "Make", not part.craft, part.craft and "Always made from its materials." or "Not possible: no recipe for it that you know or that this plan may use.")
    end
    radio("have", "Have it", nil, "You have them already (farmed or banked): they cost nothing and are neither bought nor made, however many the route uses.")
  end
  local sellItem = row.sellItem or row.sellStep
  if sellItem then
    gap()
    local now = S.sellPick[sellItem] or "auto"
    add({ title = true, text = "Sells at" })
    local function radio(key, text, tip)
      add({ radio = true, checked = now == key, text = text, tip = tip, func = function() NS.setSell(sellItem, key) end })
    end
    radio("auto", "Auto (as the plan's Sells at)", "As the plan's Sells at says (" .. SALES[S.sales] .. "); gear on Auto goes to a vendor"
      .. (S.opts.deGear == true and ", or is disenchanted when that pays more (Settings: Count gear at disenchant value)." or "."))
    radio("vendor", "Vendor", "Counted at vendor value only, for things that do not sell reliably.")
    radio("ah", "Auction house", "Counted at the cheapest real listing less the cut, up to the AH sales cap share of what is listed. Needs it scanned.")
    -- only for something that can be disenchanted (green, blue or epic armour and weapons)
    if now == "de" or (NS.deOutcome and NS.deOutcome(sellItem) ~= nil) then
      radio("de", "Disenchant", "Counted at what its disenchant materials sell for at the auction house, and the disenchant cast is added to the craft's time. Needs the materials scanned (Scan disenchant materials). Kebold never disenchants anything itself.")
    end
  end
  if row.recipe then
    gap()
    local id = row.recipe
    add({ text = "Open details", func = function()
      if NS.openPanel then NS.openPanel(id) end
    end })
    local open = type(ProfessionsFrame) == "table" and ProfessionsFrame:IsShown() and true or false
    add({ text = "Show in profession window", disabled = (not open) or nil, tip = (not open) and "Open the profession's window first." or nil,
      func = function() NS.showRecipe(id) end })
    add({ check = true, checked = S.exclude[id] == true, text = "Skip this recipe in routes", tip = "A skipped recipe is never picked by the leveling route.",
      func = function() NS.setSkip(id, not S.exclude[id]) end })
    add({ check = true, checked = S.fav[id] == true, text = "Favourite", tip = "Favourites have their own Show filter on the Craft page and their own scan (Scan favourites, /keboldscan fav).",
      func = function() NS.setFav(id, not S.fav[id]) end })
    local atNow = atAH()
    add({ text = "Scan this recipe's items", disabled = (not atNow) or nil, tip = atNow and "Reads fresh prices for what it makes and everything needed to make it." or "Open the auction house first.",
      func = function() NS.scanRecipe(id) end })
  end
  if row.item then
    gap()
    local at = ahSearch() ~= nil
    add({ text = "Search the auction house", disabled = (not at) or nil, tip = (not at) and "Open the auction house first." or nil,
      func = function() NS.searchAH(row.item) end })
    add({ text = "Link in chat", func = function() NS.linkRow(row) end })
  end
  local r = row.recipe and data().byId[row.recipe] or nil
  if r and NS.pin then   -- where to learn it: the first trainer or vendor with a known place, else the first
    local target, word
    if r.src ~= "R" and NS.trainersOf then
      local list = NS.trainersOf(r)
      for _, n in ipairs(list) do
        if not target and n.x and n.y then target = n end
      end
      target, word = target or list[1], "trainer"
    elseif r.src == "R" and NS.sourcesOf then
      local first
      for _, src in ipairs(NS.sourcesOf(r)) do
        if src.kind == "v" then
          first = first or src
          if not target and src.x and src.y then target = src end
        end
      end
      target, word = target or first, "vendor"
    end
    if target then
      gap()
      add({ text = "Pin " .. word .. " on map", tip = target.name .. ((target.zone and target.zone ~= "") and (", " .. target.zone) or ""),
        func = function() NS.pin(target) end })
    end
  end
  return items
end

-- A left click on a line whose details the pane shows or could show (owner 2026-11-14): on the line that is open
-- already it closes the pane; while the pane is closed it selects the line and opens it; on another line it just
-- switches. Every page with a split asks here before it selects:
--   NS.detailClick(same [, button]) -> true: the pane was closed, there is nothing more to do
--                                      false: go on and select (the pane is unfolded; the caller refreshes)
--   same = the line clicked is the one whose details are showing now
-- A right click and a Shift-click never close anything. The Details button follows (it reads the same saved
-- switch, S.detailOff, on the refresh).
function NS.detailClick(same, button)
  local S = settings()
  if button == "RightButton" or shiftDown() then return false end
  local page = currentPage()
  local s = page and page.split
  local open = S.detailOff ~= true and type(s) == "table" and s.rightW > 0
  if same and open then
    S.detailOff = true
    refresh()
    return true
  end
  S.detailOff = nil
  return false
end
-- Is the shared details pane (a recipe's or an item's) what the page's split shows now?
local function sharedPaneShows(page)
  return page ~= nil and page.detail and not (page.detailMine and page.detailMine(page) == true)
end

-- A click on a line. Left: a line with its own action runs it; a line that exists to choose opens its menu; a
-- recipe opens its panel (a second click on the open one closes the pane); a material searches the auction house.
-- Shift links. Right: the line's menu.
local function rowClick(b, button)
  local row = rawget(b, "row")
  if not row then return end
  if row.action and not (button == "RightButton" and row.menu) then
    row.action(button)
    return
  end
  if shiftDown() then
    NS.linkRow(row)
    return
  end
  if button == "RightButton" or row.choice then
    local items = NS.rowMenu(row)
    if #items > 0 then UI.menu(b, items) end
    return
  end
  local page = currentPage()
  if row.itemPanel and NS.openItemPanel then   -- a line of My sales: the item's auctions and price history
    if NS.detailClick(sharedPaneShows(page) and NS.detailItem ~= nil and NS.detailItem() == row.itemPanel, button) then return end
    NS.openItemPanel(row.itemPanel)
    return
  end
  if row.recipe and NS.openPanel then   -- a recipe: its details in the pane beside the list
    if NS.detailClick(sharedPaneShows(page) and NS.detailRecipe ~= nil and NS.detailRecipe() == row.recipe, button) then return end
    NS.openPanel(row.recipe)
    return
  end
  if row.item and ahSearch() then
    NS.searchAH(row.item)
    return
  end
  if row.recipe then NS.showRecipe(row.recipe) end
end


-- ---- the window ----------------------------------------------------------------------------------------------
-- Looks come from the kit (LedgerUI.lua); this part is only the shell: Blizzard's framed window, a head band with
-- the page's name and the notice bar, the rail of pages down the left, the page's frame in the inset beside it,
-- and a footer with the price status, the scan button or the running scan, and the corner that resizes it.
-- Everything a page shows lives in the page's own frame (see NS.page above).
--
-- All sizes are worked out here from the window's size and handed down (page -> bars / split -> table), so
-- nothing depends on what the game has laid out yet.

local function atAuctionHouse()
  return type(KeboldsShinyScan_AtAuctionHouse) == "function" and KeboldsShinyScan_AtAuctionHouse() and true or false
end

-- A message for the player: in the window's notice bar while the window is open, in chat otherwise.
-- kind: "warn" (default) | "info" | "error". alsoChat: in chat as well, for the answer to a typed command.
function NS.notice(text, kind, alsoChat)
  local open = frame and frame:IsShown() and type(frame.notice) == "table"
  if open then frame.notice:Say(text, kind or "warn") end
  if alsoChat or not open then say(text) end
end

-- A scan button is greyed out away from the auction house, and its tooltip says why.
-- why (optional): a function giving another reason the button cannot be used now, or nil (the quick scan's wait).
local scanButtons = {}
function NS.scanControl(b, why)
  b.scanWhy = why or false   -- false, not nil: a frame answers unknown keys itself in the tests' stand-in
  scanButtons[#scanButtons + 1] = b
  return b
end

local function winSize()
  local s = settings().win
  local w, h = frame and tonumber((frame:GetWidth())) or nil, frame and tonumber((frame:GetHeight())) or nil
  return (w and w > 0) and w or s.w, (h and h > 0) and h or s.h
end

-- The size a page's frame has inside the window.
local function pageSize()
  local w, h = winSize()
  return w - WIN.side - 8 - 2 * WIN.pad, h - WIN.top - WIN.bottom - 2 * WIN.pad
end

-- Puts controls into a bar from left to right:
--   at.put(widget, gap, width) -> widget     at.label(text, width) -> FontString     at.row(n) starts row n
--   at.right(widget, gap, width) -> widget   at the right end of the row (Find, Details), in the order added
--   at.sub(when) -> at2, made                the same bar, for controls placed and shown only while when() is true
--                                            (the two views of Merchant's Favor); made lists what at2 placed
--   at.x is where the next one goes
-- Behind it is a UI.flow (at.flow): the shell lays it out again with the page's width (at.flow:Layout(w)), so a
-- row that does not fit wraps onto a further row, and a new Row size moves the controls to their new widths.
function NS.placer(bar, x0)
  local at = { x = x0 or 0, y = -2, n = 1 }
  local flow = UI.flow(bar, WIN.bar, x0 or 0)
  at.flow = flow
  local function make(a, when, made)
    function a.put(w, gap, width, right)
      flow:Add(w, { gap = gap or 4, w = width, row = at.n, when = when, right = right == true })
      if right ~= true then
        w:SetPoint("TOPLEFT", bar, "TOPLEFT", at.x, at.y)
        at.x = at.x + (width or UI.widthOf(w)) + (gap or 4)
      end
      if made then made[#made + 1] = w end
      return w
    end
    function a.right(w, gap, width) return a.put(w, gap, width, true) end
    function a.label(text, width)
      local fs = UI.text(bar, "body", text)
      fs.kitW = 0
      function fs.kitFit(self)   -- the font follows the Row size, the width its text
        local fonts = UI.ctlFonts()
        pcall(self.SetFontObject, self, fonts.text)
        self.kitW = max(UI.textWidth(text, fonts.text) + 2, width or 0)
      end
      fs:kitFit()
      UI.fitLater(fs)
      flow:Add(fs, { gap = 4, row = at.n, when = when, dy = 5 })
      fs:SetPoint("TOPLEFT", bar, "TOPLEFT", at.x, at.y - 5)
      at.x = at.x + fs.kitW + 4
      if made then made[#made + 1] = fs end
      return fs
    end
    function a.row(n)
      at.n = n
      at.x, at.y = x0 or 0, -2 - (n - 1) * WIN.bar
    end
    return a
  end
  make(at)
  function at.sub(when)
    local made = {}
    return make({ flow = flow }, when, made), made
  end
  return at
end

-- A range typed in: a number, or nil for "follow my character". A value equal to the automatic one clears it.
local function setRange(which, v)
  local prof = settings().prof or (current and current.prof)
  if not prof then return end
  local p, st = planOf(prof), profState(prof)
  if which == "from" then
    if v then v = max(1, min(299, floor(v))) end
    p.from = (v and v ~= (st.skill or 1)) and v or nil
  else
    if v then v = max(2, min(300, floor(v))) end
    p.to = nil
    local _, auto = rangeOf(prof, st)
    p.to = (v and v ~= auto) and v or nil
  end
  NS.forgetState(prof)   -- the range is read again, also within this frame
end

-- A small number box. Enter or clicking elsewhere applies it; empty means automatic.
local function makeEdit(parent, which)
  local e = UI.edit(parent, 38, true)
  e:SetMaxLetters(3)
  e:SetScript("OnEditFocusLost", function(self)
    local v = tonumber(self:GetText())
    local cur = shown()
    if cur and v == cur[which] then return end   -- unchanged
    setRange(which, v)
    NS.resetScroll()
    refresh()
  end)
  return e
end

local RECIPES_TIP = {
  "Only recipes a trainer teaches, plus every recipe you already know.",
  "Also recipes from a recipe item that a vendor sells (a price nobody recorded is marked ? and counts as nothing) or that was on the auction house at the last scan. What the item costs is counted. Drops and quest rewards are used only while one is listed.",
  "Also recipes whose source is a guess (marked as not confirmed). A recipe item that is neither sold by a vendor nor listed still stays out.",
}
local SALES_ORDER = { "best", "vendor", "off" }
local SALES_TIP = {
  best = "Each product counts where it pays more: the auction house (less the cut, up to the AH sales cap share of what is listed) or a vendor. Gear counts at vendor value unless you set one piece to Auction house.",
  vendor = "Every product counts at vendor value only (one set to Auction house or Disenchant by hand keeps that).",
  off = "What the products sell for is not counted: the route shows what you spend.",
}

-- The plan's controls, for the pages that plan (Level and Craft), in two rows: what am I looking at (Profession,
-- From, to, My skill; Plan for at the right end), then how the list is counted (Recipes, Sells at). Each page gets
-- its own bar. Fields: .dWho, .dProf, .eFrom, .eTo, .bMine, .dRecipes, .dSell (the four d... are UI.choice: .label
-- is the value's text, .getItems the menu), .at / .flow (its placer: a page may go on with row 2), .used (the
-- width its rows need), .h, :Layout(w) -> height, :Refresh()
function NS.planBar(parent)
  local bar = CreateFrame("Frame", nil, parent)
  bar:SetSize(680, 2 * WIN.bar)
  local at = NS.placer(bar)
  bar.at, bar.flow = at, at.flow
  -- Row 1, what am I looking at: the profession (first and widest), the range, and at the right end whose plan
  -- this is: the character's own ("Me") or a profile (a plan for somebody else).
  bar.dWho = at.right(UI.choice(bar, "Plan for", function()
    local list = { "Me" }
    for _, n in ipairs(NS.profiles()) do list[#list + 1] = n end
    return list
  end, function()
    local _, name = who()
    return name and (GOLD .. name .. "|r") or "Me"
  end, function()
    local P, name = who()
    local items = { { title = true, text = "Plan for" } }
    items[#items + 1] = { radio = true, checked = P == nil, text = "Me", tip = "Your own character: your skill, the recipes you know, your bags, your Legacy talents and your prices at vendors.",
      func = function() NS.setProfile(nil) end }
    for _, n in ipairs(NS.profiles()) do
      local p = settings().profiles[n]
      items[#items + 1] = { radio = true, checked = name == n, text = n .. "  (" .. FACTION[p.faction] .. ")",
        tip = "A new " .. FACTION[p.faction] .. " character: Working Overtime " .. p.overtime .. ", Master Chef " .. p.chef .. ", Bartering " .. p.bartering .. "."
          .. (p.note ~= "" and ("  " .. p.note) or ""),
        func = function() NS.setProfile(n) end }
    end
    items[#items + 1] = { divider = true }
    items[#items + 1] = { text = "New profile...", tip = "A plan for somebody else: their faction and Legacy ranks, no known recipes, their own choices. It opens on the Settings page.",
      func = function()
        NS.setProfile(NS.newProfile("Player"))
        NS.showPage("settings")
      end }
    if P then
      items[#items + 1] = { text = "Edit " .. name, tip = "Name, faction, Legacy ranks and a note, on the Settings page.", func = function() NS.showPage("settings") end }
      items[#items + 1] = { text = "Delete " .. name .. "...", tip = "Removes the profile with its ranges and choices. It asks first.", func = function()
        if NS.confirm then
          NS.confirm("Delete the profile " .. name .. " with its ranges and choices?", "Delete", function() NS.deleteProfile(name) end)
        else
          NS.deleteProfile(name)
        end
      end }
    end
    return items
  end, function()
    local P, name = who()
    if not P then
      return { "Plan for", "Me: your own character, as the game shows it.", "A profile is a plan for somebody else: New profile... in this menu." }
    end
    return { "Plan for " .. name, FACTION[P.faction] .. ", planned as a new character: no recipes known, skill from the range typed in (1 to 300 to start with), nothing from your bags.",
      "Legacy ranks: Working Overtime " .. P.overtime .. ", Master Chef " .. P.chef .. ", Bartering " .. P.bartering .. ".",
      "Vendor prices are the original game's price list less 5% a Bartering rank, not what vendors showed you (those carry your own discounts). Auction prices are this realm's.",
      "How well things sell still comes from your own auctions.",
      "Ranges, Buy / Make / Have it, where a product sells and skipped recipes are this profile's own." }
  end, 70, 170), 0)
  bar.dProf = at.put(UI.choice(bar, "", function() return data().profs end, function()
    local cur = shown()
    return cur and cur.prof or (settings().prof or "Profession")
  end, function()
    local cur = shown()
    local items = { { title = true, text = "Profession" } }
    for _, p in ipairs(data().profs) do
      local st = profState(p)
      items[#items + 1] = { radio = true, checked = cur ~= nil and cur.prof == p,
        text = p .. (st.skill and (" (yours " .. st.skill .. "/" .. (st.max or "?") .. ")") or ""),
        func = function()
          settings().prof = p
          NS.resetScroll()
          refresh()
        end }
    end
    return items
  end, { "Profession", "Any of the nine can be planned, whether this character has it or not. Yours show your skill and cap." }, 150), 10)
  at.label("From")
  bar.eFrom = at.put(makeEdit(bar, "from"), 6)
  at.label("to")
  bar.eTo = at.put(makeEdit(bar, "to"), 8)
  bar.bMine = at.put(UI.button(bar, "My skill", nil, function()
    local prof = settings().prof or (current and current.prof)
    if prof then
      local p = planOf(prof)
      p.from, p.to = nil, nil
      NS.forgetState(prof)
    end
    NS.resetScroll()
    refresh()
  end, { "My skill", "Back to planning from your own skill to your cap (for a profile: from 1 to 300)." }))
  -- Row 2, how the list is counted: which recipes may be used and where the products sell. A page's own filters
  -- follow on the same row (Craft), Find and Details are at its right end.
  at.row(2)
  bar.dRecipes = at.put(UI.choice(bar, "Recipes", RECIPES_BOX, function() return RECIPES_BOX[settings().recipes] end, function()
    local items = { { title = true, text = "Recipes the route may use" } }
    for i, text in ipairs(RECIPES_BOX) do
      items[#items + 1] = { radio = true, checked = settings().recipes == i, text = text, tip = RECIPES_TIP[i], func = function()
        settings().recipes = i
        refresh()
      end }
    end
    return items
  end, { "Recipes the route may use", "Trainer only: " .. RECIPES_TIP[1], "Trainer + buyable: " .. RECIPES_TIP[2], "Everything: " .. RECIPES_TIP[3],
    "Scans follow this choice." }), 8)
  bar.dSell = at.put(UI.choice(bar, "Sells at", { SALES_BOX.best, SALES_BOX.vendor, SALES_BOX.off }, function() return SALES_BOX[settings().sales] end, function()
    local items = { { title = true, text = "Sells at" } }
    for _, key in ipairs(SALES_ORDER) do
      items[#items + 1] = { radio = true, checked = settings().sales == key, text = SALES_MENU[key], tip = SALES_TIP[key], func = function()
        settings().sales = key
        refresh()
      end }
    end
    return items
  end, { "Sells at", "Where the things you make are counted as sold. This is about the plan's sums; My sales is about your real auctions.",
    "One product can be set on its own: right-click its line." }), 10)
  bar.used, bar.h = at.x, 2 * WIN.bar
  -- Places the rows in the width given; returns the bar's height (two rows, more when a row had to wrap).
  function bar:Layout(w)
    self.dWho:Fit()   -- a profile's name may have changed
    self.h = self.flow:Layout(w)
    self.used = self.flow.need
    self:SetSize(w, self.h)
    return self.h
  end
  function bar:Refresh()
    self.dWho:Refresh()
    self.dProf:Refresh()
    self.dRecipes:Refresh()
    self.dSell:Refresh()
    local cur = shown()
    if cur then
      if not self.eFrom:HasFocus() then self.eFrom:SetText(tostring(cur.from)) end
      if not self.eTo:HasFocus() then self.eTo:SetText(tostring(cur.to)) end
    end
  end
  return bar
end

-- Cheapest | Fastest, as two buttons with the chosen one in gold. Fields: .bCheap, .bFast, :Refresh()
function NS.modeButtons(parent)
  local m = CreateFrame("Frame", nil, parent)
  m:SetSize(140, 22)
  m.bCheap = UI.button(m, "Cheapest", 70, function()
    settings().fast = false
    refresh()
  end, { "Cheapest", "The route with the lowest cost after sales. Your time counts at the hourly rate on the Settings page." })
  m.bCheap:SetPoint("LEFT", 0, 0)
  m.bFast = UI.button(m, "Fastest", 66, function()
    settings().fast = true
    refresh()
  end, { "Fastest", "The route with the least casting time, whatever it costs." })
  m.bFast:SetPoint("LEFT", m.bCheap, "RIGHT", 2, 0)
  function m:Refresh()
    local fast = settings().fast
    self.bCheap.label:SetText((fast and DIM or GOLD) .. "Cheapest|r")
    self.bFast.label:SetText((fast and GOLD or DIM) .. "Fastest|r")
  end
  return m
end

-- The marks the lists use, each with ONE meaning. A page says which of them it uses (`marks = { "~", "*" }`) and
-- gets a "?" button beside its name that shows this key.
NS.MARKS = {
  { "~", "an estimate, not a value read from the game or the auction house" },
  { "*", "your own choice, where Kebold would have decided by itself" },
  { "\194\187", "a favourite recipe" },
  { "?", "not known: nobody has recorded it yet" },
  { "!", "prices are missing for the plan (beside Prices on the rail)" },
}
function NS.marksKey(page)
  local want = {}
  for _, m in ipairs(page and type(page.marks) == "table" and page.marks or {}) do want[m] = true end
  local out = {}
  for _, m in ipairs(NS.MARKS) do
    if want[m[1]] then out[#out + 1] = m[1] .. "   " .. m[2] end
  end
  return out
end

-- Makes a page's frame and the parts its registration asked for, once.
local function buildPage(page)
  if type(page.frame) == "table" then return end
  local fr = CreateFrame("Frame", nil, frame.body)
  page.frame = fr
  fr:SetPoint("TOPLEFT", frame.body, "TOPLEFT", WIN.pad, -WIN.pad)
  if page.plan then page.planBar = NS.planBar(fr) end
  page.barFixed = page.barH ~= nil   -- a page whose bar holds more than rows of controls says how tall it is
  page.barShared = false
  if (page.bars or 0) > 0 then
    page.bar = CreateFrame("Frame", nil, fr)
    page.barH = page.barH or page.bars * WIN.bar
    page.at = NS.placer(page.bar)
  elseif page.planBar then
    -- a page with a plan and no bar of its own puts its filters on the plan bar's second row (Craft)
    page.bar, page.at, page.barShared = page.planBar, page.planBar.at, true
  end
  -- (Cheapest | Fastest is no longer put on any page by the shell: the engine reads it only when a route is
  -- planned. NS.modeButtons is kept for whoever wants the two buttons.)
  local host = fr
  if page.detail then
    page.split = UI.split(fr, { rightWidth = WIN.detail, minLeft = WIN.list, minRight = WIN.detailMin,
      get = function() return settings().detailOff == true end,
      set = function(v) settings().detailOff = v and true or nil end,
      onLayout = function(s, lw, rw, h)
        if page.shellTable then page.table:Layout(lw, h) end
        if rw > 0 and NS.detailLayout then pcall(NS.detailLayout, page, rw, h) end
      end,
      onToggle = function() refresh() end })
    host = page.split.left
  end
  if page.columns then
    page.table = UI.table(host, page.columns, {
      onClick = NS.rowClick, onEnter = NS.rowEnter, onLeave = NS.rowLeave, empty = page.empty, selected = page.selected,
      onSort = function(key, k)
        if page.onSort then page.onSort(page, key, k) end
      end })
    page.table:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
    page.shellTable = true   -- a table a page makes itself (Settings) is the page's to size
  end
  if page.build then page.build(page) end
  -- A page with a split gets "Details" at the right end of its last row of controls, after Find: pressed while the
  -- pane shows. On a page with a plan that row is the plan bar's second (the page's own row stays the page's).
  if page.split then
    local at = (page.planBar and page.planBar.at) or page.at
    if at then
      local host = page.planBar or page.bar
      page.bDetails = at.right(UI.toggle(host, "Details", nil, function()
        return not page.split:IsCollapsed() and page.split.rightW > 0
      end, function(v)
        page.split:SetCollapsed(not v)
      end, function()
        if page.split.forced == true then return { "Details", "The window is too narrow for the details beside the list: make it wider." } end
        return page.split:IsCollapsed() and { "Details", "Shows the details beside the list." } or { "Details", "Folds the details away; the list gets the whole width." }
      end), 0)
    end
  end
end

-- A button in the footer's right side, for the page: NS.footButton(page, { label =, onClick =, tip =, why = fn,
-- when = fn, scan = false }). The first one made is the rightmost. A scan button (the default) is greyed out away
-- from the auction house (NS.scanControl; `why` gives another reason it cannot run). `when()` false hides it (a
-- view's own scan). The shell places them, hides them while a scan's bar shows, and keeps the status line clear of
-- them (page.footRoom).
function NS.footButton(page, o)
  local b = UI.button(frame, o.label, nil, o.onClick, o.tip)
  if o.scan ~= false then NS.scanControl(b, o.why) end
  b.footAuto, b.footWhen, b.footOff, b.footX = true, o.when or false, false, 0
  page.footWidgets = type(page.footWidgets) == "table" and page.footWidgets or {}
  page.footWidgets[#page.footWidgets + 1] = b
  b:Hide()
  return b
end
local function footPlace(page)
  if type(page.footWidgets) ~= "table" then return end
  local x, any = 26, false
  for _, b in ipairs(page.footWidgets) do
    if b.footAuto == true then
      any = true
      if b.footWhen ~= false then b.footOff = not b.footWhen() end
      if b.footOff ~= true then
        b:ClearAllPoints()
        b:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -x, 3)
        b.footX = x
        x = x + (tonumber((b:GetWidth())) or 0) + 6
      end
    end
  end
  if any then page.footRoom = max(270, x + 8) end   -- 270: a running scan's bar takes the buttons' place
end

-- Gives the page showing its size: the plan bar, its own bar, then the split or the table in what is left.
local function layout(force)
  if not frame then return end
  local page = currentPage()
  if not (page and type(page.frame) == "table") then return end
  local w, h = pageSize()
  local off = settings().detailOff == true   -- the details pane folded or unfolded from outside the split's own button
  if not force and page.w == w and page.h == h and page.off == off then return end
  page.w, page.h, page.off = w, h, off
  page.frame:SetSize(w, h)
  -- the footer's line ends where its buttons (or a running scan's bar) begin: page.footRoom pixels from the right
  footPlace(page)
  frame.status:SetWidth(max(120, w + WIN.side + 8 + 2 * WIN.pad - 14 - (page.footRoom or 270)))
  frame.statusTip:SetSize(max(120, w + WIN.side + 8 + 2 * WIN.pad - 14 - (page.footRoom or 270)), 20)
  local y = 0
  if page.planBar then
    page.planBar:ClearAllPoints()
    page.planBar:SetPoint("TOPLEFT", page.frame, "TOPLEFT", 0, 0)
    y = y + page.planBar:Layout(w)   -- two rows; more when a row had to wrap
  end
  if page.bar and not page.barShared then
    -- the page's own rows: placed again in this width; a row that does not fit wraps and the bar grows
    local fh = page.at.flow:Layout(w)
    if not page.barFixed then page.barH = max(fh, (page.bars or 1) * WIN.bar) end
    page.bar:ClearAllPoints()
    page.bar:SetPoint("TOPLEFT", page.frame, "TOPLEFT", 0, -y)
    page.bar:SetSize(w, page.barH)
    y = y + page.barH
  end
  if y > 0 then y = y + WIN.gapY end
  if page.split then
    page.split:ClearAllPoints()
    page.split:SetPoint("TOPLEFT", page.frame, "TOPLEFT", 0, -y)
    page.split:Layout(w, h - y)
  elseif page.shellTable then
    page.table:ClearAllPoints()
    page.table:SetPoint("TOPLEFT", page.frame, "TOPLEFT", 0, -y)
    page.table:Layout(w, h - y)
  end
  if page.layout then page.layout(page, w, h, y) end
end
function NS.layout() layout(true) end

-- The footer belongs to the page showing (a page's `footer`):
--   "plan"                 the plan's price status and the Scan this plan button (Level and Craft)
--   function(page) -> text one line of the page's own (Shopping: the list's status; Level: what is wrong with
--                          the plan); no scan button unless the page also sets footScan = true
--   nothing                an empty footer (Prices, My sales, Settings)
-- A page may also put controls of its own into the footer: widgets parented to the window, listed in
-- page.footWidgets; each shows with its page unless its footOff is true, and gives way to a running scan's bar.
-- While a scan runs its progress bar is here on every page but Prices. Called five times a second by the scan bar.
NS.tickers = {}   -- other parts that follow a scan (the Prices page's own bar)
local function footWidgets(scanning)
  local page = currentPage()
  for _, pg in pairs(pages) do
    for _, w in ipairs(type(pg.footWidgets) == "table" and pg.footWidgets or {}) do
      if pg == page and pg.active and not scanning and w.footOff ~= true then w:Show() else w:Hide() end
    end
  end
end
function NS.onScanTick(p)
  if not frame then return end
  for _, fn in ipairs(NS.tickers) do fn(p) end
  local page = currentPage()
  local plan = page ~= nil and (page.footer == "plan" or page.footScan == true)
  frame.footKind = plan and "plan" or ((page and type(page.footer) == "function") and "page" or "none")
  if p then
    frame.footBar:Set(p.done, p.total, NS.scanText and NS.scanText(p) or (p.done .. " / " .. p.total))
    -- a scan's progress shows in one place at a time (NS.progressOwner in LedgerEntry.lua): here on every page but
    -- Prices, and not while the Kebold tab of the auction house is showing
    local here = not NS.progressOwner or NS.progressOwner() == "footer"
    if here then frame.footBar:Show() else frame.footBar:Hide() end
    frame.footScan:Hide()
    footWidgets(here)
  else
    frame.footBar:Hide()
    -- Craft shows the plan's price status but no scan button (owner 2026-11-14: "there is no plan there")
    if plan and page.footNoScan ~= true then frame.footScan:Show() else frame.footScan:Hide() end
    footWidgets(false)
  end
end

-- Everything around the page: the title, the rail, the plan bar's values, the scan buttons, the footer.
local function chrome(title)
  if not frame then return end
  local page = currentPage()
  -- a plan for somebody else says so in the title bar and beside the page's name, on every page
  local forWho, whoName = NS.whoText(), select(2, who())
  if title then frame.title:SetText("Kebold's Shiny - " .. (title:gsub("  ", " ")) .. (whoName and ("  -  for " .. whoName) or "")) end
  frame.pageTitle:SetText((page and page.title or "") .. (forWho and ("   |cffff9020" .. forWho .. "|r") or ""))
  frame.nav:Select(page and page.key)
  if page and type(page.marks) == "table" and #page.marks > 0 then frame.help:Show() else frame.help:Hide() end
  if page and page.planBar then page.planBar:Refresh() end
  if page and type(page.bDetails) == "table" then page.bDetails:Refresh() end
  local cur = shown()
  if cur and frame.iconProf ~= cur.prof then   -- the round picture: the profession shown
    frame.iconProf = cur.prof
    frame:SetIcon(NS.profIcon(cur.prof))
  end
  local at = atAuctionHouse()
  for _, b in ipairs(scanButtons) do
    local why = nil
    if at and type(b.scanWhy) == "function" then
      local okW, text = pcall(b.scanWhy)
      if okW and type(text) == "string" then why = text end
    end
    b:SetEnabled(at and why == nil, at and why or "Open the auction house first.")
  end
  -- the footer: the page's own. On Level and Craft how complete the plan's prices are and the scan button; a
  -- page's own line where it has one; nothing elsewhere. A running scan's bar shows on every page (onScanTick).
  local okS, status, short = pcall(NS.status)
  local foot = ""
  if page and page.footer == "plan" then
    foot = okS and status or ""
    -- a page may lead the line with a count of its own ("123 Cooking recipes"); the plan's status follows it
    -- without naming the profession twice
    local okL, lead = pcall(function() return page.footLead and page.footLead(page) or nil end)
    if okL and type(lead) == "string" and lead ~= "" then
      local c = shown() or NS.state()
      if c then foot = foot:gsub(c.prof .. " prices: ", "prices: ", 1) end
      foot = lead .. DIM .. "  \194\183  |r" .. foot
    end
  elseif page and type(page.footer) == "function" then
    local okF, text = pcall(page.footer, page)
    foot = (okF and type(text) == "string") and text or ""
  end
  frame.footText = foot
  frame.status:SetText(UI.show(foot))
  frame.nav:SetBadge("scan", (okS and short) and "!" or nil)
  if NS.shopBadge then pcall(NS.shopBadge) end   -- the Shopping page's count of items left (LedgerShop.lua)
  NS.onScanTick(type(KeboldsShinyScan_Progress) == "function" and KeboldsShinyScan_Progress() or nil)
end

function refresh()
  if not frame then return end
  local S = settings()
  local page = currentPage()
  if not page then return end
  S.tab = page.key
  for _, p in pairs(pages) do
    if p ~= page and p.active then
      p.active = false
      if type(p.frame) == "table" then p.frame:Hide() end
      if p.onHide then pcall(p.onHide, p) end
    end
  end
  local okB, errB = pcall(buildPage, page)
  if not okB then
    say("Error: " .. tostring(errB))
    return
  end
  local fresh = not page.active
  if fresh then
    page.active = true
    page.frame:Show()
    if page.onShow then pcall(page.onShow, page) end
  end
  local ok, a, b = pcall(build)
  if ok then
    rows = a
  else
    rows = { { left = RED .. "Kebold hit an error:|r" }, { left = tostring(a), wide = true } }
    say("Error: " .. tostring(a))
    b = "Kebold's Shiny"
  end
  -- what the rows of controls depend on besides the window's size: the Row size, whose plan it is (the Plan for
  -- box is as wide as the name), and whatever the page says (page.barKey: the view of Merchant's Favor)
  local okK, barKey = pcall(function() return page.barKey and page.barKey(page) or "" end)
  local layKey = UI.density().key .. "|" .. tostring(select(2, who()) or "") .. "|" .. tostring(okK and barKey or "")
  local again = page.layKey ~= layKey
  page.layKey = layKey
  layout(fresh or again)
  if page.detail and NS.detailAttach then
    local okD, errD = pcall(NS.detailAttach, page)   -- after the layout: the pane goes where the split put its right side
    if not okD then say("Error: " .. tostring(errD)) end
  end
  if type(page.table) == "table" then
    local view = rows
    if ok and page.view then view = page.view(page, rows) or rows end
    -- a row with aside = true is said elsewhere on the page (the footer, a tooltip): it stays in the model, so
    -- /kebold print and the tests still have it, and out of the list
    local list, any = {}, false
    for _, row in ipairs(view) do
      if row.aside == true then any = true else list[#list + 1] = row end
    end
    page.table:SetRows(any and list or view)
  end
  if ok and page.paint then
    local okP, errP = pcall(page.paint, page, rows, b)
    if not okP then say("Error: " .. tostring(errP)) end
  end
  chrome(b)
  if NS.onRefresh then NS.onRefresh() end   -- the details pane follows
end

local pending = false
local function refreshSoon(delay)
  if pending or not (frame and frame:IsShown()) then return end
  pending = true
  C_Timer.After(delay or 0.5, function()
    pending = false
    if frame and frame:IsShown() then refresh() end
  end)
end

-- kept for the other Kebold files: a kit button
local function makeButton(parent, text, width, onClick, tip)
  return UI.button(parent, text, width, onClick, tip)
end

-- Starts a scan by its /keboldscan word ("" = materials and parts, "bs", "bs all", "route", "everything").
local function scanButton(what)
  if not atAuctionHouse() then
    NS.notice("Open the auction house first.")
    return
  end
  SlashCmdList["KEBOLDSSHINYSCAN"](what or "")
end

-- The icon of a profession: the game's own when it gives one, else a fixed file.
local PROF_ICON = { Blacksmithing = "Trade_BlackSmithing", Leatherworking = "Trade_LeatherWorking", Tailoring = "Trade_Tailoring",
  Engineering = "Trade_Engineering", Alchemy = "Trade_Alchemy", Enchanting = "Trade_Engraving", Cooking = "INV_Misc_Food_15",
  ["First Aid"] = "Spell_Holy_SealOfSacrifice", Mining = "Trade_Mining" }
function NS.profIcon(prof)
  local tex = C_TradeSkillUI and try(C_TradeSkillUI.GetTradeSkillTexture, data().line[prof]) or nil
  if tex and tex ~= "" and tex ~= 0 then return tex end
  return "Interface\\Icons\\" .. (PROF_ICON[prof] or "INV_Misc_Book_09")
end

-- How much of what the plan buys has a price, and how old the oldest price is: got, wanted, age in days.
local function priceStatus(prof, st)
  local items = realmItems()
  local want = E.scanItems(data(), prof, scanScope(prof, st, "none"))
  local got, oldest = 0, nil
  for _, id in ipairs(want) do
    local L = E.parseLadder(items[id])
    if L then
      got = got + 1
      if not oldest or L.day < oldest then oldest = L.day end
    end
  end
  local today = floor(((try(time) or 0) - DAY_ZERO) / 86400)
  return got, #want, oldest and max(0, today - oldest) or 0
end

local function ageWord(age)
  return age == 0 and "today" or (age == 1 and "yesterday" or (age .. " days ago"))
end

-- One line for the footer and the minimap button: "Prices: 58 of 58 scanned, oldest today" (red when incomplete).
-- The second value is true when prices are missing.
local statusKey, statusText, statusShort
function NS.status()
  local c = shown() or NS.state()
  if not c then return "", false end
  local key = NS.sigOf(c.prof, c.st, c.from, c.to) .. "|" .. floor((try(time) or 0) / 3600)
  if key ~= statusKey then
    local got, total, age = priceStatus(c.prof, c.st)
    statusKey, statusShort = key, got < total
    if total == 0 then
      statusText = DIM .. c.prof .. ": nothing to price for this plan|r"
    elseif got == 0 then
      statusText = RED .. c.prof .. " prices: none of " .. total .. " scanned yet|r"
    else
      statusText = (got < total and RED or DIM) .. string.format("%s prices: %d of %d scanned, oldest %s|r", c.prof, got, total, ageWord(age))
    end
  end
  return statusText, statusShort
end

-- Where the window is: the saved place, else the middle of the screen.
local docked = false
local function placeWindow()
  local w = settings().win
  frame:ClearAllPoints()
  if type(w.x) == "number" and type(w.y) == "number" then
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", w.x, w.y)
  else
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  end
end

local function savePlace()
  local w = settings().win
  local x, y = tonumber((frame:GetLeft())), tonumber((frame:GetTop()))
  if x and y then w.x, w.y = floor(x + 0.5), floor(y + 0.5) end
  docked = false
  if NS.windowDragged then NS.windowDragged() end
end

-- Beside the auction house while it is open (the Kebold button there); back to its own place afterwards.
-- Only when the window fits on the screen beside it: otherwise it stays at its own place (the saved one, else the
-- middle of the screen). Returns whether it docked. When the game gives no sizes, it docks as before (the window is
-- clamped to the screen).
function NS.dockFits(anchor)
  local right = try(anchor.GetRight, anchor)
  local screen = type(UIParent) == "table" and try(UIParent.GetWidth, UIParent) or nil
  if type(right) ~= "number" or type(screen) ~= "number" or screen <= 0 then return true end
  local theirs, ours = try(anchor.GetEffectiveScale, anchor), type(UIParent) == "table" and try(UIParent.GetEffectiveScale, UIParent) or nil
  if type(theirs) == "number" and type(ours) == "number" and ours > 0 then right = right * theirs / ours end
  local w = winSize()
  return right + 4 + w * (settings().win.scale or 1) <= screen
end
function NS.dock(anchor)
  if not frame or type(anchor) ~= "table" then return false end
  if not NS.dockFits(anchor) then
    docked = false
    placeWindow()
    return false
  end
  frame:ClearAllPoints()
  frame:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 4, 0)
  docked = true
  return true
end
function NS.isDocked() return docked end

-- The window's size on screen, 0.8 to 1.2.
function NS.setScale(v)
  local w = settings().win
  w.scale = max(0.8, min(1.2, floor((tonumber(v) or 1) * 20 + 0.5) / 20))
  if frame then pcall(frame.SetScale, frame, w.scale) end
  refresh()
end
function NS.undock()
  if frame and docked then
    docked = false
    placeWindow()
  end
end

local function createFrame()
  local S = settings()
  local f = UI.window("KeboldsShinyFrame", UIParent, S.win.w, S.win.h, { top = WIN.top, bottom = WIN.bottom, left = WIN.side, right = 8 })
  frame = f
  f:SetFrameStrata("HIGH")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:SetClampedToScreen(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    savePlace()
  end)
  if S.win.scale ~= 1 then pcall(f.SetScale, f, S.win.scale) end
  placeWindow()
  f.title:SetText("Kebold's Shiny")
  f.iconProf = false

  -- the head band: the page's name, and the notice bar at its right end
  f.pageTitle = UI.text(f, "title", "")
  f.pageTitle:SetPoint("TOPLEFT", f, "TOPLEFT", f.hasPortrait and 66 or 12, -32)
  -- the key to the marks, on the pages that use any: hover it, or click for the same as a small list
  f.help = UI.button(f, "?", 22, function(self)
    local items = { { title = true, text = "Marks on this page" } }
    for _, line in ipairs(NS.marksKey(currentPage())) do items[#items + 1] = { text = line, disabled = true } end
    UI.menu(self, items)
  end, function()
    local tip = { "Marks on this page" }
    for _, line in ipairs(NS.marksKey(currentPage())) do tip[#tip + 1] = line end
    local about = NS.footTip(currentPage())   -- what the page says about its own list, as under the footer's line
    for i = 2, about and #about or 0 do tip[#tip + 1] = about[i] end
    return tip
  end)
  f.help:SetPoint("LEFT", f.pageTitle, "RIGHT", 8, 0)
  f.help:Hide()
  f.notice = UI.notice(f, 430)
  f.notice:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -29)

  -- the rail of pages
  f.nav = UI.nav(f, WIN.rail, function(key) NS.showPage(key, true) end)
  f.nav:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -(WIN.top + 4))
  for _, key in ipairs(TAB_ORDER) do
    local p = pages[key]
    if p then f.nav:Add(key, p.title, p.icon, p.tip, navGroup(p)) end
  end

  -- the footer
  local function scanTip(title, text)
    return function()
      return { title, text, atAuctionHouse() and "Keep the auction house open while it runs." or nil }
    end
  end
  f.status = UI.text(f, "body", "")
  f.status:SetPoint("BOTTOMLEFT", 14, 9)
  f.status:SetJustifyH("LEFT")
  f.status:SetWordWrap(false)
  f.footText, f.footKind = "", "none"
  -- hovering the footer's line explains it: what the page showing says about itself (page.footTip)
  f.statusTip = CreateFrame("Frame", nil, f)
  f.statusTip:SetPoint("BOTTOMLEFT", 14, 4)
  f.statusTip:SetSize(300, 20)
  f.statusTip:EnableMouse(true)
  -- (a page that says nothing has its line in full there: a long one is cut where the buttons begin)
  UI.tip(f.statusTip, function()
    local tip = NS.footTip(currentPage())
    if tip then return tip end
    local page = currentPage()
    if f.footText ~= "" then return { page and page.title or "Status", f.footText } end
  end)
  f.footScan = NS.scanControl(UI.button(f, NS.scanLabel and NS.scanLabel("plan") or "Scan this plan", 110, function()
    local cur = shown()
    if cur then scanButton(string.lower(cur.prof)) end
  end, scanTip("Scan this plan", "Looks up what the recipes this plan could use buy, and what they make when sales count at the auction house.")))
  f.footScan:SetPoint("BOTTOMRIGHT", -26, 3)
  f.footBar = UI.progress(f, 230, 16)
  f.footBar:SetPoint("BOTTOMRIGHT", -26, 6)
  f.footBar:Hide()

  -- the bottom right corner resizes the window, both ways; no grip on a client that has neither way of limiting
  -- a frame's size
  local canSize = false
  if type(f.SetResizeBounds) == "function" then
    canSize = pcall(f.SetResizeBounds, f, minW(), WIN.minH, WIN.maxW, WIN.maxH)
  elseif type(f.SetMinResize) == "function" and type(f.SetMaxResize) == "function" then
    canSize = pcall(f.SetMinResize, f, minW(), WIN.minH) and pcall(f.SetMaxResize, f, WIN.maxW, WIN.maxH)
  end
  if canSize and pcall(f.SetResizable, f, true) then
    local grip = CreateFrame("Button", nil, f)
    f.grip = grip
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -4, 4)
    for i = 1, 3 do   -- three small steps, drawn without a texture file
      local t = grip:CreateTexture(nil, "OVERLAY")
      t:SetColorTexture(0.75, 0.7, 0.55, 0.9)
      t:SetSize(4 * i, 2)
      t:SetPoint("BOTTOMRIGHT", 0, (3 - i) * 4 + 1)
    end
    local hi = grip:CreateTexture(nil, "HIGHLIGHT")
    hi:SetAllPoints()
    hi:SetColorTexture(1, 1, 1, 0.2)
    local sizing = false
    grip:SetScript("OnMouseDown", function()
      sizing = true
      f:StartSizing("BOTTOMRIGHT")
    end)
    grip:SetScript("OnMouseUp", function()
      sizing = false
      f:StopMovingOrSizing()
      local w = settings().win
      w.w = max(minW(), min(WIN.maxW, floor((tonumber((f:GetWidth())) or w.w) + 0.5)))
      w.h = max(WIN.minH, min(WIN.maxH, floor((tonumber((f:GetHeight())) or w.h) + 0.5)))
      f:SetSize(w.w, w.h)
      savePlace()
      refresh()
    end)
    f:SetScript("OnSizeChanged", function()
      if sizing then layout() end   -- the page follows while the corner is dragged
    end)
    UI.tip(grip, { "Resize", "Drag to make the window larger or smaller." })
  end

  f:SetScript("OnShow", refresh)
  if type(UISpecialFrames) == "table" then table.insert(UISpecialFrames, "KeboldsShinyFrame") end   -- Escape closes it
  f:Hide()
end

local function toggle(show)
  if not frame then createFrame() end
  if show == nil then show = not frame:IsShown() end
  if show then
    frame:Show()
    refresh()   -- a frame that is already shown does not fire OnShow
  else
    frame:Hide()
  end
end

-- Opens the window on one page (a key, or one of the names /kebold tab takes). asIs: a page with views of its own
-- stays on the view it last showed (the rail and the entry menu, which name the page, not a view).
function NS.showPage(name, asIs)
  local key = PAGE_ALIAS[name] or name
  if pages[key] then settings().tab = key end
  -- a page with views of its own (Merchant's Favor: crates, writs) opens on the one that was named
  if not asIs and type(NS.PAGE_VIEW) == "table" and NS.PAGE_VIEW[name] and type(NS.favorView) == "function" then
    settings().favorView = NS.PAGE_VIEW[name] ~= "crates" and NS.PAGE_VIEW[name] or nil
  end
  toggle(true)
end
NS.showTab = NS.showPage

-- The Shopping page until LedgerShop.lua registers its own under the same key: NS.shopRows() when something
-- provides it, else an empty state.
NS.page({ key = "shop", title = "Shopping", order = 3, icon = "Interface\\Icons\\INV_Misc_Bag_08",
  tip = { "Shopping", "What to buy for the plans you make." },
  columns = { { key = "left", title = "Item", flex = 1, min = 220 }, { key = "c1", title = "", width = 130, drop = 1 },
    { key = "c2", title = "", width = 120, align = "RIGHT" }, { key = "right", title = "", width = 120, align = "RIGHT" } },
  rows = function()
    if type(NS.shopRows) == "function" then
      local list, title = NS.shopRows()
      return list or {}, title or "Shopping"
    end
    return { { left = DIM .. "The shopping list is coming.|r", empty = { icon = "Interface\\Icons\\INV_Misc_Bag_08", title = "Shopping list",
      text = "The shopping list is coming: one list of what to buy for your plans, with what is in your bags taken off. Until then the Level page ends with what its route buys." } } }, "Shopping"
  end })

-- ---- scans for one profession or one route (called by /keboldscan and the window's buttons) ------------------------

-- Which items a scan word covers: ids, label (and for "everything" the counts by kind). false, message when the
-- word is known but there is nothing to scan; nil for a word that is not Kebold's.
function NS.scanList(cmd)
  cmd = string.lower(cmd or "")
  if cmd == "route" then
    if NS.buildRoute then pcall(NS.buildRoute) end   -- the route of the profession and settings chosen now (kept when nothing changed)
    if not current or not current.route then
      return false, "There is no route yet. Scan the profession first, for example /keboldscan bs."
    end
    local ids = E.routeItems(current.ctx, current.route.segs)
    do   -- and the recipe items of what the route has to learn, so their price follows the auction house
      local seen = {}
      for _, id in ipairs(ids) do seen[id] = true end
      local function add(r)
        local li = current.ctx.learnInfo and current.ctx.learnInfo(r)
        if r.src == "R" and r.pat > 0 and not seen[r.pat] and li and li.how ~= "known" then
          seen[r.pat] = true
          ids[#ids + 1] = r.pat
        end
      end
      for _, g in ipairs(current.route.segs) do
        if g.r then add(g.r) end
        for _, e in ipairs(g.learn or {}) do add(e.r) end
      end
    end
    if #ids == 0 then
      return false, "The route has no priced steps yet. Scan the profession first, for example /keboldscan bs."
    end
    return ids, current.prof .. " route"
  end
  local one = cmd:match("^recipe%s+(%d+)$")
  if one then
    local r = data().byId[tonumber(one)]
    if not r then return false, "No recipe with the id " .. one .. " in Kebold's data." end
    return NS.recipeItems(r), r.name .. ": what it makes and everything needed to make it"
  end
  if cmd == "fav" or cmd == "favs" or cmd == "favorites" or cmd == "favourites" then
    local ids, seen, n = {}, {}, 0
    for _, r in ipairs(data().recipes) do   -- in the data's order, so the scan is the same every time
      if settings().fav[r.id] then
        n = n + 1
        NS.recipeItems(r, ids, seen)
      end
    end
    if n == 0 then
      return false, "No favourites yet: right-click a recipe and tick Favourite (or tick it in the recipe's details)."
    end
    return ids, n .. (n == 1 and " favourite recipe" or " favourite recipes") .. ": what they make and everything needed to make them"
  end
  if cmd == "shop" or cmd == "shopping" then
    local ids = type(NS.shopScanIDs) == "function" and NS.shopScanIDs() or {}
    if #ids == 0 then
      return false, "The shopping list is empty: add a route step, a recipe or your favourites to it first."
    end
    return ids, "the shopping list: what it buys, the parts it makes and what those use"
  end
  if cmd == "de" or cmd == "disenchant" then
    local ids = type(NS.deScanIDs) == "function" and NS.deScanIDs() or {}
    if #ids == 0 then return false, "The disenchant materials are not loaded." end
    return ids, "disenchant materials: every dust, essence, shard and crystal a disenchant can give"
  end
  if cmd == "crates" or cmd == "crate" then
    local ids = type(NS.crateScanIDs) == "function" and NS.crateScanIDs() or {}
    if #ids == 0 then return false, "The crate data is not loaded." end
    return ids, "crate materials: everything a Waylaid Crate can be filled with, and the crates themselves"
  end
  if cmd == "writs" or cmd == "writ" then
    local ids = type(NS.writScanIDs) == "function" and NS.writScanIDs() or {}
    if #ids == 0 then return false, "The writ data is not loaded." end
    return ids, "writ items: the Craftsman's Writs and their envelopes, what they ask for and the materials to make it"
  end
  if cmd == "everything" then
    local ids, n = E.allItems(data())
    return ids, "every item of all nine professions", n
  end
  local all = false
  local prof = ALIAS[cmd]
  if not prof then
    local head = cmd:match("^(.-)%s+all$")
    if head then prof, all = ALIAS[head], true end
  end
  if not prof then return nil end
  if all then
    return E.scanItems(data(), prof, { outputs = "all", patterns = true }), "everything in " .. prof
  end
  local st = profState(prof)
  local from, to = rangeOf(prof, st)
  -- with AH sales counted, what the plan makes is looked up too (not gear: it counts at vendor value); otherwise
  -- only what it buys
  local best = settings().sales == "best"
  local ids = E.scanItems(data(), prof, scanScope(prof, st, best and "nongear" or "none"))
  -- products you set to "AH" by hand are looked up whatever the Sales button says
  local have = {}
  for _, id in ipairs(ids) do have[id] = true end
  for _, r in ipairs(data().byProf[prof] or {}) do
    if r.made > 0 and settings().sellPick[r.made] == "ah" and not have[r.made] then
      have[r.made] = true
      ids[#ids + 1] = r.made
    end
  end
  -- a plan that counts something as disenchanted needs the disenchant materials' prices too
  local de = settings().opts.deGear == true and best
  for _, r in ipairs(data().byProf[prof] or {}) do
    if r.made > 0 and settings().sellPick[r.made] == "de" then de = true end
  end
  if de and type(NS.deScanIDs) == "function" then
    for _, id in ipairs(NS.deScanIDs()) do
      if not have[id] then
        have[id] = true
        ids[#ids + 1] = id
      end
    end
  end
  return ids, prof .. " " .. from .. " to " .. to .. ", recipes: " .. RECIPES[settings().recipes] .. ". What it buys" .. (best and ", and what it makes" or "")
    .. (settings().recipes >= 2 and ", and the recipe items it could learn from" or "")
end

-- For the scanner's quick scans (KeboldsShiny.lua): every item id Kebold knows, in the order of
-- /keboldscan everything plus the disenchant materials, what the Waylaid Crates take and the crates themselves,
-- the Craftsman's Writs and their envelopes, and the set of crafted gear among them.
local quickIds, quickGear
function KeboldsShiny_QuickItems()
  if not quickIds then
    quickIds = E.allItems(data())
    quickGear = {}
    for _, r in ipairs(data().recipes) do
      if r.gear and r.made > 0 then quickGear[r.made] = true end
    end
  end
  local ids, seen = {}, {}
  for i, id in ipairs(quickIds) do
    ids[i] = id
    seen[id] = true
  end
  for _, fn in ipairs({ NS.deScanIDs or false, NS.crateScanIDs or false, NS.writScanIDs or false }) do
    if type(fn) == "function" then
      local ok, more = pcall(fn)
      for _, id in ipairs(ok and type(more) == "table" and more or {}) do
        if type(id) == "number" and id > 0 and not seen[id] then
          seen[id] = true
          ids[#ids + 1] = id
        end
      end
    end
  end
  return ids, quickGear
end

function KeboldsShiny_ScanCommand(cmd)
  if type(KeboldsShinyScan_Start) ~= "function" then return false end
  local ids, label, n = NS.scanList(cmd)
  if ids == nil then return false end
  if ids == false then
    NS.notice(label, "warn", true)   -- a typed /keboldscan gets its answer in chat too
    return true
  end
  if n then
    say(string.format("Everything: %d items of all nine professions, about %d minutes at the auction house. In this order: %d materials, %d parts, %d other products (gear too), %d recipe items. Stopped early, the first ones are done.",
      #ids, ceil(#ids * 0.65 / 60), n.mats, n.parts, n.products, n.patterns))
  end
  KeboldsShinyScan_Start(ids, label)
  return true
end

function KeboldsShiny_OnScanFinished()
  priceVersion = priceVersion + 1
  -- the read of your own auctions waits while a scan runs and gives up after half a minute: ask now
  if type(KeboldsShinySales) == "table" and type(KeboldsShinySales.askOwned) == "function" then pcall(KeboldsShinySales.askOwned) end
  refreshSoon(0.2)
end

-- ---- wiring ------------------------------------------------------------------------------------------------

local function onProfessionOpen()
  C_Timer.After(1.5, function()   -- after the collector has read the list
    local open = C_TradeSkillUI and try(C_TradeSkillUI.GetBaseProfessionInfo)
    local name = profNameOf(open)   -- the data's name: the game's own is not English on every client
    if name and not try(C_TradeSkillUI.IsTradeSkillLinked) and not try(C_TradeSkillUI.IsTradeSkillGuild) then
      settings().prof = name
    end
    if NS.onProfessionShown then pcall(NS.onProfessionShown) end   -- the button above the profession window (LedgerEntry.lua)
    if frame and frame:IsShown() then refresh() end
  end)
end

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, event)
  if event == "TRADE_SKILL_SHOW" then
    onProfessionOpen()
  elseif event == "BAG_UPDATE_DELAYED" then
    -- bag counts only show on the Level page; the other pages are not rebuilt for every loot or craft
    local tab = settings().tab
    if tab == nil or tab == "route" then refreshSoon(1.5) end
  elseif event ~= "TRADE_SKILL_CLOSE" then
    refreshSoon(1.5)
  end
end)
for _, event in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_CLOSE", "TRADE_SKILL_LIST_UPDATE", "NEW_RECIPE_LEARNED", "SKILL_LINES_CHANGED", "BAG_UPDATE_DELAYED" }) do
  pcall(events.RegisterEvent, events, event)
end

-- Row tables as plain lines in chat (/kebold print, /keboldshop): at most `limit` of them; prefix(row) may put
-- something before a line.
function NS.printRows(list, limit, prefix)
  for i = 1, min(#list, limit or #list) do
    local row = list[i]
    local line = row.left or (row.cols and table.concat(row.cols, "  ")) or ""
    for _, k in ipairs({ "time", "c1", "c2", "right" }) do
      if row[k] and row[k] ~= "" then line = line .. "   " .. row[k] end
    end
    if prefix then line = (prefix(row) or "") .. line end
    print(UI.plainText(line))
  end
end

SLASH_KEBOLDSSHINY1 = "/kebold"
SLASH_KEBOLDSSHINY2 = "/ledger"   -- the name before the addon was renamed
SlashCmdList["KEBOLDSSHINY"] = function(msg)
  local cmd = string.lower((msg or ""):match("^%s*(.-)%s*$"))
  local S = settings()
  if cmd == "" then
    toggle()
    return
  end
  -- the profession chosen (the plan bar's), as setRange and the My skill button take it
  local prof = S.prof or (current and current.prof) or myProfs()[1] or data().profs[1]
  local which, value = cmd:match("^(%a+)%s+(%S+)$")
  if ALIAS[cmd] then
    S.prof = ALIAS[cmd]
    NS.resetScroll()
  elseif (which == "from" or which == "to") and (tonumber(value) or value == "auto") then
    S.prof = prof
    setRange(which, tonumber(value))
  elseif cmd == "mine" then
    local p = planOf(prof)
    p.from, p.to = nil, nil
    NS.forgetState(prof)
  elseif cmd == "recipes" or cmd == "items" then
    S.recipes = S.recipes % 3 + 1
    say("Recipes the route may use: " .. RECIPES[S.recipes] .. "." .. (S.recipes >= 2 and " Scan this plan again so the recipe items are looked up." or ""))
  elseif cmd == "trainer" or cmd == "buyable" or cmd == "all" then
    S.recipes = cmd == "trainer" and 1 or (cmd == "buyable" and 2 or 3)
    say("Recipes the route may use: " .. RECIPES[S.recipes] .. ".")
  elseif cmd == "sales" or (which == "sales" and SALES[value]) then
    S.sales = which == "sales" and value or SALES_NEXT[S.sales]
    say("Sells at: " .. SALES[S.sales] .. "." .. (S.sales == "best" and " Scan this plan again so the products are looked up." or ""))
  elseif cmd == "fast" or cmd == "cheap" then
    S.fast = cmd == "fast"
  elseif (which == "tab" or which == "page") and NS.pageOf(value) then
    S.tab = NS.pageOf(value).key
    if type(NS.PAGE_VIEW) == "table" and NS.PAGE_VIEW[value] then   -- /kebold tab writs: the page on that view
      S.favorView = NS.PAGE_VIEW[value] ~= "crates" and NS.PAGE_VIEW[value] or nil
    end
    NS.resetScroll()
  elseif cmd == "ui" then
    UI.report()
    return
  elseif cmd == "ui gallery" or cmd == "gallery" then
    local ok, err = pcall(UI.gallery)
    if not ok then say("The gallery hit an error: " .. tostring(err)) end
    return
  elseif which == "strip" and (value == "pane" or value == "top" or value == "off") and NS.setStrip then
    NS.setStrip(value)   -- the recipe figures at the profession window: in its recipe pane, above it, or off
    return
  elseif which == "skin" and (value == "plain" or value == "auto") then
    S.skin = value
    say((value == "plain" and "Plain look on." or "Plain look off.") .. " Type /reload: windows that are already built keep their look until then.")
    return
  elseif cmd == "copy" then   -- the plan as text in a box to copy from, for handing it to somebody
    if NS.copyPlan then NS.copyPlan() end
    return
  elseif cmd == "print" then
    local ok, list, title = pcall(build)
    if not ok then
      say("Error: " .. tostring(list))
      return
    end
    say(title)
    NS.printRows(list, 80)
    return
  else
    say("Usage: /kebold (or /ledger) [bs | lw | tailoring | eng | alch | ench | cook | firstaid | mining | from <skill or auto> | to <skill or auto> | mine | recipes | trainer | buyable | all | sales [best | vendor | off] | fast | cheap | tab level | tab craft | tab disenchant | tab favor | tab crates | tab writs | tab shopping | tab prices | tab sales | tab settings | print | copy | strip pane | strip top | strip off | skin plain | skin auto | ui | ui gallery]")
    return
  end
  toggle(true)
end

-- for the other Kebold files
NS.E, NS.settings, NS.data, NS.say, NS.try, NS.money, NS.itemName, NS.bagCount = E, settings, data, say, try, money, itemName, bagCount
NS.legacyBonus = legacyBonus
NS.recipesOf, NS.profNameOf, NS.fieldsOf, NS.profileText = recOf, profNameOf, fieldsOf, profileText
NS.profState, NS.myProfs, NS.rangeOf, NS.legacyRank, NS.learnText, NS.realmItems, NS.collected = profState, myProfs, rangeOf, legacyRank, learnText, realmItems, collected
NS.makeButton, NS.rowEnter, NS.rowLeave, NS.rowClick, NS.scanButton, NS.toggle = makeButton, rowEnter, rowLeave, rowClick, scanButton, toggle
NS.COLOUR, NS.DIM, NS.RED, NS.GOLD, NS.WHITE, NS.GREEN = COLOUR, DIM, RED, GOLD, WHITE, GREEN
NS.PICK_TEXT, NS.SELL_TEXT, NS.SALES, NS.ROW_H, NS.DAY_ZERO, NS.RANKS = PICK_TEXT, SELL_TEXT, SALES, ROW_H, DAY_ZERO, RANKS
NS.itemText, NS.refreshSoon, NS.shown = itemText, refreshSoon, shown
function NS.wayShort(way) return WAY_SHORT[way] or " vendor" end   -- after a figure: " AH", " vendor", " disenchant"
function NS.wayLong(way) return WAY_LONG[way] end                  -- in a sentence; nil when the sale is not counted
NS.scanScope, NS.vendorPrices, NS.atAuctionHouse = scanScope, vendorPrices, atAuctionHouse
function NS.pricesOf(prof)   -- got, wanted, age in days of the oldest price: how complete a profession's plan is priced
  return priceStatus(prof, profState(prof))
end
-- The list of the page showing, for tests: its table's line widgets, the rows that table shows, its scroll position.
function NS.lines()
  local page = currentPage()
  local t = page and page.table
  if type(t) ~= "table" then return {}, rows, 0 end
  return t.lines, t.rows, t.offset
end
function NS.repaint()   -- the same lines again, for something that only changed how they look
  if not (frame and frame:IsShown()) then return end
  local page = currentPage()
  if page and type(page.table) == "table" then page.table:Paint() end
  chrome()
end
function NS.refresh() refresh() end
function NS.version() return priceVersion end
function NS.bump()   -- something every plan depends on changed
  priceVersion = priceVersion + 1
end
-- Products whose vendor value in game is not the one the addon shipped with: { { item, name, was, now }, ... }
-- (was = nil when the addon had none), by name; and the number of values read in game.
function NS.sellChanges()
  local out, seen, read = {}, {}, 0
  local g = type(KeboldsShinyDB) == "table" and KeboldsShinyDB.sell or nil
  if type(g) == "table" then for _ in pairs(g) do read = read + 1 end end
  for _, r in ipairs(data().recipes) do
    if r.made > 0 and not seen[r.made] and r.sell ~= r.sell0 then
      seen[r.made] = true
      out[#out + 1] = { item = r.made, name = r.name, was = r.sell0, now = r.sell }
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out, read
end
-- The Row size setting: "compact" | "normal" | "roomy". Every list follows on its next layout; the window grows to
-- the width the larger rows need.
function NS.setDensity(v)
  local S = settings()
  S.density = (v == "compact" or v == "roomy") and v or "normal"
  S = settings()   -- the window's width is held to the new minimum
  if frame then
    frame:SetSize(S.win.w, S.win.h)
    if type(frame.SetResizeBounds) == "function" then
      pcall(frame.SetResizeBounds, frame, minW(), WIN.minH, WIN.maxW, WIN.maxH)
    elseif type(frame.SetMinResize) == "function" then
      pcall(frame.SetMinResize, frame, minW(), WIN.minH)
    end
    UI.refit()   -- buttons, labelled dropdowns and labels take the new font and their new widths
    for _, pg in pairs(pages) do pg.w = nil end   -- every page lays itself out again when it is next shown
    refresh()
  end
  return S.density
end
NS.minW = minW
function NS.resetScroll()   -- the list of the page showing starts at its top again
  local page = currentPage()
  if page and type(page.table) == "table" then page.table.offset = 0 end
end
function NS.frame() return frame end
NS.TAB_LABEL, NS.TAB_ORDER, NS.ALIAS, NS.plain = TAB_LABEL, TAB_ORDER, ALIAS, plain
function NS.current() return current end   -- the route on the Level page: { prof, ctx, route, st, sig, from, to }
function NS.setCurrent(c) current = c end  -- LedgerLevel.lua keeps it here: scans, the footer and the slash commands read it

-- The Level page's plan as plain text, to hand to somebody: a header saying whose plan it is, the profession, the
-- range and how old the prices are, then the page's lines as /kebold print writes them (every section, folded or
-- not). Returns the text and the number of lines. NS.copyPlan (LedgerSettings.lua) shows it in a box to copy from.
function NS.planText()
  local page = pages.route
  if not (page and page.rows) then return "", 0 end
  local list = page.rows(page) or {}
  local c = current or NS.state()
  local P, name = who()
  local out = {}
  local function put(s) out[#out + 1] = s end
  put("Kebold's Shiny - leveling plan for " .. (P and (name .. " (" .. FACTION[P.faction] .. ", planned as a new character)") or (try(UnitName, "player") or "my character")))
  if P then
    put("Legacy ranks: Working Overtime " .. P.overtime .. ", Master Chef " .. P.chef .. ", Bartering " .. P.bartering
      .. ". Vendor prices: the original game's list" .. (P.bartering > 0 and (" less " .. 5 * P.bartering .. "%") or "") .. ".")
    if P.note ~= "" then put("Note: " .. P.note) end
  end
  if c then
    local got, total, age = priceStatus(c.prof, c.st)
    local now = try(time) or 0
    local day = type(date) == "function" and try(date, "%Y-%m-%d", now - age * 86400) or nil
    put(c.prof .. " " .. c.from .. " to " .. c.to .. ". Auction prices of " .. tostring(try(GetRealmName) or "this realm") .. ": "
      .. (got == 0 and "none scanned" or (got .. " of " .. total .. " items scanned, the oldest " .. ageWord(age) .. (day and (" (" .. day .. ")") or ""))) .. ".")
  end
  put("")
  for _, row in ipairs(list) do
    local line = row.left or (row.cols and table.concat(row.cols, "  ")) or ""
    for _, k in ipairs({ "time", "c1", "c2", "right" }) do
      if row[k] and row[k] ~= "" then line = line .. "   " .. row[k] end
    end
    line = UI.plainText(line):gsub("%s+$", "")
    if row.section and #out > 0 and out[#out] ~= "" then put("") end
    if line ~= "" or out[#out] ~= "" then put(line) end
  end
  return table.concat(out, "\n"), #out
end

-- for tests
KeboldsShiny_Build = build
