-- Kebold's Shiny: the widget kit
-- Every window, button, tab, dropdown, list line and so on of Kebold is made here, so the look lives in one
-- file. Each factory first tries one of Blizzard's own templates and falls back to a plain coloured widget when
-- the client lacks it (or when /kebold skin plain is set). Nothing here knows about recipes or prices.
--
-- Rules that keep this safe on a client nobody has listed the templates of:
--   * a template is tried inside pcall on an unnamed, hidden frame first (UI.probe), never assumed;
--   * a child a template is supposed to bring (Inset, CloseButton, Text, Slider ...) is used only when
--     type(child) == "table": never because it is truthy or because a method exists;
--   * a number read back from a widget goes through tonumber(...) or a default;
--   * texture FILES cannot be probed (a missing one draws as a green square), so only files that have been in the
--     game since the original release are used, and the plain skin uses none at all.
--
-- /kebold ui prints what this client has, /kebold ui gallery shows every widget in both looks.
--
-- The pieces: window, button (with a real disabled state), tab, menu, dropdown, edit, search, check, slider,
-- scrollbar, progress, row, header, bars; and for pages: text (font tokens), nav, table, split, card, stack,
-- scrollArea, empty, stepper, notice. addon/UI_PLAN2.md lists the signatures.

local UI = {}
KeboldsShinyUI = UI
UI.found = {}   -- [template] = true / false, filled by UI.probe

local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min

local function isTable(x) return type(x) == "table" end
local function num(v, d) return tonumber(v) or d end

local function ledger()
  local d = KeboldsShinyDB
  local s = isTable(d) and d.ledger or nil
  return isTable(s) and s or nil
end

-- True when every factory must use its plain fallback: /kebold skin plain, or the right half of the gallery.
function UI.plain()
  if UI.forcePlain then return true end
  local s = ledger()
  return s ~= nil and s.skin == "plain"
end

-- A switch of the saved settings that is on unless it was set to false (coins, icons).
function UI.opt(key)
  local s = ledger()
  return not (s and s[key] == false)
end

-- ---- density: how roomy lists are -------------------------------------------------------------------------------
-- One setting (Settings: "Row size", saved as settings.density) that every list of Kebold reads:
--   rowH    a line's height            font   the font object of a cell's text       icon   an item icon's size
--   gutter  the icons' strip at the left of a line           gap    the space between two columns
--   edge    kept free at the right end of a line             scale  what a column's stated width is multiplied by
--   grow    how much of its own width a fixed column may take from spare room (the rest goes to the flexible ones)
--   ctl     the height of a control drawn over a line        pad    the padding inside a card
-- Column widths are stated for the small font ("compact", the look before there was a choice); the larger font
-- of the other two needs about a tenth more, which `scale` adds, so no page states its widths twice.
UI.DENSITY = {
  compact = { key = "compact", rowH = 20, font = "GameFontHighlightSmall", icon = 16, iconX = 1, gutter = 20, gap = 2, edge = 0, scale = 1, grow = 0, ctl = 18, pad = 8 },
  normal = { key = "normal", rowH = 24, font = "GameFontHighlight", icon = 20, iconX = 3, gutter = 26, gap = 8, edge = 6, scale = 1.1, grow = 0.25, ctl = 22, pad = 12 },
  roomy = { key = "roomy", rowH = 28, font = "GameFontHighlight", icon = 22, iconX = 4, gutter = 30, gap = 12, edge = 8, scale = 1.1, grow = 0.35, ctl = 22, pad = 14 },
}
UI.DENSITY_ORDER = { "compact", "normal", "roomy" }
function UI.density()
  local s = ledger()
  return UI.DENSITY[UI.forceDensity or (s and s.density) or "normal"] or UI.DENSITY.normal
end
-- A stated width in the density now in force.
function UI.px(w)
  return floor((w or 0) * UI.density().scale + 0.5)
end
-- A font string follows the density's cell font (a list's cells, and labels that sit on a list's lines).
function UI.cellFont(fs)
  local d = UI.density()
  if rawget(fs, "fontName") ~= d.font then
    pcall(fs.SetFontObject, fs, d.font)
    fs.fontName = d.font
  end
  return fs
end

-- Does this client have the template? Tried once on an unnamed frame that is hidden at once.
local KIND = {
  UIPanelButtonTemplate = "Button", PanelTabButtonTemplate = "Button", InputBoxTemplate = "EditBox", SearchBoxTemplate = "EditBox",
  UICheckButtonTemplate = "CheckButton", InterfaceOptionsCheckButtonTemplate = "CheckButton", OptionsSliderTemplate = "Slider",
  UISliderTemplate = "Slider", UIPanelScrollBarTemplate = "Slider", WowStyle1DropdownTemplate = "DropdownButton",
}
function UI.probe(template, kind)
  local known = UI.found[template]
  if known ~= nil then return known end
  local ok, f = pcall(CreateFrame, kind or KIND[template] or "Frame", nil, UIParent, template)
  if ok and isTable(f) then pcall(f.Hide, f) end
  UI.found[template] = (ok and isTable(f)) and true or false
  return UI.found[template]
end
function UI.has(template, kind)
  if UI.plain() then return false end
  return UI.probe(template, kind)
end
function UI.hasAtlas(name)
  if not (isTable(C_Texture) and type(C_Texture.GetAtlasInfo) == "function") then return false end
  local ok, info = pcall(C_Texture.GetAtlasInfo, name)
  return ok and info ~= nil
end

-- A frame from a template, or nil when the client lacks it.
local function make(kind, name, parent, template)
  if not UI.has(template, kind) then return nil end
  local ok, f = pcall(CreateFrame, kind, name, parent, template)
  if ok and isTable(f) then return f end
  return nil
end

local function colour(parent, layer, r, g, b, a)
  local t = parent:CreateTexture(nil, layer or "BACKGROUND")
  t:SetColorTexture(r, g, b, a or 1)
  return t
end

-- A one pixel frame around a widget, from four colour textures.
local function edges(f, r, g, b, a)
  local out = {}
  for i, p in ipairs({ { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true }, { "TOPLEFT", "BOTTOMLEFT", false }, { "TOPRIGHT", "BOTTOMRIGHT", false } }) do
    local t = colour(f, "BORDER", r, g, b, a)
    t:SetPoint(p[1])
    t:SetPoint(p[2])
    if p[3] then t:SetHeight(1) else t:SetWidth(1) end
    out[i] = t
  end
  return out
end

-- ---- text ----------------------------------------------------------------------------------------------------------

-- money() in Ledger.lua writes its g / s / c letters in these three colours and nothing else may use them: that is
-- how a letter is told from ordinary text and turned into a coin.
local MARK = { g = "|cffffd701g|r", s = "|cffc7c7cfs|r", c = "|cffeda55fc|r" }
local COIN = {
  g = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t",
  s = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t",
  c = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t",
}
UI.MARK = MARK

-- What is put on screen: the money letters become coin pictures, or plain letters in the plain skin and with
-- coins switched off (a colour code inside a coloured line would end the line's own colour).
function UI.show(s)
  if type(s) ~= "string" or not s:find("|cff", 1, true) then return s end
  local coins = not UI.plain() and UI.opt("coins")
  for k, mark in pairs(MARK) do
    if s:find(mark, 1, true) then s = s:gsub(mark, coins and COIN[k] or k) end
  end
  return s
end

-- The bare text: no colours, no coin letters' colours, no pictures. For chat and for tests.
function UI.plainText(s)
  s = tostring(s or "")
  if s:find("|T", 1, true) then
    for k, pic in pairs(COIN) do   -- a coin picture reads as its letter
      local from = 1
      while true do
        local a, b = s:find(pic, from, true)
        if not a then break end
        s = s:sub(1, a - 1) .. k .. s:sub(b + 1)
        from = a + 1
      end
    end
  end
  return (s:gsub("|T.-|t", ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

-- ---- tooltips on controls --------------------------------------------------------------------------------------------

-- tip: a string, a list of lines (the first is the title), or a function that returns either when hovered.
-- Where a tooltip goes: to the right of its owner, or to the left when it would run off the screen there
-- (a window docked at the right edge, the last columns of a list).
function UI.tipAnchor(owner)
  local right = owner and owner.GetRight and select(2, pcall(owner.GetRight, owner)) or nil
  local screen = isTable(UIParent) and UIParent.GetWidth and select(2, pcall(UIParent.GetWidth, UIParent)) or nil
  if type(right) == "number" and type(screen) == "number" and screen > 0 and right + 340 > screen then return "ANCHOR_LEFT" end
  return "ANCHOR_RIGHT"
end

function UI.tip(w, tip)
  if not tip and w.wantsWhy ~= true then return end
  w.tip = tip
  w:SetScript("OnEnter", function(self)
    if not isTable(GameTooltip) then return end
    local t = self.tip
    if type(t) == "function" then t = t(self) end
    if type(t) == "string" then t = { t } end
    local why = type(self.why) == "string" and self.why or nil   -- set by SetEnabled(false, why) on a kit button
    if (not isTable(t) or #t == 0) and not why then return end
    t = isTable(t) and t or {}
    GameTooltip:SetOwner(self, UI.tipAnchor(self))
    GameTooltip:SetText(UI.show(t[1] or why), 1, 0.82, 0, 1, true)
    for i = 2, #t do GameTooltip:AddLine(UI.show(t[i]), 1, 1, 1, true) end
    if why and t[1] then GameTooltip:AddLine(why, 1, 0.35, 0.35, true) end
    GameTooltip:Show()
  end)
  w:SetScript("OnLeave", function()
    if isTable(GameTooltip) then GameTooltip:Hide() end
  end)
end

-- ---- fonts -----------------------------------------------------------------------------------------------------------

-- The four steps of the hierarchy, so a heading is larger and not only another colour. All four are font objects
-- the game has had since its first release.
UI.FONT = { title = "GameFontNormalLarge", section = "GameFontNormal", body = "GameFontHighlightSmall", dim = "GameFontDisableSmall" }

-- A text in one of the tokens above (or any font object's name).
function UI.text(parent, token, text, layer)
  local fs = parent:CreateFontString(nil, layer or "OVERLAY", UI.FONT[token or "body"] or token)
  if text ~= nil then fs:SetText(text) end
  return fs
end

-- ---- window ----------------------------------------------------------------------------------------------------------

-- opts: noPortrait (a panel without the round picture), top / bottom / left / right = where the body sits.
-- Fields: .title (FontString), .close, .body (the list area), :SetIcon(texture), .skinUsed, .hasPortrait
function UI.window(name, parent, w, h, opts)
  opts = opts or {}
  local f, used
  local chain = opts.noPortrait and { "BasicFrameTemplateWithInset" } or { "ButtonFrameTemplate", "PortraitFrameTemplate", "BasicFrameTemplateWithInset" }
  for _, t in ipairs(chain) do
    f = make("Frame", name, parent, t)
    if f then
      used = t
      break
    end
  end
  if not f then
    f = make("Frame", name, parent, "BackdropTemplate")
    if f then
      local ok = type(f.SetBackdrop) == "function" and pcall(f.SetBackdrop, f, {
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
      if ok then
        used = "BackdropTemplate"
        if type(f.SetBackdropColor) == "function" then pcall(f.SetBackdropColor, f, 0.05, 0.05, 0.07, 0.95) end
      end
    end
  end
  if not f then f = CreateFrame("Frame", name, parent) end
  if not used then   -- the plain look: a dark rectangle with a thin edge
    local bg = colour(f, "BACKGROUND", 0.05, 0.05, 0.07, 0.95)
    bg:SetAllPoints()
    edges(f, 0.35, 0.35, 0.4, 1)
  end
  f:SetSize(w, h)
  f.skinUsed = used or "plain"
  f.hasPortrait = (used == "ButtonFrameTemplate" or used == "PortraitFrameTemplate")
  local framed = used ~= nil and used ~= "BackdropTemplate"

  local function child(key, suffix)
    if isTable(f[key]) then return f[key] end
    local g = name and _G[name .. (suffix or key)] or nil
    return isTable(g) and g or nil
  end

  local tc = f.TitleContainer
  local title = (isTable(tc) and isTable(tc.TitleText) and tc.TitleText) or child("TitleText")
  if not title then
    title = f:CreateFontString(nil, "OVERLAY", framed and "GameFontNormal" or "GameFontNormalLarge")
    if framed then title:SetPoint("TOP", 0, -5) else title:SetPoint("TOPLEFT", 10, -8) end
  end
  f.title = title

  local close = child("CloseButton")
  if not close then
    close = CreateFrame("Button", nil, f)
    close:SetSize(18, 18)
    close:SetPoint("TOPRIGHT", -4, -3)
    local bg = colour(close, "BACKGROUND", 0.35, 0.1, 0.1, 0.9)
    bg:SetAllPoints()
    local hi = colour(close, "HIGHLIGHT", 1, 1, 1, 0.2)
    hi:SetAllPoints()
    local x = close:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    x:SetPoint("CENTER")
    x:SetText("x")
  end
  close:SetScript("OnClick", function() f:Hide() end)
  f.close = close

  local body = child("Inset")
  if not body then
    body = CreateFrame("Frame", nil, f)
    local bg = colour(body, "BACKGROUND", 0, 0, 0, 0.3)
    bg:SetAllPoints()
  end
  body:ClearAllPoints()
  body:SetPoint("TOPLEFT", opts.left or 6, -(opts.top or 60))
  body:SetPoint("BOTTOMRIGHT", -(opts.right or 8), opts.bottom or 28)
  f.body = body

  function f:SetIcon(tex)
    if not tex or not self.hasPortrait then return end
    if type(self.SetPortraitToAsset) == "function" and pcall(self.SetPortraitToAsset, self, tex) then return end
    local pc = self.PortraitContainer
    local p = (isTable(pc) and isTable(pc.portrait) and pc.portrait) or child("portrait", "Portrait")
    if not p then return end
    if type(SetPortraitToTexture) == "function" and pcall(SetPortraitToTexture, p, tex) then return end
    pcall(p.SetTexture, p, tex)
  end
  return f
end

-- ---- button ----------------------------------------------------------------------------------------------------------

-- Fields: .label (FontString), :SetLabel(text), :SetDim(bool), .native
function UI.button(parent, text, w, onClick, tip)
  local b = make("Button", nil, parent, "UIPanelButtonTemplate")
  local native = b ~= nil
  local label
  if native then
    pcall(b.SetNormalFontObject, b, "GameFontNormalSmall")
    pcall(b.SetHighlightFontObject, b, "GameFontHighlightSmall")
    pcall(b.SetDisabledFontObject, b, "GameFontDisableSmall")
    pcall(b.SetText, b, text or "")
    if isTable(b.Text) then
      label = b.Text
    else
      local ok, fs = pcall(b.GetFontString, b)
      if ok and isTable(fs) then label = fs end
    end
  else
    b = CreateFrame("Button", nil, parent)
    local bg = colour(b, "BACKGROUND", 0.2, 0.2, 0.25, 0.9)
    bg:SetAllPoints()
    local hi = colour(b, "HIGHLIGHT", 1, 1, 1, 0.15)
    hi:SetAllPoints()
  end
  if not label then
    label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("CENTER")
  end
  b:SetSize(w or 80, native and 22 or 20)
  b.label, b.native, b.off = label, native, false
  label:SetText(text or "")
  function b:SetLabel(s) self.label:SetText(s) end
  function b:SetDim(dim) self:SetAlpha(dim and 0.5 or 1) end
  -- SetEnabled(false, "why"): the game's own greyed-out state where the button has one, a faded one otherwise; a
  -- click then does nothing and the tooltip ends with the reason. SetEnabled(true) puts it back.
  local nativeSet = b.SetEnabled
  function b:SetEnabled(on, why)
    on = on and true or false
    self.off = not on
    self.why = (not on) and why or nil
    if type(nativeSet) == "function" then pcall(nativeSet, self, on) end
    self:SetAlpha((on or self.native) and 1 or 0.45)
  end
  pcall(b.SetMotionScriptsWhileDisabled, b, true)   -- so the tooltip with the reason still shows
  b:SetScript("OnClick", function(self, ...)
    if self.off == true then return end
    if onClick then onClick(self, ...) end
  end)
  b.wantsWhy = true
  UI.tip(b, tip)
  return b
end

-- ---- tab -------------------------------------------------------------------------------------------------------------

-- A tab that hangs under a frame's bottom edge. Fields: .label, :SetLabel(text), :SetSelected(bool)
local tabCount = 0
function UI.tab(parent, text, onClick, tip)
  tabCount = tabCount + 1
  -- named: older versions of Blizzard's tab code find a tab's parts by its name
  local b = make("Button", "KeboldsShinyTab" .. tabCount, parent, "PanelTabButtonTemplate")
  local native = b ~= nil
  local label
  if native then
    pcall(b.SetText, b, text)
    if isTable(b.Text) then
      label = b.Text
    else
      local ok, fs = pcall(b.GetFontString, b)
      if ok and isTable(fs) then label = fs end
    end
    if type(PanelTemplates_TabResize) == "function" then pcall(PanelTemplates_TabResize, b, 0) end
  else
    b = CreateFrame("Button", nil, parent)
    b:SetSize(78, 22)
    local bg = colour(b, "BACKGROUND", 0.12, 0.12, 0.16, 0.95)
    bg:SetAllPoints()
    local hi = colour(b, "HIGHLIGHT", 1, 1, 1, 0.12)
    hi:SetAllPoints()
    b.line = colour(b, "ARTWORK", 1, 0.82, 0, 1)
    b.line:SetPoint("BOTTOMLEFT", 2, 0)
    b.line:SetPoint("BOTTOMRIGHT", -2, 0)
    b.line:SetHeight(2)
    b.line:Hide()
  end
  if not label then
    label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("CENTER")
    label:SetText(text)
  end
  b.label, b.native = label, native
  function b:SetLabel(s)
    if self.native then
      pcall(self.SetText, self, s)
      if type(PanelTemplates_TabResize) == "function" then pcall(PanelTemplates_TabResize, self, 0) end
    end
    self.label:SetText(s)
  end
  function b:SetSelected(on)
    self.selected = on and true or false
    if self.native and type(PanelTemplates_SelectTab) == "function" and type(PanelTemplates_DeselectTab) == "function" then
      pcall(on and PanelTemplates_SelectTab or PanelTemplates_DeselectTab, self)
      return
    end
    if isTable(self.line) then
      if on then self.line:Show() else self.line:Hide() end
    end
    if on then self.label:SetTextColor(1, 0.82, 0) else self.label:SetTextColor(1, 1, 1) end
  end
  b:SetScript("OnClick", onClick)
  UI.tip(b, tip)
  return b
end

-- ---- menu ------------------------------------------------------------------------------------------------------------

-- items: a list of { text =, func =, title = true | divider = true | radio = true | check = true, checked =,
-- disabled =, tip = }. UI.lastMenu always holds the list last shown, so a test can run an entry's func.
local pop
local function popLine(i)
  local b = CreateFrame("Button", nil, pop)
  b:SetHeight(18)
  local hi = colour(b, "HIGHLIGHT", 1, 1, 1, 0.15)
  hi:SetAllPoints()
  b.box = colour(b, "ARTWORK", 0.5, 0.5, 0.5, 0.8)
  b.box:SetSize(8, 8)
  b.box:SetPoint("LEFT", 4, 0)
  b.mark = colour(b, "OVERLAY", 1, 0.82, 0, 1)
  b.mark:SetSize(6, 6)
  b.mark:SetPoint("CENTER", b.box, "CENTER", 0, 0)
  b.rule = colour(b, "ARTWORK", 0.5, 0.5, 0.5, 0.6)
  b.rule:SetPoint("LEFT", 4, 0)
  b.rule:SetPoint("RIGHT", -4, 0)
  b.rule:SetHeight(1)
  b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.label:SetPoint("LEFT", 18, 0)
  b.label:SetJustifyH("LEFT")
  b:SetScript("OnClick", function(self)
    local it = self.item
    if not it or it.title or it.divider or it.disabled then return end
    pop:Hide()
    pop.catch:Hide()
    if it.func then it.func() end
  end)
  b:SetScript("OnEnter", function(self)
    local it = self.item
    if it and it.tip and isTable(GameTooltip) then
      GameTooltip:SetOwner(self, UI.tipAnchor(self))
      GameTooltip:SetText(it.text or "", 1, 0.82, 0, 1, true)
      GameTooltip:AddLine(UI.show(it.tip), 1, 1, 1, true)
      GameTooltip:Show()
    end
  end)
  b:SetScript("OnLeave", function()
    if isTable(GameTooltip) then GameTooltip:Hide() end
  end)
  pop.lines[i] = b
  return b
end

local function ownMenu(owner, items)
  if not pop then
    local catch = CreateFrame("Button", nil, UIParent)   -- a click anywhere else closes the menu
    catch:SetAllPoints(UIParent)
    catch:SetFrameStrata("FULLSCREEN_DIALOG")
    pcall(catch.RegisterForClicks, catch, "AnyUp")
    pop = CreateFrame("Frame", "KeboldsShinyMenu", UIParent)
    pop.catch, pop.lines = catch, {}
    pop:SetFrameStrata("FULLSCREEN_DIALOG")
    pop:SetFrameLevel(num(catch:GetFrameLevel(), 1) + 10)
    pop:EnableMouse(true)
    pop:SetClampedToScreen(true)
    local bg = colour(pop, "BACKGROUND", 0.06, 0.06, 0.09, 0.97)
    bg:SetAllPoints()
    edges(pop, 0.5, 0.5, 0.55, 1)
    catch:SetScript("OnClick", function() pop:Hide() end)
    pop:SetScript("OnHide", function() catch:Hide() end)
    if isTable(UISpecialFrames) then table.insert(UISpecialFrames, "KeboldsShinyMenu") end   -- Escape closes it
  end
  local y, width = -5, 150
  for i, it in ipairs(items) do
    local b = pop.lines[i] or popLine(i)
    b.item = it
    local marked = it.radio or it.check
    b.label:SetText(it.divider and "" or (it.text or ""))
    if it.title then b.label:SetTextColor(1, 0.82, 0) elseif it.disabled then b.label:SetTextColor(0.5, 0.5, 0.5) else b.label:SetTextColor(1, 1, 1) end
    b.label:ClearAllPoints()
    b.label:SetPoint("LEFT", (marked or not it.title) and 18 or 6, 0)
    if marked then b.box:Show() else b.box:Hide() end
    if marked and it.checked then b.mark:Show() else b.mark:Hide() end
    if it.divider then b.rule:Show() else b.rule:Hide() end
    local h = it.divider and 7 or 18
    b:SetHeight(h)
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", 3, y)
    b:SetPoint("TOPRIGHT", -3, y)
    b:Show()
    y = y - h
    width = max(width, num(b.label:GetStringWidth(), 0) + 36)
  end
  for i = #items + 1, #pop.lines do pop.lines[i]:Hide() end
  pop:SetSize(width, -y + 5)
  local x, cy = 400, 400
  if type(GetCursorPosition) == "function" then
    local ok, a, b2 = pcall(GetCursorPosition)
    if ok then x, cy = num(a, x), num(b2, cy) end
  end
  local scale = num(UIParent:GetEffectiveScale(), 1)
  pop:ClearAllPoints()
  pop:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale, cy / scale)
  pop.catch:Show()
  pop:Show()
  return "own"
end

function UI.menu(owner, items)
  UI.lastMenu = items
  if not isTable(items) or #items == 0 then return nil end
  if not UI.plain() and isTable(MenuUtil) and type(MenuUtil.CreateContextMenu) == "function" then
    local close = isTable(MenuResponse) and MenuResponse.Close or nil
    local ok = pcall(MenuUtil.CreateContextMenu, owner, function(_, root)
      for _, it in ipairs(items) do
        local el
        if it.divider then
          root:CreateDivider()
        elseif it.title then
          root:CreateTitle(it.text)
        elseif it.radio then
          el = root:CreateRadio(it.text, function() return it.checked and true or false end, function()
            if it.func then it.func() end
            return close
          end)
        elseif it.check then
          el = root:CreateCheckbox(it.text, function() return it.checked and true or false end, function()
            if it.func then it.func() end
            return close
          end)
        else
          el = root:CreateButton(it.text, function()
            if it.func then it.func() end
          end)
        end
        if isTable(el) then
          if it.disabled and type(el.SetEnabled) == "function" then el:SetEnabled(false) end
          if it.tip and type(el.SetTooltip) == "function" then
            el:SetTooltip(function(tooltip)
              tooltip:SetText(it.text or "", 1, 0.82, 0, 1, true)
              tooltip:AddLine(UI.show(it.tip), 1, 1, 1, true)
            end)
          end
        end
      end
    end)
    if ok then return "native" end
  end
  return ownMenu(owner, items)
end

function UI.closeMenu()
  if pop then pop:Hide() end
end

-- ---- dropdown --------------------------------------------------------------------------------------------------------

-- A button that shows the current choice and opens a menu. Fields: .label, :Refresh()
function UI.dropdown(parent, w, getText, getItems, tip)
  local b
  b = UI.button(parent, "", w, function(self) UI.menu(self, getItems()) end, tip)
  b.label:ClearAllPoints()
  b.label:SetPoint("LEFT", 8, 0)
  b.label:SetPoint("RIGHT", -18, 0)
  b.label:SetJustifyH("LEFT")
  b.label:SetWordWrap(false)
  if UI.plain() then
    local v = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    v:SetPoint("RIGHT", -6, 0)
    v:SetText("v")
  else
    local arrow = b:CreateTexture(nil, "OVERLAY")
    arrow:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
    arrow:SetSize(16, 16)
    arrow:SetPoint("RIGHT", -3, 0)
  end
  b.getItems = getItems
  function b:Refresh() self.label:SetText(getText() or "") end
  return b
end

-- ---- edit boxes ------------------------------------------------------------------------------------------------------

local function plainEdit(parent)
  local e = CreateFrame("EditBox", nil, parent)
  local bg = colour(e, "BACKGROUND", 0, 0, 0, 0.7)
  bg:SetAllPoints()
  return e
end

local function dressEdit(e, w)
  e:SetSize(w, 20)
  e:SetAutoFocus(false)
  e:SetFontObject(GameFontHighlightSmall or "GameFontHighlightSmall")
  e:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  return e
end

function UI.edit(parent, w, numeric)
  local e = make("EditBox", nil, parent, "InputBoxTemplate") or plainEdit(parent)
  dressEdit(e, w)
  if numeric then
    e:SetNumeric(true)
    e:SetJustifyH("CENTER")
  end
  return e
end

-- A search box: onText(box) runs whenever the text changes.
function UI.search(parent, w, onText)
  local e = make("EditBox", nil, parent, "SearchBoxTemplate")
  local search = e ~= nil
  e = e or make("EditBox", nil, parent, "InputBoxTemplate") or plainEdit(parent)
  dressEdit(e, w)
  e:SetScript("OnEscapePressed", function(self)
    self:SetText("")
    self:ClearFocus()
  end)
  e:SetScript("OnTextChanged", function(self, ...)
    -- the template's own handler shows and hides the magnifier text and the clear button
    if search and type(SearchBoxTemplate_OnTextChanged) == "function" then pcall(SearchBoxTemplate_OnTextChanged, self) end
    if onText then onText(self, ...) end
  end)
  return e
end

-- ---- check box -------------------------------------------------------------------------------------------------------

-- Fields: .label, :SetChecked(bool), :Refresh()
function UI.check(parent, text, get, set, tip)
  local c = make("CheckButton", nil, parent, "UICheckButtonTemplate") or make("CheckButton", nil, parent, "InterfaceOptionsCheckButtonTemplate")
  local label
  if c then
    c:SetSize(22, 22)
    label = (isTable(c.Text) and c.Text) or (isTable(c.text) and c.text) or nil
    if not label then
      label = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      label:SetPoint("LEFT", c, "RIGHT", 2, 0)
    end
    pcall(label.SetFontObject, label, "GameFontHighlightSmall")
    c:SetScript("OnClick", function(self)
      local v = self:GetChecked()
      if v == nil then v = not get() end
      set(v and true or false)
    end)
  else
    c = CreateFrame("Button", nil, parent)
    c:SetSize(14, 14)
    local box = colour(c, "BACKGROUND", 0.15, 0.15, 0.2, 1)
    box:SetAllPoints()
    edges(c, 0.5, 0.5, 0.55, 1)
    c.fill = colour(c, "ARTWORK", 1, 0.82, 0, 1)
    c.fill:SetPoint("TOPLEFT", 3, -3)
    c.fill:SetPoint("BOTTOMRIGHT", -3, 3)
    c.fill:Hide()
    label = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("LEFT", c, "RIGHT", 5, 0)
    function c:SetChecked(v)
      self.on = v and true or false
      if self.on then self.fill:Show() else self.fill:Hide() end
    end
    function c:GetChecked() return self.on end
    c:SetScript("OnClick", function(self)
      self:SetChecked(not self.on)
      set(self.on)
    end)
  end
  label:SetText(text or "")
  c.label = label
  function c:Refresh() self:SetChecked(get() and true or false) end
  UI.tip(c, tip)
  c:Refresh()
  return c
end

-- ---- slider ----------------------------------------------------------------------------------------------------------

-- A number: a slider, a box with the value, the unit and a Reset button.
--   o = { min, max, step } or { values = { ... } }, plus w (whole width), sw (slider width), unit, isChanged()
--   get() -> the value now; set(v) stores it, set(nil) puts the default back
-- Fields: .slider (the real Slider), .box, .reset, :Refresh()
function UI.slider(parent, o, get, set)
  local h = CreateFrame("Frame", nil, parent)
  local sw = o.sw or 140
  h:SetSize(o.w or (sw + 150), 22)
  local lo, hi, step = o.min, o.max, o.step
  if o.values then lo, hi, step = 1, #o.values, 1 end
  local function toValue(pos)
    if o.values then return o.values[max(1, min(#o.values, floor(pos + 0.5)))] end
    return max(lo, min(hi, lo + floor((pos - lo) / step + 0.5) * step))
  end
  local function toPos(v)
    if not o.values then return max(lo, min(hi, num(v, lo))) end
    local at, gap = 1, nil
    for i, x in ipairs(o.values) do
      local d = math.abs(x - num(v, x))
      if not gap or d < gap then at, gap = i, d end
    end
    return at
  end

  local s, kind
  local m = make("Frame", nil, h, "MinimalSliderWithSteppersTemplate")
  if m then
    if isTable(m.Slider) and type(m.Init) == "function" and pcall(m.Init, m, toPos(get()), lo, hi, max(1, floor((hi - lo) / step + 0.5))) then
      s, kind = m.Slider, "MinimalSliderWithSteppersTemplate"
      m:SetPoint("LEFT", 0, 0)
      m:SetWidth(sw)
    else
      pcall(m.Hide, m)
    end
  end
  if not s then
    for _, t in ipairs({ "OptionsSliderTemplate", "UISliderTemplate" }) do
      s = make("Slider", nil, h, t)
      if s then
        kind = t
        for _, k in ipairs({ "Low", "High", "Text" }) do
          if isTable(s[k]) then pcall(s[k].SetText, s[k], "") end
        end
        break
      end
    end
  end
  if not s then
    s, kind = CreateFrame("Slider", nil, h), "plain"
    s:SetOrientation("HORIZONTAL")
    local track = colour(s, "BACKGROUND", 0.2, 0.2, 0.25, 1)
    track:SetPoint("LEFT")
    track:SetPoint("RIGHT")
    track:SetHeight(4)
    local thumb = colour(s, "OVERLAY", 1, 0.82, 0, 1)
    thumb:SetSize(8, 16)
    s:SetThumbTexture(thumb)
  end
  if kind ~= "MinimalSliderWithSteppersTemplate" then
    s:SetPoint("LEFT", 0, 0)
    s:SetSize(sw, 16)
    s:SetMinMaxValues(lo, hi)
    s:SetValueStep(step)
    pcall(s.SetObeyStepOnDrag, s, true)
  end
  h.slider, h.kind = s, kind

  local busy = false
  local function onChanged(self, value)
    if busy then return end
    value = tonumber(value) or tonumber(self:GetValue())
    if not value then return end
    local v = toValue(value)
    if v ~= get() then set(v) end
  end
  if kind == "MinimalSliderWithSteppersTemplate" then s:HookScript("OnValueChanged", onChanged) else s:SetScript("OnValueChanged", onChanged) end

  local box = UI.edit(h, 44, false)
  box:SetPoint("LEFT", sw + 12, 0)
  box:SetJustifyH("CENTER")
  box:SetScript("OnEnterPressed", function(self)
    local v = tonumber(self:GetText())
    if v then
      if o.values then v = toValue(toPos(v)) else v = max(lo, min(hi, v)) end
      set(v)
    end
    self:ClearFocus()
  end)
  box:SetScript("OnEditFocusLost", function() h:Refresh() end)
  h.box = box
  local unit = h:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  unit:SetPoint("LEFT", box, "RIGHT", 4, 0)
  unit:SetText(o.unit or "")
  h.unit = unit
  h.reset = UI.button(h, "Reset", 50, function() set(nil) end, "Back to the default.")
  h.reset:SetPoint("RIGHT", 0, 0)

  function h:Refresh()
    local v = get()
    busy = true
    pcall(s.SetValue, s, toPos(v))
    busy = false
    if not box:HasFocus() then box:SetText(tostring(v)) end
    local changed = o.isChanged and o.isChanged() or false
    self.reset:SetDim(not changed)
    if changed then self.reset.label:SetTextColor(1, 0.82, 0) else self.reset.label:SetTextColor(0.6, 0.6, 0.6) end
  end
  h:Refresh()
  return h
end

-- ---- scroll bar ------------------------------------------------------------------------------------------------------

-- A vertical bar for a list that is drawn from an offset. onValue(offset) runs when the player moves it.
-- :SetRange(count, visible), :SetOffset(n)
function UI.scrollbar(parent, onValue)
  local s = make("Slider", nil, parent, "UIPanelScrollBarTemplate")
  local native = s ~= nil
  if not s then
    s = CreateFrame("Slider", nil, parent)
    s:SetOrientation("VERTICAL")
    s:SetWidth(10)
    local track = colour(s, "BACKGROUND", 0.15, 0.15, 0.2, 0.9)
    track:SetAllPoints()
    local thumb = colour(s, "OVERLAY", 0.6, 0.6, 0.65, 1)
    thumb:SetSize(10, 28)
    s:SetThumbTexture(thumb)
  end
  s.native, s.scrollStep, s.busy = native, 3, true
  -- ours replaces the template's own script, which expects a ScrollFrame for a parent
  s:SetScript("OnValueChanged", function(self, value)
    if self.busy then return end
    value = tonumber(value) or tonumber(self:GetValue()) or 0
    onValue(floor(value + 0.5))
  end)
  s:SetMinMaxValues(0, 0)
  s:SetValueStep(1)
  pcall(s.SetObeyStepOnDrag, s, true)
  s:SetValue(0)
  s.busy = false
  local function arrows(self, at)
    local up, down = self.ScrollUpButton, self.ScrollDownButton
    if isTable(up) and type(up.SetEnabled) == "function" then up:SetEnabled(at > 0) end
    if isTable(down) and type(down.SetEnabled) == "function" then down:SetEnabled(at < (self.maxOffset or 0)) end
  end
  function s:SetRange(count, visible)
    local m = max(0, count - visible)
    self.maxOffset = m
    self.busy = true
    self:SetMinMaxValues(0, m)
    self.busy = false
    if m == 0 then self:Hide() else self:Show() end
  end
  function s:SetOffset(n)
    self.busy = true
    self:SetValue(n)
    self.busy = false
    arrows(self, n)
  end
  return s
end

-- ---- progress bar ----------------------------------------------------------------------------------------------------

-- :Set(done, total, text)
function UI.progress(parent, w, h)
  local bar = CreateFrame("StatusBar", nil, parent)
  bar:SetSize(w, h)
  local bg = colour(bar, "BACKGROUND", 0, 0, 0, 0.6)
  bg:SetAllPoints()
  if UI.plain() then
    local t = colour(bar, "ARTWORK", 0.25, 0.55, 0.9, 1)
    bar:SetStatusBarTexture(t)
  else
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetStatusBarColor(0.25, 0.55, 0.9, 1)
  end
  edges(bar, 0.45, 0.45, 0.5, 1)
  bar:SetMinMaxValues(0, 1)
  bar:SetValue(0)
  bar.text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  bar.text:SetPoint("CENTER")
  function bar:Set(done, total, text)
    self:SetMinMaxValues(0, max(1, num(total, 1)))
    self:SetValue(num(done, 0))
    self.text:SetText(text or "")
  end
  return bar
end

-- ---- list line -------------------------------------------------------------------------------------------------------

-- A line of a list: a button with zebra shading, a hover highlight, a band for section heads, an icon, a fold
-- mark and one text per cell. cells: { { key =, x =, w =, j = "LEFT" | "RIGHT", r = offset from the right edge } }
-- Fields: .cell[key], .icon, .band, .zebra, .exp
function UI.row(parent, w, h, cells)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(w, h)
  b.zebra = colour(b, "BACKGROUND", 1, 1, 1, 0.03)
  b.zebra:SetAllPoints()
  b.zebra:Hide()
  b.band = colour(b, "BORDER", 1, 0.82, 0, 0.1)
  b.band:SetAllPoints()
  b.band:Hide()
  b.sel = colour(b, "BORDER", 0.35, 0.6, 1, 0.22)   -- the selected line of a table
  b.sel:SetAllPoints()
  b.sel:Hide()
  local hi = colour(b, "HIGHLIGHT", 1, 1, 1, 0.1)
  hi:SetAllPoints()
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetSize(16, 16)
  b.icon:SetPoint("LEFT", 1, 0)
  b.icon:Hide()
  b.exp = b:CreateTexture(nil, "ARTWORK")
  b.exp:SetSize(14, 14)
  b.exp:SetPoint("LEFT", 2, 0)
  b.exp:Hide()
  b.cell = {}
  for _, c in ipairs(cells) do
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    if c.r then fs:SetPoint("RIGHT", -c.r, 0) else fs:SetPoint("LEFT", c.x or 0, 0) end
    if c.w then fs:SetWidth(c.w) end
    fs:SetJustifyH(c.j or (c.r and "RIGHT" or "LEFT"))
    fs:SetWordWrap(false)
    b.cell[c.key] = fs
  end
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  return b
end

local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"
function UI.iconOf(row)
  if row.icon then return row.icon end
  local tex
  if row.item and isTable(C_Item) and type(C_Item.GetItemIconByID) == "function" then
    local ok, t = pcall(C_Item.GetItemIconByID, row.item)
    if ok then tex = t end
  end
  if not tex and row.recipe and isTable(C_Spell) and type(C_Spell.GetSpellTexture) == "function" then
    local ok, t = pcall(C_Spell.GetSpellTexture, row.recipe)
    if ok then tex = t end
  end
  if not tex and (row.item or row.recipe) then tex = QUESTION end
  return tex
end

-- Dresses a line for the row it shows: shading on every second line, a band and a fold mark on a section head,
-- the icon of its item or recipe.
function UI.decorate(b, row, index)
  local plainSkin = UI.plain()
  if index % 2 == 0 and not row.section then b.zebra:Show() else b.zebra:Hide() end
  if row.section or row.band then b.band:Show() else b.band:Hide() end
  if row.section and not plainSkin then
    b.exp:SetTexture(row.folded and "Interface\\Buttons\\UI-PlusButton-Up" or "Interface\\Buttons\\UI-MinusButton-Up")
    b.exp:Show()
  else
    b.exp:Hide()
  end
  local tex = (not plainSkin and not row.section and UI.opt("icons")) and UI.iconOf(row) or nil
  if tex then
    b.icon:SetTexture(tex)
    b.icon:Show()
  else
    b.icon:Hide()
  end
end

-- ---- column heads ----------------------------------------------------------------------------------------------------

-- columns: { { x =, w =, j =, text =, tip =, sortable = false } }. onSort(k) makes the heads clickable (not one
-- with sortable = false).
-- Fields: .heads[k].label, :SetSort(k, descending), :SetText(k, text), :Place(k, x, w, shown)
function UI.header(parent, columns, onSort)
  local hd = CreateFrame("Frame", nil, parent)
  hd:SetSize(10, 20)
  hd.heads = {}
  local native = not UI.plain()
  for k, c in ipairs(columns) do
    local h = CreateFrame("Button", nil, hd)
    h:SetSize(c.w, 20)
    h:SetPoint("TOPLEFT", c.x, 0)
    if native then   -- the three pieces of the game's own column head
      local file = "Interface\\FriendsFrame\\WhoFrame-ColumnTabs"
      local l = h:CreateTexture(nil, "BACKGROUND")
      l:SetTexture(file)
      l:SetTexCoord(0, 0.078125, 0, 0.75)
      l:SetPoint("TOPLEFT")
      l:SetSize(5, 20)
      local r = h:CreateTexture(nil, "BACKGROUND")
      r:SetTexture(file)
      r:SetTexCoord(0.90625, 0.96875, 0, 0.75)
      r:SetPoint("TOPRIGHT")
      r:SetSize(4, 20)
      local mid = h:CreateTexture(nil, "BACKGROUND")
      mid:SetTexture(file)
      mid:SetTexCoord(0.078125, 0.90625, 0, 0.75)
      mid:SetPoint("TOPLEFT", l, "TOPRIGHT")
      mid:SetPoint("BOTTOMRIGHT", r, "BOTTOMLEFT")
      h.arrow = h:CreateTexture(nil, "OVERLAY")
      h.arrow:SetTexture("Interface\\Buttons\\UI-SortArrow")
      h.arrow:SetSize(9, 8)
      h.arrow:Hide()
    else
      local bg = colour(h, "BACKGROUND", 0.14, 0.14, 0.18, 0.9)
      bg:SetAllPoints()
    end
    if onSort and c.sortable ~= false then
      local hi = colour(h, "HIGHLIGHT", 1, 1, 1, 0.12)
      hi:SetAllPoints()
      h:SetScript("OnClick", function() onSort(k) end)
    end
    h.label = h:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    local right = c.j == "RIGHT"
    h.label:SetPoint(right and "RIGHT" or "LEFT", right and -6 or 6, 0)
    h.label:SetText(c.text or "")
    if isTable(h.arrow) then
      if right then h.arrow:SetPoint("RIGHT", h.label, "LEFT", -2, 0) else h.arrow:SetPoint("LEFT", h.label, "RIGHT", 2, 0) end
    end
    h.text = c.text or ""
    UI.tip(h, c.tip)
    hd.heads[k] = h
  end
  function hd:SetText(k, text)
    local h = self.heads[k]
    if h then
      h.text = text or ""
      h.label:SetText(h.text)
    end
  end
  function hd:Place(k, x, w, shown)   -- a table moves its heads when its width changes
    local h = self.heads[k]
    if not h then return end
    h:ClearAllPoints()
    h:SetPoint("TOPLEFT", x or 0, 0)
    h:SetWidth(max(1, w or 1))
    if shown == false then h:Hide() else h:Show() end
  end
  function hd:SetSort(key, desc)
    for k, h in ipairs(self.heads) do
      local on = k == key
      if isTable(h.arrow) then
        if on then
          if desc then h.arrow:SetTexCoord(0, 0.5625, 0, 1) else h.arrow:SetTexCoord(0, 0.5625, 1, 0) end
          h.arrow:Show()
        else
          h.arrow:Hide()
        end
        h.label:SetText((on and "|cffffd100" or "") .. h.text .. (on and "|r" or ""))
      else
        h.label:SetText((on and "|cffffd100" or "") .. h.text .. (on and ((desc and " v" or " ^") .. "|r") or ""))
      end
    end
  end
  return hd
end

-- ---- bar chart -------------------------------------------------------------------------------------------------------

-- :Set(values) draws one bar per value, scaled to the largest.
function UI.bars(parent, w, h)
  local f = CreateFrame("Frame", nil, parent)
  f:SetSize(w, h)
  local bg = colour(f, "BACKGROUND", 0, 0, 0, 0.35)
  bg:SetAllPoints()
  f.bar = {}
  function f:Set(values)
    values = values or {}
    self.values = values
    local top = 0
    for _, v in ipairs(values) do top = max(top, num(v, 0)) end
    local n = #values
    local bw = n > 0 and max(2, floor((w - 4) / n)) or 0
    for i, v in ipairs(values) do
      local t = self.bar[i]
      if not t then
        t = colour(self, "ARTWORK", 0.3, 0.65, 1, 0.9)
        self.bar[i] = t
      end
      t:ClearAllPoints()
      t:SetPoint("BOTTOMLEFT", 2 + (i - 1) * bw, 2)
      t:SetSize(max(1, bw - 1), max(1, top > 0 and (num(v, 0) / top * (h - 4)) or 1))
      t:Show()
    end
    for i = n + 1, #self.bar do self.bar[i]:Hide() end
  end
  return f
end

-- ---- containers and the pieces of a page ----------------------------------------------------------------------------
-- Everything below is laid out from the top down by numbers: a container is told its size with :Layout(w, h) and
-- tells its children theirs. Nothing reads a size back from the game (an anchored frame has none until the next
-- frame is drawn), so a page looks the same on its first paint as on its tenth.
-- A container made here carries kitLayout = true; UI.stack asks only those for their own height.

-- ---- nav: the rail of pages ------------------------------------------------------------------------------------------

-- A vertical rail of page buttons: icon, name, a mark on the selected one, an optional badge.
--   nav = UI.nav(parent, width, onPick)        onPick(key) runs on a click
--   nav:Add(key, text, icon, tip) -> button    icon: a texture path or file id; none in the plain skin or with icons off
--   nav:Select(key)   nav:SetBadge(key, text or nil)   nav:SetLabel(key, text)
-- Fields: .buttons[key] (.label, .icon, .badge, .selected), .order
local NAV_H = 30
function UI.nav(parent, w, onPick)
  local nav = CreateFrame("Frame", nil, parent)
  nav.buttons, nav.order, nav.w, nav.selectedKey = {}, {}, w or 130, false
  nav:SetSize(nav.w, 10)
  local native = not UI.plain()
  function nav:Add(key, text, icon, tip)
    local b = CreateFrame("Button", nil, self)
    local n = #self.order + 1
    self.order[n], self.buttons[key] = key, b
    b.key = key
    b:SetSize(self.w, NAV_H)
    b:SetPoint("TOPLEFT", 0, -(n - 1) * (NAV_H + 2))
    b.bg = colour(b, "BACKGROUND", 1, 0.82, 0, 0.14)
    b.bg:SetAllPoints()
    b.bg:Hide()
    b.bar = colour(b, "ARTWORK", 1, 0.82, 0, 1)   -- the gold edge of the selected page
    b.bar:SetPoint("TOPLEFT", 0, -2)
    b.bar:SetPoint("BOTTOMLEFT", 0, 2)
    b.bar:SetWidth(3)
    b.bar:Hide()
    local hi = b:CreateTexture(nil, "HIGHLIGHT")
    if native then   -- the quest log's line highlight: in the game since its first release
      hi:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
      pcall(hi.SetBlendMode, hi, "ADD")
    else
      hi:SetColorTexture(1, 1, 1, 0.12)
    end
    hi:SetAllPoints()
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(20, 20)
    b.icon:SetPoint("LEFT", 8, 0)
    local withIcon = native and icon ~= nil and UI.opt("icons")
    if withIcon then b.icon:SetTexture(icon) else b.icon:Hide() end
    b.label = UI.text(b, "section", text)
    b.label:SetPoint("LEFT", withIcon and 34 or 10, 0)
    b.label:SetJustifyH("LEFT")
    b.badge = UI.text(b, "body", "")
    b.badge:SetPoint("RIGHT", -8, 0)
    b.badge:SetTextColor(1, 0.3, 0.3)
    b.selected = false
    b:SetScript("OnClick", function() if onPick then onPick(key) end end)
    UI.tip(b, tip)
    self:SetHeight(n * (NAV_H + 2))
    return b
  end
  function nav:Select(key)
    self.selectedKey = key
    for k, b in pairs(self.buttons) do
      local on = k == key
      b.selected = on
      if on then
        b.bg:Show()
        b.bar:Show()
        b.label:SetTextColor(1, 0.82, 0)
      else
        b.bg:Hide()
        b.bar:Hide()
        b.label:SetTextColor(1, 1, 1)
      end
    end
  end
  function nav:SetBadge(key, text)
    local b = self.buttons[key]
    if b then b.badge:SetText(text or "") end
  end
  function nav:SetLabel(key, text)
    local b = self.buttons[key]
    if b then b.label:SetText(text or "") end
  end
  return nav
end

-- ---- empty state -----------------------------------------------------------------------------------------------------

-- What a list shows when it has nothing: a picture, a title, a sentence or two and at most two buttons.
--   e = UI.empty(parent, icon, title, text, buttonText, onClick)
--   e:Set(icon, title, text, buttonText, onClick [, buttonText2, onClick2])     the second button sits beside the first
-- Fields: .icon, .title, .body, .button, .button2
function UI.empty(parent, icon, title, text, buttonText, onClick)
  local e = CreateFrame("Frame", nil, parent)
  e:SetSize(340, 150)
  e.icon = e:CreateTexture(nil, "ARTWORK")
  e.icon:SetSize(40, 40)
  e.icon:SetPoint("TOP", 0, 0)
  e.title = UI.text(e, "title")
  e.title:SetPoint("TOP", 0, -48)
  e.body = UI.text(e, "body")
  e.body:SetPoint("TOP", 0, -72)
  e.body:SetWidth(320)
  e.body:SetJustifyH("CENTER")
  pcall(e.body.SetWordWrap, e.body, true)
  e.body:SetTextColor(0.7, 0.7, 0.7)
  e.onClick = false
  e.button = UI.button(e, "", 150, function()
    if e.onClick then e.onClick() end
  end)
  e.button:SetPoint("BOTTOM", 0, 0)
  e.onClick2 = false
  e.button2 = UI.button(e, "", 150, function()
    if e.onClick2 then e.onClick2() end
  end)
  e.button2:SetPoint("BOTTOM", 80, 0)
  e.button2:Hide()
  function e:Set(icon2, title2, text2, buttonText2, onClick2, buttonText3, onClick3)
    if icon2 and not UI.plain() and UI.opt("icons") then
      self.icon:SetTexture(icon2)
      self.icon:Show()
    else
      self.icon:Hide()
    end
    self.title:SetText(title2 or "")
    self.body:SetText(UI.show(text2 or ""))
    self.onClick = onClick2 or false
    if buttonText2 and onClick2 then
      self.button:SetLabel(buttonText2)
      self.button:Show()
    else
      self.button:Hide()
    end
    local two = buttonText2 and onClick2 and buttonText3 and onClick3 and true or false
    self.onClick2 = two and onClick3 or false
    self.button:ClearAllPoints()
    self.button:SetPoint("BOTTOM", two and -80 or 0, 0)
    if two then
      self.button2:SetLabel(buttonText3)
      self.button2:Show()
    else
      self.button2:Hide()
    end
  end
  e:Set(icon, title, text, buttonText, onClick)
  return e
end

-- ---- table -----------------------------------------------------------------------------------------------------------

-- One list: column heads, lines that are made as they are needed, a scroll bar, the mouse wheel, a mark on the
-- selected line, and an empty state. It takes Kebold's row tables as they are:
--   { cols = { text, ... } }                         one text per column, in the columns' order
--   { left =, time =, c1 =, c2 =, right = ... }      each text goes to the column with that key; `left` always
--                                                    goes to the first column, `right` to the last when no column
--                                                    is called "right"
--   a row with only `left` (or wide = true) is one text across the whole width; a row with nothing is a gap
--   section / folded / band / item / recipe / icon dress the line (UI.decorate); everything else on the row
--   (tip, action, menu, pickItem ...) is the caller's and reaches it through the callbacks
--   a list that is only rows with `empty` (= true, or { icon =, title =, text =, button =, onClick = }) shows
--   that as the empty state instead of a line of text
--
--   t = UI.table(parent, columns, opts)
--   columns: { { key =, title =, width =, min =, flex =, align = "LEFT" | "RIGHT", sortable = true, tip =, drop = n } }
--     width: fixed pixels. flex: a share of whatever is left over (its width is then min + share). drop: when the
--     columns do not fit, the one with the highest drop number goes first; a column without it always stays.
--   opts: header = false (no column heads), rowH (20),
--         onClick(line, button), onEnter(line), onLeave(line)   line.row is the row table, line.table this table
--         onMenu(line)              a right-click, when it should not go to onClick like any other click
--         onSort(key, index)        a click on a sortable head; the caller sorts and calls t:SetSort
--         selected(row) -> bool     the line(s) to mark
--         empty = { icon =, title =, text =, button =, onClick = }, or a function returning one
--   t:Layout(w, h)   t:SetRows(rows)   t:Paint()   t:SetOffset(n)   t:GetOffset()   t:SetColumns(columns)
--   t:SetSort(index or key, descending)   t:SetHeadText(index, text)   t:SetTop(pixels kept free above the lines)
--   t:CutTexts(line) -> the full texts of the cells the game had to cut short (for the tooltip)
-- Fields: .lines (the line widgets; .row, .cell[key], .cells[index]), .rows, .scroll, .head (.heads[k].label),
--         .shown[k] (is column k on screen), .emptyState
local SCROLL_W, GAP_H = 20, 8

local function blankRow(row)
  return not row.cols and (row.left == nil or row.left == "") and not row.c1 and not row.c2 and not row.right and not row.time and not row.section
end
UI.blankRow = blankRow

-- Where each column goes in `width`: x[k], w[k], shown[k]. d = the density (the one in force when left out).
-- A column's width is its stated one times the density's scale (fixed = true: as stated, for a tick box or a
-- button). Spare room goes to the columns, never to a blank strip at the right: the fixed ones may each take up to
-- `grow` of their own width (half the spare at most), the flexible ones share the rest; with no flexible column
-- every column takes its share.
local function fitColumns(cols, width, d)
  d = d or UI.density()
  local gap = d.gap
  local function base(c)
    local w = c.min or c.width or 60
    return c.fixed and w or floor(w * d.scale + 0.5)
  end
  local shown, need = {}, d.gutter + d.edge
  for k, c in ipairs(cols) do
    shown[k] = true
    need = need + base(c) + gap
  end
  while need > width do
    local worst, at
    for k, c in ipairs(cols) do
      if shown[k] and c.drop and (not worst or c.drop > worst) then worst, at = c.drop, k end
    end
    if not at then break end
    shown[at] = false
    need = need - base(cols[at]) - gap
  end
  local flex, fixedW, allW = 0, 0, 0
  for k, c in ipairs(cols) do
    if shown[k] then
      allW = allW + base(c)
      if c.flex then flex = flex + c.flex elseif not c.fixed then fixedW = fixedW + base(c) end
    end
  end
  local spare = max(0, width - need)
  local forFixed = 0
  if flex == 0 then
    forFixed = spare
  elseif d.grow > 0 then
    forFixed = min(floor(spare / 2), floor(fixedW * d.grow))
  end
  local forFlex = spare - forFixed
  local xs, ws, x = {}, {}, d.gutter
  for k, c in ipairs(cols) do
    if shown[k] then
      local w = base(c)
      if c.flex then
        w = w + floor(forFlex * c.flex / flex)
      elseif flex == 0 then
        if allW > 0 then w = w + floor(forFixed * base(c) / allW) end
      elseif not c.fixed and fixedW > 0 then
        w = w + floor(forFixed * base(c) / fixedW)
      end
      xs[k], ws[k] = x, w
      x = x + w + gap
    end
  end
  return xs, ws, shown
end
UI.fitColumns = fitColumns

function UI.table(parent, columns, opts)
  opts = opts or {}
  local t = CreateFrame("Frame", nil, parent)
  t.kitLayout = true
  t.d = UI.density()
  t.opts, t.rowH = opts, opts.rowH or t.d.rowH
  t.rows, t.lines, t.offset, t.top = {}, {}, 0, 0
  t.w, t.h = 300, 200
  t.headH = opts.header == false and 0 or 20
  t.headers, t.head, t.emptyState, t.stamp, t.isEmpty = {}, false, false, 0, false
  t:SetSize(t.w, t.h)

  local function shift()
    return type(IsShiftKeyDown) == "function" and IsShiftKeyDown() and true or false
  end

  t.scroll = UI.scrollbar(t, function(n)
    t.offset = n
    t:Paint()
  end)
  t.scroll:SetPoint("TOPRIGHT", t, "TOPRIGHT", -2, -(t.headH + (t.scroll.native and 17 or 1)))
  t.scroll:SetPoint("BOTTOMRIGHT", t, "BOTTOMRIGHT", -2, t.scroll.native and 17 or 1)
  t:EnableMouseWheel(true)
  t:SetScript("OnMouseWheel", function(self, delta)
    local step = shift() and max(1, self:Visible() - 1) or 3   -- Shift: a page
    self.offset = self.offset - delta * step
    self:Paint()
  end)

  -- how many whole lines fit
  function t:Visible()
    return max(1, floor((self.h - self.headH - self.top - 4) / self.rowH))
  end

  local function place(b)
    local cols = t.columns
    for k = 1, #cols do
      local fs = b.cells[k]
      if not fs then
        fs = UI.text(b, "body")
        fs:SetWordWrap(false)
        b.cells[k] = fs
      end
      UI.cellFont(fs)
      fs:ClearAllPoints()
      if t.shown[k] then
        fs:SetPoint("LEFT", t.xs[k], 0)
        fs:SetWidth(t.ws[k])
        fs:SetJustifyH(cols[k].align or "LEFT")
        fs:Show()
      else
        fs:SetPoint("LEFT", 0, 0)
        fs:Hide()
      end
    end
    for k = #cols + 1, #b.cells do b.cells[k]:Hide() end
    b.cell = {}
    for k, c in ipairs(cols) do
      if c.key then b.cell[c.key] = b.cells[k] end
    end
    b.cell.left = b.cell.left or b.cells[1]
    b:SetWidth(t.lineW)
    b.icon:SetSize(t.d.icon, t.d.icon)   -- the item icon follows the line's height
    b.icon:ClearAllPoints()
    b.icon:SetPoint("LEFT", t.d.iconX, 0)
    b.placed = t.stamp
  end

  local function line(i)
    local b = t.lines[i]
    if not b then
      b = UI.row(t, t.lineW, t.rowH, {})
      b.cells, b.table = {}, t
      b:SetScript("OnClick", function(self, button)
        if not rawget(self, "row") then return end
        if button == "RightButton" and opts.onMenu then
          opts.onMenu(self)
        elseif opts.onClick then
          opts.onClick(self, button)
        end
      end)
      b:SetScript("OnEnter", function(self)
        if opts.onEnter and rawget(self, "row") then opts.onEnter(self) end
      end)
      b:SetScript("OnLeave", function(self)
        if opts.onLeave then opts.onLeave(self) end
      end)
      t.lines[i] = b
    end
    if b.placed ~= t.stamp then place(b) end
    return b
  end

  local function arrange()
    local d = UI.density()   -- read again on every layout: the Row size setting applies at once
    t.d = d
    t.rowH = opts.rowH or d.rowH
    t.lineW = max(60, t.w - SCROLL_W)
    t.xs, t.ws, t.shown = fitColumns(t.columns, t.lineW, d)
    t.stamp = t.stamp + 1
    local hd = t.head
    if hd then
      hd:SetWidth(t.lineW)
      -- heads meet half way between two columns, so a cell's text never touches a head's edge
      local half, first = floor((d.gap - 2) / 2), true
      for k = 1, #t.columns do
        if t.shown[k] then   -- the first head also covers the icons' gutter
          local x = first and 0 or (t.xs[k] - half)
          hd:Place(k, x, t.xs[k] + t.ws[k] + d.gap - half - x, true)
          first = false
        else
          hd:Place(k, 0, 1, false)
        end
      end
    end
  end

  function t:SetColumns(cols)
    self.columns = cols
    if self.headH > 0 then
      for _, hd in pairs(self.headers) do hd:Hide() end
      local hd = self.headers[cols]
      if not hd then
        local defs, any = {}, false
        for k, c in ipairs(cols) do
          defs[k] = { x = 0, w = 10, j = c.align, text = c.title or "", tip = c.tip, sortable = c.sortable and true or false }
          any = any or (c.sortable and true or false)
        end
        hd = UI.header(self, defs, any and function(k)
          if opts.onSort then opts.onSort(cols[k].key, k) end
        end or nil)
        hd:SetPoint("TOPLEFT", 0, 0)
        self.headers[cols] = hd
      end
      hd:Show()
      self.head = hd
    end
    arrange()
  end

  function t:Layout(w, h)
    w, h = max(80, num(w, self.w)), max(40, num(h, self.h))
    self.w, self.h = w, h
    self:SetSize(w, h)
    arrange()
    self:Paint()
    return h
  end

  function t:SetRows(rows)
    self.rows = rows or {}
    self:Paint()
  end
  function t:SetOffset(n)
    self.offset = max(0, floor(num(n, 0)))
    self:Paint()
  end
  function t:GetOffset() return self.offset end
  function t:SetTop(px)
    self.top = max(0, num(px, 0))
  end
  function t:SetSort(key, desc)
    if not self.head then return end
    local at = key
    if type(key) ~= "number" then
      at = 0
      for k, c in ipairs(self.columns) do
        if c.key == key then at = k end
      end
    end
    self.sortKey, self.sortDesc = at, desc and true or false
    self.head:SetSort(at, desc and true or false)
  end
  function t:SetHeadText(k, text)
    if self.head then self.head:SetText(k, text) end
  end
  function t:CutTexts(b)
    local out = {}
    for k = 1, #self.columns do
      local fs = b.cells and b.cells[k]
      if fs and self.shown[k] and type(fs.IsTruncated) == "function" then
        local ok, cut = pcall(fs.IsTruncated, fs)
        if ok and cut == true then
          local ok2, text = pcall(fs.GetText, fs)
          if ok2 and type(text) == "string" and text ~= "" then out[#out + 1] = text end
        end
      end
    end
    return out
  end

  -- The empty state for these rows, or nil when there is something to list.
  local function emptyFor(rows)
    local def
    for _, row in ipairs(rows) do
      if not row.empty then return nil end
      def = def or row
    end
    if def then
      local e = type(def.empty) == "table" and def.empty or {}
      return { icon = e.icon, title = e.title or "", text = e.text or def.left, button = e.button, onClick = e.onClick,
        button2 = e.button2, onClick2 = e.onClick2 }
    end
    if #rows > 0 then return nil end
    local e = opts.empty
    if type(e) == "function" then e = e() end
    return isTable(e) and e or { title = "Nothing to show", text = "" }
  end

  function t:Paint()
    local rows = self.rows
    local e = emptyFor(rows)
    if e then
      if not self.emptyState then
        self.emptyState = UI.empty(self)
        self.emptyState:SetPoint("CENTER", self, "CENTER", 0, 0)
      end
      self.emptyState:Set(e.icon, e.title, e.text, e.button, e.onClick, e.button2, e.onClick2)
      self.emptyState:Show()
      for _, b in ipairs(self.lines) do
        b.row = nil
        b:Hide()
      end
      self.scroll:SetRange(0, 1)
      self.scroll:SetOffset(0)
      self.isEmpty = true
      return
    end
    self.isEmpty = false
    if self.emptyState then self.emptyState:Hide() end
    local cols, nominal = self.columns, self:Visible()
    self.offset = max(0, min(self.offset, #rows - nominal))
    local rightKey = false
    for _, c in ipairs(cols) do
      if c.key == "right" then rightKey = true end
    end
    local last = #cols
    while last > 1 and not self.shown[last] do last = last - 1 end
    local y, at, n = -(self.headH + self.top) - 2, self.offset, 0
    while true do
      local row = rows[at + 1]
      if not row then break end
      local h = blankRow(row) and GAP_H or self.rowH
      if h - y > self.h - 2 then break end
      n, at = n + 1, at + 1
      local b = line(n)
      b.row = row
      b:ClearAllPoints()
      b:SetPoint("TOPLEFT", 0, y)
      b:SetHeight(h)
      local wide = not row.cols and (row.wide or not (row.c1 or row.c2 or row.right or row.time)) and true or false
      local nextUsed   -- the first column after the first that has something in it on this line
      for k, c in ipairs(cols) do
        local text
        if row.cols then
          text = row.cols[k]
        else
          text = c.key and row[c.key] or nil
          if k == 1 and text == nil then text = row.left end
          if k == last and k > 1 and text == nil and not rightKey then text = row.right end
        end
        if not self.shown[k] or (wide and k > 1) or type(text) == "table" or type(text) == "function" then text = "" end
        text = text ~= nil and tostring(text) or ""
        if k > 1 and text ~= "" and not nextUsed then nextUsed = k end
        b.cells[k]:SetText(UI.show(text))
      end
      -- A line that is not one text per column lets its first text run on over the columns it leaves empty, and a
      -- line that is only a label and a value lets a long value grow to the left (up to 60% of the line).
      local firstW, lastX, lastW = self.ws[1], self.xs[last], self.ws[last]
      local gap, whole = self.d.gap, self.lineW - self.d.gutter - self.d.edge - 4
      if wide then
        firstW = whole
      elseif not row.cols and nextUsed then
        if nextUsed == last then
          local okW, sw = pcall(b.cells[last].GetStringWidth, b.cells[last])
          sw = okW and num(sw, 0) or 0
          if sw + 4 > lastW then
            local grow = min(ceil(sw) + 6, floor(self.lineW * 0.6))
            if grow > lastW then lastX, lastW = lastX + lastW - grow, grow end
          end
          firstW = lastX - self.xs[1] - gap
        else
          firstW = self.xs[nextUsed] - self.xs[1] - gap
        end
      elseif not row.cols then   -- the other cells are there but empty (right = ""): the text has the line
        firstW = whole
      end
      b.cells[1]:SetWidth(max(20, firstW))
      if last > 1 then
        local fs = b.cells[last]
        fs:ClearAllPoints()
        fs:SetPoint("LEFT", lastX, 0)
        fs:SetWidth(lastW)
      end
      UI.decorate(b, row, at)
      if opts.selected and opts.selected(row) then b.sel:Show() else b.sel:Hide() end
      b:Show()
      y = y - h
    end
    for k = n + 1, #self.lines do
      self.lines[k].row = nil
      self.lines[k]:Hide()
    end
    self.scroll:SetRange(#rows, nominal)
    self.scroll:SetOffset(self.offset)
  end

  t:SetColumns(columns)
  return t
end

-- ---- split -----------------------------------------------------------------------------------------------------------

-- Two panes side by side with a divider; the right one can be folded away with the small button on the divider.
--   s = UI.split(parent, opts)
--   opts: rightWidth (360), minLeft (300: under that the right pane is folded without being asked),
--         get() -> is it folded, set(bool) -> save it (both optional: without them the state lives in the split),
--         onLayout(split, leftWidth, rightWidth, height)   size what is inside the panes here (rightWidth 0 = folded)
--         onToggle(folded)
--   s:Layout(w, h)   s:SetCollapsed(bool)   s:IsCollapsed()
-- Fields: .left, .right (frames to parent things to), .toggle (the button), .leftW, .rightW
local SPLIT_GAP = 14
function UI.split(parent, opts)
  opts = opts or {}
  local s = CreateFrame("Frame", nil, parent)
  s.kitLayout = true
  s.left, s.right = CreateFrame("Frame", nil, s), CreateFrame("Frame", nil, s)
  s.wantRight, s.minLeft = opts.rightWidth or 360, opts.minLeft or 300
  s.w, s.h, s.leftW, s.rightW = 600, 300, 600, 0
  s.collapsed, s.forced = false, false
  s.rule = colour(s, "ARTWORK", 1, 1, 1, 0.12)
  s.rule:SetWidth(1)
  s.toggle = CreateFrame("Button", nil, s)
  s.toggle:SetSize(SPLIT_GAP - 2, 44)
  local bg = colour(s.toggle, "BACKGROUND", 0.2, 0.2, 0.25, 0.9)
  bg:SetAllPoints()
  local hi = colour(s.toggle, "HIGHLIGHT", 1, 1, 1, 0.2)
  hi:SetAllPoints()
  s.toggle.label = UI.text(s.toggle, "body", ">")
  s.toggle.label:SetPoint("CENTER")
  function s:IsCollapsed()
    if opts.get then return opts.get() and true or false end
    return self.collapsed and true or false
  end
  function s:SetCollapsed(v)
    v = v and true or false
    self.collapsed = v
    if opts.set then opts.set(v) end
    self:Layout(self.w, self.h)
    if opts.onToggle then opts.onToggle(v) end
  end
  s.toggle:SetScript("OnClick", function() s:SetCollapsed(not s:IsCollapsed()) end)
  UI.tip(s.toggle, function()
    return s:IsCollapsed() and { "Show details", "Opens the details beside the list." } or { "Hide details", "Folds the details away; the list gets the whole width." }
  end)
  function s:Layout(w, h)
    w, h = max(40, num(w, self.w)), max(20, num(h, self.h))
    self.w, self.h = w, h
    self:SetSize(w, h)
    local folded = self:IsCollapsed()
    local rw = folded and 0 or min(self.wantRight, w - self.minLeft - SPLIT_GAP)
    if rw < (opts.minRight or 200) then rw = 0 end   -- no room for it: folded for now, the saved choice stays
    self.forced = not folded and rw == 0
    local lw = w - SPLIT_GAP - rw
    self.leftW, self.rightW = lw, rw
    self.left:ClearAllPoints()
    self.left:SetPoint("TOPLEFT", 0, 0)
    self.left:SetSize(lw, h)
    self.right:ClearAllPoints()
    self.right:SetPoint("TOPLEFT", lw + SPLIT_GAP, 0)
    self.right:SetSize(max(1, rw), h)
    if rw > 0 then self.right:Show() else self.right:Hide() end
    self.rule:ClearAllPoints()
    self.rule:SetPoint("TOPLEFT", lw + floor(SPLIT_GAP / 2), 0)
    self.rule:SetHeight(h)
    self.toggle:ClearAllPoints()
    self.toggle:SetPoint("TOPLEFT", lw + 1, -floor(h / 2) + 22)
    self.toggle.label:SetText(rw > 0 and ">" or "<")
    if opts.onLayout then opts.onLayout(self, lw, rw, h) end
    return h
  end
  return s
end

-- ---- card and stack --------------------------------------------------------------------------------------------------

-- A titled section: a frame with a title strip and a content area whose height the caller states.
--   c = UI.card(parent, title, opts)
--   opts: height (of the content), fold = true (a click on the title folds it), get() / set(bool) for the folded
--         state (optional), onLayout(card, contentWidth) -> place what is inside; may return the content's height
--   c:SetAction(widget)   a control at the right end of the title strip
--   c:SetContentHeight(h)   c:SetTitle(text)   c:SetFolded(bool)   c:Layout(w) -> the card's height
-- Fields: .content (parent your controls to it; its top left is the origin), .title, .head, .folded, .h
local CARD_HEAD = 26   -- the padding inside a card comes from the density (UI.density().pad)
function UI.card(parent, title, opts)
  opts = opts or {}
  local c = make("Frame", nil, parent, "InsetFrameTemplate")
  local native = c ~= nil
  c = c or CreateFrame("Frame", nil, parent)
  c.kitLayout = true
  c.native = native
  if not c.native then
    local bg = colour(c, "BACKGROUND", 1, 1, 1, 0.04)
    bg:SetAllPoints()
    edges(c, 0.35, 0.35, 0.4, 0.8)
  end
  c.strip = colour(c, "BORDER", 1, 0.82, 0, 0.07)
  c.strip:SetPoint("TOPLEFT", 2, -2)
  c.strip:SetPoint("TOPRIGHT", -2, -2)
  c.strip:SetHeight(CARD_HEAD - 3)
  c.title = UI.text(c, "section", title)
  c.title:SetPoint("TOPLEFT", opts.fold and 24 or 10, -7)
  c.content = CreateFrame("Frame", nil, c)
  c.pad = UI.density().pad
  c.content:SetPoint("TOPLEFT", c.pad, -CARD_HEAD)
  c.contentH, c.w, c.h = opts.height or 0, 200, CARD_HEAD
  c.folded, c.head, c.mark, c.action = false, false, false, false
  if opts.fold then
    c.head = CreateFrame("Button", nil, c)
    c.head:SetPoint("TOPLEFT", 0, 0)
    c.head:SetSize(200, CARD_HEAD)
    local hi = colour(c.head, "HIGHLIGHT", 1, 1, 1, 0.08)
    hi:SetAllPoints()
    c.mark = UI.text(c.head, "section", "-")
    c.mark:SetPoint("LEFT", 10, 0)
    c.head:SetScript("OnClick", function() c:SetFolded(not c:IsFolded()) end)
  end
  function c:IsFolded()
    if not opts.fold then return false end
    if opts.get then return opts.get() and true or false end
    return self.folded
  end
  function c:SetFolded(v)
    self.folded = v and true or false
    if opts.set then opts.set(self.folded) end
    if opts.onFold then opts.onFold(self.folded) else self:Layout(self.w) end
  end
  function c:SetAction(w)
    self.action = w
    w:ClearAllPoints()
    w:SetPoint("TOPRIGHT", self, "TOPRIGHT", -6, -2)
    return w
  end
  function c:SetTitle(text) self.title:SetText(text or "") end
  function c:SetContentHeight(h) self.contentH = max(0, num(h, 0)) end
  function c:Layout(w)
    w = max(60, num(w, self.w))
    self.w = w
    local pad = UI.density().pad
    if pad ~= self.pad then
      self.pad = pad
      self.content:ClearAllPoints()
      self.content:SetPoint("TOPLEFT", pad, -CARD_HEAD)
    end
    local folded = self:IsFolded()
    if not folded and opts.onLayout then
      local h = opts.onLayout(self, w - 2 * pad)
      if type(h) == "number" then self.contentH = h end
    end
    local h = CARD_HEAD + (folded and 0 or (self.contentH + pad))
    self.h = h
    self:SetSize(w, h)
    self.content:SetSize(w - 2 * pad, max(1, self.contentH))
    if folded then self.content:Hide() else self.content:Show() end
    if self.head then
      self.head:SetWidth(max(40, w - (self.action and 160 or 0)))
      self.mark:SetText(folded and "+" or "-")
    end
    return h
  end
  return c
end

-- Things under one another, each as tall as it says: heights come from the content, not from constants.
--   s = UI.stack(parent, gap)
--   s:Add(widget, height)   a kit container (card, table, split, another stack) reports its own height and needs
--                           none; anything else gets the fixed height given here (default 22). Returns the widget.
--   s:Layout(w) -> total height     widget.stackSkip = true leaves one out (and hides it)
-- Fields: .items, .h
function UI.stack(parent, gap)
  local s = CreateFrame("Frame", nil, parent)
  s.kitLayout = true
  s.items, s.gap, s.h, s.w = {}, gap or 8, 0, 200
  function s:Add(w, h, fill)
    self.items[#self.items + 1] = { w = w, h = h or 22, fill = fill }
    return w
  end
  function s:Layout(w)
    w = max(40, num(w, self.w))
    self.w = w
    local y = 0
    for _, it in ipairs(self.items) do
      local child = it.w
      if child.stackSkip == true then
        child:Hide()
      else
        local h = it.h
        if child.kitLayout == true then
          h = num(child:Layout(w), it.h)
        elseif it.fill then
          child:SetWidth(w)
        end
        child:ClearAllPoints()
        child:SetPoint("TOPLEFT", self, "TOPLEFT", 0, -y)
        child:Show()
        y = y + h + self.gap
      end
    end
    y = max(1, y - self.gap)
    self.h = y
    self:SetSize(w, y)
    return y
  end
  return s
end

-- A window onto something taller than itself (a stack of cards), with a scroll bar and the mouse wheel.
--   a = UI.scrollArea(parent)     a:Layout(w, h)   a:SetContentHeight(h)   a:ScrollTo(pixels)
-- Fields: .content (parent things to it; it is a.contentW wide), .view (the ScrollFrame), .bar
local SCROLL_STEP = 20
function UI.scrollArea(parent)
  local a = CreateFrame("Frame", nil, parent)
  a.kitLayout = true
  a.w, a.h, a.contentH, a.at = 200, 200, 0, 0
  a.view = CreateFrame("ScrollFrame", nil, a)
  a.view:SetPoint("TOPLEFT", 0, 0)
  a.content = CreateFrame("Frame", nil, a.view)
  a.content:SetSize(180, 10)
  pcall(a.view.SetScrollChild, a.view, a.content)
  local function go(n)
    local most = max(0, ceil((a.contentH - a.h) / SCROLL_STEP))
    a.at = max(0, min(most, floor(num(n, 0) + 0.5)))
    pcall(a.view.SetVerticalScroll, a.view, min(a.at * SCROLL_STEP, max(0, a.contentH - a.h)))
    return a.at
  end
  a.bar = UI.scrollbar(a, function(n) go(n) end)
  a.bar:SetPoint("TOPRIGHT", a, "TOPRIGHT", -2, a.bar.native and -17 or -1)
  a.bar:SetPoint("BOTTOMRIGHT", a, "BOTTOMRIGHT", -2, a.bar.native and 17 or 1)
  a:EnableMouseWheel(true)
  a:SetScript("OnMouseWheel", function(self, delta)
    self.bar:SetOffset(go(self.at - delta * 2))
  end)
  a.contentW = 180
  function a:SetContentHeight(h)
    self.contentH = max(0, num(h, 0))
    self.content:SetHeight(max(1, self.contentH))
    local total, visible = ceil(self.contentH / SCROLL_STEP), floor(self.h / SCROLL_STEP)
    self.bar:SetRange(max(total, visible + ceil(max(0, self.contentH - self.h) / SCROLL_STEP)), visible)
    self.bar:SetOffset(go(self.at))
  end
  function a:ScrollTo(px)
    self.bar:SetOffset(go(num(px, 0) / SCROLL_STEP))
  end
  function a:Layout(w, h)
    w, h = max(60, num(w, self.w)), max(40, num(h, self.h))
    self.w, self.h = w, h
    self:SetSize(w, h)
    self.view:SetSize(w - SCROLL_W, h)
    self.contentW = w - SCROLL_W - 2
    self.content:SetWidth(self.contentW)
    self:SetContentHeight(self.contentH)
    return h
  end
  return a
end

-- ---- stepper ---------------------------------------------------------------------------------------------------------

-- A whole number with - and + beside it; a value can also be typed (Enter or a click elsewhere applies it).
--   st = UI.stepper(parent, o, get, set)
--   o: min, max (numbers or functions), step (a number, or a function of the value now), w (the box's width), tip
-- Fields: .box, .minus, .plus, :Refresh()
function UI.stepper(parent, o, get, set)
  o = o or {}
  local st = CreateFrame("Frame", nil, parent)
  local bw = o.w or 44
  st:SetSize(bw + 52, 22)
  -- min / max: a number, a function returning one, or nothing (also from the function) for no limit
  local function limit(x)
    if type(x) == "function" then x = x() end
    return tonumber(x)
  end
  local function bound(v)
    local lo, hi = limit(o.min), limit(o.max)
    v = floor(num(v, get() or 0) + 0.5)
    if lo and v < lo then v = lo end
    if hi and v > hi then v = hi end
    return v
  end
  local function apply(v)
    v = bound(v)
    if v ~= get() then set(v) end
    st:Refresh()
  end
  local function stepOf()
    local s = o.step
    if type(s) == "function" then s = s(get() or 0) end
    return num(s, 1)
  end
  st.minus = UI.button(st, "-", 22, function() apply((get() or 0) - stepOf()) end)
  st.minus:SetPoint("LEFT", 0, 0)
  st.box = UI.edit(st, bw, true)
  st.box:SetPoint("LEFT", st.minus, "RIGHT", 6, 0)
  st.plus = UI.button(st, "+", 22, function() apply((get() or 0) + stepOf()) end)
  st.plus:SetPoint("LEFT", st.box, "RIGHT", 2, 0)
  st.box:SetScript("OnEnterPressed", function(self)
    local v = tonumber(self:GetText())
    if v then apply(v) end
    self:ClearFocus()
  end)
  st.box:SetScript("OnEditFocusLost", function(self)
    local v = tonumber(self:GetText())
    if v and bound(v) ~= get() then apply(v) else st:Refresh() end
  end)
  function st:Refresh()
    local v = get() or 0
    if not self.box:HasFocus() then self.box:SetText(tostring(v)) end
    local lo, hi = limit(o.min), limit(o.max)
    self.minus:SetEnabled(not (lo and v <= lo), "Already at the lowest value.")
    self.plus:SetEnabled(not (hi and v >= hi), "Already at the highest value.")
  end
  UI.tip(st.box, o.tip)
  st:Refresh()
  return st
end

-- ---- notice ----------------------------------------------------------------------------------------------------------

-- A message bar inside a window, for what would otherwise be a line in chat ("Open the auction house first").
--   n = UI.notice(parent, w)      n:Say(text, kind, seconds)   kind: "info" (default) | "warn" | "error"
--   n:Clear()                     it goes away by itself after `seconds` (6), or on a click
-- Fields: .label, .message (the text now, false when hidden), .kind
local NOTICE_RGB = { info = { 0.15, 0.3, 0.5 }, warn = { 0.5, 0.36, 0.05 }, error = { 0.5, 0.1, 0.1 } }
function UI.notice(parent, w)
  local n = CreateFrame("Button", nil, parent)
  n:SetSize(w or 360, 22)
  n.bg = colour(n, "BACKGROUND", 0.15, 0.3, 0.5, 0.95)
  n.bg:SetAllPoints()
  edges(n, 0.6, 0.6, 0.65, 0.9)
  n.label = UI.text(n, "body")
  n.label:SetPoint("LEFT", 8, 0)
  n.label:SetPoint("RIGHT", -20, 0)
  n.label:SetJustifyH("LEFT")
  n.label:SetWordWrap(false)
  n.x = UI.text(n, "dim", "x")
  n.x:SetPoint("RIGHT", -6, 0)
  n.stamp, n.message, n.kind = 0, false, "info"
  function n:Clear()
    self.message = false
    self:Hide()
  end
  function n:Say(text, kind, seconds)
    if text == nil or text == "" then return self:Clear() end
    kind = NOTICE_RGB[kind] and kind or "info"
    local c = NOTICE_RGB[kind]
    self.bg:SetColorTexture(c[1], c[2], c[3], 0.95)
    self.message, self.kind = text, kind
    self.label:SetText(UI.show(text))
    self.stamp = self.stamp + 1
    local stamp = self.stamp
    self:Show()
    if isTable(C_Timer) and type(C_Timer.After) == "function" then
      C_Timer.After(seconds or 6, function()
        if n.stamp == stamp then n:Clear() end
      end)
    end
  end
  n:SetScript("OnClick", function(self) self:Clear() end)
  n:Hide()
  return n
end

-- ---- what this client has ------------------------------------------------------------------------------------------

local TEMPLATES = { "ButtonFrameTemplate", "PortraitFrameTemplate", "BasicFrameTemplateWithInset", "BackdropTemplate", "UIPanelButtonTemplate",
  "PanelTabButtonTemplate", "InputBoxTemplate", "SearchBoxTemplate", "UICheckButtonTemplate", "InterfaceOptionsCheckButtonTemplate",
  "MinimalSliderWithSteppersTemplate", "OptionsSliderTemplate", "UISliderTemplate", "UIPanelScrollBarTemplate", "WowStyle1DropdownTemplate",
  "TooltipBackdropTemplate", "InsetFrameTemplate" }
UI.TEMPLATES = TEMPLATES

local function path(name)
  local v = _G
  for part in name:gmatch("[^%.]+") do
    if type(v) ~= "table" then return nil end
    v = v[part]
  end
  return v
end

-- Prints which templates, functions and frames the client has, and saves it under KeboldsShinyDB.ui.
function UI.report()
  local function say(msg) print("|cff66ccffKebold UI|r " .. msg) end
  local found = {}
  local out = { found = found }
  local ok, version, build, date, toc = pcall(GetBuildInfo)
  out.build = ok and table.concat({ tostring(version), tostring(build), tostring(date), tostring(toc) }, " ") or "?"
  out.at = type(time) == "function" and time() or 0
  say("build " .. out.build .. ", skin " .. (UI.plain() and "plain" or "auto"))
  local yes, no = {}, {}
  for _, t in ipairs(TEMPLATES) do
    found[t] = UI.probe(t)
    local list = found[t] and yes or no
    list[#list + 1] = t
  end
  say("templates found (" .. #yes .. "): " .. table.concat(yes, ", "))
  say("templates missing (" .. #no .. "): " .. (#no > 0 and table.concat(no, ", ") or "none"))
  yes, no = {}, {}
  for _, name in ipairs({ "MenuUtil.CreateContextMenu", "C_Texture.GetAtlasInfo", "C_Item.GetItemIconByID", "C_Item.GetItemQualityByID",
    "C_Spell.GetSpellTexture", "GetCoinTextureString", "PanelTemplates_SelectTab", "PanelTemplates_TabResize", "SetPortraitToTexture",
    "SearchBoxTemplate_OnTextChanged", "ITEM_QUALITY_COLORS", "AddonCompartmentFrame", "Minimap" }) do
    found[name] = path(name) ~= nil
    local list = found[name] and yes or no
    list[#list + 1] = name
  end
  found["frame.SetResizeBounds"] = isTable(UIParent) and type(UIParent.SetResizeBounds) == "function"
  found["frame.SetMinResize"] = isTable(UIParent) and type(UIParent.SetMinResize) == "function"
  for _, name in ipairs({ "frame.SetResizeBounds", "frame.SetMinResize" }) do
    local list = found[name] and yes or no
    list[#list + 1] = name
  end
  say("functions found (" .. #yes .. "): " .. table.concat(yes, ", "))
  say("functions missing (" .. #no .. "): " .. (#no > 0 and table.concat(no, ", ") or "none"))
  local ah, pf = AuctionHouseFrame, ProfessionsFrame
  local parts = {}
  local function note(name, value)
    found[name] = value
    parts[#parts + 1] = name .. "=" .. tostring(value)
  end
  note("AuctionHouseFrame", isTable(ah))
  if isTable(ah) then
    note("#AuctionHouseFrame.Tabs", isTable(ah.Tabs) and #ah.Tabs or "none")
    note("AuctionHouseFrame.SearchBar.SearchBox", isTable(ah.SearchBar) and isTable(ah.SearchBar.SearchBox))
  end
  note("ProfessionsFrame", isTable(pf))
  if isTable(pf) then
    note("ProfessionsFrame.CraftingPage.SchematicForm", isTable(pf.CraftingPage) and isTable(pf.CraftingPage.SchematicForm))
  end
  say("windows: " .. table.concat(parts, ", ") .. " (open the auction house and a profession first for the full answer)")
  for _, name in ipairs({ "KeboldsShinyFrame", "KeboldsShinyPanel" }) do
    local f = _G[name]
    if isTable(f) and f.skinUsed then found[name .. ".skinUsed"] = f.skinUsed end
  end
  if type(KeboldsShinyDB) ~= "table" then KeboldsShinyDB = {} end
  KeboldsShinyDB.ui = out
  say("Saved. Type /reload so the game writes the file.")
  return out
end

-- ---- gallery ---------------------------------------------------------------------------------------------------------

-- One window with every widget twice: Blizzard's look on the left, the plain fallback on the right.
local gallery
function UI.gallery()
  if gallery then
    if gallery:IsShown() then gallery:Hide() else gallery:Show() end
    return gallery
  end
  local g = UI.window("KeboldsShinyGallery", UIParent, 1180, 640, { top = 60, bottom = 10 })
  gallery = g
  g:SetPoint("CENTER")
  g:SetFrameStrata("DIALOG")
  g:EnableMouse(true)
  g:SetMovable(true)
  g:RegisterForDrag("LeftButton")
  g:SetScript("OnDragStart", g.StartMoving)
  g:SetScript("OnDragStop", g.StopMovingOrSizing)
  g.title:SetText("Kebold's Shiny - widget gallery (" .. g.skinUsed .. ")")
  g:SetIcon("Interface\\Icons\\INV_Misc_Book_09")
  g.made = {}
  local function caption(x, y, text)
    local fs = g:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetText(text)
    return fs
  end
  caption(70, -34, "LEFT: Blizzard's look where this client has it")
  caption(610, -34, "RIGHT: the plain fallback (/kebold skin plain)")
  local sample = "Sells for 12" .. MARK.g .. " 34" .. MARK.s .. " 5" .. MARK.c
  local value, checked = 20, true
  local function column(x, forced)
    UI.forcePlain = forced
    local side = forced and "plain" or "auto"
    local y = -66
    local function put(name, w, h, note)
      w:SetPoint("TOPLEFT", g, "TOPLEFT", x, y)
      caption(x, y - (h or 22) - 1, name .. (note and (": " .. note) or ""))
      y = y - (h or 22) - 16
      g.made[side .. "." .. name] = w
      return w
    end
    local function tpl(...)
      if forced then return "fallback" end
      for _, t in ipairs({ ... }) do
        if UI.probe(t) then return t end
      end
      return "fallback"
    end
    put("button", UI.button(g, "Scan this plan", 120, function() end, "A button."), 22, tpl("UIPanelButtonTemplate"))
    local t1 = put("tab", UI.tab(g, "Route", function() end), 30, tpl("PanelTabButtonTemplate"))
    t1:SetSelected(true)
    local t2 = UI.tab(g, "Recipes", function() end)
    t2:SetPoint("LEFT", t1, "RIGHT", 2, 0)
    t2:SetSelected(false)
    local dd = put("dropdown", UI.dropdown(g, 170, function() return "Recipes: trainer only" end, function()
      return { { title = true, text = "Recipes" }, { radio = true, checked = true, text = "trainer only" }, { radio = true, text = "everything" },
        { divider = true }, { check = true, checked = true, text = "A check box" }, { text = "A plain entry" }, { text = "Not possible", disabled = true } }
    end, "Opens a menu."), 22, (not forced and type(MenuUtil) == "table") and "menu: MenuUtil" or "menu: own popup")
    dd:Refresh()
    local e = put("edit", UI.edit(g, 50, true), 20, tpl("InputBoxTemplate"))
    e:SetText("150")
    put("search", UI.search(g, 140), 20, tpl("SearchBoxTemplate", "InputBoxTemplate"))
    put("check", UI.check(g, "Only priced", function() return checked end, function(v) checked = v end, "A check box."), 22,
      tpl("UICheckButtonTemplate", "InterfaceOptionsCheckButtonTemplate"))
    local sl = UI.slider(g, { min = 0, max = 100, step = 5, w = 300, unit = "%", isChanged = function() return value ~= 20 end },
      function() return value end, function(v) value = v or 20 end)
    put("slider", sl, 22, sl.kind)
    local pr = put("progress", UI.progress(g, 240, 16), 16, "StatusBar")
    pr:Set(31, 58, "31 / 58 \194\183 2 timeouts \194\183 18 s left")
    local hd = put("header", UI.header(g, { { x = 0, w = 150, text = "Recipe" }, { x = 152, w = 70, j = "RIGHT", text = "Profit" } }, function() end), 20,
      forced and "flat" or "WhoFrame-ColumnTabs")
    hd:SetSort(2, true)
    for i = 1, 3 do
      local row = UI.row(g, 300, 20, { { key = "left", x = 20, w = 150 }, { key = "right", r = 2 } })
      local data = i == 1 and { section = "demo", left = "|cffffd100Buy for the first step|r", right = "" }
        or { item = i == 2 and 2840 or 2589, left = i == 2 and "20x Copper Bar" or "4x Linen Cloth", right = sample }
      UI.decorate(row, data, i)
      row.cell.left:SetText(data.left)
      row.cell.right:SetText(UI.show(data.right))
      put("row " .. i, row, 20, i == 1 and "section head" or (forced and "no icon, letters" or "icon and coins"))
      y = y + 16
    end
    y = y - 16
    local sb = UI.scrollbar(g, function() end)
    sb:SetPoint("TOPLEFT", g, "TOPLEFT", x + 310, -90)
    sb:SetHeight(120)
    sb:SetRange(100, 20)
    sb:SetOffset(10)
    caption(x + 296, -230, "scrollbar")
    g.made[side .. ".scrollbar"] = sb
    local bars = put("bars", UI.bars(g, 200, 40), 40, "price history")
    bars:Set({ 5, 7, 6, 9, 12, 8, 4, 6, 7, 10 })
    local w = UI.window(nil, g, 150, 60, { noPortrait = true, top = 26, bottom = 6 })
    w.title:SetText("window")
    put("window", w, 60, w.skinUsed)

    -- the pieces of a page, in a second column
    x, y = x + 330, -66
    local dis = put("button, disabled", UI.button(g, "Scan this plan", 120, function() end, "A button."), 22, "SetEnabled(false, why)")
    dis:SetEnabled(false, "Open the auction house first.")
    local nav = UI.nav(g, 120, function(key) g.made[side .. ".nav"]:Select(key) end)
    nav:Add("level", "Level", "Interface\\Icons\\INV_Misc_Book_09", "A page.")
    nav:Add("prices", "Prices", "Interface\\Icons\\INV_Misc_Coin_01")
    nav:Select("level")
    nav:SetBadge("prices", "!")
    put("nav", nav, 64, forced and "text only" or "icons")
    local tb = UI.table(g, { { key = "left", title = "Item", flex = 1, min = 90, sortable = true }, { key = "c2", title = "Each", width = 60, align = "RIGHT", drop = 1 },
      { key = "right", title = "In all", width = 64, align = "RIGHT", sortable = true } }, { selected = function(row) return row.item == 2589 end })
    tb:Layout(250, 86)
    tb:SetRows({ { left = "20x Copper Bar", c2 = "1" .. MARK.s, right = "20" .. MARK.s, item = 2840 }, { left = "4x Linen Cloth", c2 = "30" .. MARK.c, right = sample, item = 2589 },
      { left = "A line of text across every column" } })
    tb:SetSort(3, true)
    put("table", tb, 86, "heads, lines, scroll bar, selection")
    local te = UI.table(g, { { key = "left", title = "Item", flex = 1 } }, { header = false, empty = { title = "Nothing tracked yet", text = "Post an auction and it shows here." } })
    te:Layout(250, 86)
    te:SetRows({})
    put("table, empty", te, 86, "UI.empty inside")
    local sp = UI.split(g, { rightWidth = 100, minLeft = 60 })
    sp:Layout(250, 40)
    for _, pane in ipairs({ sp.left, sp.right }) do
      local t = pane:CreateTexture(nil, "BACKGROUND")
      t:SetColorTexture(1, 1, 1, 0.06)
      t:SetAllPoints()
    end
    put("split", sp, 40, "click the divider's button")
    local card = UI.card(g, "A card", { height = 26, fold = true })
    local stp = UI.stepper(card.content, { min = 1, max = 50, step = 1 }, function() return value end, function(v) value = v end)
    stp:SetPoint("TOPLEFT", 4, -2)
    card:SetAction(UI.button(card, "Reset", 50, function() end))
    card:Layout(250)
    put("card + stepper", card, card.h, card.native and "InsetFrameTemplate" or "flat")
    local nt = UI.notice(g, 250)
    nt:Say("Open the auction house first.", "warn", 3600)
    put("notice", nt, 22, "goes away by itself")
    local st = UI.stack(g, 2)
    st:Add(UI.text(st, "title", "title"), 16)
    st:Add(UI.text(st, "section", "section"), 14)
    st:Add(UI.text(st, "body", "body"), 12)
    st:Add(UI.text(st, "dim", "dim"), 12)
    st:Layout(250)
    put("stack of the four fonts", st, st.h, "heights from content")
    UI.forcePlain = nil
  end
  local ok, err = pcall(column, 20, false)
  UI.forcePlain = nil
  if not ok then print("|cff66ccffKebold UI|r gallery, left side: " .. tostring(err)) end
  ok, err = pcall(column, 600, true)
  UI.forcePlain = nil
  if not ok then print("|cff66ccffKebold UI|r gallery, right side: " .. tostring(err)) end
  g:Show()
  return g
end
