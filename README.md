# FpsWatch

A World of Warcraft **1.12** addon (made for OctoWoW) that finds out why your FPS drops during boss fights.

It records every fight automatically. After a boss it tells you where the time went in your slow frames:

- **Addon scripts**: which addon, which of its frames, and which events it was handling.
- **Lua garbage collection**: 1.12's Lua 5.0 collector stops the whole game while it runs. You get how often it ran, how long one collection takes with your memory use, and which addon made the garbage.
- **Blizzard UI scripts**: for example the combat log chat tab formatting every combat message.
- **Graphics / engine**: time spent outside Lua (spell effects, player models, terrain). No addon change fixes this; graphics settings do.

The report also lines drops up with the fight: boss casts and yells from the combat log, boss health, nameplate count, and event spam.

## Install

1. In OctoLauncher's Addons tab, install **FpsWatch** from *Our addons*. It goes into the
   right folder and updates like any other addon. Or clone it yourself:
   `git clone https://github.com/Salahaja/FpsWatch "World of Warcraft/Interface/AddOns/!FpsWatch"`.
   From the GitHub zip, rename the unpacked `FpsWatch-main` folder to `!FpsWatch`.
2. The folder must be named exactly `!FpsWatch`. The `!` makes it load before your other addons, which is how it learns which addon created each frame.
3. Log in and type `/fpsw test`. After about 11 seconds a report opens and blames `FpsWatchSelfTestFrame` for the fake lag. If it does, everything works.

## Use

Raid as normal. After each boss fight you get a two-line summary in chat, for example:

```
FpsWatch: Ragnaros (kill, 4:12): avg 41 FPS, worst second 9 FPS, 41 s below 20 FPS, 12 hitch(es).
FpsWatch: Main cause: addon scripts 58% (pfUI, KLHThreatMeter). Type /fpsw for the full report.
```

`/fpsw` opens the report window:

- **Graph**: FPS per second. Red is below the drop line, yellow ticks mark a Lua garbage collection. Hover a bar to see what was running that second.
- **Report**: verdict, what to try, every drop episode, the worst single-frame hitches, per-addon and per-frame script time, event rates, memory/GC, and your graphics settings.
- **Select all**, then **Ctrl+C** copies the whole report so you can paste it anywhere.

Reports are also saved in `WTF\Account\<ACCOUNT>\SavedVariables\!FpsWatch.lua` (the last 15).

### Reading the verdict

| Main cause | What to try |
| --- | --- |
| addon scripts | Disable the named addon (or the named part, e.g. its nameplates) for one pull and compare the next report. |
| Lua garbage collection | Turn on `/fpsw gcguard on`. It gives the collector room at the pull so it runs after combat instead. Also look at "garbage by addon". |
| Blizzard UI scripts | Usually the combat log tab. Close it or untick most message types during raids. |
| graphics / engine | Lower spell detail, terrain distance and weather, turn off full-screen glow, zoom the camera in. If "drops line up with" names a boss ability, its effects are the cost. |

## Commands

| Command | |
| --- | --- |
| `/fpsw` | open the report window |
| `/fpsw meter` | live FPS, Lua memory, garbage per second and "next GC in" estimate; right-click opens the report |
| `/fpsw start`, `/fpsw stop` | record manually (trash, a city, anything) |
| `/fpsw test` | 11 second self-test with fake lag |
| `/fpsw list` | list saved reports |
| `/fpsw drop <fps>` | a second averaging below this counts as a drop (default 20) |
| `/fpsw hitch <ms>` | a single frame this long counts as a hitch (default 150) |
| `/fpsw profile on/off` | time every addon's scripts during fights (default on) |
| `/fpsw gcguard on/off [MB]` | push Lua garbage collection out of fights (default off, 64 MB) |
| `/fpsw gcbench on/off` | time one full Lua GC right after each fight (default on) |
| `/fpsw trash on/off` | also keep non-boss fights without drops (fights with drops are always kept) |
| `/fpsw auto on/off` | open the report automatically after a fight with drops |
| `/fpsw chat on/off` | chat summary after fights |
| `/fpsw clear` | delete saved reports |
| `/fpsw status` | show settings |

## How it works

1.12 has no addon CPU usage API, so during a fight FpsWatch swaps every frame's `OnEvent` and `OnUpdate` for a small wrapper. The wrapper times the call with `debugprofilestop()` and reads Lua memory before and after. If memory went down during the call, a full garbage collection ran inside it. Frame time not covered by any script is graphics/engine time. After the fight the original scripts are put back.

Each script's addon comes from where its frame was created. FpsWatch hooks `CreateFrame` and reads the calling file's path. Frames defined in XML are matched by name and marked with `?`. Unnamed children of `WorldFrame` are the nameplates.

Things to know:

- Profiling costs a few microseconds per script call. The report prints the estimated overhead. If FPS is clearly better with `/fpsw profile off`, compare one pull each way.
- While profiling is on, Lua error messages from other addons show `!FpsWatch\Profiler.lua` in the stack. The error is in the addon below it.
- Ace2 addons share one event frame (AceEvent), so they show up together under the addon that loaded AceEvent first.
- Boss casts and yells are read from the combat log text, using the client's own message formats.
- If the client has no `debugprofilestop()`, per-addon timing is off. FPS, GC, events and the fight timeline still work.

## Development

`tests/` runs the addon inside a fake 1.12 client under a real Lua 5.0 interpreter. It simulates a boss fight with an addon hitch, a garbage-heavy addon, graphics-bound drops, nameplates and a boss kill, then runs the self-test, the UI and every slash command:

```
lua5.0 tests/run_test.lua          # normal client
lua5.0 tests/run_test.lua notimer  # client without debugprofilestop / RegisterAllEvents
```
