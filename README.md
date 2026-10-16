# Stracker Delta

Live lap delta against a reference lap from a stracker server.

The app talks to a stracker server itself: it pulls the lap list, downloads the lap you
pick and builds a position/speed/time profile out of it. While you drive, it compares your
current lap against that profile at the same point on the track and shows how much time
and how much speed you are up or down.

There is no address baked in: you configure the stracker servers you use in the app, see
[Addresses](#addresses).

Two windows: a small delta readout for the HUD, and a lap list window with the full
stracker table, search, auto refresh and diagnostics.

## Project layout

```
StrackerDelta\
  StrackerDelta.lua  manifest.ini  README.md      what the game reads
  modules\           web.lua  stracker.lua  html.lua  lap.lua  addresses.lua
  scripts\           pack.cmd / pack.ps1, install.cmd / install.ps1
  tests\             offline test suite (needs pip install lupa)
  dist\              packages built by pack (not part of the sources)
```

The root of the project is what Assetto Corsa reads; `modules\` holds the code behind it.
Everything else around them is tooling. Each module is named after its single job:

| Module | Job |
|--------|-----|
| `web.lua` | asynchronous HTTP, the only place that touches the network |
| `stracker.lua` | what the site is: page URLs, the paged lap list, server and track matching |
| `html.lua` | the three stracker pages as plain Lua tables |
| `lap.lua` | the lap model: profile, interpolation, delta formatting, CSV export |
| `addresses.lua` | the configured addresses and which one belongs to which AC server |

## Install

**Content Manager:** install the package from `dist\`. The archive contains the application
files under `apps/lua/StrackerDelta/`, which is where CM puts them.

**Scripts:** `scripts\install.cmd` copies the same files into an Assetto Corsa folder.

```
scripts\install.cmd                          asks for the game folder, then waits
scripts\install.cmd "<path to Assetto Corsa>"   silent, exit code 0 or 1
scripts\install.cmd "<path to Assetto Corsa>" -Backup   snapshots the current app first
```

The target is checked before anything is copied: a folder without `apps\lua` is refused,
because a half installed app is worse than none. Files the app writes at runtime
(`debug.log`, `cache_lap.csv`, `cache_index.txt`, `last_lap.csv`) are never touched.

Then enable **Stracker Delta** in Content Manager → *Custom* → *Apps*, or in game in
*Apps*. The app appears in the list as `Stracker Delta (lua)`.

> The folder name and the name of the main `.lua` file must match
> (`StrackerDelta/StrackerDelta.lua`). Otherwise Assetto Corsa silently creates empty
> windows with no content.
>
> Window names and sizes come from `manifest.ini` and are only read when the game starts,
> so restart Assetto Corsa after renaming or resizing anything there.

## First start

The app ships without a server address, so there is nothing to talk to until one is
configured. This is the one thing that has to be done by hand:

1. Open the lap list window, `Stracker Delta laps`, and open *Details* in its toolbar.
2. Type the address of your stracker server into `addresses`. Several addresses go into
   the same field, separated by commas.
3. Press `Refresh`.

Until an address is configured the status line says `no stracker address set`, and the app
opens *Details* by itself so the field is right there. After that it picks the right
address on its own and remembers the choice per AC server, see [Addresses](#addresses) for
what happens with more than one address.

## Pack

```
scripts\pack.cmd
```

Builds `dist\<NAME> v<VERSION>.zip` from `VERSION` and `NAME` in `manifest.ini`. Only the
files listed above go in: no logs, no caches, no tests. Entries are named relative to the
game folder with forward slashes, which is what Content Manager expects; the archive is
written through the .NET zip API rather than `Compress-Archive` for that reason.

## Tests

```
pip install lupa
cd tests
python run_tests.py
```

Exit code 0 means everything passed; the report also lands in `tests\out\report.txt`. The
suite runs `test_modules.lua` and `test_app.lua` under Lua 5.4 and LuaJIT 2.1 with `ac`,
`ui` and `web` stubbed out, against real stracker pages in `fixtures\`, and compares the
profile with `tests\reference\stracker_data.csv`. See `tests\README.md` for the details.

## The delta window

A small frameless window with two rows:

| Row | Left | Right |
|-----|------|-------|
| Labels | `TIME` + the reference lap time right after it | `SPEED` |
| Values | time delta, e.g. `+0.35` / `-1.24` | speed delta, e.g. `+12.4` / `-3.1` |

* The reference lap time next to `TIME` is the target you are driving against. It turns
  red when the reference lap comes from a different track (layout included), so a wrong
  comparison is never silent.
* Values are green when you are faster, red when slower, grey when there is nothing to
  compare against yet.
* The icon button in the top right corner opens and closes the lap list window.
* The window has no title bar, so it is dragged by clicking anywhere in it (the list
  button and the resize corner are excluded). Its size follows the content; the width is
  computed from the text so the readout never jumps around while you resize it.

Text is rendered with the vector (DWrite) font at an exact pixel size, configurable in
*Details* (12 to 64 px).

## Addresses

The app has no address built in. You tell it which stracker servers to use, in the
*Details* block of the lap list window, and it picks the right one on its own.

```
addresses           [ https://one.example, https://two.example ]
```

One field is the whole list, comma separated. To add an address, type it after a comma;
to remove one, delete it. There is nothing to press: the list is read as you type, the
scheme is added when you leave it out, a trailing slash is dropped, and whatever does not
look like an address is listed under the field as `skipped: …` instead of breaking the
rest. An address can be a plain host, a host with a path, or `localhost` with a port.

When the list is empty the app says `no stracker address set` and opens *Details* by
itself, because there is no other way in.

### Which address is used

Per AC server, so a server you race on and a server you hotlap on can live on different
stracker instances:

| Situation | What happens |
|-----------|--------------|
| an address is remembered for this AC server | it is used, no guessing (`remembered`) |
| exactly one address is configured | it is used (`the only one configured`) |
| several addresses, none remembered | each is asked for its server list in turn, the first one that knows this AC server wins (`matches "<id>"`) |
| nothing knows this AC server | the first address of the list is used (`no match, first in the list`) |

Whatever was chosen is remembered, including the fallback, so the probing does not run
again on every start. The reason is shown next to the choice in *Details*: picking another
entry there binds it for the current AC server and takes it into use at once, with no
button to press. Deleting an address from the field drops its bindings with it.

Server lists and track lists are cached per address, so two instances never mix.

The field takes the site, not a page of it. A link copied from the browser, such
as `https://stracker.example.com/lapstat?currservers=SRV1`, is refused and named
as what it is, under the field, with the rest of the list still working:

```
skipped: https://stracker.example.com/lapstat?currservers=SRV1 (a page of the site, not its address)
```

Only those three page names are refused. A stracker that lives in a folder, such
as `https://example.com/stracker`, is a valid address and stays valid.

## The lap list window

Toolbar, left to right:

| Control | What it does |
|---------|--------------|
| List dropdown | what the table shows (see below) |
| `Refresh` | request the list again |
| `Auto` | keep refreshing on an interval |
| Interval | `30s`, `60s`, `2m`, `5m` — used only while `Auto` is on |
| `Always fastest` | always take the fastest lap of the list |
| `?` | field hints on and off; off until you turn them on, remembered afterwards |
| `▸ Details` / `▾ Details` | open or close the diagnostics block |

Every control also explains itself on hover while the hints are on: what to type
into it, what the switch changes, which of several things a list is. They are off
by default because a hint that is always there stops being read; the button that
turns them on explains itself even while they are off.

Below the toolbar:

* **Filter** — local search over the loaded list. Every word of the query has to be found
  in the driver name or in the car, so `rowan gt40` finds `Rowan Keene` in `..._gt40_mk4`.
  Matching happens in memory, nothing extra is requested.
* **Status line** — a coloured dot and one message: what is loading (`loading page 2/4`),
  how many laps arrived, how many rows the filter left, or what went wrong. The dot is
  yellow while something is in progress or needs attention, red only for errors.
* **Selected** — the reference lap currently loaded: position, lap time, driver. If that
  lap is not part of the currently loaded list (for example after the list was filtered
  out or the server changed), it says so and the delta still counts against it.
* **Table** — the stracker columns exactly as the site returns them:
  `#`, `Time`, `Gap`, `Driver`, `Car`, `Grip`, `Amb/Track`, `vMax`, `Date`.
  Clicking a row makes that lap the reference.

Table styling only: alternating row background, hover highlight, a blue tint plus a left
bar on the selected row, a yellow tint on the row that is currently downloading. Column
widths are measured from the actual content once per list and recalculated when the list
or the window width changes. If the window is too narrow, `Driver` and `Car` shrink first
(they are the longest) down to their header width.

### List sources

The dropdown is a single choice; it covers both *what* to show and *which server* to ask:

| Entry | Shows | Request |
|-------|-------|---------|
| `Session - auto` | fastest lap of every driver in the last session of the server AC is on | `/lapstat?currservers=<srv>` |
| `This track` | every car that has driven the current track, all pages | `/lapstat?track=...` → `/lapstat?track=...&cars=<every car the form offers>` |
| `Track + car` | only the current car on the current track | `/lapstat?currservers=<srv>&track=<track>&cars=<car>` |
| `Session - <id>` | the last session of one specific stracker server | `/lapstat?currservers=<id>` |

All pages of a list are fetched one after another and merged into a single list, so there
are no page buttons anywhere: the table shows every lap at once and the status reports
the progress (`loading page 2/4`). The last requested URL is shown in *Details*.

`This track` really means every car. A lapstat page filtered by track carries the
complete car list in its form, so the app asks for that page first and then repeats the
query with all of those cars, fetching every page. That car list makes a url of about
9 KB, and the game refuses to send a url that long, so the query goes out as a `POST` and
the car list travels in the body instead of in the address: the url stays the bare name of
the page, and every car goes out in one request. The site reads a form body the same way
it reads a query string, so the answer is the same list the url would have given. The
result is a large track coming to a few hundred laps, and the number in the status is the
number of distinct laps, since pages of one query can repeat a lap and a repeated lap
is listed once.

### How the server and the track are resolved

* **Server** — `ac.getServerName()` is matched against the server list the address in use
  reports: exact match first, then the id inside the name, then a loose match on the
  "signature" of the name (`_SRX1_Race …` → `SRV1`, signature `S1`, that is the first
  letter plus the digits). If nothing matches, the scope switches to `This track` (that is
  the only thing that works offline, hotlapping) and the status says so once. A server
  picked by hand is remembered and reported as `picked manually` in *Details*.
* **Track** — `ac.getTrackFullID('-')` returns something like
  `tmm_lausitzring-layout_oval`. If stracker does not know that id, variants are tried:
  with the layout, without it, by base name. The layout is never dropped first, because
  stracker tells `tmm_lausitzring` and `tmm_lausitzring-layout_oval` apart.

### Picking the reference lap

* On start the app loads `Session - auto`, then picks a lap by itself: the one loaded last
  time (remembered across restarts), or the fastest row of the list.
* `Always fastest` takes the first row of every fresh list and reloads it, even when it is
  already the reference. Untick it to stop that.
* Clicking a row by hand switches `Always fastest` off, otherwise the next auto refresh
  would silently roll your choice back.
* Reloading the same lap by hand does nothing: the lap is already the reference and
  re-fetching it would only blink the indicator.

### Cache

The last reference lap profile is kept in two files next to the app:

| File | Content |
|------|---------|
| `cache_index.txt` | list key (scope, server, track, car) and lap metadata |
| `cache_lap.csv` | the profile itself, at higher precision than the exported CSV |

The cache is valid only for the same list key and the same lap. When it matches, the
profile is shown from disk immediately while the fresh one is still downloading — the
list itself is always requested from the network, cache or not, so the table is never
stale.

### Details block

Collapsed by default, opens by itself when something fails (an error has to be visible
without hunting for it). What can be changed is on top, what it produced is below a thin
line.

| Row | Kind | Meaning |
|-----|------|---------|
| `delta text size` | input | `-` / `+` to change the delta text size in pixels |
| `addresses` | input | the list, one comma separated field, as wide as the window |
| `this server uses` | input | which of them this AC server uses, with the reason next to it |
| `ac server` | output | server name as the game reports it, or that it did not report one |
| `stracker server` | output | id in use plus how it was detected, only in the Session scope |
| `asking for` | output | what is being asked for, in words: a session, every car on a track, or one car |
| `request` | output | the last query in words, with the page count when the site paginates |
| `updated` | output | time of the last successful list load |
| `reference lap` | output | lap id, number of profile points, note when it is not in the list |

A request that failed shows the query it died on, with its length, because that is the
one case where the query itself is the answer. The raw path of a successful query stays
in `debug.log`: it repeats itself per page and says nothing at a glance.

## Files shipped

| File | Purpose |
|------|---------|
| `manifest.ini` | window names, sizes, flags |
| `StrackerDelta.lua` | windows, state, whole interaction |
| `modules\web.lua` | asynchronous HTTP on top of `web.get` |
| `modules\stracker.lua` | page URLs, the paged lap list, server and track matching |
| `modules\html.lua` | `/lapstat`, `/statistics` and `/lapdetails` as Lua tables |
| `modules\lap.lua` | lap model: profile, interpolation, delta formatting, CSV export |
| `modules\addresses.lua` | the configured addresses and which one belongs to which AC server |
| `README.md` | this file |

Created at runtime, next to the app:

| File | Purpose |
|------|---------|
| `debug.log` | what happened: server detection, requests, cache hits, render errors |
| `last_lap.csv` | full profile of the last downloaded lap, easy to open and compare |
| `cache_index.txt`, `cache_lap.csv` | cache of the reference lap (see above) |

Settings are stored by the game in
`Documents/Assetto Corsa/cfg/extension/state/lua/app/StrackerDelta.ini`; they survive
reinstalls of the app files.

## Logs

`debug.log` next to the app, and the game log
`Documents/Assetto Corsa/logs/custom_shaders_patch.log` — look for `[Stracker Delta]`.
Draw errors inside a window are reported as `window laps: ERROR ...`; the draw loop
swallows them, so the log is the only place they show up.

## Notes and limitations

* Lap time is taken from `ac.StateCar.lapTimeMs`, the exact value measured at the
  start/finish line; if it is not available, a fallback counter on the line crossing is
  used.
* The time delta is compared at the same track position as the reference; interpolation is
  linear between reference points.
* If nobody drove the current car on the current track, the list is empty — switch the
  dropdown to `Session - auto`.
* Pages of the list are fetched sequentially, so a large list takes a moment; the status
  line reports which page is being loaded and the dot stays yellow meanwhile.
