#!/usr/bin/env python3
"""Engine test driver.

CmdAtom only fires when nvim has a UI, so the suite runs in an embedded
nvim with a UI attached over RPC. The steps and all assertions live in
tests/engine_steps.lua; this driver only feeds input and reports.

The step protocol exists because RPC nvim_input is processed only when
no Lua chunk (exec_lua / vim.schedule / vim.wait / coroutine) is on the
stack. Every exec_lua call here is a short request that returns
immediately, and all waiting happens driver-side.

Requires: pynvim (pip install pynvim).
"""
import sys
import time
from pathlib import Path

import pynvim

ROOT = Path(__file__).resolve().parent.parent
TIMEOUT = 10  # seconds per step


def run_step(nvim, i):
    """Execute one step; returns (name, failure_messages)."""
    name = nvim.exec_lua(f"return _G.encore_steps[{i}].name")
    if nvim.exec_lua(f"return _G.encore_steps[{i}].pre ~= nil"):
        nvim.exec_lua(f"_G.encore_steps[{i}].pre()")

    for keys in nvim.exec_lua(f"return _G.encore_steps[{i}].inputs or {{}}"):
        nvim.input(keys)

    sleep_s = nvim.exec_lua(f"return _G.encore_steps[{i}].sleep")
    if sleep_s:
        time.sleep(sleep_s)
    elif nvim.exec_lua(f"return _G.encore_steps[{i}].wait ~= nil"):
        deadline = time.time() + TIMEOUT
        while not nvim.exec_lua(f"return _G.encore_steps[{i}].wait()"):
            if time.time() > deadline:
                return name, ["timed out waiting"]
            time.sleep(0.01)
    return name, nvim.exec_lua(f"return _G.encore_steps[{i}].check()")


def main() -> int:
    nvim = pynvim.attach(
        "child",
        argv=["nvim", "--embed", "--clean", "--cmd", f"set runtimepath+={ROOT}"],
    )
    failures = 0
    try:
        nvim.request("nvim_ui_attach", 100, 40, {"ext_linegrid": True, "rgb": False})
        nvim.exec_lua('dofile("tests/engine_steps.lua")')

        skip = nvim.exec_lua("return _G.encore_skip")
        if skip:
            print("SKIP:", skip)
            return 0

        nsteps = nvim.exec_lua("return #_G.encore_steps")
        for i in range(1, nsteps + 1):
            name, msgs = run_step(nvim, i)
            if msgs:
                for m in msgs:
                    print(f"FAIL: {name}: {m}")
                    failures += 1
            else:
                print(f"ok: {name}")

        print("==", "ALL PASS" if failures == 0 else f"FAILURES: {failures}")
        return 1 if failures else 0
    finally:
        try:
            nvim.exec_lua("vim.cmd('cquit 0')")
        except Exception:
            pass
        try:
            nvim.close()
        except Exception:
            pass


if __name__ == "__main__":
    sys.exit(main())
