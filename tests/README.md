# Stracker Delta offline tests

They exercise the Lua application (the files in the root of the project and `modules\`, the
ones that get installed as `apps/lua/StrackerDelta`) **without starting the game**: the HTML
parsing, the lap model and the whole application scenario with `ac`, `ui` and `web` stubbed
out.

## Run

```
pip install lupa
cd tests
python run_tests.py
```

Exit code 0 means everything passed. The report is also written to `out/report.txt`.

## What is covered

| File | Covers |
|------|--------|
| `test_modules.lua` | `html`: parsing of `/lapstat` (lap list, servers), `/statistics` (track cars), `/lapdetails` (metadata + chart points). `lap`: building the lap profile, interpolation, CSV export. `stracker`: page URLs, pagination, server and track matching. `addresses`: normalisation, the comma separated list, bindings per AC server |
| `test_app.lua` | the whole application: address selection, server list, lap list, 3 scopes, lap pick, TARGET, delta, lap time fallback, unknown server, network error, recovery, pagination, local search, "always fastest", profile cache |
| `run_tests.py` | runs everything on **Lua 5.4** and **LuaJIT 2.1** and compares the CSV numerically with the reference in `reference/` |

Current count: 103 module checks and 129 application checks, each run on both runtimes.

## Fixtures

`fixtures/` holds saved pages of a stracker server. Driver names and server ids in them
are made up, so the project can be published without carrying anyone's data; the page
structure, the tables and the chart data are what a real response looks like.

* `lapstat_session.html` - `/lapstat?currservers=SRV1`
* `lapstat_track_car.html` - `/lapstat?currservers=SRV1&track=rmi_nelson_ledges&cars=ac_legends_gtc_corvette_63`
* `statistics_track.html` - `/statistics?tracks=rmi_nelson_ledges`
* `lapdetails_468323.html` - `/lapdetails?lapid=468323&cmpbits=0`

To take a fresh page from a server you use, point this at it:

```
python -c "import requests; open('fixtures/lapstat_session.html','w',encoding='utf-8').write(requests.get('<your address>/lapstat?currservers=<server id>').text)"
```

## Comparison reference

`reference\stracker_data.csv` - the reference profile. The profile built by the Lua code
has to match it (tolerances: position 1e-9, speed 1e-6, time 0.02 s).
