-- Runs FpsWatch inside a fake 1.12 client under a real Lua 5.0 interpreter.
-- Usage (from the repo root): lua5.0 tests/run_test.lua [full|notimer]
--   notimer: the client has no debugprofilestop() and no RegisterAllEvents.
local variant = arg and arg[1] or "full"
dofile("tests/wowmock.lua")
if variant == "notimer" then
  debugprofilestop = nil
  MOCK.noAllEvents = true
end
local rawCreate = CreateFrame

local ADDON = "!FpsWatch/"
local function Load(path, chunk)
  local f = assert(io.open(path))
  local src = f:read("*a")
  f:close()
  local fn, err = loadstring(src, chunk)
  if not fn then error(err) end
  fn()
end
local files = { "Core.lua", "Profiler.lua", "Session.lua", "Analysis.lua", "UI.lua" }
for i = 1, table.getn(files) do
  Load(ADDON .. files[i], "@Interface\\AddOns\\!FpsWatch\\" .. files[i])
end
if MOCK.noAllEvents then
  -- pretend the client lacks RegisterAllEvents
  local f = FpsWatchEventCounter
  f.RegisterAllEvents = false
end

-- Fake addons -------------------------------------------------------------
loadstring([[
local f = CreateFrame("Frame")
f:RegisterEvent("UNIT_HEALTH")
f:SetScript("OnEvent", function() MOCK.Busy(0.25) local junk = { arg1 } end)
f:SetScript("OnUpdate", function()
  if MOCK.heavySpike then MOCK.heavySpike = false; MOCK.Busy(140) end
  if MOCK.heavyLoad then MOCK.Busy(45) end
end)
]], "@Interface\\AddOns\\HeavyAddon\\Heavy.lua")()

loadstring([[
local f = CreateFrame("Frame", nil, UIParent)
f:SetScript("OnUpdate", function()
  if MOCK.garbage then
    local t = {}
    for i = 1, 20000 do t[i] = { i } end
  end
end)
]], "@Interface\\AddOns\\GarbageAddon\\core\\Garbage.lua")()

-- Nameplates are created by the engine (no CreateFrame hook), scripted by an addon.
MOCK.plates = {}
for i = 1, 30 do
  local p = rawCreate("Button", nil, WorldFrame)
  p.shown = i <= 8
  table.insert(MOCK.plates, p)
end
loadstring([[
MOCK.plateScript = function() MOCK.Busy(0.02) end
for i = 1, table.getn(MOCK.plates) do
  local p = MOCK.plates[i]
  p:SetScript("OnUpdate", MOCK.plateScript)
end
]], "@Interface\\AddOns\\PlatesAddon\\Plates.lua")()

-- An XML-style named frame (no CreateFrame call), owner must be guessed.
local bw = rawCreate("Frame", "BigWigsFrame", UIParent)
bw:RegisterEvent("CHAT_MSG_MONSTER_YELL")
MOCK.bwScript = function() MOCK.Busy(2) end
bw:SetScript("OnEvent", MOCK.bwScript)

-- Keep a big live heap so full GCs are expensive, like a real UI.
MOCK.keep = {}
for i = 1, 300000 do MOCK.keep[i] = { i, "x" } end

-- Login ---------------------------------------------------------------------
MOCK.echo = true
MOCK.Fire("ADDON_LOADED", "!FpsWatch")
MOCK.Fire("PLAYER_LOGIN")
SlashCmdList.FPSWATCH("meter")
for i = 1, 120 do MOCK.Tick() end

-- Fight -------------------------------------------------------------------
MOCK.raid = 10
MOCK.units.player = { name = "Me", combat = true }
for i = 1, 10 do
  MOCK.units["raid" .. i] = { name = "R" .. i, combat = true }
  MOCK.units["raid" .. i .. "target"] = { name = "Ragnaros", class = "worldboss", level = -1, hostile = true, combat = true, hp = 1000, hpmax = 1000 }
end
MOCK.units.target = MOCK.units["raid1target"]
MOCK.Fire("PLAYER_REGEN_DISABLED")

local function Second(fn)
  local start = MOCK.simTime
  while MOCK.simTime - start < 1 do
    fn()
  end
end

local boss = MOCK.units.target
for sec = 0, 44 do
  for i = 1, 10 do MOCK.units["raid" .. i .. "target"].hp = 1000 - sec * 20 end
  if sec == 10 or sec == 28 then
    MOCK.Fire("CHAT_MSG_SPELL_CREATURE_VS_CREATURE_DAMAGE", "Ragnaros begins to cast Wrath of Ragnaros.")
    MOCK.Fire("CHAT_MSG_MONSTER_YELL", "BY FIRE BE PURGED!", "Ragnaros")
  end
  if sec == 15 then MOCK.Fire("CHAT_MSG_SPELL_CREATURE_VS_CREATURE_DAMAGE", "Ragnaros casts Magma Blast.") end
  if sec == 18 then MOCK.heavySpike = true end
  MOCK.heavyLoad = (sec >= 38 and sec <= 40)
  MOCK.garbage = (sec >= 22 and sec <= 25)
  for i = 1, 30 do MOCK.plates[i].shown = (i <= 8) or (sec >= 10 and sec <= 14) end
  if sec == 35 then
    MOCK.Fire("CHAT_MSG_COMBAT_HOSTILE_DEATH", "Ragnaros dies.")
    boss.dead = true
  end
  if sec == 36 then
    MOCK.units.player.combat = false
    for i = 1, 10 do MOCK.units["raid" .. i].combat = false end
    MOCK.Fire("PLAYER_REGEN_ENABLED")
  end
  local engine = 0
  if (sec >= 10 and sec <= 13) or (sec >= 28 and sec <= 31) then engine = 75 end
  Second(function()
    MOCK.Fire("UNIT_HEALTH", "raid1")
    MOCK.Fire("UNIT_HEALTH", "raid2")
    MOCK.Fire("CHAT_MSG_SPELL_PERIODIC_PARTY_DAMAGE", "X suffers 100 Fire damage.")
    MOCK.Tick(engine)
  end)
  if sec >= 36 and not FpsWatch.IsRecording() then break end
end
assert(not FpsWatch.IsRecording(), "session should have ended")
-- Boss died at 35, player left combat at 36; restore for the self-test.
MOCK.units.target = nil
MOCK.heavyLoad = false
MOCK.garbage = false

local reports = FpsWatchDB.reports
assert(table.getn(reports) == 1, "expected one report, got " .. table.getn(reports))
local r = reports[1]
assert(r.result == "kill" and r.boss == "Ragnaros", "boss kill not detected")
if variant == "full" then
  assert(r.prof and r.prof.owners[1], "no profiler data")
  local blamed = {}
  for i = 1, table.getn(r.prof.gcTriggers) do blamed[r.prof.gcTriggers[i].n] = true end
  assert(blamed["GarbageAddon: unnamed child of UIParent"], "GCs not blamed on GarbageAddon")
  local h = r.hitches[1]
  assert(h and h.top == "HeavyAddon: unnamed frame", "hitch not blamed on HeavyAddon")
else
  assert(not r.prof, "profiler should be off without a timer")
end
print("\n================ REPORT ================")
print(r.text)
print("========================================")
print("report text bytes:", string.len(r.text))

-- Saved data must be plain data
local function Check(v, path, seen)
  local t = type(v)
  if t == "table" then
    assert(not getmetatable(v), "metatable in saved data at " .. path)
    assert(not seen[v], "cycle at " .. path)
    seen[v] = true
    for k, x in pairs(v) do
      assert(type(k) == "string" or type(k) == "number", "bad key at " .. path)
      Check(x, path .. "." .. tostring(k), seen)
    end
    seen[v] = nil
  else
    assert(t == "string" or t == "number" or t == "boolean", "bad value type " .. t .. " at " .. path)
  end
end
Check(FpsWatchDB, "FpsWatchDB", {})
print("saved variables: plain data OK")

-- Every script must be the addon's own function again after the fight.
assert(MOCK.plates[1].scripts.OnUpdate == MOCK.plateScript, "nameplate script was not restored")
assert(BigWigsFrame.scripts.OnEvent == MOCK.bwScript, "BigWigsFrame script was not restored")
print("scripts restored after the fight: OK")

-- UI --------------------------------------------------------------------------
SlashCmdList.FPSWATCH("")
local g = FpsWatchGraph
g:GetScript("OnEnter")()
GetCursorPosition = function() return 100 + 300 end
g:GetScript("OnUpdate")()
GetCursorPosition = function() return 100 + 10 end
g:GetScript("OnUpdate")()
g:GetScript("OnLeave")()
FpsWatchReportOlder:GetScript("OnClick")()
FpsWatchReportNewer:GetScript("OnClick")()
FpsWatchReportSelect:GetScript("OnClick")()
FpsWatchReportEdit:GetScript("OnTextChanged")()
FpsWatchReportScroll:GetScript("OnMouseWheel")()
arg1 = -1
FpsWatchReportScroll:GetScript("OnMouseWheel")()
FpsWatchMeter:GetScript("OnDragStop")()
arg1 = "RightButton"
FpsWatchMeter:GetScript("OnMouseUp")()

for _, cmd in ipairs({ "status", "list", "drop 25", "hitch 120", "gcguard on 96", "profile", "profile on", "trash on", "auto on", "chat", "chat on", "help", "bogus" }) do
  SlashCmdList.FPSWATCH(cmd)
end

-- GC guard path on next pull
MOCK.units.player.combat = true
MOCK.Fire("PLAYER_REGEN_DISABLED")
for i = 1, 30 do MOCK.Tick() end
SlashCmdList.FPSWATCH("stop")

-- Self-test -----------------------------------------------------------------
MOCK.units.player.combat = false
SlashCmdList.FPSWATCH("drop 20")
SlashCmdList.FPSWATCH("hitch 150")
SlashCmdList.FPSWATCH("test")
local start = MOCK.simTime
while FpsWatch.IsRecording() and MOCK.simTime - start < 20 do MOCK.Tick() end
assert(not FpsWatch.IsRecording(), "self-test should stop by itself")
assert(FpsWatchDB.reports[1].name == "Self-test", "self-test report missing")
print("\n================ SELF-TEST REPORT ================")
print(FpsWatchDB.reports[1].text)
SlashCmdList.FPSWATCH("list")
SlashCmdList.FPSWATCH("clear")
SlashCmdList.FPSWATCH("")
print("ALL DONE (" .. variant .. ")")
