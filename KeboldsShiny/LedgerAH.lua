-- Kebold's Shiny: the Kebold tab of the auction house
--   The "Kebold" button under the auction house (LedgerEntry.lua) works as a tab. Its page lies over the content
--   area of Blizzard's window and shows the Prices page of the Kebold window: the same view (NS.pricesView in
--   LedgerSalesTab.lua) painted from the same rows (NS.buildScan), so the two cannot disagree. This file owns the
--   frame inside the auction house, the watching of the other tabs, and the model of the Last scan table
--   (NS.ahRows: the items of the running or the last scan, filling in as they are read).
--
-- What is done to Blizzard's window, and nothing more:
--   * the page is a CHILD of AuctionHouseFrame (owner approved 2026-11-10), raised above its content;
--   * a click on any other tab is noticed with HookScript("OnClick") on the window's tab buttons, and a change of
--     the window's display mode with hooksecurefunc(AuctionHouseFrame, "SetDisplayMode"): both only hide our page;
--   * a click on a line asks the window for its Buy page and searches the item (NS.searchAH).
--   No field is written onto Blizzard's tables, nothing is inserted into AuctionHouseFrame.Tabs, no PanelTemplates
--   call is made on Blizzard's frames and no Blizzard script is replaced. Nothing is hooked before the page is
--   first shown. The addon never buys, posts, cancels or bids.
--
-- The logic output is row tables (NS.ahRows), read by tests/lua/ah_tab_mock.lua without a screen.

local NS, UI = KeboldsShinyNS, KeboldsShinyUI
if type(NS) ~= "table" or type(UI) ~= "table" then return end
local settings, try = NS.settings, NS.try
local DIM, RED, GREEN, GOLD = NS.DIM, NS.RED, NS.GREEN, NS.GOLD
local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min

local function isTable(x) return type(x) == "table" end
local function num(v, d) return tonumber(v) or d end

local PAD = 6                                  -- between the page's edge and the cards
-- Where the page lies inside the auction house window (below the title bar, above the strip with the gold) and
-- how far above the window's own content it is raised. /keboldah inset and /keboldah level change them.
local PLACE = { left = 4, top = 24, right = 6, bottom = 28, level = 100 }
-- Seen in game: with the page only raised by frame levels, the "Auctions" sub-tab of Blizzard's Auctions page showed
-- through at its top left. The page is therefore drawn one strata above the window's content ("HIGH"; the window
-- is "MEDIUM"), with an opaque background over its whole area. Nothing of Blizzard's is hidden or changed.
-- /keboldah strata <name> changes it, /keboldah strata auto leaves the page in the window's own strata.
local STRATA = "HIGH"
local STRATA_OK = { BACKGROUND = true, LOW = true, MEDIUM = true, HIGH = true, DIALOG = true }
-- The round portrait of the auction house lies over the page's top left corner (seen in game: it hid the start of
-- a title at x 10): the Scan card's title starts right of it.
local PORTRAIT = 56

local function place()
  local S = settings()
  local p = isTable(S.ahPage) and S.ahPage or {}
  local out = {}
  for k, v in pairs(PLACE) do out[k] = num(p[k], v) end
  out.strata = (type(p.strata) == "string" and (p.strata == "auto" or STRATA_OK[p.strata])) and p.strata or STRATA
  return out
end

local function ahFrame()
  return isTable(AuctionHouseFrame) and AuctionHouseFrame or nil
end

local function atAH()
  return type(KeboldsShinyScan_AtAuctionHouse) == "function" and KeboldsShinyScan_AtAuctionHouse() and true or false
end

local function lastScan()
  local run = type(KeboldsShinyScan_Last) == "function" and KeboldsShinyScan_Last() or nil
  return isTable(run) and isTable(run.ids) and isTable(run.state) and run or nil
end

local function progress()
  return type(KeboldsShinyScan_Progress) == "function" and KeboldsShinyScan_Progress() or nil
end

-- ---- the table's lines (no screen) ---------------------------------------------------------------------------------

local find = ""            -- the find box (one text for every copy of the view)
local cache, cacheOf = {}, nil   -- [item id] = its line, for the scan whose id list is cacheOf

local function vendorValue(id)
  local g = isTable(KeboldsShinyDB) and KeboldsShinyDB.sell or nil
  if isTable(g) and type(g[id]) == "number" then return g[id] end
  local ok, db = pcall(NS.data)
  local m = ok and isTable(db) and isTable(db.maker) and db.maker[id] or nil
  if isTable(m) and type(m.sell) == "number" then return m.sell end
  return nil
end

-- The usual price: the median of the cheapest price on the days before this reading (never the mean: one bait
-- day drags it). nil, 0 without an earlier day.
local function usualPrice(id, day)
  local H = KeboldsShinyHistory
  if not (isTable(H) and type(H.readings) == "function") then return nil, 0 end
  local ok, list = pcall(H.readings, id)
  if not ok or not isTable(list) then return nil, 0 end
  local lows = {}
  for _, r in ipairs(list) do
    if isTable(r) and type(r.low) == "number" and r.low > 0 and (day == nil or r.day ~= day) then lows[#lows + 1] = r.low end
  end
  local n = #lows
  if n == 0 then return nil, 0 end
  table.sort(lows)
  if n % 2 == 1 then return lows[(n + 1) / 2], n end
  return floor((lows[n / 2] + lows[n / 2 + 1]) / 2 + 0.5), n
end

local FAINT = "|cff5a5a5a"
local STATE_TEXT = { empty = DIM .. "none listed|r", timeout = RED .. "timeout|r", waiting = DIM .. "waiting|r", skipped = DIM .. "not reached|r" }

-- One item's line: { cols = { item, cheapest, listed, vendor value, against the usual price }, item, state, ... }.
-- state: found | empty | timeout | waiting (the scan has not reached it) | skipped (the scan ended before it).
local function lineOf(id, state)
  local c = cache[id]
  if c and c.state == state then return c end
  local name = NS.itemName(id)
  local row = { item = id, ahRow = true, state = state, name = name, tip = {} }
  local sv = vendorValue(id)
  row.vendor = sv
  local cols = { NS.itemText(id, name), STATE_TEXT[state] or "", "", sv and (sv > 0 and NS.money(sv) or (DIM .. "none|r")) or (DIM .. "?|r"), "" }
  local day
  if state == "found" then
    local L = NS.E.parseLadder(NS.realmItems()[id])
    local low = L and L.tiers[1] and L.tiers[1][1] or nil
    day = L and L.day or nil
    row.price, row.listed = low, L and L.total or nil
    if low then
      row.below = sv ~= nil and sv > 0 and low < sv
      cols[2] = row.below and (GREEN .. NS.money(low) .. "|r") or NS.money(low)
      if row.below then row.tip[#row.tip + 1] = GREEN .. "Listed below what a vendor pays for it.|r" end
      local steps = {}
      for i = 1, min(#L.tiers, 4) do steps[i] = L.tiers[i][2] .. " at " .. NS.money(L.tiers[i][1]) end
      row.tip[#row.tip + 1] = "Cheapest listings: " .. table.concat(steps, ", ") .. (#L.tiers > 4 and ", ..." or "")
    end
    cols[3] = row.listed and tostring(row.listed) or ""
  elseif state == "waiting" or state == "skipped" then
    cols[1] = DIM .. name .. "|r"
  end
  local med, days = usualPrice(id, day)
  row.usual = med
  if med and row.price then
    local pct = (row.price - med) / med * 100
    row.vs = pct
    local text = string.format("%+d%%", floor(pct + 0.5))
    cols[5] = (pct <= -20 and GREEN or (pct >= 20 and RED or "")) .. text .. ((pct <= -20 or pct >= 20) and "|r" or "") .. DIM .. " of |r" .. NS.money(med)
    row.tip[#row.tip + 1] = "Usual price " .. NS.money(med) .. ": the middle one of the cheapest prices on " .. days .. (days == 1 and " earlier day." or " earlier days.")
  elseif med then
    cols[5] = DIM .. "usual |r" .. NS.money(med)
  elseif state == "found" then
    cols[5] = FAINT .. "first reading|r"   -- nothing to compare with yet: fainter than the other dim texts
  end
  if state == "timeout" then row.tip[#row.tip + 1] = "The auction house did not answer for this item: it has no price now. Scan it again." end
  row.cols = cols
  cache[id] = row
  return row
end

local SORT_FIELD = { "name", "price", "listed", "vendor", "vs" }

-- The lines of the running or the last scan, filtered by the find box and sorted, and that scan (nil before the
-- first one of the session).
function NS.ahRows()
  local run = lastScan()
  if not run then
    return { { note = true, left = DIM .. "No scan yet this session. Pick one on the left: its items show here as they are read.|r",
      empty = { icon = "Interface\\Icons\\INV_Misc_Spyglass_03", title = "No scan yet this session",
        text = "Open the auction house and pick a scan on the left: its items show here as they are read." } } }, nil
  end
  if cacheOf ~= run.ids then cache, cacheOf = {}, run.ids end
  -- a quick scan has no items to show until it starts saving (or when it was stopped before that)
  if #run.ids == 0 and run.quick == true then
    local text = run.running and "The quick scan is reading the auction house. Its items show here when it starts saving them."
      or ("The quick scan saved nothing" .. (type(run.how) == "string" and (": " .. run.how) or "") .. ".")
    return { { note = true, left = DIM .. text .. "|r",
      empty = { icon = "Interface\\Icons\\INV_Misc_Spyglass_03", title = run.running and "Reading the auction house" or "Nothing saved", text = text } } }, run
  end
  local S = settings()
  local needle = string.lower(find or "")
  local out = {}
  for i, id in ipairs(run.ids) do
    local row = lineOf(id, run.state[id] or (run.running and "waiting" or "skipped"))
    row.order = i
    if needle == "" or string.lower(row.name):find(needle, 1, true) then out[#out + 1] = row end
  end
  local field = SORT_FIELD[S.ahSort or 0]
  if field then
    local desc = S.ahDesc and true or false
    table.sort(out, function(a, b)
      local x, y = a[field], b[field]
      if x == nil or y == nil then
        if x ~= nil or y ~= nil then return x ~= nil end   -- lines without the value go last, either way round
        return a.order < b.order
      end
      if field == "name" then x, y = string.lower(x), string.lower(y) end
      if x == y then return a.order < b.order end
      if desc then return x > y end
      return x < y
    end)
  end
  if #out == 0 then
    out[1] = { note = true, left = DIM .. "No item of this scan has \"" .. tostring(find) .. "\" in its name.|r",
      empty = { icon = "Interface\\Icons\\INV_Misc_Spyglass_03", title = "Nothing matches",
        text = "No item of this scan has \"" .. tostring(find) .. "\" in its name. Empty the find box to see them all." } }
  end
  return out, run
end

-- "Scanning 31 of 58 ..." / "Last scan: ..." above the table.
function NS.ahSummary()
  local run = lastScan()
  if not run then return "" end
  local found, empty, timeouts = 0, 0, 0
  for _, s in pairs(run.state) do
    if s == "found" then found = found + 1 elseif s == "empty" then empty = empty + 1 else timeouts = timeouts + 1 end
  end
  local counts = found .. " listed, " .. empty .. " none listed" .. (timeouts > 0 and (", " .. RED .. timeouts .. (timeouts == 1 and " timeout|r" or " timeouts|r")) or "")
  if run.running and run.quick == true and #run.ids == 0 then   -- a quick scan before it saves: what it is doing
    return GOLD .. "Scanning|r " .. (type(run.note) == "string" and run.note or "")
  end
  if run.running then
    return GOLD .. "Scanning|r " .. num(run.done, 0) .. " of " .. #run.ids .. ": " .. counts
  end
  local left = #run.ids - num(run.done, 0)
  return "Last scan: " .. num(run.done, 0) .. " of " .. #run.ids .. " items, " .. counts .. (left > 0 and (", " .. left .. " not reached") or "")
end

function NS.ahSort(k)
  local S = settings()
  if S.ahSort == k then
    if S.ahDesc then S.ahSort, S.ahDesc = nil, nil else S.ahDesc = true end   -- up, down, then the scan's own order
  else
    S.ahSort, S.ahDesc = k, nil
  end
  NS.pricesRepaintLast(true)   -- every copy of the table that is on screen
end

function NS.ahFind(text)
  find = tostring(text or "")
  NS.pricesRepaintLast(true)
end
function NS.ahFindText() return find end

-- ---- the page --------------------------------------------------------------------------------------------------------

local page
local wasBusy = false   -- a scan was running at the last tick

local function mark(on)
  local b = KeboldsShinyAHButton
  if not isTable(b) then return end
  if type(b.SetSelected) == "function" then pcall(b.SetSelected, b, on and true or false) end
  -- Blizzard's tab code disables the selected tab; ours must stay clickable: a second click closes the page (the
  -- way back should no other tab's click be noticed) and the right click opens the menu
  if on and type(b.Enable) == "function" then pcall(b.Enable, b) end
end

function NS.ahShown()
  return page ~= nil and page:IsShown() and true or false
end

function NS.ahHide()
  if page and page:IsShown() then page:Hide() end
  mark(false)
end

-- The Buy page of Blizzard's window, then the search (the page of ours would hide the result).
function NS.ahSearch(item)
  NS.ahHide()
  local ah, mode = ahFrame(), AuctionHouseFrameDisplayMode
  if ah and isTable(mode) and mode.Buy ~= nil and type(ah.SetDisplayMode) == "function" then pcall(ah.SetDisplayMode, ah, mode.Buy) end
  return NS.searchAH(item)
end

-- A click on a line. Left: search the item on the Buy tab. Shift: link it. Right: the line's menu.
function NS.ahRowClick(row, button, owner)
  if not isTable(row) or not row.item then return nil end
  if type(IsShiftKeyDown) == "function" and IsShiftKeyDown() then
    NS.linkRow(row)
    return "link"
  end
  if button == "RightButton" then
    local items = NS.rowMenu(row)
    for _, it in ipairs(items) do   -- the search of the menu must leave this page too
      if it.text == "Search the auction house" then it.func = function() NS.ahSearch(row.item) end end
    end
    local at = atAH()
    items[#items + 1] = { text = "Scan this item again", disabled = (not at) or nil, tip = (not at) and "Open the auction house first." or nil,
      func = function() NS.scanItem(row.item) end }
    UI.menu(owner, items)
    return "menu"
  end
  NS.ahSearch(row.item)
  return "search"
end

-- ---- noticing the other tabs -----------------------------------------------------------------------------------------

local hooked = setmetatable({}, { __mode = "k" })   -- buttons already watched (kept here, not on their tables)
local modeHooked, modeSeen = nil, nil

local function otherTab()
  if NS.ahShown() then NS.ahHide() end
end

local function isButton(b)
  if not isTable(b) or type(b.IsObjectType) ~= "function" then return false end
  local ok, yes = pcall(b.IsObjectType, b, "Button")
  return ok and yes and true or false
end

local function watch(b)
  if hooked[b] or b == KeboldsShinyAHButton or b == page or type(b.HookScript) ~= "function" then return end
  if pcall(b.HookScript, b, "OnClick", otherTab) then hooked[b] = true end
end

local function children(f)
  if not isTable(f) or type(f.GetChildren) ~= "function" then return {} end
  local got = { pcall(f.GetChildren, f) }
  if not got[1] then return {} end
  table.remove(got, 1)
  return got
end

-- Watches the tab buttons of the auction house: Blizzard's own (AuctionHouseFrame.Tabs, read only), every button
-- that is a direct child of the window, and buttons one level further down that hang under its bottom edge (other
-- addons keep their tabs in a holder frame). Called whenever the page shows and again a little after the auction
-- house opens, because other addons add their tabs late. Returns how many buttons are watched after it.
function NS.ahWatchTabs()
  local ah = ahFrame()
  if not ah then return 0 end
  if isTable(ah.Tabs) then
    for _, b in ipairs(ah.Tabs) do
      if isButton(b) then watch(b) end
    end
  end
  local bottom = type(ah.GetBottom) == "function" and tonumber((ah:GetBottom())) or nil
  for _, c in ipairs(children(ah)) do
    if c ~= page and isTable(c) then
      if isButton(c) then
        watch(c)
      elseif bottom then
        for _, g in ipairs(children(c)) do
          local top = isButton(g) and type(g.GetTop) == "function" and tonumber((g:GetTop())) or nil
          if top and top <= bottom + 14 then watch(g) end
        end
      end
    end
  end
  -- the window's display mode: Blizzard's tabs and most other tabs change it
  if modeHooked ~= ah and type(hooksecurefunc) == "function" and type(ah.SetDisplayMode) == "function" then
    if pcall(hooksecurefunc, ah, "SetDisplayMode", function(_, mode)
      if mode ~= modeSeen then   -- the same mode set again (a refresh) does not close the page
        modeSeen = mode
        otherTab()
      end
    end) then
      modeHooked = ah
    end
  end
  local n = 0
  for _ in pairs(hooked) do n = n + 1 end
  return n
end

-- ---- drawing ---------------------------------------------------------------------------------------------------------

-- The whole page again, from the Prices page's rows.
function NS.ahPaint()
  if not NS.ahShown() then return end
  local ok, rows = pcall(NS.buildScan)
  if not ok then
    NS.say("The Kebold tab hit an error: " .. tostring(rows))
    return
  end
  page.view:Paint(rows)
end

-- ---- building --------------------------------------------------------------------------------------------------------

local function anchor(f, ah)
  local g = place()
  if f.ahParent ~= ah then
    pcall(f.SetParent, f, ah)
    f.ahParent = ah
  end
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", ah, "TOPLEFT", g.left, -g.top)
  f:SetPoint("BOTTOMRIGHT", ah, "BOTTOMRIGHT", -g.right, g.bottom)
  -- above the window's own content; Blizzard's border and title bar are drawn far higher still
  if g.strata ~= "auto" then
    pcall(f.SetFrameStrata, f, g.strata)
  elseif f.strataNow and f.strataNow ~= "auto" and type(ah.GetFrameStrata) == "function" then
    local ok, own = pcall(ah.GetFrameStrata, ah)   -- back to the window's own
    if ok and type(own) == "string" then pcall(f.SetFrameStrata, f, own) end
  end
  f.strataNow = g.strata
  pcall(f.SetFrameLevel, f, num(ah:GetFrameLevel(), 1) + g.level)
  local w, h = num(ah:GetWidth(), 0), num(ah:GetHeight(), 0)
  if w < 500 then w = 890 end
  if h < 300 then h = 505 end
  f.w, f.h = w - g.left - g.right, h - g.top - g.bottom
end

local function build(ah)
  local f = CreateFrame("Frame", "KeboldsShinyAHPage", ah)
  f.ahParent, f.strataNow = ah, false
  anchor(f, ah)
  f:Hide()
  f:EnableMouse(true)   -- clicks do not fall through to the page of Blizzard's underneath
  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetColorTexture(0.05, 0.05, 0.07, 1)
  bg:SetAllPoints()
  if not UI.plain() and UI.hasAtlas("auctionhouse-background-index") then   -- the auction house's own backdrop, when it has one
    local art = f:CreateTexture(nil, "BORDER")
    art:SetAllPoints()
    pcall(art.SetAtlas, art, "auctionhouse-background-index")
  end
  -- the Prices page's cards: Scan on the left, Last scan, Prices by profession and Vendor values on the right
  f.view = NS.pricesView(f, { ah = true, bottom = 140, titleX = PORTRAIT, visible = NS.ahShown,
    click = function(line, button) NS.ahRowClick(rawget(line, "row"), button, line) end })
  f.view:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -PAD)
  f.view:Layout(f.w - 2 * PAD, f.h - 2 * PAD)
  f:SetScript("OnHide", function() mark(false) end)   -- hidden with the auction house, whatever closed it
  return f
end

-- The profession the scans (and the Kebold window) follow.
function NS.ahSetProf(prof)
  NS.pricesSetProf(prof)
end

-- Shows the page inside the auction house. False when there is no auction house window to show it in.
function NS.ahShow()
  local ah = ahFrame()
  if not ah or not atAH() then return false end
  if type(ah.IsShown) == "function" and not ah:IsShown() then return false end
  if not page then
    local ok, f = pcall(build, ah)
    if not ok or not isTable(f) then
      NS.say("The Kebold tab could not be built: " .. tostring(f))
      return false
    end
    page = f
  else
    anchor(page, ah)
    page.view:Layout(page.w - 2 * PAD, page.h - 2 * PAD)
  end
  modeSeen = ah.displayMode   -- read only: the mode the window is in while our page lies over it
  pcall(NS.ahWatchTabs)
  page:Show()
  mark(true)
  local ok, err = pcall(NS.ahPaint)
  if not ok then NS.say("The Kebold tab hit an error: " .. tostring(err)) end
  return true
end

-- The tab's click: shows the page, or closes it again. False when the page cannot be shown at all.
function NS.ahToggle()
  if NS.ahShown() then
    NS.ahHide()
    return true
  end
  return NS.ahShow()
end

function NS.ahPage() return page, page and page.view or nil end   -- for tests: the frame and its view

-- ---- following the scanner (called by LedgerEntry.lua) --------------------------------------------------------------

-- A scan started, from anywhere: its items go into the table and, at the auction house, the tab comes forward.
function NS.ahOnScanStarted()
  NS.pricesScanStarted()   -- the lists follow the item being read again
  if settings().ahFollow ~= false and not NS.ahShown() then NS.ahShow() end
  if NS.ahShown() then
    NS.ahPaint()
    wasBusy = true
  end
end

-- Five times a second while a scan runs, and once more with nil when it is over.
function NS.ahTick(p)
  if not NS.ahShown() then
    wasBusy = p ~= nil
    return
  end
  if p then
    if not wasBusy then NS.ahPaint() end
    wasBusy = true
    page.view:Tick(p)   -- the bar every time; the table only when an item is settled
  else
    wasBusy = false
    NS.ahPaint()        -- the counts and times may have moved with the new prices
  end
end

-- The auction house opened: other addons add their tabs a little later, so look for them a few times.
function NS.ahOnOpen()
  if not page then return end   -- nothing of Blizzard's is touched before the page was first used
  for _, d in ipairs({ 0.5, 2 }) do
    C_Timer.After(d, function() pcall(NS.ahWatchTabs) end)
  end
end

-- ---- /keboldah -------------------------------------------------------------------------------------------------------

SLASH_KEBOLDSSHINYAH1 = "/keboldah"
SLASH_KEBOLDSSHINYAH2 = "/ledgerah"   -- the name before the addon was renamed
SlashCmdList["KEBOLDSSHINYAH"] = function(msg)
  local cmd = string.lower((msg or ""):match("^%s*(.-)%s*$"))
  local S = settings()
  local function replace()
    if page and ahFrame() then
      anchor(page, ahFrame())
      page.view:Layout(page.w - 2 * PAD, page.h - 2 * PAD)
    end
    if NS.ahShown() then NS.ahPaint() end
  end
  if cmd == "" then
    if not NS.ahToggle() then NS.say("Open the auction house first.") end
  elseif cmd == "follow on" or cmd == "follow off" then
    S.ahFollow = cmd == "follow on"
    NS.say("The Kebold tab " .. (S.ahFollow and "opens" or "no longer opens") .. " when a scan starts.")
  elseif cmd:find("^level%s+%d+$") then
    if not isTable(S.ahPage) then S.ahPage = {} end
    S.ahPage.level = max(1, min(2000, tonumber(cmd:match("%d+"))))
    replace()
    NS.say("The Kebold tab's page is raised " .. S.ahPage.level .. " levels above the auction house window.")
  elseif cmd:find("^inset%s+%-?%d+%s+%-?%d+%s+%-?%d+%s+%-?%d+$") then
    local l, t, r, b = cmd:match("^inset%s+(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)$")
    if not isTable(S.ahPage) then S.ahPage = {} end
    S.ahPage.left, S.ahPage.top, S.ahPage.right, S.ahPage.bottom = tonumber(l), tonumber(t), tonumber(r), tonumber(b)
    replace()
    NS.say("The Kebold tab's page now lies " .. l .. " from the left, " .. t .. " from the top, " .. r .. " from the right and " .. b .. " from the bottom of the auction house window.")
  elseif cmd:find("^strata%s+%a+$") then
    local name = cmd:match("^strata%s+(%a+)$")
    local key = name == "auto" and "auto" or string.upper(name)
    if key == "auto" or STRATA_OK[key] then
      if not isTable(S.ahPage) then S.ahPage = {} end
      S.ahPage.strata = key
      replace()
      NS.say("The Kebold tab's page is drawn " .. (key == "auto" and "in the auction house window's own strata." or ("in the strata " .. key .. ".")))
    else
      NS.say("Strata: auto, background, low, medium, high or dialog.")
    end
  elseif cmd == "reset" then
    S.ahPage = nil
    replace()
    NS.say("The Kebold tab's page is back where it was made to lie.")
  elseif cmd == "tabs" then
    local ok, n = pcall(NS.ahWatchTabs)
    NS.say("Watching " .. tostring(ok and n or 0) .. " tab buttons of the auction house" .. (modeHooked and " and its display mode." or "; its display mode could not be watched."))
  else
    local g = place()
    NS.say("Usage: /keboldah (show or hide the tab's page) | follow on | follow off | level <n> | strata <auto | medium | high | dialog> | inset <left> <top> <right> <bottom> | reset | tabs")
    NS.say("Now: inset " .. g.left .. " " .. g.top .. " " .. g.right .. " " .. g.bottom .. ", level " .. g.level .. ", strata " .. g.strata .. ", follow " .. (S.ahFollow ~= false and "on" or "off") .. ".")
  end
end
