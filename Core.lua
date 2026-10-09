-- FpsWatch: find out why FPS drops during boss fights.
-- Written for the 1.12 client (Lua 5.0): no '#', no '%' operator, no string
-- methods, handlers read this/event/arg1 globals.

FpsWatch = {}
local FW = FpsWatch
FW.VERSION = "1.0.0"

local floor = math.floor
local format = string.format
local strfind, strlower, strsub = string.find, string.lower, string.sub
local getn, tinsert = table.getn, table.insert

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
-- Lua 5.0's table.getn caches sizes set by tinsert, so clearing the
-- entries is not enough: the cached size has to go back to 0 as well.
function FW.wipe(t)
  for k in pairs(t) do t[k] = nil end
  if table.setn then table.setn(t, 0) end
  return t
end

function FW.round1(x)
  return floor(x * 10 + 0.5) / 10
end

function FW.fmtTime(sec)
  sec = floor((sec or 0) + 0.5)
  local m = floor(sec / 60)
  return format("%d:%02d", m, sec - m * 60)
end

function FW.Print(msg)
  if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99FpsWatch|r: " .. msg)
  end
end

-- Turns a GlobalStrings format ("%s casts %s on %s.") into a Lua pattern.
function FW.FormatToPattern(fmt)
  local p = string.gsub(fmt, "([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
  p = string.gsub(p, "%%%d%$s", "(.-)")
  p = string.gsub(p, "%%%d%$d", "(%%d+)")
  p = string.gsub(p, "%%s", "(.-)")
  p = string.gsub(p, "%%d", "(%%d+)")
  return "^" .. p
end

----------------------------------------------------------------------
-- Precise timer. GetTime() is cached per frame, so handler timing needs
-- debugprofilestop(). Without it we still record FPS, GC and events.
----------------------------------------------------------------------
local function ProbeTimer()
  if type(debugprofilestop) ~= "function" then return nil end
  local ok, a = pcall(debugprofilestop)
  if not ok or type(a) ~= "number" then return nil end
  local x = 0
  for i = 1, 200000 do x = x + i end
  local b = debugprofilestop()
  if b > a then return debugprofilestop end
  if type(debugprofilestart) == "function" then
    debugprofilestart()
    a = debugprofilestop()
    for i = 1, 200000 do x = x + i end
    b = debugprofilestop()
    if b > a then return debugprofilestop end
  end
  return nil
end
FW.timer = ProbeTimer()

----------------------------------------------------------------------
-- Frame ownership. FpsWatch loads first (the "!" in the folder name), so
-- every frame other addons create through CreateFrame passes through this
-- hook and we can read which addon file created it from the call stack.
----------------------------------------------------------------------
FW.frameOwner = setmetatable({}, { __mode = "k" })
FW.preexisting = setmetatable({}, { __mode = "k" })
FW.own = setmetatable({}, { __mode = "k" })

function FW.OwnerFromWhere(where)
  if type(where) ~= "string" or where == "" then return nil end
  local _, _, addon = strfind(where, "[Aa][Dd][Dd][Oo][Nn][Ss][\\/]([^\\/]+)[\\/]")
  if addon then return addon end
  if strfind(where, "FrameXML") then return "Blizzard UI" end
  return nil
end

-- Frames that exist before any addon runs are the default Blizzard UI.
if EnumerateFrames then
  pcall(function()
    local f = EnumerateFrames()
    while f do
      FW.preexisting[f] = true
      f = EnumerateFrames(f)
    end
  end)
end

FW.ownedFrames = 0
local origCreateFrame = CreateFrame
FW.origCreateFrame = origCreateFrame
CreateFrame = function(...)
  local f = origCreateFrame(unpack(arg))
  if f then
    -- level 3 = whoever called CreateFrame
    local ok, where = pcall(error, "", 3)
    if ok == false and where then
      local ok2, owner = pcall(FW.OwnerFromWhere, where)
      if ok2 and owner then
        FW.frameOwner[f] = owner
        FW.ownedFrames = FW.ownedFrames + 1
      end
    end
  end
  return f
end

-- Frames FpsWatch makes for itself are never profiled.
function FW.CreateOwnFrame(ftype, name, parent, template)
  local f
  if template then
    f = origCreateFrame(ftype, name, parent, template)
  elseif parent then
    f = origCreateFrame(ftype, name, parent)
  else
    f = origCreateFrame(ftype, name)
  end
  FW.own[f] = true
  return f
end

----------------------------------------------------------------------
-- Saved settings
----------------------------------------------------------------------
FW.defaults = {
  dropFps = 20,      -- a second averaging below this is a drop
  hitchMs = 150,     -- a single frame at least this long is a hitch
  profile = true,    -- time every frame's OnEvent/OnUpdate during fights
  gcBench = true,    -- time one full Lua GC right after each fight
  gcGuard = false,   -- raise the GC threshold at pull, collect after combat
  gcGuardMB = 64,
  keepTrash = false, -- keep reports for non-boss fights without drops
  chat = true,
  autoOpen = false,
  meter = false,
  maxReports = 15,
}

function FW.InitDB()
  if type(FpsWatchDB) ~= "table" then FpsWatchDB = {} end
  local db = FpsWatchDB
  if type(db.settings) ~= "table" then db.settings = {} end
  for k, v in pairs(FW.defaults) do
    if db.settings[k] == nil then db.settings[k] = v end
  end
  if type(db.reports) ~= "table" then db.reports = {} end
  FW.db = db
  FW.cfg = db.settings
end

----------------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------------
local function OnOff(v)
  if v then return "|cff00ff00on|r" end
  return "|cffff4040off|r"
end

local function ParseBool(word, current)
  if word == "on" or word == "1" or word == "true" then return true end
  if word == "off" or word == "0" or word == "false" then return false end
  return not current
end

local HELP = {
  "|cff33ff99FpsWatch|r " .. FW.VERSION .. ": records every boss fight automatically.",
  "  /fpsw - open the report window",
  "  /fpsw meter - toggle the live FPS / Lua memory meter",
  "  /fpsw start, stop - record manually (trash, a city, anything)",
  "  /fpsw test - 11 second self-test with fake lag",
  "  /fpsw list - list saved reports",
  "  /fpsw drop <fps> - FPS that counts as a drop",
  "  /fpsw hitch <ms> - frame length that counts as a hitch",
  "  /fpsw profile on/off - time every addon's scripts during fights",
  "  /fpsw gcguard on/off [MB] - push Lua garbage collection out of fights",
  "  /fpsw gcbench on/off - time one full Lua GC after each fight",
  "  /fpsw trash on/off - keep reports for non-boss fights without drops",
  "  /fpsw auto on/off - open the report after a fight with drops",
  "  /fpsw chat on/off - print a summary in chat after fights",
  "  /fpsw clear - delete saved reports",
  "  /fpsw status - show settings",
}

function FW.Status()
  local c = FW.cfg
  FW.Print(format("drop < %d FPS, hitch >= %d ms, profile %s, gcbench %s, gcguard %s (%d MB), trash %s, auto %s, chat %s",
    c.dropFps, c.hitchMs, OnOff(c.profile), OnOff(c.gcBench), OnOff(c.gcGuard), c.gcGuardMB,
    OnOff(c.keepTrash), OnOff(c.autoOpen), OnOff(c.chat)))
  if not FW.timer then
    FW.Print("|cffff8040No debugprofilestop() on this client: per-addon timing is off, FPS/GC/event data still works.|r")
  end
  local mem, thr = gcinfo()
  FW.Print(format("Lua heap %.1f MB, next GC at %.1f MB. %d saved report(s).%s",
    mem / 1024, thr / 1024, getn(FW.db.reports), FW.IsRecording() and " |cffff4040Recording now.|r" or ""))
end

local function ListReports()
  local reports = FW.db.reports
  if getn(reports) == 0 then
    FW.Print("No reports yet. They are made automatically when you fight a boss.")
    return
  end
  for i = 1, getn(reports) do
    local r = reports[i]
    DEFAULT_CHAT_FRAME:AddMessage(format("  %d. %s  %s (%s) %s - %s", i, r.date or "?", r.name or "?",
      r.result or r.kind or "?", FW.fmtTime(r.duration), r.verdict or ""))
  end
end

SLASH_FPSWATCH1 = "/fpsw"
SLASH_FPSWATCH2 = "/fpswatch"
SlashCmdList["FPSWATCH"] = function(msg)
  msg = strlower(msg or "")
  local _, _, cmd, rest = strfind(msg, "^%s*(%S*)%s*(.-)%s*$")
  cmd = cmd or ""
  local c = FW.cfg
  if cmd == "" or cmd == "show" or cmd == "report" then
    local n = tonumber(rest)
    FW.UI.ShowReport(n or 1)
  elseif cmd == "help" or cmd == "?" then
    for i = 1, getn(HELP) do DEFAULT_CHAT_FRAME:AddMessage(HELP[i]) end
  elseif cmd == "meter" then
    c.meter = ParseBool(rest, c.meter)
    FW.UI.SetMeterShown(c.meter)
  elseif cmd == "start" then
    if FW.IsRecording() then FW.Print("Already recording.") else
      FW.StartSession("manual")
      FW.Print("Recording. Type /fpsw stop when done.")
    end
  elseif cmd == "stop" then
    if FW.IsRecording() then FW.StopSession("stopped") else FW.Print("Not recording.") end
  elseif cmd == "test" then
    FW.SelfTest()
  elseif cmd == "list" then
    ListReports()
  elseif cmd == "drop" then
    local v = tonumber(rest)
    if v and v >= 5 and v <= 200 then c.dropFps = v end
    FW.Print("A second averaging below " .. c.dropFps .. " FPS counts as a drop.")
  elseif cmd == "hitch" then
    local v = tonumber(rest)
    if v and v >= 30 and v <= 5000 then c.hitchMs = v end
    FW.Print("A single frame of " .. c.hitchMs .. " ms or more counts as a hitch.")
  elseif cmd == "profile" then
    c.profile = ParseBool(rest, c.profile)
    FW.Print("Script profiling " .. OnOff(c.profile) .. " (takes effect next fight).")
  elseif cmd == "gcguard" then
    local _, _, word, mb = strfind(rest, "^(%S*)%s*(%d*)")
    c.gcGuard = ParseBool(word, c.gcGuard)
    if tonumber(mb) and tonumber(mb) >= 8 then c.gcGuardMB = tonumber(mb) end
    FW.Print("GC guard " .. OnOff(c.gcGuard) .. format(" (%d MB of headroom at pull).", c.gcGuardMB))
  elseif cmd == "gcbench" then
    c.gcBench = ParseBool(rest, c.gcBench)
    FW.Print("GC benchmark after fights " .. OnOff(c.gcBench) .. ".")
  elseif cmd == "trash" then
    c.keepTrash = ParseBool(rest, c.keepTrash)
    FW.Print("Keep non-boss fights without drops: " .. OnOff(c.keepTrash) .. ".")
  elseif cmd == "auto" then
    c.autoOpen = ParseBool(rest, c.autoOpen)
    FW.Print("Open report after fights with drops: " .. OnOff(c.autoOpen) .. ".")
  elseif cmd == "chat" then
    c.chat = ParseBool(rest, c.chat)
    FW.Print("Chat summary " .. OnOff(c.chat) .. ".")
  elseif cmd == "clear" then
    FW.wipe(FW.db.reports)
    FW.UI.Refresh()
    FW.Print("Saved reports deleted.")
  elseif cmd == "status" then
    FW.Status()
  else
    for i = 1, getn(HELP) do DEFAULT_CHAT_FRAME:AddMessage(HELP[i]) end
  end
end
