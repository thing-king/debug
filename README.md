# Nim Time‑Travel Debugger

A **trace‑based time‑travel debugger** for Nim. It records execution at Nim‑level statement boundaries and lets you move **forward and backward through recorded program history** with a fast, full‑screen TUI.

---

## Features

* **Time Navigation** – Step forward and backward through recorded execution
* **Statement‑Level Tracing** – Execution recorded at Nim statement boundaries (best‑effort)
* **Tracked Locals** – Automatically tracks locals declared inside `debug:` regions
* **Variable Watches** – Track arbitrary expressions across all steps
* **Diff View** – See exactly what changed since the previous step
* **Call Depth Tracking** – Visualize scope entry/exit and nesting depth
* **Breakpoints** – Jump forward or backward to matching file:line
* **Search** – Find steps by code, variable name, or value
* **Full‑Screen TUI** – Source‑aligned, keyboard‑driven interface
* **Single Binary** – No services, no background daemons

---

![image of TUI](https://i.ibb.co/8DjRTMMz/Capture.png)

## Quick Start

### 1. Instrument Code

```nim
import debug

debug:
  var x = 10
  let y = 20
  x = x + y

  if x > 15:
    echo "x is large: ", x

  for i in 1..3:
    echo "Iteration: ", i
```

### 2. Run Normally

```bash
nim c -r myprogram.nim
```

This produces a local trace file:

```
.debug.trace
```

### 3. Inspect the Trace

```bash
debug .debug.trace
```

## Controls

| Key         | Action                         |
| ----------- | ------------------------------ |
| Left / A    | Step backward                  |
| Right / L   | Step forward                   |
| PgUp / PgDn | Jump ±10 steps                 |
| Home / End  | First / last step              |
| G           | Goto step number               |
| B           | Set breakpoint (file:line)     |
| C           | Continue forward to breakpoint |
| R           | Reverse to previous breakpoint |
| W           | Add/remove watch               |
| D           | Show diff from previous step   |
| F or /      | Search                         |
| N / P       | Next / previous result         |
| I           | Trace info                     |
| Q           | Quit                           |

---

## Variable Tracking Model

### Automatic Tracking

The debugger automatically tracks:

* `var` and `let` declared inside `debug:` blocks
* loop variables (`for i in ...`)
* procedure parameters (inside instrumented scopes)

Tracking is **best‑effort** and scoped to code rewritten by the macro.

### Watches

Use watches for anything else:

```nim
debug:
  var x = 10
  watch x
  watch x * 2
  x += 5
```

Watched expressions are evaluated once per step and recorded.

---

## Diff View

Each step stores **only changes**, not full snapshots.

Diff markers:

* `+name` – Variable entered scope
* `~name` – Value changed
* `-name` – Variable left scope

This keeps traces smaller and highlights what actually matters.

---

## Skipping Instrumentation

Use `noDebug:` to avoid tracing hot paths:

```nim
debug:
  var sum = 0

  noDebug:
    for i in 1..1_000_000:
      sum += i

  echo sum
```

---

## Trace Format

Traces use JSON Lines (one event per line):

```json
{"step":12,"file":"example.nim","line":15,"col":2,"desc":"echo(Iteration, i)","depth":1,"scope":"<module>","changes":{"i":"2"}}
```

Fields are designed for **incremental reconstruction**, not raw replay.

---

## Performance Notes

* Tracing adds overhead proportional to executed statements
* Large traces are expected; use search, breakpoints, and diffs
* Intended for debugging and exploration, not production builds
* Use `noDebug:` aggressively in tight loops
