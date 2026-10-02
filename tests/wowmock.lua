-- Minimal WoW 1.12 API mock for running FpsWatch under a real Lua 5.0 interpreter.
MOCK = { frames = {}, chat = {}, simTime = 0, renderMs = 10, units = {}, cvars = {} }

local noop = function() end
local Methods = {}
local FrameMT = { __index = function(t, k)
  local m = Methods[k]
  if m then return m end
  -- only method names (Capitalized) fall back to a no-op
  if type(k) == "string" and string.find(k, "^%u") then return noop end
  return nil
end }

local function NewRegion(kind)
  local r = { kind = kind, w = 0, h = 0, shown = true }
  return setmetatable(r, { __index = function(t, k)
    if k == "GetHeight" then return function(self)
      if self.text and self.kind == "FontString" then
        local n = 1
        for _ in string.gfind(self.text, "\n") do n = n + 1 end
        return n * 12
      end
      return self.h end end
    if k == "GetWidth" then return function(self) return self.w end end
    if k == "SetWidth" then return function(self, v) self.w = v end end
    if k == "SetHeight" then return function(self, v) self.h = v end end
    if k == "SetText" then return function(self, v) self.text = v end end
    if k == "GetText" then return function(self) return self.text end end
    if k == "Show" then return function(self) self.shown = true end end
    if k == "Hide" then return function(self) self.shown = false end end
    if k == "IsShown" then return function(self) return self.shown end end
    return noop
  end })
end

function CreateFrame(ftype, name, parent, template)
  local f = setmetatable({ ftype = ftype, name = name, parent = parent, scripts = {}, events = {}, shown = true,
    kids = {}, w = 0, h = 0, regions = {} }, FrameMT)
  table.insert(MOCK.frames, f)
  f.__idx = table.getn(MOCK.frames)
  if parent then table.insert(parent.kids, f) end
  if name then setglobal(name, f) end
  if ftype == "ScrollFrame" and template and name then
    local bar = CreateFrame("Slider", name .. "ScrollBar", f)
  end
  return f
end

function setglobal(n, v) _G[n] = v end
function getglobal(n) return _G[n] end

function Methods:SetScript(s, fn) self.scripts[s] = fn end
function Methods:GetScript(s) return self.scripts[s] end
function Methods:RegisterEvent(e) self.events[e] = true end
function Methods:UnregisterEvent(e) self.events[e] = nil end
function Methods:UnregisterAllEvents() self.events = {}; self.allEvents = false end
function Methods:RegisterAllEvents() self.allEvents = true end
function Methods:GetName() return rawget(self, "name") end
function Methods:GetParent() return rawget(self, "parent") end
function Methods:GetChildren() return unpack(self.kids) end
function Methods:Show() self.shown = true end
function Methods:Hide() self.shown = false end
function Methods:IsShown() return self.shown end
function Methods:IsVisible()
  local f = self
  while f do
    if not rawget(f, "shown") then return false end
    f = rawget(f, "parent")
  end
  return true
end
function Methods:SetWidth(v) self.w = v end
function Methods:SetHeight(v) self.h = v end
function Methods:GetWidth() return self.w end
function Methods:GetHeight() return self.h end
function Methods:GetLeft() return 100 end
function Methods:GetEffectiveScale() return 1 end
function Methods:GetVerticalScroll() return rawget(self, "vs") or 0 end
function Methods:SetVerticalScroll(v) self.vs = v end
function Methods:GetVerticalScrollRange() return 500 end
function Methods:GetPoint() return "TOP", UIParent, "TOP", 0, -120 end
function Methods:CreateTexture() local r = NewRegion("Texture"); table.insert(self.regions, r); return r end
function Methods:CreateFontString() local r = NewRegion("FontString"); table.insert(self.regions, r); return r end
function Methods:SetText(t) self.text = t end
function Methods:GetText() return rawget(self, "text") end
function Methods:SetValue(v) self.value = v end

function EnumerateFrames(f)
  local i = f and f.__idx + 1 or 1
  return MOCK.frames[i]
end

-- engine helpers --------------------------------------------------------
local lastClock = os.clock()
function MOCK.Fire(e, a1, a2, a3, a4, a5)
  local list = {}
  for i = 1, table.getn(MOCK.frames) do
    local f = MOCK.frames[i]
    if (f.events[e] or rawget(f, "allEvents")) and f.scripts.OnEvent then table.insert(list, f) end
  end
  for i = 1, table.getn(list) do
    local f = list[i]
    local fn = f.scripts.OnEvent
    if fn then
      this, event, arg1, arg2, arg3, arg4, arg5 = f, e, a1, a2, a3, a4, a5
      fn()
    end
  end
end

-- One rendered frame: OnUpdates with the measured elapsed plus fake render time.
function MOCK.Tick(extraRenderMs)
  local now = os.clock()
  local elapsed = (now - lastClock) + (MOCK.renderMs + (extraRenderMs or 0)) / 1000
  lastClock = now
  MOCK.simTime = MOCK.simTime + elapsed
  local list = {}
  for i = 1, table.getn(MOCK.frames) do
    local f = MOCK.frames[i]
    if f.scripts.OnUpdate and f:IsVisible() then table.insert(list, f) end
  end
  for i = 1, table.getn(list) do
    local f = list[i]
    local fn = f.scripts.OnUpdate
    if fn then
      this, arg1 = f, elapsed
      fn()
    end
  end
end

function MOCK.Busy(ms)
  local t0 = os.clock()
  while (os.clock() - t0) * 1000 < ms do end
end

-- API -------------------------------------------------------------------
function debugprofilestop() return os.clock() * 1000 end
function GetTime() return MOCK.simTime end
function GetFramerate() return 60 end
date = os.date
time = os.time
function GetRealZoneText() return MOCK.zone or "Molten Core" end
function GetSubZoneText() return "" end
function GetRealmName() return "OctoWoW" end
function GetBuildInfo() return "1.12.1", "5875", "Sep 19 2006" end
function GetNetStats() return 0, 0, 85 end
function GetCVar(n)
  local v = MOCK.cvars[n]
  if v == nil then error("Couldn't find CVar named '" .. n .. "'") end
  return v
end
MOCK.cvars = { farclip = "777", spellEffectLevel = "2", weatherDensity = "3", gxApi = "d3d", maxfps = "0", ffxGlow = "1" }

MOCK.addons = { "!FpsWatch", "HeavyAddon", "GarbageAddon", "PlatesAddon", "BigWigs" }
function GetNumAddOns() return table.getn(MOCK.addons) end
function GetAddOnInfo(i) return MOCK.addons[i], MOCK.addons[i] end
function IsAddOnLoaded(i) return 1 end

function GetNumRaidMembers() return MOCK.raid or 0 end
function GetNumPartyMembers() return 0 end
local function U(u) return MOCK.units[u] end
function UnitExists(u) return U(u) ~= nil end
function UnitIsDead(u) return U(u) and U(u).dead end
function UnitIsDeadOrGhost(u) return U(u) and U(u).dead end
function UnitClassification(u) return U(u) and U(u).class or "normal" end
function UnitLevel(u) return U(u) and U(u).level or 60 end
function UnitCanAttack(a, u) return U(u) and U(u).hostile end
function UnitName(u) return U(u) and U(u).name end
function UnitAffectingCombat(u) return U(u) and U(u).combat end
function UnitHealth(u) return U(u) and U(u).hp or 0 end
function UnitHealthMax(u) return U(u) and U(u).hpmax or 0 end

DEFAULT_CHAT_FRAME = { AddMessage = function(self, m)
  m = string.gsub(m, "|c%x%x%x%x%x%x%x%x", "")
  m = string.gsub(m, "|r", "")
  table.insert(MOCK.chat, m)
  if MOCK.echo then print("[chat] " .. m) end
end }
SlashCmdList = {}
UISpecialFrames = {}
GameFontHighlightSmall, GameFontNormalLarge, GameFontDisable = {}, {}, {}

SPELLCASTOTHERSTART = "%s begins to cast %s."
SPELLCASTGOOTHER = "%s casts %s."
UNITDIESOTHER = "%s dies."

-- Blizzard UI made before any addon loads
UIParent = CreateFrame("Frame", "UIParent")
WorldFrame = CreateFrame("Frame", "WorldFrame")
GameTooltip = CreateFrame("GameTooltip", "GameTooltip", UIParent)
GameTooltip.IsShown = function() return false end
for i = 1, 3 do
  local cf = CreateFrame("ScrollingMessageFrame", "ChatFrame" .. i, UIParent)
  cf:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_PARTY_DAMAGE")
  cf:SetScript("OnEvent", function() MOCK.Busy(0.05) local s = "formatted " .. tostring(arg1) end)
end
