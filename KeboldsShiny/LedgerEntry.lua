-- Kebold's Shiny: the ways in
--   a button on the auction house with a scan bar beside it, a button above the profession window, a minimap
--   button, the addon compartment entry and a key binding (Bindings.xml).
-- Every frame here belongs to UIParent (the minimap button to Minimap) and is only ANCHORED to Blizzard's windows:
-- none of their fields is written. The auction house button works as a tab: its page (LedgerAH.lua) is the one
-- frame of ours that sits inside Blizzard's window.

local NS = KeboldsShinyNS
local UI = KeboldsShinyUI
local settings, try = NS.settings, NS.try
local floor, ceil = math.floor, math.ceil
local BOOK = "Interface\\Icons\\INV_Misc_Book_09"

BINDING_HEADER_KEBOLDSSHINY = "Kebold's Shiny"
BINDING_NAME_KEBOLDSSHINY_TOGGLE = "Open or close Kebold"

function KeboldsShiny_Toggle()
  NS.toggle()
end

function KeboldsShiny_OnCompartmentClick()
  NS.toggle()
end

local function atAH()
  return type(KeboldsShinyScan_AtAuctionHouse) == "function" and KeboldsShinyScan_AtAuctionHouse() and true or false
end

local function progress()
  return type(KeboldsShinyScan_Progress) == "function" and KeboldsShinyScan_Progress() or nil
end

-- 90 -> "1.5 min", 18 -> "18 s"
local function span(seconds)
  if seconds >= 90 then return string.format("%.1f min", seconds / 60) end
  return ceil(seconds) .. " s"
end

-- "31 / 58 · 2 timeouts · 18 s left"
function NS.scanText(p)
  if not p then return "" end
  if type(p.text) == "string" and p.text ~= "" then return p.text end   -- a quick scan says what it is doing
  return p.done .. " / " .. p.total .. (p.timeouts > 0 and (" \194\183 " .. p.timeouts .. (p.timeouts == 1 and " timeout" or " timeouts")) or "")
    .. " \194\183 " .. span(p.eta) .. " left"
end

-- ---- the scans, by name ---------------------------------------------------------------------------------------------
-- ONE table of scan names. The Prices page, the Kebold tab of the auction house, the entry menu, the footer and
-- /keboldscan's help all read it (NS.scanName, NS.scanLabel, NS.scanPresets); nothing else names a scan.
local SCAN_NAME = { plan = "This plan", route = "This route", whole = "Whole profession", mats = "Materials and parts",
  all = "Everything", fav = "Favourites", shop = "Shopping list", de = "Disenchant materials", crates = "Crate materials",
  quick = "Quick scan", gear = "Gear (quick)" }
NS.SCAN_NAME = SCAN_NAME
-- names that are already what a button says ("Scan quick scan" would not do)
local SCAN_LABEL = { quick = "Quick scan", gear = "Gear (quick)" }

-- "This plan": on a button under the heading Scan.
function NS.scanName(key)
  return SCAN_NAME[key] or tostring(key or "")
end
-- "Scan this plan": on a button or a menu line that stands alone.
function NS.scanLabel(key)
  if SCAN_LABEL[key] then return SCAN_LABEL[key] end
  local name = NS.scanName(key)
  return "Scan " .. name:sub(1, 1):lower() .. name:sub(2)
end
-- 58 -> "38 s", 3805 -> "42 min": how long a scan of that many items takes
function NS.scanTime(n)
  return n < 90 and (ceil(n * 0.65) .. " s") or (ceil(n * 0.65 / 60) .. " min")
end

-- More scans can be added from other files: NS.scanPresetAdd(function(c) return { key =, word =, count =, tip =,
-- scope =, none = } end). c is the plan's state (NS.state()); return nil to leave the scan out for now. A new key
-- gets its name with NS.SCAN_NAME[key] = "...". The function is asked every time the list is built.
local extra = {}
function NS.scanPresetAdd(fn)
  extra[#extra + 1] = fn
end

-- Why the quick scan cannot be asked for now although the auction house is open: the game allows its one request
-- for the whole house once per 15 minutes. nil when it can.
function NS.quickWhy()
  local wait = type(KeboldsShinyScan_QuickWait) == "function" and try(KeboldsShinyScan_QuickWait) or 0
  if type(wait) ~= "number" or wait <= 0 then return nil end
  return "The game allows the whole-auction-house request once per 15 minutes: ready in " .. span(wait) .. ". " .. SCAN_NAME.gear .. " works meanwhile."
end

-- The scans the buttons and menus offer, in their order. Each:
--   key     plan | route | whole | mats | all | fav | ...
--   word    what /keboldscan gets
--   count   items it would look up now
--   name    "This plan"            label   "Scan this plan"
--   scope   "Blacksmithing 152 to 225" (what it covers, may be nil)
--   info    "58 items · 38 s", or why there is nothing to scan
--   text    "Scan this plan (Blacksmithing 152 to 225, 58 items, 38 s)": the whole of it on one line
--   tip
--   blocked why it cannot run now although the auction house is open (the quick scan's 15 minutes), or nil
function NS.scanPresets()
  local c = NS.state()
  local word = string.lower(c.prof)
  local function count(w)
    local ok, ids = pcall(NS.scanList, w)
    return (ok and type(ids) == "table") and #ids or 0
  end
  local base = 0
  do
    local items, seen = type(KeboldsShinyScanItems) == "table" and KeboldsShinyScanItems or {}, {}
    for _, list in ipairs({ items.mats or {}, items.parts or {} }) do
      for _, id in ipairs(list) do
        if not seen[id] then
          seen[id] = true
          base = base + 1
        end
      end
    end
  end
  local favs = 0
  for _ in pairs(NS.settings().fav) do favs = favs + 1 end
  local list = {}
  -- the two quick scans come first: one request for the whole house, or one browse of the gear
  if type(KeboldsShinyScan_HasQuick) == "function" and type(KeboldsShiny_QuickItems) == "function" then
    local ok, ids, gear = pcall(KeboldsShiny_QuickItems)
    local n, g = (ok and type(ids) == "table") and #ids or 0, 0
    for _ in pairs((ok and type(gear) == "table") and gear or {}) do g = g + 1 end
    local why = NS.quickWhy()
    local wait = why and try(KeboldsShinyScan_QuickWait) or 0
    list[#list + 1] = { key = "quick", word = "quick", count = n, blocked = why,
      info = why and ("once per 15 min \194\183 ready in " .. span(wait)) or "whole auction house \194\183 about a minute \194\183 once per 15 min",
      text = SCAN_LABEL.quick .. " (whole auction house, " .. n .. " items Kebold knows, about a minute, once per 15 min)",
      tip = "One request for every auction: a full price ladder for each of the " .. n .. " items Kebold knows, and \"none listed\" for the ones without an auction. "
        .. "The game allows it once per 15 minutes. If the server does not answer within 30 seconds it reads gear only instead (" .. SCAN_NAME.gear .. ")." }
    list[#list + 1] = { key = "gear", word = "gear", count = g,
      info = "armour and weapons \194\183 cheapest price and number listed",
      text = SCAN_LABEL.gear .. " (armour and weapons, cheapest price and number listed, no price steps)",
      tip = "One browse of all armour and weapons, uncommon and better: per item the cheapest price and how many are listed, without the price steps a normal scan reads. "
        .. "Enough for the Disenchant page; a reading from today with more price steps is kept." }
  end
  for _, p in ipairs({
    { key = "plan", word = word, count = count(word), scope = string.format("%s %d to %d", c.prof, c.from, c.to),
      tip = "What the recipes this plan could use buy, and what they make when sales count at the auction house." },
    { key = "route", word = "route", count = count("route"), none = "no route yet",
      tip = "Only the items of the route on the Level page: a quick refresh before buying." },
    { key = "whole", word = word .. " all", count = count(word .. " all"), scope = c.prof,
      tip = "Every material, part, product and recipe item of the profession." },
    { key = "mats", word = "", count = base,
      tip = "The materials of all nine professions and the parts they make." },
    { key = "all", word = "everything", count = count("everything"), about = true,
      tip = "Every item any recipe makes, uses or is taught by. Materials first, so a scan stopped early has done the useful part." },
  }) do list[#list + 1] = p end
  if favs > 0 then
    list[#list + 1] = { key = "fav", word = "fav", count = count("fav"), scope = favs .. (favs == 1 and " recipe" or " recipes"),
      tip = "What your favourite recipes make and everything needed to make them. Mark one with a right-click on a recipe." }
  end
  for _, fn in ipairs(extra) do
    local ok, p = pcall(fn, c)
    if ok and type(p) == "table" and p.key then list[#list + 1] = p end
  end
  -- every scan gets its name and its texts here, whoever added it
  for _, p in ipairs(list) do
    p.count = tonumber(p.count) or 0
    p.word = p.word or ""
    p.name = p.name or NS.scanName(p.key)
    p.label = p.label or NS.scanLabel(p.key)
    local size = p.count > 0 and (p.count .. " items, " .. (p.about and "about " or "") .. NS.scanTime(p.count)) or (p.none or "nothing to scan")
    p.info = p.info or (p.count > 0 and (p.count .. " items \194\183 " .. NS.scanTime(p.count)) or (p.none or "nothing to scan"))
    p.text = p.text or (p.label .. " (" .. (p.scope and (p.scope .. ", ") or "") .. size .. ")")
    p.tip = p.tip or ""
  end
  return list
end

-- /keboldscan's help ends with the scans by name (called by the scanner's usage text).
function KeboldsShiny_ScanHelp()
  local ok, list = pcall(NS.scanPresets)
  if not ok or type(list) ~= "table" then return end
  local parts = {}
  for _, p in ipairs(list) do
    parts[#parts + 1] = p.name .. " = /keboldscan" .. (p.word ~= "" and (" " .. p.word) or "")
  end
  NS.say("The scans by the names on the Prices page: " .. table.concat(parts, "; ") .. ".")
end

-- Where a running scan's progress shows. ONE place at a time:
--   "ah"      the Kebold tab inside the auction house, when its page is showing (its Scan card)
--   "page"    the Kebold window on its Prices page (the same Scan card)
--   "footer"  the Kebold window on any other page (the bar in its footer)
--   "float"   neither is on screen: the small bar beside the Kebold button under the auction house
-- The minimap button's tooltip says it in words whenever it is asked.
function NS.progressOwner()
  if NS.ahShown and NS.ahShown() then return "ah" end
  local f = NS.frame()
  if f and f:IsShown() then return settings().tab == "scan" and "page" or "footer" end
  return "float"
end

-- The menu of the auction house button and the minimap button.
function NS.entryMenu()
  local at, busy = atAH(), progress() ~= nil
  local items = { { title = true, text = "Kebold's Shiny" } }
  for _, p in ipairs(NS.scanPresets()) do
    items[#items + 1] = { text = p.text, disabled = (not at) or busy or p.blocked ~= nil,
      tip = (not at) and "Open the auction house first." or (busy and "A scan is running." or (p.blocked or p.tip)),
      func = function() NS.scanButton(p.word) end }
  end
  items[#items + 1] = { text = "Stop scan", disabled = not busy, func = function()
    if type(KeboldsShinyScan_Stop) == "function" then KeboldsShinyScan_Stop() end
  end }
  items[#items + 1] = { check = true, checked = settings().ahFollow ~= false, text = "Open the Kebold tab when a scan starts",
    tip = "At the auction house every scan, typed ones too, switches to the Kebold tab so its items show as they are read.",
    func = function() settings().ahFollow = (settings().ahFollow == false) and true or false end }
  items[#items + 1] = { divider = true }
  for _, name in ipairs(NS.TAB_ORDER) do
    items[#items + 1] = { text = NS.TAB_LABEL[name], func = function() NS.showTab(name) end }
  end
  return items
end

-- ---- the auction house button and the scan bar ---------------------------------------------------------------------

local ahTab, ahTitle, bar
local BAR_UNDER = 4     -- the gap between the tab row under the auction house and the small scan bar below it (a guess)
local dragged = false   -- the window was moved by hand during this auction house visit: leave it where it is

local function ahFrame()
  return type(AuctionHouseFrame) == "table" and AuctionHouseFrame or nil
end

-- The Kebold window, beside the auction house when it is docked there (toggles; `open` = true only opens).
function NS.openDocked(open)
  local f = NS.frame()
  local was = f and f:IsShown()
  if open and was then return end
  NS.toggle()
  if was then return end
  -- beside the auction house when the switch is on and there is room for the window there (NS.dock says no
  -- otherwise and leaves it at its own place); with the switch off a window still docked from before is put back
  if settings().win.dock and not dragged and ahFrame() and NS.dock then
    NS.dock(ahFrame())
  elseif not settings().win.dock and NS.isDocked and NS.isDocked() and NS.undock then
    NS.undock()
  end
end

-- Left: Kebold page inside the auction house, like any other tab (a second click closes it again). Without
-- that page (no auction house window to put it in) the Kebold window opens beside it as before.
local function ahClick(self, button)
  if button == "RightButton" then
    UI.menu(self, NS.entryMenu())
    return
  end
  if NS.ahToggle then
    local ok, done = pcall(NS.ahToggle)
    if ok and done then return end
  end
  NS.openDocked()
end

local AH_TIP = { "Kebold's Shiny", "Left-click: the Kebold tab, with the scans and what the last one found. Click again to go back.", "Right-click: scans and the Kebold window." }

local function ahButton()
  local S = settings()
  if S.ahButton == "off" then return nil end
  local ah = ahFrame()
  local b
  if S.ahButton == "title" then
    if not ahTitle then
      ahTitle = UI.button(UIParent, "Kebold", 70, ahClick, AH_TIP)
      ahTitle:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    end
    b = ahTitle
    b:ClearAllPoints()
    if ah then b:SetPoint("BOTTOMRIGHT", ah, "TOPRIGHT", -28, -2) else b:SetPoint("TOP", UIParent, "TOP", 200, -40) end
  else
    if not ahTab then
      ahTab = UI.tab(UIParent, UI.plain() and "Kebold" or ("|T" .. BOOK .. ":14:14:0:0|t Kebold"), ahClick, AH_TIP)
      ahTab:RegisterForClicks("LeftButtonUp", "RightButtonUp")
      ahTab:SetSelected(false)
    end
    b = ahTab
    b:ClearAllPoints()
    -- the tab band under the window, right-aligned: Blizzard's and other addons' tabs start from the left
    if ah then b:SetPoint("TOPRIGHT", ah, "BOTTOMRIGHT", -6, 2) else b:SetPoint("TOP", UIParent, "TOP", 200, -40) end
  end
  KeboldsShinyAHButton = b
  return b
end

local function hideAH()
  if ahTab then ahTab:Hide() end
  if ahTitle then ahTitle:Hide() end
end

local function showAH()
  hideAH()
  local b = ahButton()
  if b and atAH() then b:Show() end
  return b
end

local function scanBar()
  if not bar then
    bar = UI.progress(UIParent, 240, 18)
    KeboldsShinyScanBar = bar
    bar:SetFrameStrata("HIGH")
    bar.stop = UI.button(bar, "Stop", 44, function()
      if type(KeboldsShinyScan_Stop) == "function" then KeboldsShinyScan_Stop() end
    end, "Ends the scan and keeps what it has read so far.")
    bar:Hide()
  end
  -- The small bar only shows while neither the Kebold tab's page nor the Kebold window is on screen
  -- (NS.progressOwner). It must not lie on the tab row under the auction house (seen in game: it covered other
  -- addons' tabs there): [ bar ][ Stop ] hang UNDER that row, below the Kebold tab; with the button above the
  -- title bar they sit to its left, where there are no tabs.
  local b = KeboldsShinyAHButton
  local ah = ahFrame()
  bar.stop:ClearAllPoints()
  bar:ClearAllPoints()
  if type(b) == "table" and b:IsShown() and b == ahTitle then
    bar.stop:SetPoint("RIGHT", b, "LEFT", -6, 0)
  elseif type(b) == "table" and b:IsShown() then
    bar.stop:SetPoint("TOPRIGHT", b, "BOTTOMRIGHT", 0, -BAR_UNDER)
  elseif ah then
    bar.stop:SetPoint("TOPRIGHT", ah, "BOTTOMRIGHT", -6, -(32 + BAR_UNDER))
  else
    bar.stop:SetPoint("TOP", UIParent, "TOP", 120, -42)
  end
  bar:SetPoint("RIGHT", bar.stop, "LEFT", -4, 0)
  return bar
end

-- One look at the running scan, five times a second while one runs. The body runs inside pcall and the ticker
-- always either stops (ticking = false) or books its next look, so one error in a bar or a page cannot leave
-- `ticking` set with nothing scheduled, which would stop every later scan's progress from showing this session.
local ticking = false
local tickFails = 0
local function tickBody()
  local p = progress()
  if NS.onScanTick then pcall(NS.onScanTick, p) end   -- the window's own footer bar
  if NS.ahTick then pcall(NS.ahTick, p) end           -- Kebold page inside the auction house
  if not p then
    if bar then bar:Hide() end
    return false
  end
  if not bar then scanBar() end
  bar:Set(p.done, p.total, NS.scanText(p))
  if NS.progressOwner() == "float" then bar:Show() else bar:Hide() end   -- one place at a time (NS.progressOwner)
  return true
end
local function tick()
  local ok, more = pcall(tickBody)
  if ok then
    tickFails = 0
  else
    tickFails = tickFails + 1
    -- keep going while a scan runs; a ticker that fails every time stops after a minute's worth and starts
    -- afresh with the next scan
    local okP, p = pcall(progress)
    more = okP and p ~= nil and tickFails < 300
  end
  if more ~= true then
    ticking = false
    tickFails = 0
    return
  end
  if not pcall(C_Timer.After, 0.2, tick) then ticking = false end
end
function NS.scanTickState() return ticking end   -- for tests

-- Called by the scanner for every scan that starts, typed ones too.
function KeboldsShiny_OnScanStarted(total, label)
  scanBar()
  if NS.ahOnScanStarted then pcall(NS.ahOnScanStarted, total, label) end   -- the scan's items show on the Kebold tab
  if not ticking then
    ticking = true
    tick()
  end
end

-- ---- the button above the profession window ----------------------------------------------------------------------

local profButton
local function profFrame()
  return type(ProfessionsFrame) == "table" and ProfessionsFrame or nil
end

-- With the strip above the profession window showing, the button sits at the strip's right end; without it, above
-- the window's top right corner.
local stripNow
function NS.placeProfButton(strip)
  stripNow = strip
  local pf = profFrame()
  if not profButton then return end
  profButton:ClearAllPoints()
  if type(strip) == "table" then
    profButton:SetPoint("LEFT", strip, "RIGHT", 4, 0)
  elseif pf then
    profButton:SetPoint("BOTTOMRIGHT", pf, "TOPRIGHT", -40, 2)
  end
end

function NS.onProfessionShown()
  local pf = profFrame()
  -- with Kebold's block inside the recipe pane (LedgerPane.lua) its own Kebold button replaces this one
  local inPane = NS.stripPlace ~= nil and NS.stripPlace() == "pane"
  if not profButton and pf and settings().profButton ~= false and not inPane then
    profButton = UI.button(UIParent, "Kebold", 74, function() NS.toggle() end, { "Kebold's Shiny", "Open or close Kebold." })
    KeboldsShinyProfButton = profButton
    profButton:SetFrameStrata("HIGH")
    profButton:SetPoint("BOTTOMRIGHT", pf, "TOPRIGHT", -40, 2)
    if not UI.plain() then
      local icon = profButton:CreateTexture(nil, "OVERLAY")
      icon:SetTexture(BOOK)
      icon:SetSize(14, 14)
      icon:SetPoint("LEFT", 6, 0)
      profButton.label:ClearAllPoints()
      profButton.label:SetPoint("CENTER", 8, 0)
    end
    if stripNow then NS.placeProfButton(stripNow) end
  end
  if profButton then
    if pf and pf:IsShown() and settings().profButton ~= false and not inPane then profButton:Show() else profButton:Hide() end
  end
end

-- ---- the minimap button ----------------------------------------------------------------------------------------------

local mm
local function placeMinimap()
  local angle = math.rad(settings().minimap.angle or 215)
  local radius = (tonumber((Minimap:GetWidth())) or 140) / 2 + 6
  if radius < 40 then radius = 76 end
  mm:ClearAllPoints()
  mm:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function minimapTip()
  local lines = { "Kebold's Shiny" }
  if NS.status then
    local ok, text = pcall(NS.status)
    if ok and text then lines[#lines + 1] = text end
  end
  local p = progress()
  lines[#lines + 1] = p and ("Scanning: " .. NS.scanText(p)) or "No scan running."
  lines[#lines + 1] = "|cff909090Left-click: open or close. Right-click: scans and tabs. Drag to move it.|r"
  return lines
end

function NS.minimapButton()
  if mm or type(Minimap) ~= "table" then return mm end
  mm = CreateFrame("Button", "KeboldsShinyMinimapButton", Minimap)
  mm:SetSize(31, 31)
  mm:SetFrameStrata("MEDIUM")
  mm:SetFrameLevel(8)
  mm:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  mm:RegisterForDrag("LeftButton")
  if UI.plain() then
    local bg = mm:CreateTexture(nil, "BACKGROUND")
    bg:SetColorTexture(0.1, 0.1, 0.14, 0.95)
    bg:SetPoint("CENTER")
    bg:SetSize(20, 20)
    local fs = mm:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("CENTER")
    fs:SetText("L")
  else
    local icon = mm:CreateTexture(nil, "BACKGROUND")
    icon:SetTexture(BOOK)
    icon:SetSize(20, 20)
    icon:SetPoint("TOPLEFT", 7, -5)
    local border = mm:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    mm:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  end
  mm:SetScript("OnClick", function(self, button)
    if button == "RightButton" then UI.menu(self, NS.entryMenu()) else NS.toggle() end
  end)
  mm:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
      local mx, my = Minimap:GetCenter()
      local px, py = GetCursorPosition()
      local scale = tonumber((Minimap:GetEffectiveScale())) or 1
      mx, my, px, py = tonumber(mx) or 0, tonumber(my) or 0, tonumber(px) or 0, tonumber(py) or 0
      settings().minimap.angle = math.deg(math.atan2(py / scale - my, px / scale - mx)) % 360
      placeMinimap()
    end)
  end)
  mm:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  UI.tip(mm, minimapTip)
  placeMinimap()
  if settings().minimap.hide then mm:Hide() end
  return mm
end

-- The settings changed: put every entry point where and how they say.
function NS.applyEntry()
  local S = settings()
  if atAH() then showAH() else hideAH() end
  if bar and bar:IsShown() then scanBar() end
  if profButton and S.profButton == false then profButton:Hide() end
  if S.profButton ~= false then pcall(NS.onProfessionShown) end
  if not S.minimap.hide then NS.minimapButton() end
  if mm then
    if S.minimap.hide then mm:Hide() else mm:Show() end
  end
end

-- ---- wiring ----------------------------------------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, event)
  if event == "AUCTION_HOUSE_SHOW" then
    dragged = false
    C_Timer.After(0, function()   -- a frame later: Blizzard's window exists by then
      pcall(showAH)
      if NS.ahOnOpen then pcall(NS.ahOnOpen) end
      if progress() then pcall(KeboldsShiny_OnScanStarted) end
      if NS.repaint then pcall(NS.repaint) end
    end)
  elseif event == "AUCTION_HOUSE_CLOSED" then
    hideAH()
    if NS.ahHide then pcall(NS.ahHide) end
    if NS.undock then pcall(NS.undock) end
    if NS.repaint then pcall(NS.repaint) end
  elseif event == "TRADE_SKILL_CLOSE" then
    if profButton then profButton:Hide() end
  elseif event == "PLAYER_LOGIN" then
    if not settings().minimap.hide then pcall(NS.minimapButton) end
  end
end)
for _, event in ipairs({ "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "TRADE_SKILL_CLOSE", "PLAYER_LOGIN" }) do
  pcall(events.RegisterEvent, events, event)
end

function NS.windowDragged() dragged = true end
