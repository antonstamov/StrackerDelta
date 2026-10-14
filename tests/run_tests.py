#!/usr/bin/env python3
"""Offline test run for Stracker Delta through lupa (Lua 5.4 and LuaJIT 2.1).

Run:
    python run_tests.py

The script runs test_modules.lua and test_app.lua against real stracker pages
from fixtures/, then compares the CSV produced by the Lua code with the reference
in reference/stracker_data.csv.

Everything is resolved relative to this file, so the project can live anywhere.
"""

import os
import sys

try:  # so that the messages do not turn into mush in the Windows console
    sys.stdout.reconfigure(encoding="utf-8", errors="replace", line_buffering=True)
except Exception:  # pragma: no cover
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
# the application sources live in the root of the project, one level up
APP_DIR = os.path.dirname(HERE)
FIXTURES = os.path.join(HERE, "fixtures")
OUT_DIR = os.path.join(HERE, "out")
REFERENCE_CSV = os.path.join(HERE, "reference", "stracker_data.csv")


def run_with(module_name: str) -> int:
    try:
        module = __import__(module_name, fromlist=["LuaRuntime"])
    except ImportError as exc:  # pragma: no cover - depends on the environment
        print(f"  skipped: {module_name} is not available ({exc})")
        return -1

    LuaRuntime = module.LuaRuntime
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().package.path = (
        APP_DIR.replace("\\", "/") + "/?.lua;" + os.path.join(HERE, "?.lua")
    )
    print(f"\n########## {module_name} ##########")
    script = open(os.path.join(HERE, "test_modules.lua"), "r", encoding="utf-8").read()
    chunk = lua.eval("function(s, ...) return assert(load(s))(...) end")
    try:
        chunk(script, FIXTURES)
    except Exception as exc:  # noqa: BLE001 - lupa raises LuaError
        print(f"  EXECUTION ERROR: {exc}")
        return 1
    return 0


REPORT_PATH = os.path.join(OUT_DIR, "report.txt")
# the report is opened at import time, so out/ has to exist right here
os.makedirs(OUT_DIR, exist_ok=True)
_report = open(REPORT_PATH, "w", encoding="utf-8")


def say(*args: object) -> None:
    """print with an explicit flush plus a copy in out/report.txt.

    After the lupa runs Python output sometimes gets lost to buffers,
    so the report text is written to a file as well.
    """
    line = " ".join(str(value) for value in args)
    print(line, flush=True)
    _report.write(line + "\n")
    _report.flush()


def compare_csv() -> int:
    lua_csv = os.path.join(OUT_DIR, "lua_data.csv")
    if not os.path.exists(lua_csv):
        say("CSV from Lua not found - comparison skipped")
        return 1
    if not os.path.exists(REFERENCE_CSV):
        say(f"Reference CSV not found: {REFERENCE_CSV}")
        return 1

    def load(path):
        rows = []
        with open(path, "r", encoding="utf-8") as handle:
            header = handle.readline().strip().split(",")
            assert header == ["Position", "Speed", "Time"], header
            for line in handle:
                line = line.strip()
                if line:
                    rows.append([float(value) for value in line.split(",")])
        return rows

    lua_rows = load(lua_csv)
    ref_rows = load(REFERENCE_CSV)

    say("\n########## CSV comparison (Lua vs Python) ##########")
    say(f"  rows: lua={len(lua_rows)} python={len(ref_rows)}")
    if len(lua_rows) != len(ref_rows):
        say("  FAIL: different number of points")
        return 1

    max_pos = max_speed = max_time = 0.0
    for lua_row, ref_row in zip(lua_rows, ref_rows):
        max_pos = max(max_pos, abs(lua_row[0] - ref_row[0]))
        max_speed = max(max_speed, abs(lua_row[1] - ref_row[1]))
        max_time = max(max_time, abs(lua_row[2] - ref_row[2]))

    say(f"  max |Δposition| = {max_pos:.10f}")
    say(f"  max |Δspeed|    = {max_speed:.6f} km/h")
    say(f"  max |Δtime|     = {max_time:.6f} s")

    if max_pos > 1e-9 or max_speed > 1e-6 or max_time > 0.02:
        say("  FAIL: difference above the tolerance")
        return 1
    say("  ok: the profiles match")
    return 0


def run_app_test(runtime_module: str) -> int:
    """Runs the whole application with ac/ui/web stubbed out."""
    module = __import__(runtime_module, fromlist=["LuaRuntime"])
    lua = module.LuaRuntime(unpack_returned_tuples=True)
    lua.globals().package.path = APP_DIR.replace("\\", "/") + "/?.lua"
    script = open(os.path.join(HERE, "test_app.lua"), "r", encoding="utf-8").read()
    chunk = lua.eval("function(s, ...) return assert(load(s))(...) end")
    app_lua = APP_DIR.replace("\\", "/") + "/StrackerDelta.lua"
    say(f"\n########## application: {runtime_module} ##########")
    try:
        chunk(script, app_lua, FIXTURES.replace("\\", "/"))
    except Exception as exc:  # noqa: BLE001
        say(f"  EXECUTION ERROR: {exc}")
        return 1
    return 0


def main() -> int:
    os.makedirs(OUT_DIR, exist_ok=True)
    result = 0
    for module_name in ("lupa.lua54", "lupa.luajit21"):
        code = run_with(module_name)
        if code > 0:
            result = code
        code = run_app_test(module_name)
        if code > 0:
            result = code
    result = max(result, compare_csv())
    say("\nResult:", "OK" if result == 0 else "FAILED")
    return result


if __name__ == "__main__":
    sys.exit(main())
