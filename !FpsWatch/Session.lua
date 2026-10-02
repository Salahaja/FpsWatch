-- Recording: one session per fight. Starts when you enter combat, figures
-- out whether it is a boss fight, and ends once combat is over.

local FW = FpsWatch
local P = FW.Profiler

local floor = math.floor
local getn, tinsert, tsort = table.getn, table.insert, table.sort
local strfind, strsub, strlen, gsub = string.find, string.sub, string.len, string.gsub
local round1 = FW.round1

local S          -- the report being recorded (ends up in SavedVariables)
local R = {}     -- runtime-only state for the current session
FW.R = R

local MAX_HITCHES = 150
local MAX_TIMELINE = 300
local MAX_SESSION = 45 * 60
local END_GRACE = 3

FW.live = { fps = 0, mem = 0, alloc = 0, thr = 0 }

function FW.IsRecording() return S ~= nil end
function FW.CurrentSession() return S, R end

local RAID, RAIDT, PARTY, PARTYT = {}, {}, {}, {}
for i = 1, 40 do RAID[i] = "raid" .. i; RAIDT[i] = "raid" .. i .. "target" end
for i = 1, 4 do PARTY[i] = "party" .. i; PARTYT[i] = "party" .. i .. "target" end

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------
local function Merge(dst, src)
  for k, v in pairs(src) do dst[k] = (dst[k] or 0) + v end
end

local function TopCounts(t, n, div)
  local list = {}
  for k, v in pairs(t) do tinsert(list, { n = k, v = v }) end
  tsort(list, function(a, b) return a.v > b.v end)
  local out = {}
  for i = 1, n do
    if not list[i] then break end
    out[i] = { n = list[i].n, v = floor(list[i].v / div + 0.5) }
  end
  return out
end

function FW.CountNameplates()
  if not WorldFrame or not WorldFrame.GetChildren then return nil end
  local n = 0
  local kids = { WorldFrame:GetChildren() }
  for i = 1, getn(kids) do
    local f = kids[i]
    if f:IsVisible() and not f:GetName() then n = n + 1 end
  end
  return n
end

local baseline, baseIdx = {}, 0
function FW.BaselineFps()
  local list = {}
  for i = 1, getn(baseline) do list[i] = baseline[i] end
  local n = getn(list)
  if n == 0 then return nil end
  tsort(list)
  return round1(list[floor((n + 1) / 2)])
end

local CVARS = {
  "gxApi", "gxResolution", "gxRefresh", "gxWindow", "gxMaximize", "gxVSync", "gxTripleBuffer",
  "gxMultisample", "maxfps", "farclip", "spellEffectLevel", "weatherDensity", "smallcull",
  "detailDoodadAlpha", "DistCull", "SkyCloudLOD", "SkySunGlare", "pixelShaders",
  "M2UsePixelShaders", "M2UseShaders", "M2Faster", "trilinear", "anisotropic", "shadowLevel",
  "BaseMip", "unitDrawDist", "ffx", "ffxGlow", "ffxDeath",
}

function FW.SnapshotSettings()
  local out = {}
  for i = 1, getn(CVARS) do
    local ok, v = pcall(GetCVar, CVARS[i])
    if ok and v then out[CVARS[i]] = v end
  end
  return out
end

local function ClientInfo()
  local info = {}
  if GetBuildInfo then
    local ok, ver, build = pcall(GetBuildInfo)
    if ok then info.build = (ver or "?") .. " " .. (build or "") end
  end
  if GetRealmName then info.realm = GetRealmName() end
  local loaded = 0
  for i = 1, GetNumAddOns() do
    if IsAddOnLoaded(i) then loaded = loaded + 1 end
  end
  info.addons = loaded
  info.ownedFrames = FW.ownedFrames
  if GetNetStats then
    local _, _, lat = GetNetStats()
    info.latency = lat
  end
  return info
end

----------------------------------------------------------------------
-- Boss / group tracking (once per second)
----------------------------------------------------------------------
local function BossCheck(u)
  if not UnitExists(u) or UnitIsDead(u) then return nil end
  if UnitClassification(u) ~= "worldboss" and UnitLevel(u) ~= -1 then return nil end
  if not UnitCanAttack("player", u) then return nil end
  local name = UnitName(u)
  if not name then return nil end
  local b = S.bosses[name]
  if not b then
    if not UnitAffectingCombat(u) then return nil end
    b = { first = floor(R.clock) }
    S.bosses[name] = b
    if not S.boss then
      S.boss = name
      if not S.fixedName then S.name = name end
    end
  end
  local hp, hpmax = UnitHealth(u), UnitHealthMax(u)
  if name == S.boss and hpmax and hpmax > 0 then
    return floor(hp / hpmax * 100 + 0.5)
  end
  return nil
end

local function ScanUnits(smp)
  local s = S
  local nraid = GetNumRaidMembers()
  local size = nraid
  if size == 0 then size = GetNumPartyMembers() + 1 end
  if size > s.groupSize then s.groupSize = size end

  local hp = BossCheck("target")
  if nraid > 0 then
    for i = 1, nraid do
      local v = BossCheck(RAIDT[i])
      hp = hp or v
    end
  else
    for i = 1, GetNumPartyMembers() do
      local v = BossCheck(PARTYT[i])
      hp = hp or v
    end
  end
  if hp then smp.bh = hp end
end

local function GroupInCombat()
  local n = GetNumRaidMembers()
  if n > 0 then
    for i = 1, n do if UnitAffectingCombat(RAID[i]) then return true end end
  else
    for i = 1, GetNumPartyMembers() do if UnitAffectingCombat(PARTY[i]) then return true end end
  end
  return false
end

local function CheckEnd()
  if R.clock > MAX_SESSION then
    R.wantStop = "timeout"
    return
  end
  if S.kind == "manual" then return end
  -- If you die, keep going while the raid is still fighting.
  local busy = UnitAffectingCombat("player") or (UnitIsDeadOrGhost("player") and GroupInCombat())
  if busy then
    R.idleSecs = 0
  else
    R.idleSecs = R.idleSecs + 1
    if R.idleSecs >= END_GRACE then R.wantStop = "combat ended" end
  end
end

----------------------------------------------------------------------
-- Boss ability timeline from the (text) combat log
----------------------------------------------------------------------
local function G(name, fallback)
  local v = getglobal(name)
  if type(v) == "string" then return v end
  return fallback
end

local PATTERNS = {
  { k = "cast", pat = FW.FormatToPattern(G("SPELLCASTOTHERSTART", "%s begins to cast %s.")) },
  { k = "cast", pat = FW.FormatToPattern(G("SPELLPERFORMOTHERSTART", "%s begins to perform %s.")) },
  { k = "cast", pat = FW.FormatToPattern(G("SPELLCASTGOOTHERTARGETTED", "%s casts %s on %s.")) },
  { k = "cast", pat = FW.FormatToPattern(G("SPELLCASTGOOTHER", "%s casts %s.")) },
  { k = "gain", pat = FW.FormatToPattern(G("AURAADDEDOTHERHELPFUL", "%s gains %s.")) },
  { k = "hit", pat = FW.FormatToPattern(G("SPELLLOGCRITOTHEROTHER", "%s's %s crits %s for %d.")) },
  { k = "hit", pat = FW.FormatToPattern(G("SPELLLOGOTHEROTHER", "%s's %s hits %s for %d.")) },
  { k = "hit", pat = FW.FormatToPattern(G("SPELLLOGCRITOTHERSELF", "%s's %s crits you for %d.")) },
  { k = "hit", pat = FW.FormatToPattern(G("SPELLLOGOTHERSELF", "%s's %s hits you for %d.")) },
}
local DEATH_PAT = FW.FormatToPattern(G("UNITDIESOTHER", "%s dies."))

local TEXT_EVENTS = {
  "CHAT_MSG_MONSTER_YELL", "CHAT_MSG_MONSTER_EMOTE", "CHAT_MSG_RAID_BOSS_EMOTE",
  "CHAT_MSG_SPELL_CREATURE_VS_CREATURE_DAMAGE", "CHAT_MSG_SPELL_CREATURE_VS_CREATURE_BUFF",
  "CHAT_MSG_SPELL_CREATURE_VS_PARTY_DAMAGE", "CHAT_MSG_SPELL_CREATURE_VS_PARTY_BUFF",
  "CHAT_MSG_SPELL_CREATURE_VS_SELF_DAMAGE", "CHAT_MSG_SPELL_CREATURE_VS_SELF_BUFF",
  "CHAT_MSG_SPELL_PERIODIC_CREATURE_BUFFS",
}

local function AddTimeline(kind, src, what)
  local s = S
  if s.nTimeline >= MAX_TIMELINE then return end
  local key = kind .. "|" .. src .. "|" .. what
  local last = R.tlSeen[key]
  if last and R.clock - last < 10 then return end
  R.tlSeen[key] = R.clock
  local n = s.nTimeline + 1
  s.nTimeline = n
  s.timeline[n] = { t = round1(R.clock), k = kind, s = src, n = what }
end

local function OnCombatText(ev, msg, sender)
  if not S or type(msg) ~= "string" then return end
  if ev == "CHAT_MSG_MONSTER_YELL" or ev == "CHAT_MSG_MONSTER_EMOTE" or ev == "CHAT_MSG_RAID_BOSS_EMOTE" then
    local txt = gsub(msg, "%%s", sender or "")
    if strlen(txt) > 70 then txt = strsub(txt, 1, 67) .. "..." end
    local kind = "emote"
    if ev == "CHAT_MSG_MONSTER_YELL" then kind = "yell" end
    AddTimeline(kind, sender or "?", txt)
    return
  end
  for i = 1, getn(PATTERNS) do
    local p = PATTERNS[i]
    local _, _, src, spell = strfind(msg, p.pat)
    if src and spell then
      if p.k ~= "hit" or S.bosses[src] then AddTimeline(p.k, src, spell) end
      return
    end
  end
end

function FW.OnHostileDeath(msg)
  if not S or type(msg) ~= "string" then return end
  local _, _, name = strfind(msg, DEATH_PAT)
  if not name then return end
  name = gsub(name, "%.$", "")
  local b = S.bosses[name]
  if b then
    b.died = floor(R.clock)
    AddTimeline("died", name, "dies")
    if name == S.boss then S.result = "kill" end
  end
end

----------------------------------------------------------------------
-- Frames
----------------------------------------------------------------------
local recorder = FW.CreateOwnFrame("Frame", "FpsWatchRecorder")
local counter = FW.CreateOwnFrame("Frame", "FpsWatchEventCounter")
local textFrame = FW.CreateOwnFrame("Frame", "FpsWatchCombatText")

-- Fallback when the client has no RegisterAllEvents.
local COUNT_EVENTS = {
  "CHAT_MSG_COMBAT_CREATURE_VS_CREATURE_HITS", "CHAT_MSG_COMBAT_CREATURE_VS_CREATURE_MISSES",
  "CHAT_MSG_COMBAT_CREATURE_VS_PARTY_HITS", "CHAT_MSG_COMBAT_CREATURE_VS_PARTY_MISSES",
  "CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS", "CHAT_MSG_COMBAT_CREATURE_VS_SELF_MISSES",
  "CHAT_MSG_COMBAT_FRIENDLYPLAYER_HITS", "CHAT_MSG_COMBAT_FRIENDLYPLAYER_MISSES",
  "CHAT_MSG_COMBAT_FRIENDLY_DEATH", "CHAT_MSG_COMBAT_HOSTILE_DEATH",
  "CHAT_MSG_COMBAT_PARTY_HITS", "CHAT_MSG_COMBAT_PARTY_MISSES",
  "CHAT_MSG_COMBAT_PET_HITS", "CHAT_MSG_COMBAT_PET_MISSES",
  "CHAT_MSG_COMBAT_SELF_HITS", "CHAT_MSG_COMBAT_SELF_MISSES",
  "CHAT_MSG_SPELL_AURA_GONE_OTHER", "CHAT_MSG_SPELL_AURA_GONE_PARTY", "CHAT_MSG_SPELL_AURA_GONE_SELF",
  "CHAT_MSG_SPELL_BREAK_AURA", "CHAT_MSG_SPELL_DAMAGESHIELDS_ON_OTHERS", "CHAT_MSG_SPELL_DAMAGESHIELDS_ON_SELF",
  "CHAT_MSG_SPELL_CREATURE_VS_CREATURE_BUFF", "CHAT_MSG_SPELL_CREATURE_VS_CREATURE_DAMAGE",
  "CHAT_MSG_SPELL_CREATURE_VS_PARTY_BUFF", "CHAT_MSG_SPELL_CREATURE_VS_PARTY_DAMAGE",
  "CHAT_MSG_SPELL_CREATURE_VS_SELF_BUFF", "CHAT_MSG_SPELL_CREATURE_VS_SELF_DAMAGE",
  "CHAT_MSG_SPELL_FRIENDLYPLAYER_BUFF", "CHAT_MSG_SPELL_FRIENDLYPLAYER_DAMAGE",
  "CHAT_MSG_SPELL_PARTY_BUFF", "CHAT_MSG_SPELL_PARTY_DAMAGE",
  "CHAT_MSG_SPELL_PET_BUFF", "CHAT_MSG_SPELL_PET_DAMAGE",
  "CHAT_MSG_SPELL_SELF_BUFF", "CHAT_MSG_SPELL_SELF_DAMAGE",
  "CHAT_MSG_SPELL_PERIODIC_CREATURE_BUFFS", "CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE",
  "CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_BUFFS", "CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_DAMAGE",
  "CHAT_MSG_SPELL_PERIODIC_PARTY_BUFFS", "CHAT_MSG_SPELL_PERIODIC_PARTY_DAMAGE",
  "CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS", "CHAT_MSG_SPELL_PERIODIC_SELF_DAMAGE",
  "CHAT_MSG_SPELL_ITEM_ENCHANTMENTS", "CHAT_MSG_SPELL_FAILED_LOCALPLAYER",
  "CHAT_MSG_MONSTER_YELL", "CHAT_MSG_MONSTER_EMOTE", "CHAT_MSG_MONSTER_SAY",
  "CHAT_MSG_ADDON", "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER", "CHAT_MSG_RAID_WARNING",
  "CHAT_MSG_PARTY", "CHAT_MSG_CHANNEL", "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_WHISPER",
  "CHAT_MSG_SYSTEM",
  "UNIT_HEALTH", "UNIT_MAXHEALTH", "UNIT_MANA", "UNIT_MAXMANA", "UNIT_RAGE", "UNIT_ENERGY",
  "UNIT_FOCUS", "UNIT_AURA", "UNIT_COMBAT", "UNIT_FLAGS", "UNIT_DYNAMIC_FLAGS",
  "UNIT_PORTRAIT_UPDATE", "UNIT_MODEL_CHANGED", "UNIT_INVENTORY_CHANGED", "UNIT_NAME_UPDATE",
  "UNIT_PET", "UNIT_DISPLAYPOWER", "UNIT_FACTION",
  "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "PLAYER_AURAS_CHANGED",
  "SPELLCAST_START", "SPELLCAST_STOP", "SPELLCAST_FAILED", "SPELLCAST_INTERRUPTED",
  "SPELLCAST_DELAYED", "SPELLCAST_CHANNEL_START", "SPELLCAST_CHANNEL_UPDATE", "SPELLCAST_CHANNEL_STOP",
  "ACTIONBAR_UPDATE_COOLDOWN", "ACTIONBAR_UPDATE_USABLE", "ACTIONBAR_UPDATE_STATE",
  "SPELL_UPDATE_COOLDOWN", "SPELL_UPDATE_USABLE", "BAG_UPDATE", "BAG_UPDATE_COOLDOWN",
  "RAID_ROSTER_UPDATE", "PARTY_MEMBERS_CHANGED", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
}

counter:SetScript("OnEvent", function()
  local t = R.secEvents
  if t then
    local e = event
    t[e] = (t[e] or 0) + 1
  end
end)

textFrame:SetScript("OnEvent", function()
  local t0 = FW.timer and FW.timer()
  OnCombatText(event, arg1, arg2)
  if t0 and S then
    local d = FW.timer() - t0
    if d > 0 then S.selfMs = S.selfMs + d end
  end
end)

local function RegisterCounting()
  if counter.RegisterAllEvents and pcall(counter.RegisterAllEvents, counter) then
    R.allEvents = true
    return
  end
  for i = 1, getn(COUNT_EVENTS) do pcall(counter.RegisterEvent, counter, COUNT_EVENTS[i]) end
end

local function UnregisterList(f, list)
  if f.UnregisterAllEvents then
    f:UnregisterAllEvents()
  else
    for i = 1, getn(list) do pcall(f.UnregisterEvent, f, list[i]) end
  end
end

----------------------------------------------------------------------
-- Per-second sample
----------------------------------------------------------------------
local function ResetSecond()
  R.secFrames = 0; R.secMs = 0; R.secMaxMs = 0
  R.secAlloc = 0; R.secGc = 0; R.secHandlerMs = 0
  FW.wipe(R.secEvents)
end

local function FlushSecond()
  local s = S
  local dur = R.clock - R.secStart
  R.secStart = R.clock
  if R.secFrames == 0 or R.secMs <= 0 or dur <= 0 then
    ResetSecond()
    return
  end
  local fps = R.secFrames * 1000 / R.secMs
  local smp = {
    t = floor(R.clock + 0.5),
    f = round1(fps),
    mn = round1(1000 / R.secMaxMs),
    m = round1(R.mem / 1024),
    al = floor(R.secAlloc / dur + 0.5),
  }
  if R.secGc > 0 then smp.gc = R.secGc end
  if R.profiling then smp.h = round1(R.secHandlerMs / R.secMs * 100) end
  local np = FW.CountNameplates()
  if np then smp.np = np end
  local evTotal = 0
  for _, c in pairs(R.secEvents) do evTotal = evTotal + c end
  smp.ev = floor(evTotal / dur + 0.5)
  ScanUnits(smp)

  local slow = fps < s.dropFps or R.secMaxMs >= s.hitchMs
  if slow then
    smp.s = 1
    if fps < s.dropFps then s.lowSecs = s.lowSecs + dur end
    if R.profiling then smp.sa = P.TakeSecondTop(4) end
    smp.se = TopCounts(R.secEvents, 4, dur)
    Merge(R.dropEvents, R.secEvents)
    R.dropSecs = R.dropSecs + dur
  else
    if R.profiling then P.TakeSecondTop(0) end
    Merge(R.normalEvents, R.secEvents)
    R.normalSecs = R.normalSecs + dur
  end
  local n = s.nSamples + 1
  s.nSamples = n
  s.samples[n] = smp

  local live = FW.live
  live.fps = round1(fps); live.mem = R.mem; live.thr = R.thr
  if R.secGc == 0 then live.alloc = smp.al end

  ResetSecond()
  CheckEnd()
  if R.profiling and not R.scanning then
    R.rescan = R.rescan + dur
    if R.rescan >= 5 then
      R.rescan = 0
      R.scanning = true
    end
  end
  if FW.UI and FW.UI.UpdateMeter then FW.UI.UpdateMeter() end
end

----------------------------------------------------------------------
-- The per-frame recorder
----------------------------------------------------------------------
local function AddHitch(h)
  local list = S.hitches
  local n = getn(list)
  if n < MAX_HITCHES then
    list[n + 1] = h
    return
  end
  local mi, mv = 1, list[1].ms
  for i = 2, n do
    if list[i].ms < mv then mi, mv = i, list[i].ms end
  end
  if h.ms > mv then list[mi] = h end
end

local function Record(elapsed)
  local s = S
  local timer = FW.timer
  local t0 = timer and timer()
  local mem, thr = gcinfo()

  if R.skip then
    -- The first elapsed after starting covers time before we started.
    R.skip = false
    if R.profiling then P.CloseInterval(false) end
    R.mem, R.thr = mem, thr
    return
  end

  local ms = elapsed * 1000
  R.clock = R.clock + elapsed
  s.frames = s.frames + 1
  s.totalMs = s.totalMs + ms
  local h = s.hist
  if ms < 17 then h[1] = h[1] + 1
  elseif ms < 34 then h[2] = h[2] + 1
  elseif ms < 50 then h[3] = h[3] + 1
  elseif ms < 100 then h[4] = h[4] + 1
  elseif ms < 250 then h[5] = h[5] + 1
  else h[6] = h[6] + 1 end
  if ms > s.worstMs then
    s.worstMs = ms
    s.worstAt = R.clock
  end
  R.secFrames = R.secFrames + 1
  R.secMs = R.secMs + ms
  if ms > R.secMaxMs then R.secMaxMs = ms end

  -- Lua 5.0's collector is stop-the-world: memory only ever goes down
  -- (and the threshold only moves) when a full GC ran.
  local gc = false
  if mem < R.mem or thr ~= R.thr then
    gc = true
    s.gcCount = s.gcCount + 1
    R.secGc = R.secGc + 1
  elseif mem > R.mem then
    R.secAlloc = R.secAlloc + (mem - R.mem)
    s.allocKB = s.allocKB + (mem - R.mem)
  end
  R.mem, R.thr = mem, thr
  if mem > s.peakMemKB then s.peakMemKB = mem end

  local slow = ms >= R.slowThresh
  local hms, gms, top, topMs, hAlloc = 0, 0, nil, 0, 0
  if R.profiling then
    hms, gms, top, topMs, hAlloc = P.CloseInterval(slow)
    R.secHandlerMs = R.secHandlerMs + hms
    s.handlerMs = s.handlerMs + hms
    if gc then
      -- The heap delta is useless across a GC; use what the scripts allocated.
      R.secAlloc = R.secAlloc + hAlloc
      s.allocKB = s.allocKB + hAlloc
    end
  end

  if slow then
    s.slowFrames = s.slowFrames + 1
    s.slowMs = s.slowMs + ms
    s.slowHandlerMs = s.slowHandlerMs + hms - gms
    s.slowGcHandlerMs = s.slowGcHandlerMs + gms
    if gc then
      s.slowGcFrames = s.slowGcFrames + 1
      if gms == 0 then
        -- GC ran outside any script we timed: whatever is left over after
        -- scripts and a normal frame's worth of rendering is the collector.
        local extra = ms - hms - R.typicalMs
        if extra > 0 then s.slowGcOutsideMs = s.slowGcOutsideMs + extra end
      end
    end
  else
    R.typicalMs = R.typicalMs * 0.95 + ms * 0.05
  end

  if ms >= s.hitchMs then
    s.hitchCount = s.hitchCount + 1
    if gc then s.gcHitches = s.gcHitches + 1 end
    local hitch = { t = round1(R.clock), ms = floor(ms + 0.5) }
    if R.profiling then
      hitch.h = round1(hms - gms)
      if gms > 0 then hitch.gm = round1(gms) end
      if top then
        hitch.top = P.SlotName(top)
        hitch.tm = round1(topMs)
      end
    end
    if gc then hitch.gc = 1 end
    AddHitch(hitch)
  end

  if R.clock - R.secStart >= 1 then FlushSecond() end
  if R.scanning and P.ScanStep(250) then R.scanning = false end
  if t0 then
    -- (negative if another addon called debugprofilestart() meanwhile)
    local d = timer() - t0
    if d > 0 then s.selfMs = s.selfMs + d end
  end
  if R.wantStop then FW.StopSession(R.wantStop) end
end

local idleAcc, idleMem = 0, 0
local function Idle(elapsed)
  idleAcc = idleAcc + elapsed
  if idleAcc < 1 then return end
  local mem, thr = gcinfo()
  local live = FW.live
  if idleMem > 0 and mem >= idleMem then live.alloc = floor((mem - idleMem) / idleAcc + 0.5) end
  idleMem = mem
  live.mem, live.thr = mem, thr
  live.fps = GetFramerate()
  baseIdx = baseIdx + 1
  if baseIdx > 15 then baseIdx = 1 end
  baseline[baseIdx] = live.fps
  idleAcc = 0
  if FW.UI and FW.UI.UpdateMeter then FW.UI.UpdateMeter() end
end

recorder:SetScript("OnUpdate", function()
  local elapsed = arg1
  if not elapsed or elapsed <= 0 then return end
  if S then Record(elapsed) else Idle(elapsed) end
end)

----------------------------------------------------------------------
-- Session lifecycle
----------------------------------------------------------------------
function FW.StartSession(kind, name)
  if S then return end
  local cfg = FW.cfg
  local mem, thr = gcinfo()
  local target
  if UnitExists("target") and UnitCanAttack("player", "target") then target = UnitName("target") end
  S = {
    v = 1, kind = kind, fixedName = name and true or nil,
    name = name or target or GetRealZoneText() or "Unknown",
    zone = GetRealZoneText(), subzone = GetSubZoneText and GetSubZoneText() or nil,
    date = date("%Y-%m-%d %H:%M"), started = time(),
    dropFps = cfg.dropFps, hitchMs = cfg.hitchMs,
    baseline = FW.BaselineFps(),
    frames = 0, totalMs = 0, worstMs = 0, worstAt = 0,
    hist = { 0, 0, 0, 0, 0, 0 },
    gcCount = 0, gcHitches = 0, allocKB = 0, startMemKB = mem, peakMemKB = mem, startThrKB = thr,
    slowFrames = 0, slowMs = 0, slowHandlerMs = 0, slowGcHandlerMs = 0, slowGcFrames = 0, slowGcOutsideMs = 0,
    handlerMs = 0, selfMs = 0,
    hitchCount = 0, hitches = {},
    lowSecs = 0,
    samples = {}, nSamples = 0,
    bosses = {}, timeline = {}, nTimeline = 0,
    groupSize = 1,
    settings = FW.SnapshotSettings(),
    client = ClientInfo(),
    profiled = false,
  }
  if R.gcGuard then
    S.gcGuard = R.gcGuard
    R.gcGuard = nil
  end
  R.clock = 0; R.secStart = 0
  R.secEvents = R.secEvents or {}
  R.dropEvents = {}; R.normalEvents = {}
  R.dropSecs = 0; R.normalSecs = 0
  R.tlSeen = {}
  R.idleSecs = 0
  R.rescan = 0
  R.scanning = false
  R.mem, R.thr = mem, thr
  R.typicalMs = 16
  R.slowThresh = 1000 / cfg.dropFps
  R.wantStop = nil
  R.allEvents = false
  ResetSecond()

  R.profiling = false
  if cfg.profile and FW.timer then
    local ok, started = pcall(P.Start)
    R.profiling = ok and started or false
  end
  S.profiled = R.profiling
  S.overheadUs = R.profiling and FW.round1(P.overheadUs) or nil

  RegisterCounting()
  for i = 1, getn(TEXT_EVENTS) do pcall(textFrame.RegisterEvent, textFrame, TEXT_EVENTS[i]) end
  R.skip = true
  if FW.UI and FW.UI.UpdateMeter then FW.UI.UpdateMeter() end
end

local function GcBench()
  if type(collectgarbage) ~= "function" then return nil end
  local before = gcinfo()
  local t0 = FW.timer and FW.timer()
  collectgarbage()
  local ms = t0 and FW.round1(FW.timer() - t0)
  if ms and ms < 0 then ms = nil end
  local after = gcinfo()
  return { ms = ms, before = before, after = after }
end

local function ShouldKeep(s)
  if s.kind == "manual" then return true end
  if s.duration < 5 then return false end
  if s.boss then return true end
  if FW.cfg.keepTrash and s.duration >= 10 then return true end
  return s.duration >= 10 and (s.lowSecs >= 3 or s.hitchCount >= 3)
end

function FW.StopSession(reason, silent)
  local s = S
  if not s then return end
  if R.secFrames > 0 and R.clock - R.secStart >= 0.3 then
    R.wantStop = nil
    FlushSecond()
  end
  S = nil
  R.wantStop = nil
  UnregisterList(counter, COUNT_EVENTS)
  UnregisterList(textFrame, TEXT_EVENTS)
  if R.profiling then
    local ok, prof = pcall(P.Stop)
    if ok then s.prof = prof end
    R.profiling = false
  end

  s.duration = R.clock
  s.ended = reason
  s.avgFps = s.totalMs > 0 and FW.round1(s.frames * 1000 / s.totalMs) or 0
  s.endMemKB = R.mem
  s.allEvents = R.allEvents
  s.dropSecs = FW.round1(R.dropSecs)
  s.normalSecs = FW.round1(R.normalSecs)
  s.events = FW.BuildEventRates(R.dropEvents, R.dropSecs, R.normalEvents, R.normalSecs)
  if s.boss and not s.result and s.kind ~= "manual" then s.result = "no kill" end
  if s.kind ~= "manual" and not s.boss then s.kind = "trash" end
  s.worstMs = floor(s.worstMs + 0.5)
  s.selfMs = FW.round1(s.selfMs)

  local cfg = FW.cfg
  if not ShouldKeep(s) then
    if cfg.gcGuard and not silent then collectgarbage() end
    if FW.UI and FW.UI.UpdateMeter then FW.UI.UpdateMeter() end
    return
  end

  if not silent and not UnitAffectingCombat("player") and (cfg.gcBench or cfg.gcGuard) then
    s.gcBench = GcBench()
  end

  local a = FW.Analyze(s)
  s.verdict = a.short
  s.text = FW.BuildReportText(s, a)

  local reports = FW.db.reports
  tinsert(reports, 1, s)
  while getn(reports) > cfg.maxReports do table.remove(reports) end

  if not silent then
    if cfg.chat then FW.PrintSummary(s, a) end
    if FW.UI then
      FW.UI.Refresh()
      if reason == "self-test" or (cfg.autoOpen and a.hasDrops) then FW.UI.ShowReport(1) end
    end
  end
  if FW.UI and FW.UI.UpdateMeter then FW.UI.UpdateMeter() end
end

-- GC guard: at pull, make sure the next collection is far away so it
-- does not land in the middle of the boss; after combat, collect.
local function GuardBeforePull()
  if not FW.cfg.gcGuard or type(collectgarbage) ~= "function" then return end
  local mem, thr = gcinfo()
  local want = mem + FW.cfg.gcGuardMB * 1024
  if thr < want then
    collectgarbage(want)
    R.gcGuard = { from = thr, to = want }
  end
end

----------------------------------------------------------------------
-- Self-test: fake an addon stall, a low-FPS stretch and a GC stall.
----------------------------------------------------------------------
local function Busy(ms)
  local timer = FW.timer
  if timer then
    local t0 = timer()
    while timer() - t0 < ms do end
  else
    local x = 0
    for i = 1, ms * 20000 do x = x + i end
  end
end

function FW.SelfTest()
  if S then
    FW.Print("Already recording, try again after this fight.")
    return
  end
  -- A normal (not FpsWatch-owned) frame, so the profiler times it like
  -- any other addon's frame.
  local f = FW.testFrame or CreateFrame("Frame", "FpsWatchSelfTestFrame")
  FW.testFrame = f
  local step = 0
  f:SetScript("OnUpdate", function()
    -- Use the session clock so the report's times match the plan.
    local t = R.clock or 0
    if step == 0 and t >= 2 then
      step = 1
      Busy(300)
    elseif step == 1 and t >= 4 then
      if t < 7 then Busy(70) else step = 2 end
    elseif step == 2 and t >= 8 then
      step = 3
      local junk = {}
      for i = 1, 150000 do junk[i] = { i } end
      junk = nil
      collectgarbage()
    elseif step == 3 and t >= 11 then
      step = 4
      f:SetScript("OnUpdate", nil)
      R.wantStop = "self-test"
      FW.testDone = true
    end
  end)
  FW.StartSession("manual", "Self-test")
  FW.Print("Self-test running for 11 seconds. The report should blame FpsWatchSelfTestFrame for a 300 ms freeze at 0:02 and low FPS from 0:04 to 0:07, and list one Lua GC at 0:08.")
end

----------------------------------------------------------------------
-- Events
----------------------------------------------------------------------
local ctl = FW.CreateOwnFrame("Frame", "FpsWatchControl")
local CTL_EVENTS = {
  "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_REGEN_DISABLED", "PLAYER_LEAVING_WORLD",
  "PLAYER_LOGOUT", "CHAT_MSG_COMBAT_HOSTILE_DEATH",
}
for i = 1, getn(CTL_EVENTS) do pcall(ctl.RegisterEvent, ctl, CTL_EVENTS[i]) end

ctl:SetScript("OnEvent", function()
  if event == "ADDON_LOADED" then
    if arg1 == "!FpsWatch" or arg1 == "FpsWatch" then FW.InitDB() end
  elseif event == "PLAYER_LOGIN" then
    if not FW.db then FW.InitDB() end
    if FW.UI then FW.UI.Init() end
    local msg = "loaded. Boss fights are recorded automatically; /fpsw for reports, /fpsw help for options."
    if not FW.timer then msg = msg .. " (No precise timer on this client: per-addon timing disabled.)" end
    FW.Print(msg)
  elseif event == "PLAYER_REGEN_DISABLED" then
    if not FW.db then FW.InitDB() end
    if not S then
      GuardBeforePull()
      FW.StartSession("combat")
    end
  elseif event == "CHAT_MSG_COMBAT_HOSTILE_DEATH" then
    FW.OnHostileDeath(arg1)
  elseif event == "PLAYER_LEAVING_WORLD" then
    if S then FW.StopSession("zoned") end
  elseif event == "PLAYER_LOGOUT" then
    if S then FW.StopSession("logout", true) end
  end
end)
