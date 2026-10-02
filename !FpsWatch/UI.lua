-- Report window (FPS graph + copyable report text) and the live meter.

local FW = FpsWatch
local UI = {}
FW.UI = UI

local floor, ceil = math.floor, math.ceil
local format = string.format
local getn, tinsert = table.getn, table.insert
local CF = FW.CreateOwnFrame

local W, H = 780, 600
local GRAPH_H = 140
local frame, graph, scroll, edit, title, pageText, older, newer, measure
local bars, marks = {}, {}
local current = 1
local settingText = false

local function Clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function Backdrop(f, a)
  f:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
  })
  f:SetBackdropColor(0.05, 0.05, 0.08, a)
  f:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
end

local function Button(name, text, width)
  local b = CF("Button", name, frame, "UIPanelButtonTemplate")
  b:SetWidth(width)
  b:SetHeight(22)
  b:SetText(text)
  return b
end

local function Label(parent, template)
  local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
  fs:SetJustifyH("LEFT")
  return fs
end

----------------------------------------------------------------------
-- Graph
----------------------------------------------------------------------
local function Tex(layer)
  local t = graph:CreateTexture(nil, layer or "ARTWORK")
  t:SetTexture(1, 1, 1, 1)
  return t
end

local function HideAll(list)
  for _, t in pairs(list) do t:Hide() end
end

local function DrawGraph(s)
  HideAll(bars)
  HideAll(marks)
  graph.s = nil
  graph.line:Hide()
  graph.lineLabel:SetText("")
  graph.topLabel:SetText("")
  graph.x0:SetText("")
  graph.x1:SetText("")
  graph.x2:SetText("")
  if not s or not s.samples or (s.nSamples or 0) == 0 then
    graph.empty:Show()
    return
  end
  graph.empty:Hide()
  local samples, n = s.samples, s.nSamples
  local gw, gh = graph:GetWidth(), graph:GetHeight()
  local per = 1
  local maxBars = floor(gw / 2)
  if n > maxBars then per = ceil(n / maxBars) end
  local nb = ceil(n / per)
  local bw = gw / nb
  local top = 30
  for i = 1, n do
    if samples[i].f > top then top = samples[i].f end
  end
  top = ceil(top / 10) * 10
  graph.s, graph.per, graph.nb, graph.bw, graph.top = s, per, nb, bw, top

  for b = 1, nb do
    local lo = (b - 1) * per + 1
    local hi = b * per
    if hi > n then hi = n end
    local f, gc, slow = 1e9, false, false
    for i = lo, hi do
      local smp = samples[i]
      if smp.f < f then f = smp.f end
      if smp.gc then gc = true end
      if smp.s then slow = true end
    end
    local bar = bars[b]
    if not bar then
      bar = Tex("ARTWORK")
      bars[b] = bar
    end
    bar:ClearAllPoints()
    bar:SetPoint("BOTTOMLEFT", graph, "BOTTOMLEFT", (b - 1) * bw, 0)
    local width = bw
    if bw >= 3 then width = bw - 1 end
    bar:SetWidth(width)
    local h = gh * Clamp(f, 0, top) / top
    if h < 1 then h = 1 end
    bar:SetHeight(h)
    if f < s.dropFps then
      bar:SetTexture(0.9, 0.2, 0.2, 0.9)
    elseif f < s.dropFps * 2 or slow then
      bar:SetTexture(0.95, 0.65, 0.15, 0.9)
    else
      bar:SetTexture(0.25, 0.8, 0.35, 0.9)
    end
    bar:Show()
    if gc then
      local m = marks[b]
      if not m then
        m = Tex("OVERLAY")
        marks[b] = m
      end
      m:ClearAllPoints()
      m:SetPoint("TOPLEFT", graph, "TOPLEFT", (b - 1) * bw, 0)
      m:SetWidth(width)
      m:SetHeight(5)
      m:SetTexture(1, 0.9, 0.1, 1)
      m:Show()
    end
  end

  local y = gh * s.dropFps / top
  graph.line:ClearAllPoints()
  graph.line:SetPoint("BOTTOMLEFT", graph, "BOTTOMLEFT", 0, y)
  graph.line:SetWidth(gw)
  graph.line:Show()
  graph.lineLabel:ClearAllPoints()
  graph.lineLabel:SetPoint("RIGHT", graph, "BOTTOMLEFT", -3, y)
  graph.lineLabel:SetText(s.dropFps)
  graph.topLabel:SetText(top)
  graph.x0:SetText("0:00")
  graph.x1:SetText(FW.fmtTime(samples[floor((n + 1) / 2)].t))
  graph.x2:SetText(FW.fmtTime(samples[n].t))
end

local function Hover()
  local s = graph.s
  if not s then return end
  local x = GetCursorPosition()
  local scale = graph:GetEffectiveScale()
  x = x / scale - graph:GetLeft()
  local b = floor(x / graph.bw) + 1
  if b < 1 or b > graph.nb then
    GameTooltip:Hide()
    graph.cursor:Hide()
    return
  end
  if b == graph.hoverBar and GameTooltip:IsShown() then return end
  graph.hoverBar = b
  graph.cursor:ClearAllPoints()
  graph.cursor:SetPoint("BOTTOMLEFT", graph, "BOTTOMLEFT", (b - 1) * graph.bw, 0)
  graph.cursor:SetWidth(graph.bw)
  graph.cursor:SetHeight(graph:GetHeight())
  graph.cursor:Show()

  local lo = (b - 1) * graph.per + 1
  local hi = b * graph.per
  if hi > s.nSamples then hi = s.nSamples end
  -- Show the worst second in this bar.
  local smp = s.samples[lo]
  for i = lo + 1, hi do
    if s.samples[i].f < smp.f then smp = s.samples[i] end
  end
  GameTooltip:SetOwner(graph, "ANCHOR_CURSOR")
  GameTooltip:AddLine(format("%s  -  %.0f FPS (worst frame %.0f FPS)", FW.fmtTime(smp.t), smp.f, smp.mn), 1, 1, 1)
  if smp.h then GameTooltip:AddLine(format("Scripts: %.0f%% of frame time", smp.h), 0.8, 0.8, 0.8) end
  GameTooltip:AddLine(format("Lua heap %.1f MB, garbage %d KB/s%s", smp.m or 0, smp.al or 0, smp.gc and ", |cffffe000GC ran|r" or ""), 0.8, 0.8, 0.8)
  local extra = {}
  if smp.np then tinsert(extra, "nameplates " .. smp.np) end
  if smp.ev then tinsert(extra, "events " .. smp.ev .. "/s") end
  if smp.bh then tinsert(extra, "boss " .. smp.bh .. "%") end
  if getn(extra) > 0 then GameTooltip:AddLine(table.concat(extra, ", "), 0.8, 0.8, 0.8) end
  if smp.sa then
    for i = 1, getn(smp.sa) do
      GameTooltip:AddDoubleLine(smp.sa[i].n, format("%.0f ms", smp.sa[i].v), 1, 0.82, 0, 1, 1, 1)
    end
  end
  if smp.se then
    for i = 1, getn(smp.se) do
      GameTooltip:AddDoubleLine(smp.se[i].n, smp.se[i].v .. "/s", 0.6, 0.8, 1, 1, 1, 1)
    end
  end
  for i = 1, s.nTimeline or 0 do
    local x = s.timeline[i]
    if x.t >= smp.t - 4 and x.t <= smp.t then
      GameTooltip:AddLine(FW.fmtTime(x.t) .. " " .. FW.TimelineText(x), 1, 0.5, 0.5)
    end
  end
  GameTooltip:Show()
end

----------------------------------------------------------------------
-- Window
----------------------------------------------------------------------
local function SetReportText(text)
  edit.text = text
  settingText = true
  edit:SetText(text)
  settingText = false
  measure:SetText(text)
  local h = measure:GetHeight() or 0
  -- Fallback if the client doesn't report wrapped height: count lines.
  local lines = 1
  for _ in string.gfind(text, "\n") do lines = lines + 1 end
  if h < lines * 12 then h = lines * 12 end
  edit:SetHeight(h + 30)
  scroll:UpdateScrollChildRect()
  local bar = getglobal("FpsWatchReportScrollScrollBar")
  if bar then bar:SetValue(0) else scroll:SetVerticalScroll(0) end
end

local NO_REPORTS = table.concat({
  "No reports yet.",
  "",
  "FpsWatch records every fight automatically and keeps the boss fights",
  "(and any fight where FPS dropped). After the next boss this window shows",
  "an FPS graph and what was eating your frame time.",
  "",
  "Want to see it working first? Type /fpsw test (takes 10 seconds).",
  "Other commands: /fpsw help",
}, "\n")

local function Render()
  if not frame then return end
  local reports = FW.db.reports
  local n = getn(reports)
  if n == 0 then
    title:SetText("FpsWatch")
    pageText:SetText("")
    older:Disable()
    newer:Disable()
    DrawGraph(nil)
    SetReportText(NO_REPORTS)
    return
  end
  current = Clamp(current, 1, n)
  local s = reports[current]
  title:SetText(format("FpsWatch - %s - %s", FW.SessionTitle(s), s.date or ""))
  pageText:SetText(format("%d / %d", current, n))
  if current < n then older:Enable() else older:Disable() end
  if current > 1 then newer:Enable() else newer:Disable() end
  DrawGraph(s)
  if not s.text then s.text = FW.BuildReportText(s) end
  SetReportText(s.text)
end

local function Build()
  frame = CF("Frame", "FpsWatchReportFrame", UIParent)
  frame:SetWidth(W)
  frame:SetHeight(H)
  frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  frame:SetFrameStrata("DIALOG")
  frame:EnableMouse(true)
  frame:SetMovable(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function() frame:StartMoving() end)
  frame:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)
  Backdrop(frame, 0.95)
  frame:Hide()
  tinsert(UISpecialFrames, "FpsWatchReportFrame")

  title = Label(frame, "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -12)
  title:SetWidth(W - 60)
  title:SetHeight(20)

  local close = CF("Button", "FpsWatchReportClose", frame, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)

  graph = CF("Frame", "FpsWatchGraph", frame)
  graph:SetPoint("TOPLEFT", frame, "TOPLEFT", 40, -44)
  graph:SetWidth(W - 60)
  graph:SetHeight(GRAPH_H)
  local bg = graph:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(graph)
  bg:SetTexture(0, 0, 0, 0.6)
  graph.line = Tex("OVERLAY")
  graph.line:SetHeight(1)
  graph.line:SetTexture(1, 0.3, 0.3, 0.8)
  graph.cursor = Tex("BORDER")
  graph.cursor:SetTexture(1, 1, 1, 0.15)
  graph.cursor:Hide()
  graph.lineLabel = Label(graph)
  graph.topLabel = Label(graph)
  graph.topLabel:SetPoint("TOPRIGHT", graph, "TOPLEFT", -3, 0)
  graph.yUnit = Label(graph)
  graph.yUnit:SetPoint("BOTTOMRIGHT", graph, "BOTTOMLEFT", -3, 0)
  graph.yUnit:SetText("FPS")
  graph.x0 = Label(graph)
  graph.x0:SetPoint("TOPLEFT", graph, "BOTTOMLEFT", 0, -2)
  graph.x1 = Label(graph)
  graph.x1:SetPoint("TOP", graph, "BOTTOM", 0, -2)
  graph.x2 = Label(graph)
  graph.x2:SetPoint("TOPRIGHT", graph, "BOTTOMRIGHT", 0, -2)
  graph.empty = Label(graph, "GameFontNormalSmall")
  graph.empty:SetPoint("CENTER", graph, "CENTER", 0, 0)
  graph.empty:SetText("no data")
  graph:EnableMouse(true)
  graph:SetScript("OnEnter", function() graph.hover = true; graph.hoverBar = nil end)
  graph:SetScript("OnLeave", function()
    graph.hover = false
    graph.cursor:Hide()
    GameTooltip:Hide()
  end)
  graph:SetScript("OnUpdate", function() if graph.hover then Hover() end end)

  local legend = Label(frame)
  legend:SetPoint("TOPLEFT", graph, "BOTTOMLEFT", 60, -2)
  legend:SetText("|cffe63333red|r below drop line   |cfff2a626orange|r slow   |cff40cc59green|r fine   |cffffe61ayellow tick|r Lua GC   (hover for details)")

  older = Button("FpsWatchReportOlder", "< Older", 80)
  older:SetPoint("TOPLEFT", graph, "BOTTOMLEFT", -26, -20)
  older:SetScript("OnClick", function() current = current + 1; Render() end)
  newer = Button("FpsWatchReportNewer", "Newer >", 80)
  newer:SetPoint("LEFT", older, "RIGHT", 4, 0)
  newer:SetScript("OnClick", function() current = current - 1; Render() end)
  pageText = Label(frame)
  pageText:SetPoint("LEFT", newer, "RIGHT", 8, 0)
  local sel = Button("FpsWatchReportSelect", "Select all", 90)
  sel:SetPoint("LEFT", newer, "RIGHT", 70, 0)
  sel:SetScript("OnClick", function()
    edit:SetFocus()
    edit:HighlightText()
  end)
  local hint = Label(frame)
  hint:SetPoint("LEFT", sel, "RIGHT", 8, 0)
  hint:SetText("then Ctrl+C to copy the report")

  scroll = CF("ScrollFrame", "FpsWatchReportScroll", frame, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -(44 + GRAPH_H + 50))
  scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -34, 12)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function()
    local maxv = scroll:GetVerticalScrollRange()
    local v = Clamp(scroll:GetVerticalScroll() - arg1 * 60, 0, maxv)
    local bar = getglobal("FpsWatchReportScrollScrollBar")
    if bar then bar:SetValue(v) else scroll:SetVerticalScroll(v) end
  end)

  local textWidth = W - 60
  edit = CF("EditBox", "FpsWatchReportEdit", scroll)
  edit:SetMultiLine(true)
  edit:SetAutoFocus(false)
  edit:SetFontObject(GameFontHighlightSmall)
  edit:SetWidth(textWidth)
  edit:SetHeight(400)
  edit:SetScript("OnEscapePressed", function() edit:ClearFocus() end)
  edit:SetScript("OnTextChanged", function()
    -- Read-only: put the report back if something was typed.
    if not settingText and edit.text then
      settingText = true
      edit:SetText(edit.text)
      settingText = false
    end
  end)
  scroll:SetScrollChild(edit)

  -- Hidden copy of the text, used to measure how tall the report is.
  measure = frame:CreateFontString(nil, "BACKGROUND", "GameFontHighlightSmall")
  measure:SetWidth(textWidth)
  measure:SetJustifyH("LEFT")
  measure:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 0, -2000)
  measure:SetTextColor(0, 0, 0, 0)
end

function UI.ShowReport(i)
  if not FW.db then return end
  if not frame then Build() end
  current = i or 1
  Render()
  frame:Show()
end

function UI.Refresh()
  if frame and frame:IsVisible() then
    current = 1
    Render()
  end
end

----------------------------------------------------------------------
-- Live meter
----------------------------------------------------------------------
local meter

local function SaveMeterPos()
  local point, _, relPoint, x, y = meter:GetPoint()
  FW.db.meterPos = { point = point, rel = relPoint, x = x, y = y }
end

local function BuildMeter()
  meter = CF("Frame", "FpsWatchMeter", UIParent)
  meter:SetWidth(330)
  meter:SetHeight(24)
  local pos = FW.db.meterPos
  if pos and pos.point then
    meter:SetPoint(pos.point, UIParent, pos.rel or pos.point, pos.x or 0, pos.y or 0)
  else
    meter:SetPoint("TOP", UIParent, "TOP", 0, -120)
  end
  Backdrop(meter, 0.7)
  meter:EnableMouse(true)
  meter:SetMovable(true)
  meter:RegisterForDrag("LeftButton")
  meter:SetScript("OnDragStart", function() meter:StartMoving() end)
  meter:SetScript("OnDragStop", function()
    meter:StopMovingOrSizing()
    SaveMeterPos()
  end)
  meter:SetScript("OnMouseUp", function()
    if arg1 == "RightButton" then UI.ShowReport(1) end
  end)
  meter.text = Label(meter)
  meter.text:SetPoint("LEFT", meter, "LEFT", 8, 0)
  meter.text:SetPoint("RIGHT", meter, "RIGHT", -8, 0)
end

function UI.UpdateMeter()
  if not meter or not meter:IsVisible() then return end
  local live = FW.live
  local fps = live.fps or 0
  local col = "40cc59"
  if fps < (FW.cfg and FW.cfg.dropFps or 20) then
    col = "e63333"
  elseif fps < 40 then
    col = "f2a626"
  end
  local eta = "?"
  if live.alloc and live.alloc > 0 and live.thr > live.mem then
    local secs = (live.thr - live.mem) / live.alloc
    if secs > 600 then eta = ">10m" else eta = FW.fmtTime(secs) end
  end
  local txt = format("|cff%sFPS %.0f|r   Lua %.1f MB  +%d KB/s   next GC ~%s", col, fps, (live.mem or 0) / 1024, live.alloc or 0, eta)
  if FW.IsRecording() then
    txt = txt .. "   |cffff4040REC " .. FW.fmtTime(FW.R.clock) .. "|r"
  end
  meter.text:SetText(txt)
end

function UI.SetMeterShown(show)
  if show then
    if not meter then BuildMeter() end
    meter:Show()
    UI.UpdateMeter()
  elseif meter then
    meter:Hide()
  end
end

function UI.Init()
  if FW.cfg.meter then UI.SetMeterShown(true) end
end
