-- Script profiler. 1.12 has no addon CPU API, so during a fight every
-- frame's OnEvent/OnUpdate is swapped for a wrapper that times the call,
-- measures how much Lua memory it allocated, and notices when a full
-- garbage collection ran inside it. Wrapped scripts are put back after.

local FW = FpsWatch
local P = {}
FW.Profiler = P

local floor = math.floor
local getn, tinsert, tsort = table.getn, table.insert, table.sort
local strfind, strlower, strsub, strlen, gsub = string.find, string.lower, string.sub, string.len, string.gsub
local gcinfo = gcinfo
local round1 = FW.round1

local timer
local active = false

local slots = {}     -- "owner|label" -> stats, shared by frames with the same label
local evSlots = {}   -- event name -> stats
local gcSlot
local frameSlot = setmetatable({}, { __mode = "k" })
local wrapperSet = setmetatable({}, { __mode = "k" })
local cacheEvent = setmetatable({}, { __mode = "k" })
local cacheUpdate = setmetatable({}, { __mode = "k" })
local installed, nInstalled = {}, 0
local seenFrames = setmetatable({}, { __mode = "k" })
local addonKeys = {}

-- Per-interval bucket: everything that ran between two of our OnUpdates,
-- which is exactly the span covered by that OnUpdate's elapsed time.
local serial = 1
local touched, nTouched = {}, 0
local evTouched, nEvTouched = {}, 0
local bucketMs, bucketGcMs, bucketAlloc = 0, 0, 0
local secSer = 1
local secList, nSec = {}, 0

P.overheadUs = 0
P.wrapped = 0

local function ResetSlot(sl)
  sl.total = 0; sl.slow = 0; sl.calls = 0; sl.max = 0; sl.upd = 0
  sl.alloc = 0; sl.gcHits = 0; sl.gcMs = 0; sl.frames = 0
  sl.ev = {}
  sl.ser = 0; sl.fms = 0; sl.sss = 0; sl.secSlow = 0
end

local function Record(sl, e, dt, dm)
  if dm < 0 then
    -- Memory went down, so a full GC ran inside this call. The stall is
    -- the collector's, not the handler's own work.
    sl.gcHits = sl.gcHits + 1
    sl.gcMs = sl.gcMs + dt
    bucketGcMs = bucketGcMs + dt
    sl = gcSlot
    e = nil
  else
    sl.alloc = sl.alloc + dm
    bucketAlloc = bucketAlloc + dm
    if not e then sl.upd = sl.upd + dt end
  end
  sl.total = sl.total + dt
  sl.calls = sl.calls + 1
  if dt > sl.max then sl.max = dt end
  bucketMs = bucketMs + dt
  if sl.ser ~= serial then
    sl.ser = serial
    sl.fms = dt
    nTouched = nTouched + 1
    touched[nTouched] = sl
  else
    sl.fms = sl.fms + dt
  end
  if e then
    local ev = sl.ev
    ev[e] = (ev[e] or 0) + dt
    local es = evSlots[e]
    if not es then
      es = { name = e, total = 0, calls = 0, slow = 0, ser = 0, fms = 0 }
      evSlots[e] = es
    end
    es.total = es.total + dt
    es.calls = es.calls + 1
    if es.ser ~= serial then
      es.ser = serial
      es.fms = dt
      nEvTouched = nEvTouched + 1
      evTouched[nEvTouched] = es
    else
      es.fms = es.fms + dt
    end
  end
end

-- The 1.12 engine calls script handlers with no arguments (they read
-- this/event/arg1..), so pass nothing unless someone called us directly.
local function MakeWrapper(orig, sl, isEvent)
  local w
  if isEvent then
    w = function(a1, a2, a3, a4)
      if not active then
        if a1 == nil then return orig() end
        return orig(a1, a2, a3, a4)
      end
      local e = event
      local m0 = gcinfo()
      local t0 = timer()
      if a1 == nil then orig() else orig(a1, a2, a3, a4) end
      local dt = timer() - t0
      local dm = gcinfo() - m0
      if dt >= 0 and dt < 60000 then Record(sl, e, dt, dm) end
    end
  else
    w = function(a1, a2, a3, a4)
      if not active then
        if a1 == nil then return orig() end
        return orig(a1, a2, a3, a4)
      end
      local m0 = gcinfo()
      local t0 = timer()
      if a1 == nil then orig() else orig(a1, a2, a3, a4) end
      local dt = timer() - t0
      local dm = gcinfo() - m0
      if dt >= 0 and dt < 60000 then Record(sl, nil, dt, dm) end
    end
  end
  wrapperSet[w] = true
  return w
end

----------------------------------------------------------------------
-- Naming: which addon does a frame belong to?
----------------------------------------------------------------------
local function Norm(s)
  return strlower((gsub(s, "[^%w]", "")))
end

local function BuildAddonKeys()
  FW.wipe(addonKeys)
  for i = 1, GetNumAddOns() do
    local name = GetAddOnInfo(i)
    if name and IsAddOnLoaded(i) then
      local key = Norm(name)
      if strlen(key) >= 2 then tinsert(addonKeys, { name = name, key = key }) end
    end
  end
end

-- Named frames made in XML don't pass through CreateFrame; guess the
-- addon from the name ("BigWigsFrame" -> BigWigs).
local function GuessOwner(name)
  local fk = Norm(name)
  local flen = strlen(fk)
  local best, bestLen = nil, 0
  for i = 1, getn(addonKeys) do
    local ak = addonKeys[i].key
    local alen = strlen(ak)
    local maxn = alen
    if flen < maxn then maxn = flen end
    local n = 0
    while n < maxn and strsub(ak, n + 1, n + 1) == strsub(fk, n + 1, n + 1) do n = n + 1 end
    if (n == alen or n >= 5) and n > bestLen then
      best, bestLen = addonKeys[i].name, n
    end
  end
  if best then return best .. "?" end
  return nil
end

local function Describe(f)
  local owner = FW.frameOwner[f]
  local name = f:GetName()
  local label
  if name then
    label = gsub(name, "%d+", "#")
  else
    local p = f:GetParent()
    if p and p == WorldFrame then
      -- Unnamed children of WorldFrame are the nameplates in 1.12; their
      -- scripts come from whatever nameplate addon you run.
      return owner or "Nameplates", "nameplate frames"
    end
    local depth = 0
    while p and depth < 8 do
      if not owner then owner = FW.frameOwner[p] end
      local pn = p:GetName()
      if pn then
        label = "unnamed child of " .. gsub(pn, "%d+", "#")
        break
      end
      p = p:GetParent()
      depth = depth + 1
    end
    label = label or "unnamed frame"
  end
  if not owner and name then owner = GuessOwner(name) end
  if not owner and FW.preexisting[f] then owner = "Blizzard UI" end
  return owner or "unknown", label
end

local function SlotFor(f)
  local sl = frameSlot[f]
  if sl then return sl end
  local owner, label = Describe(f)
  local key = owner .. "|" .. label
  sl = slots[key]
  if not sl then
    sl = { key = key, owner = owner, label = label }
    ResetSlot(sl)
    slots[key] = sl
  end
  frameSlot[f] = sl
  return sl
end

function P.SlotName(sl)
  if not sl then return nil end
  if sl == gcSlot then return "Lua garbage collection" end
  return sl.owner .. ": " .. sl.label
end

----------------------------------------------------------------------
-- Wrapping
----------------------------------------------------------------------
local function WrapScript(f, script, cache, isEvent)
  local fn = f:GetScript(script)
  if not fn or wrapperSet[fn] then return end
  local sl = SlotFor(f)
  local byslot = cache[fn]
  if not byslot then
    byslot = {}
    cache[fn] = byslot
  end
  local w = byslot[sl]
  if not w then
    w = MakeWrapper(fn, sl, isEvent)
    byslot[sl] = w
  end
  f:SetScript(script, w)
  nInstalled = nInstalled + 1
  installed[nInstalled] = { f, script, fn, w }
  if not seenFrames[f] then
    seenFrames[f] = true
    sl.frames = sl.frames + 1
  end
  P.wrapped = P.wrapped + 1
end

local function WrapBoth(f)
  WrapScript(f, "OnEvent", cacheEvent, true)
  WrapScript(f, "OnUpdate", cacheUpdate, false)
end

local function WrapFrame(f)
  if FW.own[f] then return end
  pcall(WrapBoth, f)
end

local function Walk(f, depth)
  WrapFrame(f)
  if depth > 12 or not f.GetChildren then return end
  local kids = { f:GetChildren() }
  for i = 1, getn(kids) do Walk(kids[i], depth + 1) end
end

-- Wraps scripts that aren't wrapped yet (new frames, OnUpdates switched
-- on since the last pass). A full pass runs at the pull, outside any
-- measured frame; later passes go through ScanStep a slice at a time so
-- the rescan never causes a hitch of its own.
local cursor
function P.ScanStep(budget)
  if not active then return true end
  if not EnumerateFrames then
    P.Scan()
    return true
  end
  local f
  if cursor then f = EnumerateFrames(cursor) else f = EnumerateFrames() end
  local n = 0
  while f and n < budget do
    WrapFrame(f)
    cursor = f
    f = EnumerateFrames(f)
    n = n + 1
  end
  if not f then
    cursor = nil
    return true
  end
  return false
end

function P.Scan()
  if not active then return end
  if EnumerateFrames then
    local f = EnumerateFrames()
    while f do
      WrapFrame(f)
      f = EnumerateFrames(f)
    end
  else
    for f in pairs(FW.frameOwner) do WrapFrame(f) end
    if UIParent then Walk(UIParent, 0) end
    if WorldFrame then Walk(WorldFrame, 0) end
  end
end

local function Unwrap()
  for i = 1, nInstalled do
    local rec = installed[i]
    local f, script, orig, w = rec[1], rec[2], rec[3], rec[4]
    local ok, cur = pcall(f.GetScript, f, script)
    -- Only put back what is still ours; if an addon replaced or hooked the
    -- script meanwhile, leave theirs (our wrapper passes straight through).
    if ok and cur == w then pcall(f.SetScript, f, script, orig) end
    installed[i] = nil
  end
  nInstalled = 0
end

local function ResetBuckets()
  serial = serial + 1
  nTouched = 0; nEvTouched = 0
  bucketMs = 0; bucketGcMs = 0; bucketAlloc = 0
  secSer = secSer + 1
  nSec = 0
end

-- Cost of the wrapper itself, so the report can say how much we added.
local function Calibrate()
  local dummy = { owner = "", label = "" }
  ResetSlot(dummy)
  local noop = function() end
  local w = MakeWrapper(noop, dummy, false)
  local N = 2000
  local t0 = timer()
  for i = 1, N do noop() end
  local t1 = timer()
  for i = 1, N do w() end
  local t2 = timer()
  local us = ((t2 - t1) - (t1 - t0)) * 1000 / N
  if us < 0 then us = 0 end
  return us
end

function P.Start()
  timer = FW.timer
  if not timer then return false end
  for _, sl in pairs(slots) do ResetSlot(sl) end
  FW.wipe(evSlots)
  if not gcSlot then
    gcSlot = { key = "Lua GC|garbage collection", owner = "Lua GC", label = "garbage collection" }
    slots[gcSlot.key] = gcSlot
  end
  ResetSlot(gcSlot)
  gcSlot.isGC = true
  BuildAddonKeys()
  FW.wipe(seenFrames)
  P.wrapped = 0
  active = true
  cursor = nil
  P.overheadUs = Calibrate()
  ResetBuckets()
  P.Scan()
  ResetBuckets()
  return true
end

-- Called from our OnUpdate once per frame. Returns the script time in the
-- interval that just ended, the part of it that was GC, and (for slow
-- intervals) the heaviest slot.
function P.CloseInterval(slow)
  local h, g = bucketMs, bucketGcMs
  local top, topMs = nil, 0
  if slow then
    for i = 1, nTouched do
      local sl = touched[i]
      local v = sl.fms
      sl.slow = sl.slow + v
      if sl.sss ~= secSer then
        sl.sss = secSer
        sl.secSlow = v
        nSec = nSec + 1
        secList[nSec] = sl
      else
        sl.secSlow = sl.secSlow + v
      end
      if v > topMs then top, topMs = sl, v end
    end
    for i = 1, nEvTouched do
      local es = evTouched[i]
      es.slow = es.slow + es.fms
    end
  end
  local alloc = bucketAlloc
  serial = serial + 1
  nTouched = 0; nEvTouched = 0
  bucketMs = 0; bucketGcMs = 0; bucketAlloc = 0
  return h, g, top, topMs, alloc
end

local function BySecSlow(a, b) return a.secSlow > b.secSlow end

-- Heaviest slots during the slow frames of the second that just ended.
function P.TakeSecondTop(n)
  local out
  if n > 0 and nSec > 0 then
    local tmp = {}
    for i = 1, nSec do tmp[i] = secList[i] end
    tsort(tmp, BySecSlow)
    out = {}
    for i = 1, n do
      local sl = tmp[i]
      if not sl then break end
      out[i] = { n = P.SlotName(sl), v = round1(sl.secSlow) }
    end
  end
  secSer = secSer + 1
  nSec = 0
  return out
end

local function TopKeys(t, n)
  local list = {}
  for k, v in pairs(t) do tinsert(list, { n = k, v = v }) end
  tsort(list, function(a, b) return a.v > b.v end)
  local out = {}
  for i = 1, n do
    if not list[i] then break end
    out[i] = { n = list[i].n, v = round1(list[i].v) }
  end
  return out
end

local function BySlowThenTotal(a, b)
  if a.slow ~= b.slow then return a.slow > b.slow end
  return a.total > b.total
end

function P.Stop()
  active = false
  Unwrap()
  return P.Collect()
end

function P.IsActive() return active end

function P.Collect()
  local out = { slots = {}, owners = {}, events = {}, garbage = {}, gcTriggers = {} }
  local list = {}
  local owners = {}
  local calls = 0
  local slowAddons, slowBlizz, slowGc = 0, 0, 0
  for _, sl in pairs(slots) do
    if sl.calls > 0 then
      tinsert(list, sl)
      calls = calls + sl.calls
      if sl == gcSlot then
        slowGc = slowGc + sl.slow
      else
        if sl.owner == "Blizzard UI" then slowBlizz = slowBlizz + sl.slow else slowAddons = slowAddons + sl.slow end
        local o = owners[sl.owner]
        if not o then
          o = { name = sl.owner, slow = 0, total = 0, alloc = 0, max = 0, calls = 0, gcHits = 0, top = nil, topSlow = -1 }
          owners[sl.owner] = o
        end
        o.slow = o.slow + sl.slow
        o.total = o.total + sl.total
        o.alloc = o.alloc + sl.alloc
        o.calls = o.calls + sl.calls
        o.gcHits = o.gcHits + sl.gcHits
        if sl.max > o.max then o.max = sl.max end
        if sl.slow > o.topSlow or (sl.slow == o.topSlow and o.top and sl.total > o.top.total) then
          o.top, o.topSlow = sl, sl.slow
        end
      end
    end
  end
  out.calls = calls
  out.overheadMs = round1(calls * P.overheadUs / 1000)
  out.overheadUs = round1(P.overheadUs)
  out.wrapped = P.wrapped
  out.slowAddons = round1(slowAddons)
  out.slowBlizz = round1(slowBlizz)
  out.slowGc = round1(slowGc)

  tsort(list, BySlowThenTotal)
  for i = 1, 30 do
    local sl = list[i]
    if not sl then break end
    out.slots[i] = {
      o = sl.owner, l = sl.label, gc = sl.isGC and 1 or nil,
      slow = round1(sl.slow), total = round1(sl.total), calls = sl.calls,
      max = round1(sl.max), alloc = floor(sl.alloc), upd = round1(sl.upd),
      gcHits = sl.gcHits, gcMs = round1(sl.gcMs), n = sl.frames,
      ev = TopKeys(sl.ev, 3),
    }
  end

  local olist = {}
  for _, o in pairs(owners) do tinsert(olist, o) end
  tsort(olist, BySlowThenTotal)
  for i = 1, 20 do
    local o = olist[i]
    if not o then break end
    out.owners[i] = {
      n = o.name, slow = round1(o.slow), total = round1(o.total), alloc = floor(o.alloc),
      max = round1(o.max), calls = o.calls, gcHits = o.gcHits,
      top = o.top and o.top.label,
    }
  end

  tsort(olist, function(a, b) return a.alloc > b.alloc end)
  for i = 1, 10 do
    local o = olist[i]
    if not o or o.alloc <= 0 then break end
    out.garbage[i] = { n = o.name, alloc = floor(o.alloc), top = o.top and o.top.label }
  end

  local trig = {}
  for i = 1, getn(list) do
    if list[i].gcHits > 0 and list[i] ~= gcSlot then tinsert(trig, list[i]) end
  end
  tsort(trig, function(a, b) return a.gcMs > b.gcMs end)
  for i = 1, 8 do
    local sl = trig[i]
    if not sl then break end
    out.gcTriggers[i] = { n = P.SlotName(sl), hits = sl.gcHits, ms = round1(sl.gcMs) }
  end

  local elist = {}
  for _, es in pairs(evSlots) do tinsert(elist, es) end
  tsort(elist, BySlowThenTotal)
  for i = 1, 15 do
    local es = elist[i]
    if not es then break end
    out.events[i] = { e = es.name, slow = round1(es.slow), total = round1(es.total), calls = es.calls }
  end
  return out
end
