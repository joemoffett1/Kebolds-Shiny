-- Kebold's Shiny: the Settings page
-- The numbers the calculations use (NS.setOpt), the switches (NS.setSwitch), the model of the page
-- (NS.buildSettings: every setting and every choice as a line) and the page itself: cards in a stack.
-- Also here, because they belong to "Plan for" profiles: a small question window (NS.confirm) and the window the
-- plan is copied from (NS.copyPlan, /kebold copy). The profiles themselves live in Ledger.lua (NS.who, NS.setProfile,
-- NS.newProfile, NS.editProfile, NS.renameProfile, NS.deleteProfile).

local NS = KeboldsShinyNS
local UI = KeboldsShinyUI
local E = NS.E
local floor, ceil, max, min, abs = math.floor, math.ceil, math.max, math.min, math.abs
local DIM, RED, GOLD, WHITE, GREEN = NS.DIM, NS.RED, NS.GOLD, NS.WHITE, NS.GREEN
local money, itemName, settings, try = NS.money, NS.itemName, NS.settings, NS.try
local ORANGE = "|cffff9020"   -- the colour a plan for somebody else is marked with (also in the window's head)

local OPTIONS = {
  { key = "timeValue", label = "Your time is worth", unit = " g an hour", step = 5, min = 0, max = 500, hint = "What an hour of casting costs.",
    tip = "The cheapest route adds this for every hour of casting, so it will not send you through 400 crafts to save a few silver." },
  { key = "cap", label = "AH sales count up to this share of what is listed", unit = "%", step = 10, min = 0, max = 100, hint = "Past it, crafts count at vendor value.",
    tip = "Past this share of what is already listed, a step's extra crafts count at vendor value." },
  { key = "cut", label = "Auction house cut", unit = "%", step = 1, min = 0, max = 20, hint = "Taken off every AH sale.",
    tip = "The share of a sale the auction house keeps." },
  { key = "minListed", label = "Listings needed before an AH price counts", unit = "", step = 1, min = 1, max = 20, hint = "Fewer listings: no AH sale price.",
    tip = "A product with fewer units listed than this is not counted as sold at the auction house." },
  { key = "depth", label = "A list price is the average of the cheapest", unit = " units", values = { 1, 5, 10, 20, 50, 100 }, hint = "So one bait listing barely counts.",
    tip = "One unit posted at 1 copper barely moves an average of 20." },
  { key = "gap", label = "Seconds between casts", unit = " s", step = 0.5, min = 0, max = 5, hint = "Added to every cast.",
    tip = "Time lost between two casts (clicking, bags), added to each recipe's cast time." },
  { key = "minPH", label = "Worth making stops when a craft earns less than", unit = " g an hour", step = 5, min = 0, max = 500, hint = "For the Worth making count.",
    tip = "The number of a recipe worth making stops where the next craft earns less than this an hour." },
  -- Legacy talents: your own rank unless one is typed in (game = the rank read from the game, which is these two's
  -- default). A plan for somebody else has its own ranks in its profile ("Plan for").
  { key = "overtime", label = "Working Overtime rank (Legacy)", unit = " of 5", step = 1, min = 0, max = 5, talent = "Working Overtime", game = function() return (NS.legacyRank("Working Overtime")) end,
    tip = "The chance of a point on crafts that are not orange: +2 points a rank. This overrides your own rank; Reset uses the rank read from the game." },
  { key = "chef", label = "Master Chef rank (Legacy)", unit = " of 5", step = 1, min = 0, max = 5, talent = "Master Chef", game = function() return (NS.legacyRank("Master Chef")) end,
    tip = "Chance of one extra item on a Cooking craft: 10% a rank. This overrides your own rank; Reset uses the rank read from the game." },
}

-- An option's value when nothing was chosen: the engine's default, or for a Legacy talent your own rank.
local function optDefault(o)
  if o.game then return o.game() or 0 end
  return E.defaults[o.key] or 0
end
-- A Legacy talent the collector has not found (never read, or a client that gives neither the talent's known spell
-- id nor its English name) counts as rank 0, and the page says so instead of showing a 0 as if it were read.
local NOT_READ = "not read from the game: type your rank"
local UNREAD_TIP = "Legacy talents are read by themselves every few minutes, in any language of the game. If yours have not been read yet, or this one could not be found, type your rank in the Legacy talents card."
local function rankRead(name)
  local rank, found = NS.legacyRank(name)
  return rank, found == true
end
local function defaultText(o)
  if o.game then
    local _, found = rankRead(o.talent)
    return found and "Default: your own rank, read from the game." or "Default: 0. Your rank was not read from the game: type your rank."
  end
  return "Default: " .. tostring(E.defaults[o.key] or 0) .. o.unit .. "."
end

local function optValue(o)
  local v = settings().opts[o.key]
  if v == nil then v = optDefault(o) end
  return v or 0
end

-- Stores one number of the calculations: clamped to its range (or snapped to its list of values), and forgotten
-- when it equals the default. nil puts the default back. Every control and every line comes here.
function NS.setOpt(key, value)
  local S = settings()
  local o
  for _, x in ipairs(OPTIONS) do
    if x.key == key then o = x end
  end
  if not o then return end
  local v = tonumber(value)
  if v ~= nil then
    if o.values then
      local best, gap
      for _, x in ipairs(o.values) do
        local d = abs(x - v)
        if not gap or d < gap then best, gap = x, d end
      end
      v = best
    else
      v = max(o.min, min(o.max, v))
    end
  end
  S.opts[key] = (v ~= nil and v ~= optDefault(o)) and v or nil
  NS.bump()
  NS.refresh()
end

-- "Reset all numbers": every number this page's list owns goes back to its default, in place. What else lives in
-- S.opts (Count gear at disenchant value, the Route settings' most to pay for a point) is not this button's.
function NS.resetOpts()
  local opts = settings().opts
  for _, o in ipairs(OPTIONS) do opts[o.key] = nil end
  NS.bump()
  NS.refresh()
end

local function optStep(o, dir)
  local v = optValue(o)
  if o.values then
    local at = 1
    for i, x in ipairs(o.values) do
      if x == v then at = i end
    end
    v = o.values[max(1, min(#o.values, at + dir))]
  else
    v = v + dir * o.step
  end
  NS.setOpt(o.key, v)
end

-- The window back in the middle of the screen at its first size and scale.
function NS.resetWindow()
  local w = settings().win
  w.x, w.y, w.w, w.h, w.scale = nil, nil, math.max(NS.WIN.w, NS.minW()), NS.WIN.h, 1
  local f = NS.frame()
  if f then
    pcall(f.SetScale, f, 1)
    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetSize(w.w, w.h)
  end
  NS.layout()
  NS.refresh()
end

local function dayText(t)
  t = tonumber(t)
  if not t or t <= 0 then return "?" end
  return (type(date) == "function" and try(date, "%Y-%m-%d", t)) or "?"
end

-- What the addon has read from the game and what it shipped with, as { label, value } pairs (the About card).
local aboutAt, aboutRows
local function aboutData()
  if aboutRows and aboutAt == NS.version() then return aboutRows end
  local out = {}
  local c = NS.collected()
  local profs, nProfs = {}, 0
  for _, p in ipairs(NS.data().profs) do
    local rec = NS.recipesOf(p)   -- by name, else by the profession's id (a client that is not in English)
    if type(rec) == "table" then
      nProfs = nProfs + 1
      profs[#profs + 1] = p .. " " .. dayText(rec.time) .. (type(rec.who) == "string" and (" (" .. rec.who .. ")") or "")
    end
  end
  out[#out + 1] = { "Profession windows read", nProfs == 0 and "none yet: open a profession window" or table.concat(profs, ", ") }
  local function count(t)
    local n, last = 0, 0
    for _, rec in pairs(type(t) == "table" and t or {}) do
      n = n + 1
      local at = type(rec) == "table" and tonumber(rec.time) or 0
      if at > last then last = at end
    end
    return n, last
  end
  local nT, lastT = count(c.trainers)
  local nM, lastM = count(c.merchants)
  out[#out + 1] = { "Trainers read", nT == 0 and "none yet" or (nT .. ", the last on " .. dayText(lastT)) }
  out[#out + 1] = { "Vendors read", nM == 0 and "none yet" or (nM .. ", the last on " .. dayText(lastM) .. " (prices with your discounts)") }
  out[#out + 1] = { "Legacy talents read", type(c.legacy) == "table" and dayText(c.legacy.time) or "not yet (/keboldcollect legacy)" }
  local nSell = 0
  for _ in pairs(type(KeboldsShinyDB) == "table" and type(KeboldsShinyDB.sell) == "table" and KeboldsShinyDB.sell or {}) do nSell = nSell + 1 end
  out[#out + 1] = { "Vendor values read in game", tostring(nSell) }
  local nItems, newest = 0, nil
  for _, line in pairs(NS.realmItems()) do
    nItems = nItems + 1
    local d = type(line) == "string" and tonumber(line:match("^(%d+);")) or nil
    if d and (not newest or d > newest) then newest = d end
  end
  local myFaction = try(UnitFactionGroup, "player")   -- prices are kept per realm and faction: each faction has its own auction house
  out[#out + 1] = { "Auction prices on " .. tostring(try(GetRealmName) or "this realm") .. ((myFaction == "Alliance" or myFaction == "Horde") and (" (" .. myFaction .. ")") or ""),
    nItems == 0 and "none yet: scan at the auction house" or (nItems .. " items, the newest from " .. dayText(newest and (NS.DAY_ZERO + newest * 86400 + 43200) or nil)) }
  local d = NS.data()
  local nIt = 0
  for _ in pairs(d.items) do nIt = nIt + 1 end
  out[#out + 1] = { "Shipped with the addon", #d.recipes .. " recipes in " .. #d.profs .. " professions, " .. nIt .. " items"
    .. (type(KeboldsShinyPlaces) == "table" and ", trainer and vendor places (original game)" or "") }
  out[#out + 1] = { "Profiles", tostring(#NS.profiles()) }
  aboutAt, aboutRows = NS.version(), out
  return out
end

-- Row size: how roomy every list is (UI.density in the kit reads settings().density).
local DENSITY_TEXT = { compact = "Compact", normal = "Normal", roomy = "Roomy" }
local DENSITY_HINT = { compact = "20 px lines in the small font: the most lines on screen.", normal = "24 px lines in the game's normal font, with space between the columns.",
  roomy = "28 px lines with wider gaps." }
local DENSITY_TIP = "How tall the lines of every list are and how large their text: compact, normal or roomy. The window is at least 1010 wide with normal rows (1050 with roomy ones, 920 with compact ones)."

local LONG = { tooltips = "Kebold lines on item tooltips", strip = "Recipe figures at the profession window", ahButton = "Kebold button at the auction house",
  profButton = "Kebold button above the profession window", minimap = "Kebold button at the minimap", coins = "Coin icons for money",
  icons = "Item icons in the lists", plain = "Plain look instead of Blizzard's", dock = "Open beside the auction house",
  ahFollow = "Open Kebold's auction house tab when a scan starts", salesAuto = "Read your own auctions at each auction house visit",
  deGear = "Count gear at disenchant value" }

function NS.buildSettings()
  local S = settings()
  local P, pname = NS.who()
  local out = {}
  -- form = true: a line the page shows as a control in one of its cards, not as a line
  local function add(row)
    row.form = true
    out[#out + 1] = row
    return row
  end
  add({ left = GOLD .. "Plan for|r  " .. DIM .. "whose plan the Level and Craft pages make|r" })
  add({ left = "   Planning for", right = P and (ORANGE .. pname .. "|r") or "Me",
    tip = { "Me: your own character as the game shows it. A profile is a plan for somebody else." } })
  if P then
    add({ left = "   Their faction", right = NS.FACTION[P.faction] })
    add({ left = "   Their Working Overtime rank", right = P.overtime .. " of 5" })
    add({ left = "   Their Master Chef rank", right = P.chef .. " of 5" })
    add({ left = "   Their Bartering rank", right = P.bartering .. " of 2" })
    if P.note ~= "" then add({ left = "   Note", right = P.note }) end
    add({ left = DIM .. "   Planned as a new character: no recipes known, no bags, vendor prices from the original game's list less Bartering.|r" })
  end
  local names = NS.profiles()
  if #names > 0 then add({ left = "   Profiles", right = table.concat(names, ", ") }) end

  add({ left = "" })
  add({ left = GOLD .. "Numbers the calculations use|r", right = DIM .. "now|r" })
  for _, o in ipairs(OPTIONS) do
    local v = optValue(o)
    add({ left = "   " .. o.label, right = ((S.opts[o.key] ~= nil) and GOLD or "") .. v .. o.unit .. ((S.opts[o.key] ~= nil) and "|r" or ""),
      action = function(button) optStep(o, button == "RightButton" and -1 or 1) end,
      tip = { o.tip or "", defaultText(o) .. " A changed value is shown in gold." } })
  end

  add({ left = "" })
  add({ left = GOLD .. "Where things show|r" })
  for _, sw in ipairs(NS.SWITCHES) do
    local on = sw.get(S)
    add({ left = "   " .. LONG[sw.key], right = on and "on" or "off", action = function() NS.setSwitch(sw.key, not sw.get(settings())) end, tip = { sw.tip } })
    if sw.key == "tooltips" then
      add({ left = "   Tooltip lines", right = S.tipMode == "short" and "first two lines" or "all lines", action = function()
        S.tipMode = S.tipMode == "short" and "full" or "short"
        NS.refresh()
      end, tip = { "All lines: every line Kebold has for the item. First two lines: the rest shows while Shift is held." } })
    elseif sw.key == "strip" then
      add({ left = "   Where the recipe figures sit", right = S.strip == "top" and "above the window" or "under the recipe", action = function()
        if NS.setStrip then NS.setStrip(S.strip == "top" and "pane" or "top") end
      end, tip = { "Under the recipe: a small block inside the profession window, bottom left, with a Kebold and a Scan button. Above the window: a strip of the same figures." } })
    elseif sw.key == "ahButton" then
      add({ left = "   Where the auction house button sits", right = S.ahButton == "title" and "above the title bar" or "under the window", action = function()
        S.ahButton = S.ahButton == "title" and "tabs" or "title"
        if NS.applyEntry then pcall(NS.applyEntry) end
        NS.refresh()
      end, tip = { "Under the window: at the right end of its row of tabs. Above the title bar: at the right." } })
    end
  end
  add({ left = "   Row size", right = DENSITY_TEXT[S.density] or S.density, density = S.density, action = function()
    local order = UI.DENSITY_ORDER
    for k, key in ipairs(order) do
      if key == S.density then NS.setDensity(order[k % #order + 1]) return end
    end
    NS.setDensity("normal")
  end, tip = { DENSITY_TIP } })
  add({ left = "   Window scale", right = string.format("%.2f", S.win.scale), action = function(button)
    if NS.setScale then NS.setScale(S.win.scale + (button == "RightButton" and -0.05 or 0.05)) end
  end, tip = { "The window's size on screen, 0.8 to 1.2." } })

  -- Waylaid crates (LedgerCrates.lua): not engine options, kept under S.crates
  if NS.crateOptions then
    add({ left = "" })
    add({ left = GOLD .. "Waylaid crates|r  " .. DIM .. "from guide sites of the beta; the Artisan reward seen in game|r" })
    for _, o in ipairs(NS.crateOptions()) do
      add({ left = "   " .. o.label, right = o.text(), crateOpt = o.key,
        action = function(button) o.set(o.get() + (button == "RightButton" and -1 or 1)) end,
        tip = { o.tip, o.hint } })
    end
  end
  -- Craftsman's Writs (LedgerWrits.lua): the reputation typed in, kept under S.writs
  if NS.writOptions then
    add({ left = "" })
    add({ left = GOLD .. "Craftsman's Writs|r  " .. DIM .. "from guide sites of the beta, not seen in game|r" })
    for _, o in ipairs(NS.writOptions()) do
      add({ left = "   " .. o.label, right = o.text(), writOpt = o.key,
        action = function(button) o.set(o.get() + (button == "RightButton" and -1 or 1) * (o.step or 1)) end,
        tip = { o.tip, o.hint } })
    end
  end

  add({ left = "" })
  add({ left = GOLD .. "Read from the game|r" })
  add({ left = "   Faction", right = tostring(try(UnitFactionGroup, "player") or "?") })
  local function talent(name, what, guess)
    local b = NS.legacyBonus(name)
    local rank, found = rankRead(name)
    add({ left = "   " .. name .. " (Legacy talent)", right = found and ("rank " .. rank .. (b and string.format(": +%.0f%%", 100 * b) or "")) or NOT_READ,
      talent = name, notRead = not found,
      tip = { what, (not found and UNREAD_TIP) or (b and "The percentage is read from the talent's own text in the game.") or guess } })
  end
  talent("Working Overtime", "Added to the chance of a point on every craft that is not orange.", "No rank bought.")
  do   -- Master Chef: 10 points a rank. Its text in game reads "30%" at every rank, so the text is not used.
    local rank, found = rankRead("Master Chef")
    add({ left = "   Master Chef (Legacy talent)", right = found and ("rank " .. rank .. (rank > 0 and (": +" .. 10 * rank .. "%") or "")) or NOT_READ,
      talent = "Master Chef", notRead = not found,
      tip = { "The chance that a Cooking craft makes one extra item.", (not found and UNREAD_TIP) or (rank > 0 and "Counted as 10% for each rank.") or "No rank bought." } })
  end
  add({ left = "   Vendor prices", right = DIM .. (P and "for this profile: the original game's list less Bartering" or "as seen at vendors you visited, your discounts included") .. "|r" })
  for _, pair in ipairs(aboutData()) do
    add({ left = "   " .. pair[1], right = DIM .. pair[2] .. "|r", about = true })
  end

  add({ left = "" })
  add({ left = GOLD .. "Scans|r  " .. DIM .. "at the auction house (the Prices page has them all)|r" })
  do
    local ids, n = E.allItems(NS.data())
    add({ left = "   Scan everything: every item of all nine professions", right = #ids .. " items, about " .. ceil(#ids * 0.65 / 60) .. " min  " .. GOLD .. "[scan]|r",
      action = function() NS.scanButton("everything") end,
      tip = { "The same as /keboldscan everything: " .. n.mats .. " materials, then " .. n.parts .. " parts, " .. n.products .. " other products (gear too) and "
          .. n.patterns .. " recipe items, so a scan stopped early has done the useful part.",
        "An item's saved price is replaced when the scan reaches it: one stopped early keeps the older prices of what it did not reach.",
        "Keep the auction house open. /keboldscan stop ends it." } })
  end

  -- The choices of the set shown (yours, or the active profile's): one group each for how a material is got, where a
  -- product sells and the recipes skipped. The page shows them in its Choices card with a Remove button on every
  -- line and Clear all on every group; `action` (what /kebold print and the tests can run) removes the one line.
  local any = false
  local whose = P and (" for " .. pname) or ""
  local function choices(key, title, tbl, text, label, field)
    local keys = {}
    for id in pairs(tbl) do keys[#keys + 1] = id end
    if #keys == 0 then return end
    table.sort(keys)
    if any then out[#out + 1] = { left = "" } end
    any = true
    out[#out + 1] = { left = GOLD .. title .. whose .. "|r", right = DIM .. #keys .. "|r", band = true, choiceHead = key, n = #keys, clear = function()
      for id in pairs(tbl) do tbl[id] = nil end   -- emptied in place: the table is the one the plans read
      NS.bump()
      NS.refresh()
    end }
    for _, id in ipairs(keys) do
      local function remove()
        tbl[id] = nil
        NS.bump()
        NS.refresh()
      end
      local row = { left = "   " .. label(id), right = text and (GOLD .. "[" .. (text[tbl[id]] or tostring(tbl[id])) .. "]|r") or (GOLD .. "[skipped]|r"),
        menu = true, choice = key, action = remove, remove = remove }
      row[field] = id
      if field ~= "recipe" then row.item = id end
      out[#out + 1] = row
    end
  end
  choices("pick", "Materials and parts set to Buy, Make or Have it", S.pick, NS.PICK_TEXT, NS.itemText, "pickItem")
  choices("sell", "Products with their own Sells at (vendor, auction house or disenchant)", S.sellPick, NS.SELL_TEXT, NS.itemText, "sellItem")
  choices("skip", "Recipes skipped in routes", S.exclude, nil, function(id)
    local r = NS.data().byId[id]
    return r and (r.name .. DIM .. "  " .. r.prof .. "|r") or ("recipe " .. id)
  end, "recipe")
  if not any then
    out[#out + 1] = { left = DIM .. (P and ("No choices for " .. pname .. " yet.") or "No choices of your own yet.")
      .. " A right-click on a line of the Level or the Craft page sets how a material is got, where a product sells, or skips a recipe; they are then listed here.|r" }
  end

  add({ left = "" })
  add({ left = "Put every number back to its default", right = DIM .. "[reset]|r", resetAll = true, action = function()
    NS.resetOpts()
  end })
  return out, "Settings"
end


local SWITCHES = {
  { key = "tooltips", text = "Tooltip lines", tip = "Adds what an item costs at the last scan, what making it costs, and what a recipe item teaches to item tooltips.",
    get = function(S) return S.tooltips ~= false end, set = function(S, v) S.tooltips = v and true or false end },
  { key = "strip", text = "Recipe figures", tip = "Sale, profit and the chance of a point of the recipe selected in the profession window: in a small block under the recipe, or in a strip above the window.",
    get = function(S) return S.strip ~= false and S.strip ~= "off" end, set = function(S, v)
      S.strip = v and (S.strip == "top" and "top" or "pane") or "off"
      if NS.stripRefresh then NS.stripRefresh() end
    end },
  { key = "ahButton", text = "Auction house button", tip = "The Kebold button at the auction house, with the scan bar beside it.",
    get = function(S) return S.ahButton ~= "off" end, set = function(S, v) S.ahButton = v and "tabs" or "off" end, entry = true },
  { key = "profButton", text = "Profession button", tip = "The Kebold button above the profession window.",
    get = function(S) return S.profButton ~= false end, set = function(S, v) if v then S.profButton = nil else S.profButton = false end end, entry = true },
  { key = "minimap", text = "Minimap button", tip = "The Kebold button at the minimap. Drag it to move it around the rim.",
    get = function(S) return not S.minimap.hide end, set = function(S, v) S.minimap.hide = (not v) or nil end, entry = true },
  { key = "coins", text = "Coin icons", tip = "Gold, silver and copper as coin pictures instead of the letters g, s and c.",
    get = function(S) return S.coins ~= false end, set = function(S, v) if v then S.coins = nil else S.coins = false end end },
  { key = "icons", text = "Item icons", tip = "An icon in front of every line that is about an item or a recipe.",
    get = function(S) return S.icons ~= false end, set = function(S, v) if v then S.icons = nil else S.icons = false end end },
  { key = "plain", text = "Plain look", tip = "Plain coloured widgets instead of Blizzard's, in case something looks broken. Type /reload afterwards: windows that are already built keep their look until then.",
    get = function(S) return S.skin == "plain" end, set = function(S, v)
      S.skin = v and "plain" or "auto"
      NS.say((v and "Plain look on." or "Plain look off.") .. " Type /reload: windows that are already built keep their look until then.")
    end },
  -- settings that only had a slash command, or none
  { key = "dock", text = "Open beside the auction house", tip = "Opened from the auction house's Kebold button, the window sits beside the auction house when there is room for it on the screen, until you drag it. Off, or without the room: it opens where you left it.",
    get = function(S) return S.win.dock ~= false end, set = function(S, v) S.win.dock = v and true or false end },
  { key = "ahFollow", text = "Show scans at the auction house", tip = "Kebold's tab inside the auction house opens by itself when a scan starts (/keboldah follow on | off).",
    get = function(S) return S.ahFollow ~= false end, set = function(S, v) S.ahFollow = v and true or false end },
  { key = "salesAuto", text = "Read my auctions", tip = "Asks the game for the list of your own auctions once at each auction house visit, so My sales can tell sold from expired (/keboldsales auto on | off).",
    get = function() return not (type(KeboldsShinyDB) == "table" and KeboldsShinyDB.salesAuto == false) end,
    set = function(_, v)
      if type(KeboldsShinyDB) == "table" then KeboldsShinyDB.salesAuto = v and true or false end
    end },
  -- an engine option (S.opts.deGear), off unless switched on: the disenchant tables are the original game's
  { key = "deGear", text = "Gear at disenchant value", tip = "With Sells at on best price, gear on Auto counts as disenchanted when its disenchant materials sell for more than where it would sell otherwise (a vendor). The disenchant cast is added to the craft's time. Off by default: the disenchant table is the original game's until your own disenchants have been logged (20 per band), and you need an enchanter. One product can be set to Disenchant by hand whatever this says.",
    get = function(S) return S.opts.deGear == true end, set = function(S, v)
      S.opts.deGear = v and true or nil
      NS.bump()
    end },
}
NS.SWITCHES = SWITCHES

-- Flips one of the switches above (the page's check boxes and the model's lines both come here).
function NS.setSwitch(key, on)
  local S = settings()
  for _, sw in ipairs(SWITCHES) do
    if sw.key == key then
      sw.set(S, on and true or false)
      if sw.entry and NS.applyEntry then pcall(NS.applyEntry) end
    end
  end
  NS.refresh()
end


-- ---- a question before something is thrown away ------------------------------------------------------------------------
-- NS.confirm(text, yesText, onYes): a small window of our own in the middle of the screen with the question, a
-- button that does it and Cancel. Escape cancels. One question at a time: a new one replaces the old.
local ask
function NS.confirm(text, yesText, onYes)
  if not ask then
    ask = UI.window("KeboldsShinyConfirm", UIParent, 360, 130, { noPortrait = true, top = 26, bottom = 36, left = 8, right = 8 })
    pcall(ask.SetFrameStrata, ask, "DIALOG")
    ask:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
    ask.title:SetText("Kebold's Shiny")
    ask.question = UI.text(ask.body, "body", "")
    ask.question:SetPoint("TOPLEFT", 8, -8)
    ask.question:SetPoint("BOTTOMRIGHT", -8, 4)
    ask.question:SetJustifyH("LEFT")
    ask.question:SetJustifyV("TOP")
    ask.question:SetWordWrap(true)
    ask.run = false
    ask.yes = UI.button(ask, "Yes", 110, function()
      local fn = ask.run
      ask.run = false
      ask:Hide()
      if type(fn) == "function" then fn() end
    end)
    ask.no = UI.button(ask, "Cancel", 84, function()
      ask.run = false
      ask:Hide()
    end)
    ask.no:SetPoint("BOTTOMRIGHT", -10, 8)
    ask.yes:SetPoint("RIGHT", ask.no, "LEFT", -6, 0)   -- beside Cancel, however wide Cancel is
    if type(UISpecialFrames) == "table" then table.insert(UISpecialFrames, "KeboldsShinyConfirm") end
  end
  if UI.closePopup then UI.closePopup("other") end   -- an open panel (Route settings) would lie over the question
  ask.run = onYes
  ask.question:SetText(text or "")
  ask.yes.label:SetText(yesText or "Yes")
  ask:Show()
  return ask
end
function NS.confirmFrame() return ask end   -- for tests


-- ---- the plan as text to copy -------------------------------------------------------------------------------------------
-- NS.copyPlan(): NS.planText() (Ledger.lua) in an edit box with all of it selected, so Ctrl+C takes it; /kebold copy
-- opens it. The game gives an addon no way to write to the clipboard, so the box is how every addon hands text over.
local copyWin
function NS.copyPlan(text)
  local count
  if text == nil then
    local ok, t, n = pcall(NS.planText)
    if not ok then
      NS.say("Error: " .. tostring(t))
      return
    end
    text, count = t, n
  end
  if not copyWin then
    local f = UI.window("KeboldsShinyCopy", UIParent, 620, 460, { noPortrait = true, top = 26, bottom = 36, left = 8, right = 8 })
    copyWin = f
    pcall(f.SetFrameStrata, f, "DIALOG")
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f.title:SetText("Kebold's Shiny - copy the plan")
    f.text = ""
    local ok, sf = pcall(CreateFrame, "ScrollFrame", "KeboldsShinyCopyScroll", f.body, "UIPanelScrollFrameTemplate")
    if not ok or type(sf) ~= "table" then   -- no such template: a bare scroll frame moved by the mouse wheel
      sf = CreateFrame("ScrollFrame", nil, f.body)
      sf:EnableMouseWheel(true)
      sf:SetScript("OnMouseWheel", function(self, delta)
        local now = tonumber((self:GetVerticalScroll())) or 0
        local most = tonumber((self:GetVerticalScrollRange())) or 0
        pcall(self.SetVerticalScroll, self, max(0, min(most, now - delta * 40)))
      end)
    end
    f.scroll = sf
    sf:SetPoint("TOPLEFT", 6, -6)
    sf:SetPoint("BOTTOMRIGHT", -26, 6)
    local e = CreateFrame("EditBox", nil, sf)
    f.edit = e
    e:SetMultiLine(true)
    e:SetAutoFocus(false)
    pcall(e.SetFontObject, e, "ChatFontNormal")
    e:SetWidth(560)
    e:SetScript("OnEscapePressed", function() f:Hide() end)
    e:SetScript("OnTextChanged", function(self, user)   -- a box to copy from, not to write in
      if user == true then
        self:SetText(f.text)
        self:HighlightText()
      end
    end)
    pcall(sf.SetScrollChild, sf, e)
    f.info = UI.text(f, "dim", "")
    f.info:SetPoint("BOTTOMLEFT", 12, 12)
    f.bClose = UI.button(f, "Close", 80, function() f:Hide() end)
    f.bClose:SetPoint("BOTTOMRIGHT", -10, 8)
    f.bAll = UI.button(f, "Select all", 90, function()
      f.edit:SetFocus()
      f.edit:HighlightText()
    end, { "Select all", "Marks the whole text again; then Ctrl+C copies it." })
    f.bAll:SetPoint("RIGHT", f.bClose, "LEFT", -4, 0)
    if type(UISpecialFrames) == "table" then table.insert(UISpecialFrames, "KeboldsShinyCopy") end
  end
  local f = copyWin
  f.text = text or ""
  f.edit:SetText(f.text)
  f.info:SetText((count and (count .. " lines. ") or "") .. "Press Ctrl+C to copy, then paste it into chat, a mail or a note.")
  f:Show()
  f.edit:SetFocus()
  f.edit:HighlightText()
  return f
end
function NS.copyWindow() return copyWin end   -- for tests


-- ---- the Settings page -----------------------------------------------------------------------------------------------
-- Cards in a stack inside a scroll area, so the page works at the smallest window too:
--   planfor   whose plan is made: Me or a profile, and the profile's name, faction, three ranks and note
--   numbers   the numbers of the calculations: a slider, a box and Reset each, with a line saying what it is
--   legacy    your own two Legacy ranks, read from the game, with an override
--   shown     where things show: the switches, and where the tooltip lines, recipe figures and AH button sit
--   choices   the choices of the set shown (yours or the profile's): a Remove button a line, Clear all a group
--   about     what was read from the game and when, what the addon shipped with, and three buttons
-- Every card's height comes from what is in it. NS.buildSettings above stays the model: it is what /kebold print
-- writes and what the tests read.
-- what the three "where" dropdowns say for the saved values
local TIP_TEXT = { full = "All lines", short = "First two lines" }
local STRIP_TEXT = { pane = "Under the recipe", top = "Above the window" }
local AH_TEXT = { tabs = "Under the window", title = "Above the title bar" }
local LINE = 24
local ROW2 = 36    -- a number's line: its name, and under it what it is and its default
local CTL_X = 348  -- where the controls start; the labels have the width before it

local function isLegacy(o) return o.game ~= nil end

local function choiceRows(rows)
  local out = {}
  for _, row in ipairs(rows) do
    if not row.form then out[#out + 1] = row end
  end
  return out
end

local function buildPage(page)
  local form = { num = {}, checks = {}, all = {}, prof = {} }
  page.form = form
  local function keep(w)
    form.all[#form.all + 1] = w
    return w
  end
  page.area = UI.scrollArea(page.frame)
  page.stack = UI.stack(page.area.content, 8)
  page.stack:SetPoint("TOPLEFT", page.area.content, "TOPLEFT", 0, 0)
  page.cards = {}
  local function card(key, title, height, opts)
    opts = opts or {}
    opts.height = height
    local c = UI.card(page.stack, title, opts)
    page.cards[key] = c
    page.stack:Add(c)
    return c
  end
  local function label(parent, s, x, y, width, token)
    local fs = UI.text(parent, token or "body", s)
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetWidth(width or (CTL_X - 12))
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    return fs
  end
  local function number(parent, o, y, tall)
    label(parent, o.label, 4, y - 4)
    if tall then label(parent, (o.hint and (o.hint .. " ") or "") .. defaultText(o), 4, y - 19, nil, "dim") end
    local ctl = keep(UI.slider(parent, { min = o.min, max = o.max, step = o.step, values = o.values, w = 268, sw = 100, unit = o.unit,
      isChanged = function() return settings().opts[o.key] ~= nil end }, function() return optValue(o) end, function(v) NS.setOpt(o.key, v) end))
    ctl:SetPoint("TOPLEFT", CTL_X, y - (tall and 6 or 0))
    UI.tip(ctl.slider, { o.label, o.tip or "Drag, or type a value into the box.", defaultText(o) })
    form.num[o.key] = ctl
  end

  -- 1. Plan for: Me or a profile
  local c0 = card("planfor", "Plan for", LINE + 34)
  local pf = form.prof
  label(c0.content, "Planning for", 4, -4, 120)
  pf.who = keep(UI.dropdown(c0.content, 170, function()
    local _, name = NS.who()
    return name and (ORANGE .. name .. "|r") or "Me"
  end, function()
    local _, name = NS.who()
    local items = { { title = true, text = "Plan for" },
      { radio = true, checked = name == nil, text = "Me", tip = "Your own character, as the game shows it.", func = function() NS.setProfile(nil) end } }
    for _, n in ipairs(NS.profiles()) do
      items[#items + 1] = { radio = true, checked = name == n, text = n .. "  (" .. NS.FACTION[settings().profiles[n].faction] .. ")", func = function() NS.setProfile(n) end }
    end
    return items
  end, { "Plan for", "Me, or one of the profiles: a plan for somebody else. The Level and Craft pages have the same choice." }))
  pf.who:SetPoint("TOPLEFT", 130, 0)
  pf.new = UI.button(c0.content, "New profile", 96, function()
    NS.setProfile(NS.newProfile("Player"))
  end, { "New profile", "A plan for somebody else. It starts as a new character of your own faction with no Legacy ranks; name it and set the rest below." })
  pf.new:SetPoint("LEFT", pf.who, "RIGHT", 8, 0)   -- each after the one before: a button is as wide as its text
  pf.delete = UI.button(c0.content, "Delete", 70, function()
    local _, name = NS.who()
    if not name then return end
    NS.confirm("Delete the profile " .. name .. " with its ranges and choices?", "Delete", function() NS.deleteProfile(name) end)
  end, { "Delete this profile", "Removes the profile shown with its ranges and choices. It asks first." })
  pf.delete:SetPoint("LEFT", pf.new, "RIGHT", 4, 0)
  pf.only = {}   -- shown only while a profile is the one planned for
  local function only(w)
    pf.only[#pf.only + 1] = w
    return w
  end
  local y = -LINE
  only(label(c0.content, "Name", 4, y - 4, 120))
  pf.name = only(UI.edit(c0.content, 164))
  pf.name:SetPoint("TOPLEFT", 134, y)
  pcall(pf.name.SetMaxLetters, pf.name, 24)
  local function rename(self)
    local _, name = NS.who()
    if name and NS.profileText(self:GetText(), 24) ~= name then   -- compared as it would be saved ("|" doubled)
      local now = NS.renameProfile(name, self:GetText())
      if now == name then self:SetText(name) end   -- empty, "Me" or taken: the old name stays
    end
  end
  pf.name:SetScript("OnEnterPressed", function(self)
    rename(self)
    self:ClearFocus()
  end)
  pf.name:SetScript("OnEditFocusLost", rename)
  UI.tip(pf.name, { "Name", "What the profile is called. Enter applies it." })
  y = y - LINE
  only(label(c0.content, "Faction", 4, y - 4, 120))
  pf.faction = only(keep(UI.dropdown(c0.content, 120, function()
    local P = NS.who()
    return P and NS.FACTION[P.faction] or ""
  end, function()
    local P, name = NS.who()
    local items = { { title = true, text = "Faction" } }
    for _, side in ipairs({ "A", "H" }) do
      items[#items + 1] = { radio = true, checked = P ~= nil and P.faction == side, text = NS.FACTION[side], func = function() NS.editProfile(name, "faction", side) end }
    end
    return items
  end, { "Faction", "Decides which trainers and vendors count and which recipes the character can learn at all." })))
  pf.faction:SetPoint("TOPLEFT", 130, y)
  local function rank(key, text, hi, hint, tip)
    y = y - LINE
    only(label(c0.content, text, 4, y - 4, 150))
    local st = only(keep(UI.stepper(c0.content, { min = 0, max = hi, step = 1, w = 30, tip = { text, tip } }, function()
      local P = NS.who()
      return P and P[key] or 0
    end, function(v)
      local _, name = NS.who()
      if name then NS.editProfile(name, key, v) end
    end)))
    st:SetPoint("TOPLEFT", 160, y)
    only(label(c0.content, hint, 256, y - 4, 400, "dim"))
    pf[key] = st
  end
  rank("overtime", "Working Overtime rank", 5, "0 to 5: +2 points to the chance of a point a rank", "The Legacy talent: added to the chance of a point on every craft that is not orange.")
  rank("chef", "Master Chef rank", 5, "0 to 5: the chance of one extra item on a Cooking craft", "The Legacy talent: 10% a rank up to 4, 50% at 5.")
  rank("bartering", "Bartering rank", 2, "0 to 2: vendor prices 5% lower a rank", "The Legacy talent. Applied to the original game's vendor price list, because the prices you saw at vendors carry your own discounts.")
  y = y - LINE
  only(label(c0.content, "Note", 4, y - 4, 120))
  pf.note = only(UI.edit(c0.content, 420))
  pf.note:SetPoint("TOPLEFT", 134, y)
  pcall(pf.note.SetMaxLetters, pf.note, 200)
  local function renote(self)
    local P, name = NS.who()
    if P and NS.profileText(self:GetText(), 200) ~= P.note then NS.editProfile(name, "note", self:GetText()) end
  end
  pf.note:SetScript("OnEnterPressed", function(self)
    renote(self)
    self:ClearFocus()
  end)
  pf.note:SetScript("OnEditFocusLost", renote)
  UI.tip(pf.note, { "Note", "Anything worth remembering about this plan; it is written into the copied plan." })
  pf.rows = 7   -- the lines a profile's controls take, the first one included
  pf.text = UI.text(c0.content, "dim", "")
  pf.text:SetJustifyH("LEFT")
  pf.text:SetJustifyV("TOP")
  pf.text:SetWordWrap(true)

  -- 2. the numbers of the calculations, and the window's size on screen
  local plainOpts, legacy = {}, {}
  for _, o in ipairs(OPTIONS) do
    if isLegacy(o) then legacy[#legacy + 1] = o else plainOpts[#plainOpts + 1] = o end
  end
  local c1 = card("numbers", "Numbers", (#plainOpts + 1) * ROW2)
  y = 0
  for _, o in ipairs(plainOpts) do
    number(c1.content, o, y, true)
    y = y - ROW2
  end
  label(c1.content, "Window scale", 4, y - 4)
  label(c1.content, "The Kebold window's size on screen. Default: 1 x.", 4, y - 19, nil, "dim")
  form.scale = keep(UI.slider(c1.content, { min = 0.8, max = 1.2, step = 0.05, w = 268, sw = 100, unit = " x",
    isChanged = function() return settings().win.scale ~= 1 end }, function() return settings().win.scale end, function(v)
      if NS.setScale then NS.setScale(v or 1) end
    end))
  form.scale:SetPoint("TOPLEFT", CTL_X, y - 6)
  form.resetAll = c1:SetAction(UI.button(c1, "Reset all numbers", 130, function()
    NS.confirm("Put every number back to its default? (Your own Legacy rank overrides too.)", "Reset", function()
      NS.resetOpts()
    end)
  end, { "Reset all numbers", "Puts every number of the calculations back to its default (the Legacy rank overrides too). It asks first." }))

  -- 3. Legacy talents: your own ranks, read from the game, unless one is typed in
  local c2 = card("legacy", "Legacy talents (yours)", #legacy * LINE + 18)
  y = 0
  for _, o in ipairs(legacy) do
    number(c2.content, o, y)
    y = y - LINE
  end
  form.game = UI.text(c2.content, "dim", "")
  form.game:SetPoint("TOPLEFT", 4, y - 2)
  form.game:SetJustifyH("LEFT")
  form.game:SetWordWrap(false)
  form.legacyNote = UI.text(c2.content, "body", "")
  form.legacyNote:SetPoint("TOPLEFT", 4, y - 18)
  form.legacyNote:SetJustifyH("LEFT")
  form.legacyNote:SetWordWrap(false)

  -- 3b. Waylaid crates (LedgerCrates.lua): the Performance Bonus rank
  if NS.crateOptions then
    local opts = NS.crateOptions()
    local wopts = NS.writOptions and NS.writOptions() or {}   -- Craftsman's Writs: the same card, under the crates' lines
    local cc = card("crates", "Waylaid crates", (#opts + #wopts) * LINE + 2)
    form.crate, form.writ = {}, {}
    y = 0
    for i, o in ipairs(opts) do
      label(cc.content, o.label, 4, y - 4, 220)
      local st = keep(UI.stepper(cc.content, { min = o.min, max = o.max, step = 1, w = o.w or 36, tip = { o.label, o.tip } }, o.get, o.set))
      st:SetPoint("TOPLEFT", 230, y)
      label(cc.content, o.hint, 336, y - 4, 350, "dim")
      form.crate[o.key] = st
      y = y - LINE
    end
    for _, o in ipairs(wopts) do
      label(cc.content, o.label, 4, y - 4, 220)
      local st = keep(UI.stepper(cc.content, { min = o.min, max = o.max, step = o.step or 1, w = o.w or 36, tip = { o.label, o.tip } }, o.get, o.set))
      st:SetPoint("TOPLEFT", 230, y)
      label(cc.content, o.hint, 346, y - 4, 340, "dim")
      form.writ[o.key] = st
      y = y - LINE
    end
  end

  -- 4. where things show: the switches in two columns, then where three of them sit
  local half = ceil(#SWITCHES / 2)
  local c3 = card("shown", "Look and where things show", half * LINE + 6 + 4 * LINE)
  for i, sw in ipairs(SWITCHES) do
    local c = keep(UI.check(c3.content, sw.text, function() return sw.get(settings()) end, function(v) NS.setSwitch(sw.key, v) end, { LONG[sw.key] or sw.text, sw.tip }))
    c:SetPoint("TOPLEFT", i > half and CTL_X or 4, -((i - 1) % half) * LINE)
    form.checks[sw.key] = c
  end
  local py = -(half * LINE + 6)
  label(c3.content, "Row size of the lists", 4, py - 4)
  form.density = keep(UI.dropdown(c3.content, 150, function() return DENSITY_TEXT[settings().density] or "Normal" end, function()
    local items = { { title = true, text = "Row size" } }
    for _, key in ipairs(UI.DENSITY_ORDER) do
      items[#items + 1] = { radio = true, checked = settings().density == key, text = DENSITY_TEXT[key], tip = DENSITY_HINT[key], func = function() NS.setDensity(key) end }
    end
    return items
  end, { "Row size", DENSITY_TIP }))
  form.density:SetPoint("TOPLEFT", CTL_X, py)
  py = py - LINE
  label(c3.content, "Tooltip lines: how many", 4, py - 4)
  form.tipMode = keep(UI.dropdown(c3.content, 150, function() return TIP_TEXT[settings().tipMode] end, function()
    local items = { { title = true, text = "Tooltip lines" } }
    for _, mode in ipairs({ "full", "short" }) do
      items[#items + 1] = { radio = true, checked = settings().tipMode == mode, text = TIP_TEXT[mode],
        tip = mode == "full" and "Every line Kebold has for the item." or "Only the first two lines; hold Shift for all of them.", func = function()
          settings().tipMode = mode
          NS.refresh()
        end }
    end
    return items
  end, { "Tooltip lines", "All lines, or only the first two (all of them while Shift is held)." }))
  form.tipMode:SetPoint("TOPLEFT", CTL_X, py)
  label(c3.content, "Recipe figures at the profession window: where", 4, py - 4 - LINE)
  form.stripPlace = keep(UI.dropdown(c3.content, 150, function() return STRIP_TEXT[settings().strip == "top" and "top" or "pane"] end, function()
    local items = { { title = true, text = "Recipe figures" } }
    for _, place in ipairs({ "pane", "top" }) do
      items[#items + 1] = { radio = true, checked = (settings().strip == "top") == (place == "top"), text = STRIP_TEXT[place],
        tip = place == "pane" and "A small block inside the profession window, under the recipe, bottom left." or "A strip above the profession window.", func = function()
          if NS.setStrip then NS.setStrip(place) end
        end }
    end
    return items
  end, { "Where the recipe figures sit", "Inside the profession window under the recipe, or in a strip above the window." }))
  form.stripPlace:SetPoint("TOPLEFT", CTL_X, py - LINE)
  label(c3.content, "Kebold button at the auction house: where", 4, py - 4 - 2 * LINE)
  form.ahPlace = keep(UI.dropdown(c3.content, 150, function() return AH_TEXT[settings().ahButton == "title" and "title" or "tabs"] end, function()
    local items = { { title = true, text = "Auction house button" } }
    for _, place in ipairs({ "tabs", "title" }) do
      items[#items + 1] = { radio = true, checked = settings().ahButton == place, text = AH_TEXT[place],
        tip = place == "tabs" and "Under the auction house window, at the right end of its row of tabs." or "Above the auction house window's title bar, at the right.", func = function()
          settings().ahButton = place
          if NS.applyEntry then pcall(NS.applyEntry) end
          NS.refresh()
        end }
    end
    return items
  end, { "Where the auction house button sits", "Under the window at the right end of its row of tabs, or above the title bar." }))
  form.ahPlace:SetPoint("TOPLEFT", CTL_X, py - 2 * LINE)

  -- 5. the choices of the set shown: lines made as they are needed (page.choiceLines), filled by paint
  card("choices", "Your choices", 28)
  page.choiceLines = {}

  -- 6. about: what was read, what shipped, and three buttons
  local c6 = card("about", "About and data", 60)
  page.aboutLines = {}
  form.bReport = UI.button(c6.content, "Report what this client has", 190, function()
    UI.report()
    NS.notice("The report is in chat, and saved for the next /reload.", "info")
  end, { "Report what this client has", "The same as /kebold ui: which of Blizzard's templates and functions this client has, printed in chat and saved with the addon's data." })
  form.bWindow = UI.button(c6.content, "Reset window position and size", 210, function()
    NS.confirm("Put the Kebold window back in the middle of the screen at its first size and scale?", "Reset", NS.resetWindow)
  end, { "Reset window position and size", "For a window that ended up off the screen or at an odd size. It asks first." })
  form.bEverything = NS.scanControl(UI.button(c6.content, "Scan everything", 120, function() NS.scanButton("everything") end,
    { "Scan everything", "Every item of all nine professions, about 40 minutes at the auction house (/keboldscan everything). A scan stopped early keeps what it reached." }))
end

local function relayout(page)
  page.area:SetContentHeight(page.stack:Layout(page.area.contentW))
end

-- One line of the Choices card: a group's head (its name, how many, Clear all) or one choice (what, how, Remove).
local function choiceLine(page, i)
  local line = page.choiceLines[i]
  if line then return line end
  local content = page.cards.choices.content
  line = CreateFrame("Button", nil, content)
  line.row = false
  line:SetHeight(UI.density().rowH)
  line:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  local hi = line:CreateTexture(nil, "HIGHLIGHT")
  hi:SetAllPoints()
  hi:SetColorTexture(1, 1, 1, 0.06)
  line.name = UI.text(line, "body", "")
  line.name:SetPoint("LEFT", 4, 0)
  line.name:SetJustifyH("LEFT")
  line.name:SetWordWrap(false)
  line.value = UI.text(line, "body", "")
  line.value:SetWidth(88)
  line.value:SetJustifyH("RIGHT")
  -- made with its longer label, so it is wide enough for both ("Clear all" on a group's head, "Remove" on a choice)
  line.button = UI.button(line, "Clear all", 76, function()
    local row = line.row
    if type(row) ~= "table" then return end
    if row.choiceHead then
      NS.confirm("Clear all " .. row.n .. " under \"" .. UI.plainText(row.left) .. "\"?", "Clear all", row.clear)
    elseif row.remove then
      row.remove()
    end
  end, function()
    local row = line.row
    if type(row) == "table" and row.choiceHead then return { "Clear all", "Removes every choice of this group. It asks first." } end
    return { "Remove", "Forgets this choice: the plans decide by themselves again." }
  end)
  line.button:SetPoint("RIGHT", -2, 0)
  line.button.fitLock = true   -- the label changes per line, the width stays the longer label's
  -- the value ends where the button begins, the name where the value begins: nothing is placed by a number that
  -- assumes the button's width
  line.value:SetPoint("RIGHT", line.button, "LEFT", -6, 0)
  line.name:SetPoint("RIGHT", line.value, "LEFT", -4, 0)
  line:SetScript("OnClick", function(self)   -- the line itself: the menu with the other choices
    local row = self.row
    if type(row) ~= "table" or row.choiceHead then return end
    local items = NS.rowMenu(row)
    if #items > 0 then UI.menu(self, items) end
  end)
  line:SetScript("OnEnter", function(self)
    if type(self.row) == "table" and not self.row.choiceHead then NS.rowEnter(self) end
  end)
  line:SetScript("OnLeave", NS.rowLeave)
  page.choiceLines[i] = line
  return line
end

-- Fills the Choices card from the model's lines and returns the height they take.
local function paintChoices(page, rows)
  local content = page.cards.choices.content
  local y, n = 2, 0
  if type(page.noChoices) ~= "table" then
    page.noChoices = UI.text(content, "dim", "")
    page.noChoices:SetPoint("TOPLEFT", 4, -4)
    page.noChoices:SetPoint("RIGHT", content, "RIGHT", -4, 0)
    page.noChoices:SetJustifyH("LEFT")
    page.noChoices:SetJustifyV("TOP")
    page.noChoices:SetWordWrap(true)
  end
  local empty = nil
  for _, row in ipairs(rows) do
    if row.choiceHead or row.choice then
      n = n + 1
      local line = choiceLine(page, n)
      line.row = row
      line:ClearAllPoints()
      line:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
      line:SetPoint("RIGHT", content, "RIGHT", 0, 0)
      line:SetHeight(UI.density().rowH)
      UI.cellFont(line.name)
      UI.cellFont(line.value)
      line.name:SetText(UI.show(row.choiceHead and row.left or (row.left:gsub("^   ", ""))))
      line.value:SetText(UI.show(row.right or ""))
      line.button.label:SetText(row.choiceHead and "Clear all" or "Remove")
      line:Show()
      y = y + UI.density().rowH
    elseif UI.blankRow(row) then
      y = y + 6
    else
      empty = row.left
    end
  end
  for i = n + 1, #page.choiceLines do
    page.choiceLines[i].row = false
    page.choiceLines[i]:Hide()
  end
  page.choiceCount = n
  if n == 0 then
    page.noChoices:SetText(empty or "")
    page.noChoices:Show()
    return 34
  end
  page.noChoices:Hide()
  return y + 2
end

-- Fills the About card and returns its height.
local function paintAbout(page)
  local content, form = page.cards.about.content, page.form
  local data = aboutData()
  for i, pair in ipairs(data) do
    local l = page.aboutLines[i]
    if not l then
      l = { name = UI.text(content, "body", ""), value = UI.text(content, "dim", "") }
      l.name:SetPoint("TOPLEFT", 4, -(i - 1) * 16 - 2)
      l.name:SetWidth(200)
      l.name:SetJustifyH("LEFT")
      l.name:SetWordWrap(false)
      l.value:SetPoint("TOPLEFT", 210, -(i - 1) * 16 - 2)
      l.value:SetPoint("RIGHT", content, "RIGHT", -4, 0)
      l.value:SetJustifyH("LEFT")
      l.value:SetWordWrap(false)
      page.aboutLines[i] = l
    end
    l.name:SetText(pair[1])
    l.value:SetText(pair[2])
  end
  local y = #data * 16 + 8
  form.bReport:ClearAllPoints()
  form.bReport:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -y)
  form.bWindow:ClearAllPoints()
  form.bWindow:SetPoint("LEFT", form.bReport, "RIGHT", 6, 0)   -- each after the one before: a button is as wide as its text
  form.bEverything:ClearAllPoints()
  form.bEverything:SetPoint("LEFT", form.bWindow, "RIGHT", 6, 0)
  return y + 26
end

NS.page({ key = "settings", title = "Settings", order = 6, icon = "Interface\\Icons\\Trade_Engineering",
  tip = { "Settings", "Whose plan is made, the numbers the calculations use, what Kebold shows, and the choices made." },
  rows = function() return NS.buildSettings() end,
  build = buildPage,
  layout = function(page, w, h, y)
    page.area:ClearAllPoints()
    page.area:SetPoint("TOPLEFT", page.frame, "TOPLEFT", 0, -y)
    page.area:Layout(w, h - y)
    relayout(page)
  end,
  paint = function(page, rows)
    local form, cards = page.form, page.cards
    local pf = form.prof
    local P, name = NS.who()
    local changed = false
    local function height(card, h)
      if card.contentH ~= h then
        card:SetContentHeight(h)
        changed = true
      end
    end
    -- Plan for
    for _, w in ipairs(pf.only) do
      if P then w:Show() else w:Hide() end
    end
    pf.delete:SetEnabled(P ~= nil, "Nothing to delete: the plan is your own.")
    if P then
      if not pf.name:HasFocus() then pf.name:SetText(name) end
      if not pf.note:HasFocus() then pf.note:SetText(P.note) end
    end
    local lines = P and pf.rows or 1
    pf.text:ClearAllPoints()
    pf.text:SetPoint("TOPLEFT", cards.planfor.content, "TOPLEFT", 4, -(lines * LINE + 4))
    pf.text:SetPoint("RIGHT", cards.planfor.content, "RIGHT", -4, 0)
    if P then
      pf.text:SetText("Planned as a new character: no recipes known, skill from the range typed in (1 to 300 to start with), nothing taken from your bags. "
        .. "Vendor prices are the original game's price list less Bartering, not the prices vendors showed you (those carry your own discounts). "
        .. "Auction prices are this realm's, and how well things sell still comes from your own auctions. "
        .. "Ranges, Buy / Make / Have it, where a product sells and skipped recipes are this profile's own. /kebold copy gives the plan as text.")
    else
      pf.text:SetText("Your own character: your skill, known recipes, bags, Legacy talents and the prices vendors showed you. "
        .. "A profile is a plan for somebody else, with their faction and Legacy ranks and their own choices.")
    end
    height(cards.planfor, lines * LINE + (P and 58 or 34))
    cards.planfor:SetTitle(P and ("Plan for: " .. name) or "Plan for")
    -- the controls
    for _, w in ipairs(form.all) do w:Refresh() end
    local over = NS.legacyBonus("Working Overtime")
    local wo, woRead = rankRead("Working Overtime")
    local chef, chefRead = rankRead("Master Chef")
    form.game:SetText("Read from the game: faction " .. tostring(try(UnitFactionGroup, "player") or "?") .. " \194\183 Working Overtime "
      .. (woRead and ("rank " .. wo .. (over and string.format(" (+%.0f%%)", 100 * over) or "")) or NOT_READ)
      .. " \194\183 Master Chef " .. (chefRead and ("rank " .. chef .. (chef > 0 and (" (+" .. 10 * chef .. "%)") or "")) or NOT_READ)
      .. " \194\183 vendor prices as seen at vendors you visited")
    form.legacyNote:SetText(P and (ORANGE .. "Not used while planning for " .. name .. ": the profile has its own ranks, in the first card.|r") or "")
    height(cards.legacy, 2 * LINE + 18 + (P and 16 or 0))
    -- the choices and the data
    cards.choices:SetTitle(P and ("Choices for " .. name) or "Your choices")
    height(cards.choices, paintChoices(page, choiceRows(rows)))
    height(cards.about, paintAbout(page))
    if changed then relayout(page) end
  end })
