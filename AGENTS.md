# encore.nvim — project notes for coding agents

## Embedded-nvim test scripts: known hang and safe probe pattern

The engine test suite and ad-hoc CmdAtom experiments run an embedded
nvim with a UI attached (CmdAtom does not fire headless), driven by
pynvim over RPC. Some input patterns **deadlock** — verified on nvim
0.13.0-dev (nightly, CmdAtom-era) with pynvim:

### The hang: completing a pending-char command via a separate `nvim_input`

When a UI is attached (`nvim_ui_attach`), feeding the key that completes
a pending-char command as its **own** `nvim_input` call blocks forever:

- `nvim.input("r")` then `nvim.input("s")` → the second call hangs
- `nvim.input("f")` then `nvim.input("x")` → the second call hangs
- same for `t` + char; happens with `ext_linegrid` **and** with plain
  `rgb` UI options
- without a UI attached, the same split inputs work fine

Feeding the **whole sequence in one call** never hangs:

- `nvim.input("rs")`, `nvim.input("fx")`, `nvim.input("diw")`,
  `nvim.input("iabc<Esc>")`, `nvim.input("3j")` — all fine
- single self-contained keys (`j`, `p`, `x`, `u`, `<C-r>`, `<F5>`) — fine

This is the known upstream issue family: neovim/neovim#6159 ("RPC hangs
if nvim is waiting for input") and #13626 ("nvim_command hangs when in
'f' mode"). While nvim sits in the pending-input loop, the RPC response
is never sent.

**Rule: never split a pending-char / pending-operator sequence across
separate `nvim_input` calls when a UI is attached. Always feed the
complete key sequence in one call.**

### Probe-script hygiene (a hang must not hang the harness)

After a hang, the pynvim session is desynchronized — any further RPC
(including `cquit` cleanup) blocks again. Probe scripts must:

1. wrap **every** blocking call in a `signal.alarm` timeout;
2. on timeout, print the failing step and `os._exit(0)` immediately
   (no cleanup RPC — the child dies when the pipes close);
3. run with `python3 -u` so prints are unbuffered and the step that hung
   is visible in the tool output;
4. expect `EOFError` from the final `cquit` (nvim exits before replying).

Template:

```python
import pynvim, time, signal, os

def call(nvim, fn, tag):
    signal.signal(signal.SIGALRM, lambda *_: (print(f"HANG at {tag}", flush=True), os._exit(0)))
    signal.alarm(6)
    try:
        return fn()
    finally:
        signal.alarm(0)

nvim = pynvim.attach("child", argv=["nvim", "--embed", "--clean", "--cmd", "set runtimepath+=."])
call(nvim, lambda: nvim.request("nvim_ui_attach", 100, 40, {"ext_linegrid": True, "rgb": False}), "ui_attach")
# feed complete sequences only, one nvim.input per sequence
```

## Established CmdAtom facts (do not rediscover)

- CmdAtom fires only with a UI attached (`--embed` + `nvim_ui_attach`);
  headless nvim does not fire it.
- In embedded/RPC contexts `nvim_input` triggers CmdAtom while
  `nvim_feedkeys` does not; in interactive sessions feedkeys DOES emit
  CmdAtom (user-verified). Engine tests drive input via run.py's
  `nvim.input`; replay suppresses its reproductions via
  `engine.suppress` (match-based on replay keys + type, never blind
  counting, so unrelated actions are never eaten).
- RPC `nvim_input` is only processed when **no Lua chunk** is on the
  stack: input fed while any exec_lua / vim.schedule callback /
  coroutine / vim.wait is running stays queued until that chunk
  returns. Engine tests therefore use the step protocol: short
  exec_lua requests that return immediately, with all waiting done
  driver-side (this also rules out plenary.busted's coroutine runner
  for CmdAtom tests).
- uv timer callbacks run in a fast context where `vim.fn.*` is forbidden
  (E5560): wrap in `vim.schedule`.
- Persistence stores `keys`/`lhs`/`text`/`cmdarg` base64-encoded
  (vim.json does not escape invalid UTF-8 bytes; raw K_SPECIAL bytes
  would corrupt the file for external tools).
- Float `width`/`height` is the content area; the border adds one cell
  per side — panel spacing must be `h + 2`.
