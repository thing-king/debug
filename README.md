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

---

## CLI Commands

The debug package includes CLI commands for managing instrumentation:

### Basic Commands

```bash
# Add debug: wrapper to a file
debug add myfile.nim

# Add debug: wrapper to all .nim files recursively
debug add

# Remove debug: wrapper from a file
debug remove myfile.nim

# Remove debug: wrapper from all .nim files recursively
debug remove
```

### Raw Instrumentation (Advanced)

For cases where the `debug:` macro approach doesn't work (e.g., debugging macros, compile-time code, or when you need to see the expanded instrumentation):

```bash
# Expand debug instrumentation inline (creates .predebug backup)
debug addRaw myfile.nim

# Expand recursively on all .nim files
debug addRaw

# Restore original from backup
debug removeRaw myfile.nim

# Restore recursively on all .nim files
debug removeRaw
```

**Use cases for `addRaw`:**

1. **Debugging macros** – Macros get echo-based logging at compile time
2. **Understanding instrumentation** – See exactly what code gets generated
3. **Files that can't use the macro** – When `debug:` block syntax isn't suitable
4. **Troubleshooting the debug package** – Debug the debugger itself

**Important notes:**

* `addRaw` creates a `.predebug` backup file before transforming
* `removeRaw` requires this backup to restore the original
* The raw instrumentation is verbose – use only when needed
* For normal debugging, prefer the `debug:` macro approach

**Example raw output:**

```nim
# Original
proc greet(name: string) =
  echo "Hello, " & name

# After addRaw (compile with -d:debugVars for variable capture)
proc greet(name: string) =
  enterScope("greet")
  defer:
    exitScope()
  when defined(debugVars):
    debugLog("file.nim", 2, 2, "echo \"Hello, \" & name", toVarList([("name", safeRepr(name))]))
  else:
    debugLog("file.nim", 2, 2, "echo \"Hello, \" & name")
  echo "Hello, " & name
```
