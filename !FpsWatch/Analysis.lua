-- Turns a recorded session into a verdict and a plain-text report.

local FW = FpsWatch

local floor = math.floor
local format = string.format
local getn, tinsert, tsort, tconcat = table.getn, table.insert, table.sort, table.concat
local strfind = string.find
local fmtTime, round1 = FW.fmtTime, FW.round1

local function Pct(a, b)
  if not b or b <= 0 then return 0 end
  return floor(a / b * 100 + 0.5)
end

local function Max(a, b)
  if a > b then return a end
  return b
end

local function Sec(ms)
  return format("%.1f s", (ms or 0) / 1000)
end

local function MB(kb)
  return format("%.1f MB", (kb or 0) / 1024)
end

local function Add(lines, fmt, ...)
  if getn(arg) > 0 then
    tinsert(lines, format(fmt, unpack(arg)))
  else
    tinsert(lines, fmt)
  end
end

local function SortMap(map, n, div)
  local list = {}
  for k, v in pairs(map) do tinsert(list, { n = k, v = v }) end
  tsort(list, function(a, b) return a.v > b.v end)
  local out = {}
  for i = 1, n do
    if not list[i] then break end
    out[i] = { n = list[i].n, v = round1(list[i].v / div) }
  end
  return out
end

function FW.BuildEventRates(drop, dropSecs, normal, normalSecs)
  local seen, list = {}, {}
  for e in pairs(drop) do seen[e] = true end
  for e in pairs(normal) do seen[e] = true end
  for e in pairs(seen) do
    local d, r = 0, 0
    if dropSecs > 0 then d = (drop[e] or 0) / dropSecs end
    if normalSecs > 0 then r = (normal[e] or 0) / normalSecs end
    tinsert(list, { e = e, d = floor(d + 0.5), r = floor(r + 0.5) })
  end
  if dropSecs > 0 then
    tsort(list, function(a, b) return a.d > b.d end)
  else
    tsort(list, function(a, b) return a.r > b.r end)
  end
  local out = {}
  for i = 1, 15 do
    if not list[i] then break end
    out[i] = list[i]
  end
  return out
end

function FW.TimelineText(x)
  if x.k == "yell" then return x.s .. " yells: " .. x.n end
  if x.k == "emote" then return x.n end
  if x.k == "gain" then return x.s .. " gains " .. x.n end
  if x.k == "hit" then return x.s .. "'s " .. x.n end
  if x.k == "died" then return x.s .. " dies" end
  return x.s .. " casts " .. x.n
end

local function IsNotAddon(name)
  return name == "Blizzard UI" or name == "Lua GC"
end

----------------------------------------------------------------------
-- Analysis
----------------------------------------------------------------------
function FW.Analyze(s)
  local a = { episodes = {}, causes = {}, advice = {}, notes = {} }
  local eps = a.episodes
  local slowAlloc, slowN, normAlloc, normN = 0, 0, 0, 0
  local slowPlates, slowPN, normPlates, normPN = 0, 0, 0, 0
  local worstSec, worstSecAt
  local cur

  for i = 1, s.nSamples do
    local smp = s.samples[i]
    if not worstSec or smp.f < worstSec then worstSec, worstSecAt = smp.f, smp.t end
    if smp.s then
      slowAlloc = slowAlloc + (smp.al or 0); slowN = slowN + 1
      if smp.np then slowPlates = slowPlates + smp.np; slowPN = slowPN + 1 end
      if not cur or smp.t - cur.to > 2 then
        cur = { from = Max(smp.t - 1, 0), to = smp.t, n = 0, minFps = 1e9, fpsSum = 0, low = false,
                addons = {}, events = {}, plates = 0, allocSum = 0, gc = 0, hSum = 0, hN = 0 }
        tinsert(eps, cur)
      end
      cur.to = smp.t
      cur.n = cur.n + 1
      if smp.mn < cur.minFps then cur.minFps = smp.mn end
      cur.fpsSum = cur.fpsSum + smp.f
      if smp.f < s.dropFps then cur.low = true end
      if smp.sa then
        for j = 1, getn(smp.sa) do
          local x = smp.sa[j]
          cur.addons[x.n] = (cur.addons[x.n] or 0) + x.v
        end
      end
      if smp.se then
        for j = 1, getn(smp.se) do
          local x = smp.se[j]
          cur.events[x.n] = (cur.events[x.n] or 0) + x.v
        end
      end
      if smp.np and smp.np > cur.plates then cur.plates = smp.np end
      cur.allocSum = cur.allocSum + (smp.al or 0)
      cur.gc = cur.gc + (smp.gc or 0)
      if smp.h then cur.hSum = cur.hSum + smp.h; cur.hN = cur.hN + 1 end
      if smp.bh and not cur.bossHp then cur.bossHp = smp.bh end
    else
      normAlloc = normAlloc + (smp.al or 0); normN = normN + 1
      if smp.np then normPlates = normPlates + smp.np; normPN = normPN + 1 end
    end
  end
  a.worstSec, a.worstSecAt = worstSec, worstSecAt

  -- Timeline around each episode, and which entries keep showing up.
  local tlTotal, tlEp = {}, {}
  for i = 1, s.nTimeline do
    local x = s.timeline[i]
    if x.k ~= "died" then
      local key = FW.TimelineText(x)
      tlTotal[key] = (tlTotal[key] or 0) + 1
    end
  end
  for i = 1, getn(eps) do
    local e = eps[i]
    e.avgFps = round1(e.fpsSum / e.n)
    e.alloc = floor(e.allocSum / e.n + 0.5)
    if e.hN > 0 then e.handler = round1(e.hSum / e.hN) end
    e.topAddons = SortMap(e.addons, 3, e.n)
    e.topEvents = SortMap(e.events, 3, e.n)
    e.tl = {}
    local seen = {}
    for j = 1, s.nTimeline do
      local x = s.timeline[j]
      if x.t >= e.from - 3 and x.t <= e.to then
        tinsert(e.tl, x)
        local key = FW.TimelineText(x)
        if not seen[key] and x.k ~= "died" then
          seen[key] = true
          tlEp[key] = (tlEp[key] or 0) + 1
        end
      end
    end
  end
  local nEps = getn(eps)
  a.correlated = {}
  if nEps >= 2 then
    for key, n in pairs(tlEp) do
      if n >= 2 and n >= nEps * 0.5 and n / tlTotal[key] >= 0.5 then
        tinsert(a.correlated, { n = key, eps = n, total = tlTotal[key] })
      end
    end
    tsort(a.correlated, function(x, y) return x.eps > y.eps end)
  end

  a.hasDrops = s.lowSecs >= 1 or s.hitchCount > 0
  a.slowAlloc = slowN > 0 and floor(slowAlloc / slowN) or nil
  a.normAlloc = normN > 0 and floor(normAlloc / normN) or nil
  a.slowPlates = slowPN > 0 and round1(slowPlates / slowPN) or nil
  a.normPlates = normPN > 0 and round1(normPlates / normPN) or nil

  -- Where did the time go during slow frames?
  local T = s.slowMs
  local prof = s.prof
  local cfgDrop = s.dropFps
  if T > 0 then
    local gcMs = s.slowGcOutsideMs + (prof and prof.slowGc or 0)
    local addonMs = prof and prof.slowAddons or 0
    local blizzMs = prof and prof.slowBlizz or 0
    local ours = 0
    if s.totalMs > 0 then
      ours = ((prof and prof.overheadMs or 0) + (s.selfMs or 0)) * T / s.totalMs
    end
    local engineMs = Max(0, T - addonMs - blizzMs - gcMs - ours)
    a.split = { total = T, addons = addonMs, blizz = blizzMs, gc = gcMs, engine = engineMs, ours = ours }

    local function Cause(key, ms, title)
      tinsert(a.causes, { key = key, ms = ms, share = Pct(ms, T), title = title })
    end
    if prof then
      if Pct(addonMs, T) >= 15 then Cause("addons", addonMs, "addon scripts") end
      if Pct(blizzMs, T) >= 15 then Cause("blizz", blizzMs, "Blizzard UI scripts") end
      if Pct(engineMs, T) >= 20 then Cause("engine", engineMs, "graphics / game engine") end
    else
      if Pct(engineMs, T) >= 20 then Cause("cpu", engineMs, "scripts or graphics (no timer to tell them apart)") end
    end
    if Pct(gcMs, T) >= 15 or (s.gcHitches >= 2 and s.gcHitches * 3 >= s.hitchCount) then
      Cause("gc", gcMs, "Lua garbage collection")
    end
    tsort(a.causes, function(x, y) return x.ms > y.ms end)
  end

  -- Top addons (not Blizzard, not GC) during slow frames.
  a.topAddons = {}
  if prof then
    for i = 1, getn(prof.owners) do
      local o = prof.owners[i]
      if not IsNotAddon(o.n) and o.slow > 0 and (getn(a.topAddons) == 0 or o.slow >= T * 0.05) then
        tinsert(a.topAddons, o)
      end
      if getn(a.topAddons) >= 3 then break end
    end
  end

  -- Short verdict for chat and the report list.
  if not a.hasDrops then
    a.short = format("no drops below %d FPS", cfgDrop)
  elseif getn(a.causes) == 0 then
    a.short = "drops, no single cause"
  else
    local c = a.causes[1]
    a.short = c.title .. " " .. c.share .. "%"
    if c.key == "addons" and a.topAddons[1] then
      local names = {}
      for i = 1, getn(a.topAddons) do tinsert(names, a.topAddons[i].n) end
      a.short = a.short .. " (" .. tconcat(names, ", ") .. ")"
    end
  end

  -- Advice
  local adv = a.advice
  local set = s.settings or {}
  for i = 1, getn(a.causes) do
    local c = a.causes[i]
    if c.key == "addons" then
      local o = a.topAddons[1]
      if o then
        local what = o.n
        if o.top then what = what .. " (" .. o.top .. ")" end
        tinsert(adv, format("Addon scripts: %s used %s during slow frames. Disable it (or just that part of it) for one pull and compare the next report.", what, Sec(o.slow)))
        if o.top == "nameplate frames" or o.n == "Nameplates" then
          tinsert(adv, "Nameplate scripts cost more with every plate on screen. Turn off enemy nameplates during the boss or use a lighter nameplate addon.")
        end
        if strfind(o.n, "%?$") then
          tinsert(adv, "Names ending in '?' are guessed from the frame name; the frame name is shown next to it.")
        end
      end
    elseif c.key == "gc" then
      local line = format("Lua garbage collection: %d full GC(s) during the fight", s.gcCount)
      if s.gcBench and s.gcBench.ms then
        line = line .. format(", and one full GC of your %s heap takes %d ms. 1.12's collector stops the game until it is done.", MB(s.gcBench.before), s.gcBench.ms)
      else
        line = line .. ". 1.12's collector stops the game until it is done."
      end
      tinsert(adv, line)
      if prof and prof.garbage[1] then
        local g = {}
        for j = 1, 3 do
          local x = prof.garbage[j]
          if not x then break end
          tinsert(g, x.n .. " " .. MB(x.alloc))
        end
        tinsert(adv, "Biggest garbage producers this fight: " .. tconcat(g, ", ") .. ". Less garbage means fewer collections.")
      end
      if s.gcGuard then
        tinsert(adv, "GC guard was on and collections still happened: give it more room with /fpsw gcguard on 128 (or more).")
      else
        tinsert(adv, "Try /fpsw gcguard on: at the pull it raises the GC threshold so the collection waits until combat ends, then collects out of combat.")
      end
    elseif c.key == "blizz" then
      local label
      if prof then
        for j = 1, getn(prof.slots) do
          if prof.slots[j].o == "Blizzard UI" then label = prof.slots[j].l; break end
        end
      end
      if label and strfind(label, "ChatFrame") then
        tinsert(adv, "Blizzard UI: chat frames are the heaviest. The combat log tab formats every combat message; close it or untick most message types for it during raids.")
      else
        tinsert(adv, "Blizzard UI scripts are heavy" .. (label and (" (mostly " .. label .. ")") or "") .. ". Addons that hook Blizzard frames show up here too.")
      end
    elseif c.key == "cpu" then
      tinsert(adv, "This client has no precise timer, so addon scripts and graphics can't be told apart. Do one pull with your heaviest addons disabled: if the drops stay, it's graphics; if they go away, it was one of those addons.")
    elseif c.key == "engine" then
      local tips = {}
      local function Num(k) return tonumber(set[k] or "") end
      if Num("farclip") and Num("farclip") > 350 then tinsert(tips, "terrain distance (farclip " .. set.farclip .. ")") end
      if Num("spellEffectLevel") and Num("spellEffectLevel") > 1 then tinsert(tips, "spell detail (spellEffectLevel " .. set.spellEffectLevel .. ")") end
      if Num("weatherDensity") and Num("weatherDensity") > 0 then tinsert(tips, "weather (weatherDensity " .. set.weatherDensity .. ")") end
      if Num("ffxGlow") and Num("ffxGlow") > 0 then tinsert(tips, "full screen glow (ffxGlow)") end
      if Num("ffxDeath") and Num("ffxDeath") > 0 then tinsert(tips, "death effect (ffxDeath)") end
      local line = "Graphics / engine: this time is spent outside Lua (drawing spell effects, player models, terrain), so no addon change will fix it."
      if getn(tips) > 0 then
        line = line .. " Lower: " .. tconcat(tips, ", ") .. "."
      else
        line = line .. " Lower spell detail, terrain distance and weather in raids."
      end
      tinsert(adv, line .. " Zooming the camera in also helps in 40-man fights.")
    end
  end
  for i = 1, 2 do
    local c = a.correlated[i]
    if not c then break end
    tinsert(a.notes, format("Drops line up with \"%s\": %d of %d drop episodes started within 3 s of it.", c.n, c.eps, nEps))
  end
  local isGcCause = false
  for i = 1, getn(a.causes) do
    if a.causes[i].key == "gc" then isGcCause = true end
  end
  if not isGcCause and s.gcCount >= 3 then
    local each = ""
    if s.gcBench and s.gcBench.ms then each = format(" (about %d ms each)", s.gcBench.ms) end
    tinsert(a.notes, format("%d full Lua GCs ran during the fight%s; not the main cause here, but each one is a short freeze.", s.gcCount, each))
  end
  if a.slowPlates and a.normPlates and a.slowPlates >= 15 and a.slowPlates >= a.normPlates * 1.5 then
    tinsert(a.notes, format("More nameplates during drops: %.0f on average vs %.0f otherwise.", a.slowPlates, a.normPlates))
  end
  if a.slowAlloc and a.normAlloc and a.slowAlloc >= 500 and a.slowAlloc >= a.normAlloc * 2 then
    tinsert(a.notes, format("Garbage spikes during drops: %d KB/s vs %d KB/s otherwise.", a.slowAlloc, a.normAlloc))
  end
  if s.events and s.events[1] and s.dropSecs > 0 then
    local e = s.events[1]
    if e.d >= 200 and e.d >= e.r * 2 then
      tinsert(a.notes, format("Event spike during drops: %s %d/s vs %d/s otherwise.", e.e, e.d, e.r))
    end
  end
  if prof and s.totalMs > 0 and prof.overheadMs / s.totalMs > 0.05 then
    tinsert(a.notes, format("The profiler itself cost about %d%% of the fight. Run a pull with /fpsw profile off to compare FPS.", Pct(prof.overheadMs, s.totalMs)))
  end
  return a
end

----------------------------------------------------------------------
-- Report text
----------------------------------------------------------------------
local HIST_LABELS = { "<17ms", "17-33ms", "33-50ms", "50-100ms", "100-250ms", "250ms+" }

function FW.SessionTitle(s)
  local t = s.name or "?"
  if s.zone and s.zone ~= s.name then t = t .. " (" .. s.zone .. ")" end
  return t
end

function FW.BuildReportText(s, a)
  a = a or FW.Analyze(s)
  local L = {}
  local prof = s.prof
  local dur = s.duration or 0

  Add(L, "FpsWatch %s report", FW.VERSION)
  local result = s.result and string.upper(s.result) or s.kind
  Add(L, "%s - %s - %s, %d player(s) - %s", FW.SessionTitle(s), result, fmtTime(dur), s.groupSize or 1, s.date or "?")
  if s.kind == "manual" then Add(L, "Recorded manually.") end
  tinsert(L, "")

  -- FPS
  local line = format("FPS: avg %.0f", s.avgFps or 0)
  if s.baseline then line = line .. format(" (before the pull ~%.0f)", s.baseline) end
  if a.worstSec then line = line .. format("; worst second %.0f FPS at %s", a.worstSec, fmtTime(a.worstSecAt)) end
  line = line .. format("; worst frame %d ms at %s", s.worstMs or 0, fmtTime(s.worstAt))
  tinsert(L, line)
  Add(L, "Below %d FPS for %d s (%d%% of the fight) in %d episode(s); %d hitch(es) of %d ms or more (%d with a Lua GC in the same frame).",
    s.dropFps, floor(s.lowSecs + 0.5), Pct(s.lowSecs, dur), getn(a.episodes), s.hitchCount, s.hitchMs, s.gcHitches)
  local hist = {}
  for i = 1, 6 do
    tinsert(hist, HIST_LABELS[i] .. " " .. Pct(s.hist[i], s.frames) .. "%")
  end
  tinsert(L, "Frame times: " .. tconcat(hist, "; "))
  tinsert(L, "")

  -- Split
  if a.split then
    local sp = a.split
    Add(L, "WHERE THE TIME WENT in slow frames (%d ms or longer: %d frames, %s):", floor(1000 / s.dropFps + 0.5), s.slowFrames, Sec(sp.total))
    if prof then
      Add(L, "  addon scripts ........ %3d%%  %s", Pct(sp.addons, sp.total), Sec(sp.addons))
      Add(L, "  Lua garbage collection %3d%%  %s", Pct(sp.gc, sp.total), Sec(sp.gc))
      Add(L, "  Blizzard UI scripts .. %3d%%  %s", Pct(sp.blizz, sp.total), Sec(sp.blizz))
      Add(L, "  graphics / engine .... %3d%%  %s  (everything outside Lua)", Pct(sp.engine, sp.total), Sec(sp.engine))
      Add(L, "  FpsWatch itself ...... %3d%%", Pct(sp.ours, sp.total))
    else
      Add(L, "  Lua garbage collection %3d%%  %s", Pct(sp.gc, sp.total), Sec(sp.gc))
      Add(L, "  scripts + graphics ... %3d%%  (no precise timer on this client to split these)", Pct(sp.engine, sp.total))
    end
    tinsert(L, "")
  end

  -- Verdict
  tinsert(L, "VERDICT")
  if not a.hasDrops then
    Add(L, "  No drops below %d FPS and no hitches of %d ms or more in this fight.", s.dropFps, s.hitchMs)
  elseif getn(a.causes) == 0 then
    tinsert(L, "  Drops happened but no single cause stands out; see the episodes below.")
  else
    for i = 1, getn(a.causes) do
      local c = a.causes[i]
      Add(L, "  %d) %s: %d%% of slow-frame time", i, c.title, c.share)
      if c.key == "addons" then
        for j = 1, getn(a.topAddons) do
          local o = a.topAddons[j]
          Add(L, "     - %s: %s (%d%%)%s", o.n, Sec(o.slow), Pct(o.slow, a.split.total), o.top and (", mostly " .. o.top) or "")
        end
      end
    end
  end
  for i = 1, getn(a.notes) do tinsert(L, "  * " .. a.notes[i]) end
  tinsert(L, "")
  if getn(a.advice) > 0 then
    tinsert(L, "WHAT TO TRY")
    for i = 1, getn(a.advice) do tinsert(L, "  - " .. a.advice[i]) end
    tinsert(L, "")
  end

  -- Episodes
  local eps = a.episodes
  if getn(eps) > 0 then
    tinsert(L, "DROP EPISODES")
    for i = 1, getn(eps) do
      if i > 12 then
        Add(L, "  ... and %d more", getn(eps) - 12)
        break
      end
      local e = eps[i]
      local kind = "stutter"
      if e.low then kind = "low FPS" end
      local hdr = format("  #%d %s-%s (%d s) %s: min %.0f, avg %.0f FPS", i, fmtTime(e.from), fmtTime(e.to), e.to - e.from, kind, e.minFps, e.avgFps)
      if e.bossHp then hdr = hdr .. format(", boss at %d%%", e.bossHp) end
      tinsert(L, hdr)
      if getn(e.topAddons) > 0 and e.topAddons[1].v >= 0.5 then
        local parts = {}
        for j = 1, getn(e.topAddons) do
          if e.topAddons[j].v >= 0.5 then tinsert(parts, format("%s %.0f ms/s", e.topAddons[j].n, e.topAddons[j].v)) end
        end
        tinsert(L, "     scripts: " .. tconcat(parts, "; "))
      end
      if getn(e.topEvents) > 0 then
        local parts = {}
        for j = 1, getn(e.topEvents) do tinsert(parts, format("%s %.0f", e.topEvents[j].n, e.topEvents[j].v)) end
        tinsert(L, "     events/s: " .. tconcat(parts, "; "))
      end
      if getn(e.tl) > 0 then
        local parts = {}
        for j = 1, getn(e.tl) do
          if j > 5 then
            tinsert(parts, "...")
            break
          end
          tinsert(parts, fmtTime(e.tl[j].t) .. " " .. FW.TimelineText(e.tl[j]))
        end
        tinsert(L, "     fight: " .. tconcat(parts, "; "))
      end
      local extra = {}
      if e.plates > 0 then tinsert(extra, "nameplates " .. e.plates) end
      tinsert(extra, "garbage " .. e.alloc .. " KB/s")
      if e.gc > 0 then tinsert(extra, "Lua GC x" .. e.gc) end
      if e.handler then tinsert(extra, format("scripts %.0f%% of frame time", e.handler)) end
      tinsert(L, "     " .. tconcat(extra, "; "))
    end
    tinsert(L, "")
  end

  -- Worst hitches
  if getn(s.hitches) > 0 then
    local list = {}
    for i = 1, getn(s.hitches) do list[i] = s.hitches[i] end
    tsort(list, function(x, y) return x.ms > y.ms end)
    tinsert(L, "WORST HITCHES")
    for i = 1, 10 do
      local h = list[i]
      if not h then break end
      local d
      if h.gm then
        d = format("Lua GC inside a script (%d ms)", h.gm)
      elseif h.gc then
        d = "Lua GC outside timed scripts"
      elseif prof and h.h and h.h < h.ms * 0.3 then
        d = format("scripts only %d ms -> graphics / engine", h.h)
      elseif h.h then
        d = format("scripts %d ms", h.h)
      else
        d = ""
      end
      if h.top and not h.gm then d = d .. format(", top: %s %d ms", h.top, h.tm or 0) end
      Add(L, "  %s  %4d ms  %s", fmtTime(h.t), h.ms, d)
    end
    tinsert(L, "")
  end

  -- Addons
  if prof then
    tinsert(L, "ADDONS (script time this fight; 'slow' = inside slow frames)")
    for i = 1, getn(prof.owners) do
      if i > 15 then break end
      local o = prof.owners[i]
      local msps = dur > 0 and o.total / dur or 0
      Add(L, "  %s: slow %s; total %s (%.1f ms/s); max %d ms; garbage %s; GCs %d%s",
        o.n, Sec(o.slow), Sec(o.total), msps, o.max, MB(o.alloc), o.gcHits, o.top and ("; heaviest: " .. o.top) or "")
    end
    tinsert(L, "")
    tinsert(L, "HEAVIEST SCRIPT FRAMES")
    for i = 1, getn(prof.slots) do
      if i > 15 then break end
      local x = prof.slots[i]
      if x.gc then
        Add(L, "  Lua garbage collection (inside scripts): slow %s, total %s, %d time(s), longest %d ms", Sec(x.slow), Sec(x.total), x.calls, x.max)
      else
        local evs = {}
        for j = 1, getn(x.ev) do tinsert(evs, x.ev[j].n .. " " .. Sec(x.ev[j].v)) end
        local extra = ""
        if getn(evs) > 0 then extra = "; events: " .. tconcat(evs, ", ") end
        if x.upd > 0 then extra = extra .. "; OnUpdate " .. Sec(x.upd) end
        Add(L, "  %s: %s x%d - slow %s, total %s, max %d ms, garbage %s%s", x.o, x.l, x.n, Sec(x.slow), Sec(x.total), x.max, MB(x.alloc), extra)
      end
    end
    tinsert(L, "")
    if getn(prof.events) > 0 then
      tinsert(L, "EVENTS BY SCRIPT TIME (all frames' handlers for that event)")
      for i = 1, getn(prof.events) do
        if i > 10 then break end
        local e = prof.events[i]
        if e.total >= 1 then
          Add(L, "  %s: total %s, slow %s, %d handler calls", e.e, Sec(e.total), Sec(e.slow), e.calls)
        end
      end
      tinsert(L, "")
    end
  end

  if s.events and getn(s.events) > 0 then
    if s.dropSecs > 0 then
      tinsert(L, "EVENTS PER SECOND (during drops vs the rest of the fight)")
    else
      tinsert(L, "EVENTS PER SECOND")
    end
    for i = 1, getn(s.events) do
      if i > 10 then break end
      local e = s.events[i]
      if e.d == 0 and e.r == 0 then
        -- nothing worth a line
      elseif s.dropSecs > 0 then
        Add(L, "  %s: %d/s vs %d/s", e.e, e.d, e.r)
      else
        Add(L, "  %s: %d/s", e.e, e.r)
      end
    end
    if not s.allEvents then tinsert(L, "  (counted from a fixed list of combat/unit/chat events)") end
    tinsert(L, "")
  end

  -- Memory
  tinsert(L, "LUA MEMORY AND GC")
  Add(L, "  heap %s at the pull, peak %s; %s allocated (%d KB/s); %d full GC(s) during the fight",
    MB(s.startMemKB), MB(s.peakMemKB), MB(s.allocKB), dur > 0 and floor(s.allocKB / dur) or 0, s.gcCount)
  if a.slowAlloc and a.normAlloc then
    Add(L, "  garbage rate: %d KB/s during drops, %d KB/s otherwise", a.slowAlloc, a.normAlloc)
  end
  if s.gcBench and s.gcBench.ms then
    Add(L, "  one full GC right after the fight took %d ms (%s -> %s)", s.gcBench.ms, MB(s.gcBench.before), MB(s.gcBench.after))
  end
  if s.gcGuard then
    Add(L, "  GC guard raised the GC threshold from %s to %s at the pull", MB(s.gcGuard.from), MB(s.gcGuard.to))
  end
  if prof and getn(prof.garbage) > 0 then
    local g = {}
    for i = 1, getn(prof.garbage) do
      if i > 6 then break end
      tinsert(g, prof.garbage[i].n .. " " .. MB(prof.garbage[i].alloc))
    end
    tinsert(L, "  garbage by addon: " .. tconcat(g, ", "))
  end
  if prof and getn(prof.gcTriggers) > 0 then
    local g = {}
    for i = 1, getn(prof.gcTriggers) do
      local x = prof.gcTriggers[i]
      tinsert(g, format("%s x%d (%d ms)", x.n, x.hits, x.ms))
    end
    tinsert(L, "  GCs that ran inside: " .. tconcat(g, ", "))
  end
  tinsert(L, "")

  -- Boss timeline
  if s.nTimeline > 0 then
    tinsert(L, "FIGHT TIMELINE (boss/creature casts and yells from the combat log)")
    for i = 1, s.nTimeline do
      if i > 40 then
        Add(L, "  ... %d more", s.nTimeline - 40)
        break
      end
      local x = s.timeline[i]
      Add(L, "  %s %s", fmtTime(x.t), FW.TimelineText(x))
    end
    tinsert(L, "")
  end

  -- Client / settings
  tinsert(L, "CLIENT")
  local c = s.client or {}
  Add(L, "  build %s, realm %s, %d addons loaded, latency %s ms, %d addon frames with a known owner",
    c.build or "?", c.realm or "?", c.addons or 0, tostring(c.latency or "?"), c.ownedFrames or 0)
  local keys = {}
  for k in pairs(s.settings or {}) do tinsert(keys, k) end
  tsort(keys)
  local parts = {}
  for i = 1, getn(keys) do tinsert(parts, keys[i] .. "=" .. s.settings[keys[i]]) end
  if getn(parts) > 0 then tinsert(L, "  " .. tconcat(parts, " ")) end
  if prof then
    Add(L, "  profiler: %d scripts wrapped, %d calls, ~%.1f us per call => ~%s overhead; FpsWatch's own work %s",
      prof.wrapped or 0, prof.calls or 0, prof.overheadUs or 0, Sec(prof.overheadMs), Sec(s.selfMs))
  elseif FW.timer then
    tinsert(L, "  profiler was off for this fight (/fpsw profile on)")
  else
    tinsert(L, "  no debugprofilestop() on this client, so scripts could not be timed")
  end
  return tconcat(L, "\n")
end

function FW.PrintSummary(s, a)
  local result = s.result or s.kind
  FW.Print(format("%s (%s, %s): avg %.0f FPS, worst second %.0f FPS, %d s below %d FPS, %d hitch(es).",
    s.name or "?", result, fmtTime(s.duration), s.avgFps or 0, a.worstSec or 0, floor(s.lowSecs + 0.5), s.dropFps, s.hitchCount))
  if a.hasDrops then
    FW.Print("Main cause: |cffffd100" .. (a.short or "?") .. "|r. Type /fpsw for the full report.")
  end
end
