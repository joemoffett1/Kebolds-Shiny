-- Kebold's Shiny: the selected recipe's figures inside the profession window's recipe pane
--   A small block in the pane's bottom left corner, in the game's own small fonts: gold label, white value.
--   Under it two small buttons: Kebold (open the window; right-click: scans and tabs) and Scan (this recipe's
--   items, at the auction house). A click on a line opens the recipe's details.
-- The block is a CHILD of Blizzard's recipe pane (owner approved 2026-11-10), so it sits inside the window and
-- shows and hides with it. Nothing is written onto Blizzard's tables and none of their scripts is replaced.
-- settings().strip: "pane" (this, the default) | "top" (the strip above the window, LedgerExtras.lua) | "off".
-- A client whose recipe pane cannot be found gets "top" by itself (NS.stripPlace).
-- NS.paneLines(recipeID) is the only logic output: plain data, read by the tests.
-- Profit, per hour and Worth making are the Craft page's figures (NS.figures): the way of getting the parts that earns
-- the most per hour, unless the player chose Buy or Make for a part. The profit line carries `mode` and says so.

local NS = KeboldsShinyNS
local UI = KeboldsShinyUI
local E = NS.E
local floor, max, min = math.floor, math.max, math.min
local DIM, RED, GREEN = NS.DIM, NS.RED, NS.GREEN
local money, settings, try = NS.money, NS.settings, NS.try

-- Where the block sits and how big it is: adjust these from a screenshot.
local PANE = {
  x = 14, y = 12,        -- from the recipe pane's bottom left corner, right and up
  w = 250,               -- the block's width (the pane is about 420 wide; Track Recipe keeps the bottom right)
  keepRight = 150,       -- at least this much of the pane's width is left free at the right
  lineH = 14,            -- one line
  labelW = 100,          -- the label column ("Chance of a point" is the longest label)
  gap = 4,               -- between the lines and the buttons
  buttonH = 20, ledgerW = 60, scanW = 52, buttonGap = 4,
  level = 10,            -- frame levels above the pane, so the block is drawn over its background
}
NS.PANE = PANE
local MAX_LINES = 5

local function signed(v)
  if v == nil then return DIM .. "-|r" end
  if v >= 0 then return GREEN .. "+" .. money(v) .. "|r" end
  return RED .. "-" .. money(-v) .. "|r"
end

local function count(n)
  if n == floor(n) then return tostring(n) end
  return string.format("%.1f", n)
end

local function atAH()
  return type(KeboldsShinyScan_AtAuctionHouse) == "function" and KeboldsShinyScan_AtAuctionHouse() and true or false
end

local function scanning()
  return type(KeboldsShinyScan_Progress) == "function" and KeboldsShinyScan_Progress() ~= nil
end

-- ---- the figures -----------------------------------------------------------------------------------------------------

-- The block's lines for one recipe: { { key, label, value, tip = { title, line, ... } }, ... } in the order shown.
-- keys: vendor, ah, profit, skill, worth. A recipe Kebold does not have gives one line with key "none" and
-- dim = true. nil without a recipe.
function NS.paneLines(recipeID)
  if not recipeID then return nil end
  local r = NS.data().byId[recipeID]
  if not r then
    return { { key = "none", dim = true, label = "Kebold", value = DIM .. "not in Kebold's data|r",
      tip = { "Kebold's Shiny", "This recipe is not in Kebold's list, so it has no figures for it." } } }
  end
  local c = NS.state(r.prof)
  local f = NS.figures(c, r)
  local x, mk = f.x, f.mk or 1
  local skill = c.st.skill or c.from
  local out = {}

  -- what one craft sells for at a vendor
  local made = mk ~= 1 and (DIM .. " (makes " .. count(mk) .. ")|r") or ""
  out[#out + 1] = { key = "vendor", label = "Vendor", value = r.sell and (money(r.sell * mk) .. made) or (DIM .. "no vendor value|r"),
    tip = { "Vendor", r.sell and "What a vendor pays for what one craft makes." or "Kebold has no vendor value for what this makes.",
      mk ~= 1 and ("One craft makes " .. count(mk) .. " on average" .. (r.sell and (", " .. money(r.sell) .. " each.") or ".")) or nil } }

  -- what it is listed for at the auction house
  local L = r.made > 0 and E.parseLadder(NS.realmItems()[r.made]) or nil
  local ah, why
  if r.made <= 0 then
    ah, why = DIM .. "nothing to list|r", "This recipe makes nothing that can be sold."
  elseif not L then
    ah, why = DIM .. "not scanned|r", "No price yet: press Scan at the auction house."
  elseif #L.tiers == 0 then
    ah, why = DIM .. "none listed|r", "Nothing was listed at the last scan."
  elseif x.ahp then
    ah, why = money(x.ahp * mk) .. DIM .. " (" .. L.total .. " listed)|r", "The cheapest listing that is not below vendor value, for what one craft makes, before the auction house's cut."
  else
    ah, why = money(L.tiers[1][1] * mk) .. DIM .. " (below vendor)|r", "Every listing is below vendor value (" .. L.total .. " listed), so a vendor pays more."
  end
  local ahTip = { "Auction house", why }
  if L then
    local age = max(0, floor(((try(time) or 0) - NS.DAY_ZERO) / 86400) - L.day)
    ahTip[#ahTip + 1] = DIM .. "Scanned " .. (age == 0 and "today" or (age == 1 and "yesterday" or (age .. " days ago"))) .. ".|r"
  end
  out[#out + 1] = { key = "ah", label = "AH", value = ah, tip = ahTip, scanned = L ~= nil, listed = L and L.total or nil }

  -- profit of one craft and per hour
  local profit
  if x.cost == nil then
    profit = RED .. "materials not priced|r"
  elseif x.p == nil then
    profit = DIM .. "no sale price|r"
  else
    profit = signed(x.p) .. DIM .. NS.wayShort(x.way) .. "|r" .. (f.ph and ("  " .. signed(f.ph) .. DIM .. " /h|r") or "")
  end
  local how = f.mode == "buy" and "Parts bought: that earns the most per hour." or (f.mode == "craft" and "Parts made: that earns the most per hour.")
    or (f.why == "pick" and "Your own Buy / Make choices for parts are used.") or nil
  out[#out + 1] = { key = "profit", label = "Profit", value = profit, mode = f.mode, why = f.why,
    tip = { "Profit", "Materials " .. (x.cost and money(x.cost) or (RED .. "not priced|r") .. " (scan them at the auction house)") .. ".",
      x.p and ("Sold " .. (x.way == "AH" and "at the auction house, after its cut." or (x.way == "DE" and "as disenchant materials at the auction house, after its cut." or "to a vendor."))) or nil,
      f.ph and ("Per hour: " .. signed(f.ph) .. (x.secs and string.format(", at %.1f s a craft with its parts.", x.secs) or ".")) or nil,
      (x.cost and how) or nil } }

  -- the chance of a skill point at the character's skill
  if r.col then
    out[#out + 1] = { key = "skill", label = "Chance of a point", value = string.format("%.0f%%", 100 * c.ctx.chanceAt(r, skill)) .. DIM .. " at " .. skill .. "|r",
      tip = { "Chance of a point", "The chance that one craft gives a skill point at skill " .. skill .. ".",
        "Yellow from " .. tostring(r.y or "?") .. ", grey at " .. tostring(r.grey or "?") .. "." } }
  end

  -- how many are worth making before buying moves the price
  local w = x.cost and x.p and NS.worthOf(c, r)
  if w and w.worth ~= math.huge then
    out[#out + 1] = { key = "worth", label = "Worth making", value = (w.known and "" or "~") .. w.worth,
      tip = { "Worth making", "How many crafts still pay before the cheap materials are bought up or the sales stop counting at the auction house price.",
        (not w.known) and "~: some prices have no depth behind them, so this is a guess." or nil } }
  end
  for _, line in ipairs(out) do   -- a tip is a plain list: drop the gaps the optional lines left
    local tip = {}
    for i = 1, 5 do
      if line.tip[i] ~= nil then tip[#tip + 1] = line.tip[i] end
    end
    line.tip = tip
  end
  return out
end

-- Whether the Scan button can be pressed now, and what its tooltip says.
function NS.paneScanState(recipeID)
  local known = recipeID and NS.data().byId[recipeID] ~= nil
  local tip = { "Scan this recipe" }
  if not known then
    tip[2] = "This recipe is not in Kebold's data."
    return false, tip
  end
  if not atAH() then
    tip[2] = "Open the auction house first: prices can only be read there."
    return false, tip
  end
  if scanning() then
    tip[2] = "A scan is running."
    return false, tip
  end
  tip[2] = "Reads the auction house prices of what this recipe makes and of everything needed to make it."
  return true, tip
end

-- ---- the block ---------------------------------------------------------------------------------------------------------

local pane, broken
local paneOn = false   -- our own note of whether the block is up (a new frame counts as shown before it is used)

-- The recipe pane, when it is a real frame something can be put into.
local function paneForm()
  local form = NS.schematicForm and NS.schematicForm() or nil
  if type(form) ~= "table" or type(form.IsShown) ~= "function" or type(form.GetWidth) ~= "function" then return nil end
  return form
end

function NS.paneUsable()
  return not broken and paneForm() ~= nil
end

local function lineClick(self)
  local id = pane and pane.recipe
  if id and NS.data().byId[id] and NS.openPanel then NS.openPanel(id) end
end

local function createPane(form)
  local f = CreateFrame("Frame", "KeboldsShinyPane", form)
  local formW = tonumber((form:GetWidth())) or 0
  local w = PANE.w
  if formW > 0 then w = max(180, min(w, formW - PANE.keepRight)) end
  f.w = w
  f:SetSize(w, MAX_LINES * PANE.lineH + PANE.gap + PANE.buttonH)
  f:SetPoint("BOTTOMLEFT", form, "BOTTOMLEFT", PANE.x, PANE.y)
  if type(form.GetFrameLevel) == "function" then
    local level = tonumber((form:GetFrameLevel()))
    if level then pcall(f.SetFrameLevel, f, level + PANE.level) end
  end
  f.lines = {}
  for i = 1, MAX_LINES do
    local b = CreateFrame("Button", nil, f)
    b:SetSize(w, PANE.lineH)
    local hi = b:CreateTexture(nil, "HIGHLIGHT")
    hi:SetAllPoints()
    hi:SetColorTexture(1, 1, 1, 0.08)
    b.label = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.label:SetPoint("LEFT", 0, 0)
    b.label:SetWidth(PANE.labelW)
    b.label:SetJustifyH("LEFT")
    b.label:SetWordWrap(false)
    b.value = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.value:SetPoint("LEFT", PANE.labelW + 2, 0)
    b.value:SetWidth(w - PANE.labelW - 2)
    b.value:SetJustifyH("LEFT")
    b.value:SetWordWrap(false)
    b:SetScript("OnClick", lineClick)
    UI.tip(b, function(self) return self.tipLines end)
    f.lines[i] = b
  end
  f.ledger = UI.button(f, "Kebold", PANE.ledgerW, function(self, button)
    if button == "RightButton" then
      if NS.entryMenu then UI.menu(self, NS.entryMenu()) end
    else
      NS.toggle()
    end
  end, { "Kebold's Shiny", "Left-click: open or close Kebold.", "Right-click: scans and tabs." })
  f.ledger:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  f.ledger:SetHeight(PANE.buttonH)
  f.ledger:SetPoint("BOTTOMLEFT", 0, 0)
  f.scan = UI.button(f, "Scan", PANE.scanW, function()
    local id = pane and pane.recipe
    if id and NS.paneScanState(id) and NS.scanRecipe then NS.scanRecipe(id) end
  end, function() return (select(2, NS.paneScanState(pane and pane.recipe))) end)
  f.scan:SetHeight(PANE.buttonH)
  -- a disabled button must still show why it is disabled
  if type(f.scan.SetMotionScriptsWhileDisabled) == "function" then pcall(f.scan.SetMotionScriptsWhileDisabled, f.scan, true) end
  -- the pane answers a newly selected recipe at once where the client lets us listen (a secure hook, nothing replaced)
  if type(hooksecurefunc) == "function" and type(form.Init) == "function" and type(C_Timer) == "table" then
    pcall(hooksecurefunc, form, "Init", function()
      C_Timer.After(0, function()
        if NS.stripRefresh then NS.stripRefresh() end
      end)
    end)
  end
  return f
end

function NS.paneHide()
  if pane and paneOn then
    paneOn = false
    pane:Hide()
  end
  if pane then pane.recipe = nil end
end

-- Shows the block for this recipe (nil: hides it). True when the recipe pane exists and the block is in use, so the
-- strip above the window is not needed; false when the pane cannot be found or the block could not be built.
function NS.paneUpdate(recipeID)
  if broken then return false end
  local form = paneForm()
  if not form then
    NS.paneHide()
    return false
  end
  if not pane then
    local ok, f = pcall(createPane, form)
    if not ok or type(f) ~= "table" then
      broken = true
      if type(KeboldsShinyPane) == "table" and type(KeboldsShinyPane.Hide) == "function" then pcall(KeboldsShinyPane.Hide, KeboldsShinyPane) end
      return false
    end
    pane = f
  end
  local lines = recipeID and NS.paneLines(recipeID) or nil
  if not lines then
    NS.paneHide()
    return true
  end
  pane.recipe = recipeID
  local known = lines[1].key ~= "none"
  local n = min(#lines, MAX_LINES)
  local S = settings()
  local withKebold = S.profButton ~= false
  -- lines from the top of the block down, the buttons along its bottom edge
  pane:SetHeight(n * PANE.lineH + PANE.gap + PANE.buttonH)
  for i, b in ipairs(pane.lines) do
    local line = lines[i]
    if line and i <= n then
      b.label:SetText(line.dim and (DIM .. line.label .. "|r") or (line.label .. ":"))
      b.value:SetText(UI.show(line.value))
      local tip = {}
      for k, t in ipairs(line.tip or {}) do tip[k] = t end
      if known then tip[#tip + 1] = DIM .. "Click for this recipe's details.|r" end
      b.tipLines = tip
      b:ClearAllPoints()
      b:SetPoint("TOPLEFT", 0, -(i - 1) * PANE.lineH)
      b:Show()
    else
      b.tipLines = nil
      b:Hide()
    end
  end
  pane.shownLines = n
  if withKebold then pane.ledger:Show() else pane.ledger:Hide() end
  pane.scan:ClearAllPoints()
  if withKebold then
    pane.scan:SetPoint("BOTTOMLEFT", PANE.ledgerW + PANE.buttonGap, 0)
  else
    pane.scan:SetPoint("BOTTOMLEFT", 0, 0)
  end
  local can = NS.paneScanState(recipeID)
  pane.scan:SetEnabled(can)
  pane.scan:SetDim(not can)
  pane.scan:Show()
  if not paneOn then
    paneOn = true
    pane:Show()
  end
  return true
end

-- /kebold strip pane | top | off
function NS.setStrip(mode)
  if mode ~= "pane" and mode ~= "top" and mode ~= "off" then return false end
  settings().strip = mode
  if NS.stripRefresh then NS.stripRefresh() end
  if NS.onProfessionShown then pcall(NS.onProfessionShown) end
  local place = NS.stripPlace and NS.stripPlace() or mode
  NS.say("Recipe figures at the profession window: " .. (mode == "pane" and "under the recipe" or (mode == "top" and "above the window" or "off")) .. "."
    .. ((mode == "pane" and place == "top" and type(ProfessionsFrame) == "table") and " The place under the recipe was not found in this profession window, so they stay above the window." or ""))
  local win = NS.frame and NS.frame()
  if type(win) == "table" and win:IsShown() and NS.refresh then pcall(NS.refresh) end   -- the Settings page shows the choice
  return true
end

-- The block shows the character's own figures (NS.asMe), whatever "Plan for" profile the Kebold window is showing:
-- in the profession window he crafts as himself.
do
  local inner = NS.paneLines
  if type(NS.asMe) == "function" then
    NS.paneLines = function(...) return NS.asMe(inner, ...) end
  end
end
