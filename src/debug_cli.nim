## Debug CLI - Interactive Time-Travel Debugger TUI
##
## A full-screen terminal debugger for stepping through execution traces.
## Navigate with arrow keys/WASD, view source code with highlighted lines.

import std/[terminal, strutils, tables, os, strformat, algorithm, sequtils]
import pkg/colors/highlighter
import ./debug_log

type
  Panel = enum
    pSource, pVars, pWatch, pHelp

  ViewMode = enum
    vmNormal, vmSearch, vmJump, vmBreakpoint, vmHelp, vmWatch, vmInspect, vmTimeline

  DebugTUI = object
    entries: seq[DebugEntry]
    pos: int
    sourceCache: Table[string, seq[string]]
    breakpoints: seq[tuple[file: string, line: int]]
    watched: seq[string]

    # UI state
    mode: ViewMode
    inputBuffer: string
    message: string
    messageIsError: bool
    sourceScroll: int
    varsScroll: int
    selectedPanel: Panel

    # Screen dimensions
    width, height: int

    # Search results
    searchResults: seq[int]
    searchIdx: int

const
  HEADER_HEIGHT = 2
  FOOTER_HEIGHT = 3
  VARS_PANEL_WIDTH = 35
  MIN_SOURCE_WIDTH = 40

# ─────────────────────────────────────────────────────────────────────────────
# Terminal Helpers
# ─────────────────────────────────────────────────────────────────────────────

proc clearScreen() =
  stdout.write("\e[2J\e[H")

proc moveTo(x, y: int) =
  stdout.setCursorPos(x, y)

proc clearLine() =
  stdout.write("\e[2K")

proc hideCursor() =
  stdout.write("\e[?25l")

proc showCursor() =
  stdout.write("\e[?25h")

proc writeAt(x, y: int, s: string) =
  moveTo(x, y)
  stdout.write(s)

proc writeStyled(s: string, fg: ForegroundColor = fgDefault,
                 bg: BackgroundColor = bgDefault, style: set[Style] = {}) =
  stdout.setForegroundColor(fg)
  stdout.setBackgroundColor(bg)
  if styleBright in style: stdout.write("\e[1m")
  if styleDim in style: stdout.write("\e[2m")
  if styleReverse in style: stdout.write("\e[7m")
  stdout.write(s)
  stdout.resetAttributes()

proc boxChar(c: string): string = c

# ─────────────────────────────────────────────────────────────────────────────
# Data Access
# ─────────────────────────────────────────────────────────────────────────────

proc current(tui: DebugTUI): DebugEntry =
  if tui.pos >= 0 and tui.pos < tui.entries.len:
    return tui.entries[tui.pos]
  return DebugEntry()

proc loadSource(tui: var DebugTUI, path: string): seq[string] =
  if path.len == 0:
    return @[]
  if path in tui.sourceCache:
    return tui.sourceCache[path]
  result = @[]
  if fileExists(path):
    for line in lines(path):
      result.add(line)
    tui.sourceCache[path] = result

proc getChangedVars(tui: DebugTUI): seq[string] =
  result = @[]
  if tui.pos == 0:
    return
  let curr = tui.current()
  let prev = tui.entries[tui.pos - 1]
  for name, val in curr.vars.pairs:
    if name notin prev.vars or prev.vars[name] != val:
      result.add(name)

proc getWatchHistory(tui: DebugTUI, varName: string): seq[tuple[step: int, val: string]] =
  result = @[]
  var lastVal = ""
  for entry in tui.entries:
    if varName in entry.vars:
      let val = entry.vars[varName]
      if val != lastVal:
        result.add((entry.step, val))
        lastVal = val

# ─────────────────────────────────────────────────────────────────────────────
# Drawing
# ─────────────────────────────────────────────────────────────────────────────

proc drawHeader(tui: DebugTUI) =
  let entry = tui.current()
  let total = tui.entries.len

  moveTo(0, 0)
  stdout.setBackgroundColor(bgBlue)
  stdout.setForegroundColor(fgWhite)
  stdout.write(" ".repeat(tui.width))

  moveTo(0, 0)
  let title = &" TIME-TRAVEL DEBUGGER "
  stdout.write(title)

  let stepInfo = &" Step {tui.pos}/{total - 1} "
  moveTo(tui.width - stepInfo.len, 0)
  stdout.write(stepInfo)

  # Second line: file info
  moveTo(0, 1)
  stdout.setBackgroundColor(bgCyan)
  stdout.setForegroundColor(fgBlack)
  stdout.write(" ".repeat(tui.width))

  moveTo(0, 1)
  var fileInfo = entry.file
  if fileInfo.len > 0:
    fileInfo = fileInfo.splitFile().name & fileInfo.splitFile().ext
  else:
    fileInfo = "<unknown>"
  let locInfo = &" {fileInfo}:{entry.line} "
  stdout.write(locInfo)

  if entry.scope != "<module>":
    stdout.write(&"in {entry.scope} ")

  if entry.depth > 0:
    stdout.write(&"[depth:{entry.depth}] ")

  stdout.resetAttributes()

proc drawFooter(tui: DebugTUI) =
  let y = tui.height - FOOTER_HEIGHT

  # Key hints line
  moveTo(0, y)
  stdout.setBackgroundColor(bgBlue)
  stdout.setForegroundColor(fgWhite)
  stdout.write(" ".repeat(tui.width))
  moveTo(0, y)

  case tui.mode
  of vmNormal:
    let hints = " [</>]Step [G]oto [F]ind [W]atch [B]reak [T]ime [V]iew [D]iff [H]elp [Q]uit "
    stdout.write(hints)
  of vmSearch:
    stdout.write(" Type search pattern, Enter to search, Esc to cancel ")
  of vmJump:
    stdout.write(" Type step number, Enter to jump, Esc to cancel ")
  of vmBreakpoint:
    stdout.write(" Type file:line, Enter to set, [L]ist, [C]lear all, Esc to cancel ")
  of vmWatch:
    stdout.write(" Type variable name to watch, Enter to add, [L]ist, [C]lear all, Esc cancel ")
  of vmInspect:
    stdout.write(" Press any key to close ")
  of vmTimeline:
    stdout.write(" [</>] Navigate  [Enter] Jump to step  [Esc] Close ")
  of vmHelp:
    stdout.write(" Press any key to close help ")

  # Input/message line
  moveTo(0, y + 1)
  stdout.resetAttributes()
  clearLine()

  case tui.mode
  of vmSearch:
    writeStyled("Search: ", fgYellow)
    stdout.write(tui.inputBuffer)
    stdout.write("_")
  of vmJump:
    writeStyled("Jump to step: ", fgYellow)
    stdout.write(tui.inputBuffer)
    stdout.write("_")
  of vmBreakpoint:
    writeStyled("Breakpoint: ", fgYellow)
    stdout.write(tui.inputBuffer)
    stdout.write("_")
  of vmWatch:
    writeStyled("Watch var: ", fgYellow)
    stdout.write(tui.inputBuffer)
    stdout.write("_")
  of vmInspect, vmTimeline, vmHelp, vmNormal:
    if tui.message.len > 0:
      if tui.messageIsError:
        writeStyled(tui.message, fgRed)
      else:
        writeStyled(tui.message, fgGreen)

  # Statement description line
  moveTo(0, y + 2)
  stdout.setBackgroundColor(bgDefault)
  stdout.setForegroundColor(fgCyan)
  clearLine()
  let desc = tui.current().desc
  let maxLen = tui.width - 4
  if desc.len > maxLen:
    stdout.write("  " & desc[0..<maxLen-3] & "...")
  else:
    stdout.write("  " & desc)
  stdout.resetAttributes()

proc drawSourcePanel(tui: var DebugTUI) =
  let entry = tui.current()
  let sourceWidth = tui.width - VARS_PANEL_WIDTH - 1
  let sourceHeight = tui.height - HEADER_HEIGHT - FOOTER_HEIGHT
  let startY = HEADER_HEIGHT

  let source = tui.loadSource(entry.file)

  # Calculate scroll to keep current line visible
  let visibleLines = sourceHeight
  let currentLine = entry.line - 1  # 0-indexed

  var scroll = tui.sourceScroll
  if source.len > 0 and entry.line > 0:
    if currentLine < scroll:
      scroll = max(0, currentLine - 2)
    elif currentLine >= scroll + visibleLines:
      scroll = currentLine - visibleLines + 3
  tui.sourceScroll = scroll

  # Draw source lines
  for i in 0..<sourceHeight:
    let lineIdx = scroll + i
    let y = startY + i
    moveTo(0, y)
    clearLine()

    if lineIdx < source.len:
      let lineNum = lineIdx + 1
      let isCurrentLine = lineNum == entry.line
      let isBreakpoint = tui.breakpoints.anyIt(it.file == entry.file and it.line == lineNum)

      # Line number gutter
      let gutter = align($lineNum, 4)
      if isBreakpoint:
        writeStyled(" * ", fgRed, bgDefault, {styleBright})
      else:
        stdout.write("   ")

      if isCurrentLine:
        writeStyled(gutter, fgBlack, bgYellow, {styleBright})
        writeStyled(" > ", fgBlack, bgYellow, {styleBright})
      else:
        writeStyled(gutter, fgWhite, bgDefault, {styleDim})
        stdout.write("   ")

      # Source line
      var line = source[lineIdx]
      let maxLineLen = sourceWidth - 10
      if line.len > maxLineLen:
        line = line[0..<maxLineLen-3] & "..."

      if isCurrentLine:
        writeStyled(line, fgBlack, bgYellow)
        # Fill rest of line with highlight
        let remaining = sourceWidth - 10 - line.len
        if remaining > 0:
          writeStyled(" ".repeat(remaining), fgBlack, bgYellow)
      else:
        stdout.write(line.highlightNimCode())
    else:
      writeStyled("~", fgBlue, bgDefault, {styleDim})

proc drawVarsPanel(tui: DebugTUI) =
  let entry = tui.current()
  let panelX = tui.width - VARS_PANEL_WIDTH
  let panelHeight = tui.height - HEADER_HEIGHT - FOOTER_HEIGHT
  let startY = HEADER_HEIGHT

  let changed = tui.getChangedVars()

  # Draw vertical separator
  for i in 0..<panelHeight:
    moveTo(panelX - 1, startY + i)
    writeStyled("|", fgWhite, bgDefault, {styleDim})

  # Header
  moveTo(panelX, startY)
  writeStyled(" VARIABLES ", fgBlack, bgGreen)
  stdout.write(" ".repeat(VARS_PANEL_WIDTH - 12))

  # Variables list
  var y = startY + 1
  var sortedVars: seq[string] = @[]
  for name in entry.vars.keys:
    sortedVars.add(name)
  sortedVars.sort()

  for name in sortedVars:
    if y >= startY + panelHeight - 1:
      break

    moveTo(panelX, y)
    let val = entry.vars[name]
    let isChanged = name in changed
    let isWatched = name in tui.watched

    # Indicator
    if isWatched:
      writeStyled(" @", fgMagenta)
    elif isChanged:
      writeStyled(" >", fgGreen, bgDefault, {styleBright})
    else:
      stdout.write("  ")

    # Name
    let displayName = if name.len > 10: name[0..9] else: name
    if isChanged:
      writeStyled(displayName, fgGreen, bgDefault, {styleBright})
    else:
      writeStyled(displayName, fgYellow)

    stdout.write(" = ")

    # Value (truncated)
    let maxValLen = VARS_PANEL_WIDTH - displayName.len - 6
    var displayVal = val
    if displayVal.len > maxValLen:
      displayVal = displayVal[0..<maxValLen-2] & ".."

    if isChanged:
      writeStyled(displayVal, fgWhite, bgDefault, {styleBright})
    else:
      stdout.write(displayVal)

    inc y

  if sortedVars.len == 0:
    moveTo(panelX, y)
    writeStyled("  (no variables)", fgWhite, bgDefault, {styleDim})
    inc y

  # Watch section
  if tui.watched.len > 0:
    inc y
    if y < startY + panelHeight - 1:
      moveTo(panelX, y)
      writeStyled(" WATCHED ", fgBlack, bgMagenta)
      inc y

      for wvar in tui.watched:
        if y >= startY + panelHeight:
          break
        moveTo(panelX, y)
        let hist = tui.getWatchHistory(wvar)
        let currVal = if wvar in entry.vars: entry.vars[wvar] else: "?"
        writeStyled(&"  {wvar}: {currVal}", fgMagenta)
        inc y

proc drawHelp(tui: DebugTUI) =
  let boxW = 54
  let boxH = 22
  let startX = (tui.width - boxW) div 2
  let startY = (tui.height - boxH) div 2

  for y in startY..<startY+boxH:
    moveTo(startX, y)
    stdout.setBackgroundColor(bgBlue)
    stdout.write(" ".repeat(boxW))

  moveTo(startX + 2, startY + 1)
  writeStyled("KEYBOARD SHORTCUTS", fgWhite, bgBlue, {styleBright})

  let shortcuts = [
    ("Left / A", "Step backward"),
    ("Right / L", "Step forward"),
    ("Up/Down/W/S/J/K", "Scroll source"),
    ("PgUp / PgDn", "Jump 10 steps"),
    ("Home / End", "First / last step"),
    ("G", "Goto step number"),
    ("/ or F", "Find in trace"),
    ("N / P", "Next / prev match"),
    ("T", "Timeline view"),
    ("B", "Breakpoints menu"),
    ("C / R", "Continue / Reverse to break"),
    ("W", "Watch variable menu"),
    ("V", "View/inspect variable"),
    ("D", "Diff from previous"),
    ("I", "Trace info"),
    ("H / ?", "This help"),
    ("Q / Esc", "Quit"),
  ]

  for i, (key, desc) in shortcuts:
    if i >= boxH - 4:
      break
    moveTo(startX + 2, startY + 3 + i)
    writeStyled(key.alignLeft(18), fgYellow, bgBlue)
    writeStyled(desc, fgWhite, bgBlue)

  stdout.resetAttributes()

proc drawTimeline(tui: DebugTUI) =
  let boxW = min(70, tui.width - 4)
  let boxH = min(20, tui.height - 4)
  let startX = (tui.width - boxW) div 2
  let startY = (tui.height - boxH) div 2

  for y in startY..<startY+boxH:
    moveTo(startX, y)
    stdout.setBackgroundColor(bgBlue)
    stdout.write(" ".repeat(boxW))

  moveTo(startX + 2, startY + 1)
  writeStyled("EXECUTION TIMELINE", fgWhite, bgBlue, {styleBright})

  let total = tui.entries.len
  let barWidth = boxW - 6

  # Draw position bar
  moveTo(startX + 2, startY + 3)
  writeStyled("Position: ", fgYellow, bgBlue)
  let posRatio = if total > 1: tui.pos / (total - 1) else: 0.0
  let markerPos = int(posRatio * float(barWidth - 1))

  for i in 0..<barWidth:
    if i == markerPos:
      writeStyled("|", fgGreen, bgBlue, {styleBright})
    else:
      writeStyled("-", fgWhite, bgBlue, {styleDim})

  moveTo(startX + 2, startY + 4)
  writeStyled(&"Step {tui.pos} of {total - 1}", fgWhite, bgBlue)

  # Show files accessed
  moveTo(startX + 2, startY + 6)
  writeStyled("Files:", fgYellow, bgBlue)

  var files: seq[string] = @[]
  for entry in tui.entries:
    let f = entry.file.splitFile().name & entry.file.splitFile().ext
    if f.len > 0 and f notin files:
      files.add(f)

  for i, f in files:
    if i >= boxH - 10: break
    moveTo(startX + 4, startY + 7 + i)
    writeStyled(f, fgWhite, bgBlue)

  # Show scope changes
  let scopeY = startY + 8 + files.len
  if scopeY < startY + boxH - 3:
    moveTo(startX + 2, scopeY)
    writeStyled("Scopes entered:", fgYellow, bgBlue)
    var scopes: seq[string] = @[]
    for entry in tui.entries:
      if entry.scope notin scopes:
        scopes.add(entry.scope)
    for i, s in scopes:
      if scopeY + 1 + i >= startY + boxH - 1: break
      moveTo(startX + 4, scopeY + 1 + i)
      writeStyled(s, fgMagenta, bgBlue)

  stdout.resetAttributes()

proc drawInspect(tui: DebugTUI, varName: string) =
  let boxW = min(60, tui.width - 4)
  let boxH = min(15, tui.height - 4)
  let startX = (tui.width - boxW) div 2
  let startY = (tui.height - boxH) div 2

  for y in startY..<startY+boxH:
    moveTo(startX, y)
    stdout.setBackgroundColor(bgBlue)
    stdout.write(" ".repeat(boxW))

  moveTo(startX + 2, startY + 1)
  writeStyled(&"INSPECT: {varName}", fgWhite, bgBlue, {styleBright})

  let entry = tui.current()
  if varName in entry.vars:
    let val = entry.vars[varName]

    # Show full value with word wrap
    moveTo(startX + 2, startY + 3)
    writeStyled("Current value:", fgYellow, bgBlue)

    let maxW = boxW - 4
    var y = startY + 4
    var i = 0
    while i < val.len and y < startY + boxH - 4:
      let chunk = val[i ..< min(i + maxW, val.len)]
      moveTo(startX + 2, y)
      writeStyled(chunk, fgWhite, bgBlue)
      i += maxW
      inc y

    # Show history
    let hist = tui.getWatchHistory(varName)
    if hist.len > 0 and y < startY + boxH - 2:
      inc y
      moveTo(startX + 2, y)
      writeStyled(&"History ({hist.len} changes):", fgYellow, bgBlue)
      inc y
      for h in hist:
        if y >= startY + boxH - 1: break
        moveTo(startX + 2, y)
        let marker = if h.step == tui.pos: " <--" else: ""
        let hval = if h.val.len > maxW - 15: h.val[0..<maxW-18] & "..." else: h.val
        writeStyled(&"  [{h.step}] {hval}{marker}", fgCyan, bgBlue)
        inc y
  else:
    moveTo(startX + 2, startY + 3)
    writeStyled("Variable not in scope", fgRed, bgBlue)

  stdout.resetAttributes()

proc drawBreakpointList(tui: DebugTUI) =
  let boxW = min(50, tui.width - 4)
  let boxH = min(15, tui.height - 4)
  let startX = (tui.width - boxW) div 2
  let startY = (tui.height - boxH) div 2

  for y in startY..<startY+boxH:
    moveTo(startX, y)
    stdout.setBackgroundColor(bgBlue)
    stdout.write(" ".repeat(boxW))

  moveTo(startX + 2, startY + 1)
  writeStyled("BREAKPOINTS", fgWhite, bgBlue, {styleBright})

  if tui.breakpoints.len == 0:
    moveTo(startX + 2, startY + 3)
    writeStyled("No breakpoints set", fgWhite, bgBlue, {styleDim})
    moveTo(startX + 2, startY + 5)
    writeStyled("Type file:line to add one", fgYellow, bgBlue)
  else:
    for i, bp in tui.breakpoints:
      if i >= boxH - 4: break
      moveTo(startX + 2, startY + 3 + i)
      writeStyled(&"[{i}] {bp.file}:{bp.line}", fgWhite, bgBlue)

  stdout.resetAttributes()

proc drawWatchList(tui: DebugTUI) =
  let boxW = min(50, tui.width - 4)
  let boxH = min(15, tui.height - 4)
  let startX = (tui.width - boxW) div 2
  let startY = (tui.height - boxH) div 2

  for y in startY..<startY+boxH:
    moveTo(startX, y)
    stdout.setBackgroundColor(bgMagenta)
    stdout.write(" ".repeat(boxW))

  moveTo(startX + 2, startY + 1)
  writeStyled("WATCHED VARIABLES", fgWhite, bgMagenta, {styleBright})

  let entry = tui.current()

  if tui.watched.len == 0:
    moveTo(startX + 2, startY + 3)
    writeStyled("No watched variables", fgWhite, bgMagenta, {styleDim})
    moveTo(startX + 2, startY + 5)
    writeStyled("Available vars:", fgYellow, bgMagenta)
    var y = startY + 6
    for name in entry.vars.keys:
      if y >= startY + boxH - 1: break
      moveTo(startX + 4, y)
      writeStyled(name, fgWhite, bgMagenta)
      inc y
  else:
    for i, wvar in tui.watched:
      if i >= boxH - 4: break
      moveTo(startX + 2, startY + 3 + i)
      let val = if wvar in entry.vars: entry.vars[wvar] else: "?"
      let hist = tui.getWatchHistory(wvar)
      writeStyled(&"{wvar} = {val} ({hist.len} changes)", fgWhite, bgMagenta)

  stdout.resetAttributes()

var inspectVar: string = ""  # Variable being inspected

proc draw(tui: var DebugTUI) =
  clearScreen()
  drawHeader(tui)
  drawSourcePanel(tui)
  drawVarsPanel(tui)
  drawFooter(tui)

  case tui.mode
  of vmHelp:
    drawHelp(tui)
  of vmTimeline:
    drawTimeline(tui)
  of vmInspect:
    drawInspect(tui, inspectVar)
  of vmBreakpoint:
    if tui.inputBuffer.len == 0:
      drawBreakpointList(tui)
  of vmWatch:
    if tui.inputBuffer.len == 0:
      drawWatchList(tui)
  else:
    discard

  stdout.flushFile()

# ─────────────────────────────────────────────────────────────────────────────
# Actions
# ─────────────────────────────────────────────────────────────────────────────

proc stepForward(tui: var DebugTUI) =
  if tui.pos < tui.entries.len - 1:
    inc tui.pos
    tui.message = ""

proc stepBackward(tui: var DebugTUI) =
  if tui.pos > 0:
    dec tui.pos
    tui.message = ""

proc jumpTo(tui: var DebugTUI, step: int) =
  if step >= 0 and step < tui.entries.len:
    tui.pos = step
    tui.message = &"Jumped to step {step}"
    tui.messageIsError = false
  else:
    tui.message = &"Invalid step: {step}"
    tui.messageIsError = true

proc search(tui: var DebugTUI, pattern: string) =
  tui.searchResults = @[]
  let lowerPattern = pattern.toLowerAscii()

  for i, entry in tui.entries:
    if lowerPattern in entry.desc.toLowerAscii() or
       lowerPattern in entry.file.toLowerAscii() or
       lowerPattern in entry.scope.toLowerAscii():
      tui.searchResults.add(i)
    else:
      for name, val in entry.vars.pairs:
        if lowerPattern in name.toLowerAscii() or lowerPattern in val.toLowerAscii():
          tui.searchResults.add(i)
          break

  if tui.searchResults.len > 0:
    tui.searchIdx = 0
    tui.pos = tui.searchResults[0]
    tui.message = &"Found {tui.searchResults.len} matches (N/P to navigate)"
    tui.messageIsError = false
  else:
    tui.message = "No matches found"
    tui.messageIsError = true

proc nextSearchResult(tui: var DebugTUI) =
  if tui.searchResults.len > 0:
    tui.searchIdx = (tui.searchIdx + 1) mod tui.searchResults.len
    tui.pos = tui.searchResults[tui.searchIdx]
    tui.message = &"Match {tui.searchIdx + 1}/{tui.searchResults.len}"
    tui.messageIsError = false

proc prevSearchResult(tui: var DebugTUI) =
  if tui.searchResults.len > 0:
    tui.searchIdx = (tui.searchIdx - 1 + tui.searchResults.len) mod tui.searchResults.len
    tui.pos = tui.searchResults[tui.searchIdx]
    tui.message = &"Match {tui.searchIdx + 1}/{tui.searchResults.len}"
    tui.messageIsError = false

proc setBreakpoint(tui: var DebugTUI, spec: string) =
  let colonIdx = spec.rfind(':')
  if colonIdx < 0:
    tui.message = "Invalid format. Use: file:line"
    tui.messageIsError = true
    return

  let file = spec[0..<colonIdx]
  try:
    let line = parseInt(spec[colonIdx + 1..^1])
    tui.breakpoints.add((file, line))
    tui.message = &"Breakpoint set at {file}:{line}"
    tui.messageIsError = false
  except:
    tui.message = "Invalid line number"
    tui.messageIsError = true

proc continueToBreakpoint(tui: var DebugTUI) =
  for i in (tui.pos + 1)..<tui.entries.len:
    let entry = tui.entries[i]
    for bp in tui.breakpoints:
      if entry.file.endsWith(bp.file) and entry.line == bp.line:
        tui.pos = i
        tui.message = &"Breakpoint hit at step {i}"
        tui.messageIsError = false
        return
  tui.message = "No breakpoint hit"
  tui.messageIsError = true

proc reverseToBreakpoint(tui: var DebugTUI) =
  for i in countdown(tui.pos - 1, 0):
    let entry = tui.entries[i]
    for bp in tui.breakpoints:
      if entry.file.endsWith(bp.file) and entry.line == bp.line:
        tui.pos = i
        tui.message = &"Breakpoint hit at step {i}"
        tui.messageIsError = false
        return
  tui.message = "No breakpoint hit"
  tui.messageIsError = true

proc toggleWatch(tui: var DebugTUI) =
  let entry = tui.current()
  if entry.vars.len == 0:
    tui.message = "No variables to watch"
    tui.messageIsError = true
    return

  # Get first var that isn't watched, or remove first watched
  for name in entry.vars.keys:
    if name notin tui.watched:
      tui.watched.add(name)
      tui.message = &"Watching: {name}"
      tui.messageIsError = false
      return

  # All watched, remove first
  if tui.watched.len > 0:
    let removed = tui.watched[0]
    tui.watched.delete(0)
    tui.message = &"Stopped watching: {removed}"
    tui.messageIsError = false

proc showDiff(tui: var DebugTUI) =
  if tui.pos == 0:
    tui.message = "First step - no previous state"
    tui.messageIsError = true
    return

  let curr = tui.current()
  let prev = tui.entries[tui.pos - 1]
  var changes: seq[string] = @[]

  for name, val in curr.vars.pairs:
    if name notin prev.vars:
      changes.add(&"+{name}")
    elif prev.vars[name] != val:
      changes.add(&"~{name}")

  for name in prev.vars.keys:
    if name notin curr.vars:
      changes.add(&"-{name}")

  if changes.len == 0:
    tui.message = "No variable changes"
  else:
    tui.message = "Changed: " & changes.join(" ")
  tui.messageIsError = false

proc showInfo(tui: var DebugTUI) =
  let stats = getTraceStats(tui.entries)
  tui.message = &"Steps:{stats.totalSteps} Files:{stats.uniqueFiles} MaxDepth:{stats.maxDepth} Duration:{stats.duration:.3f}s"
  tui.messageIsError = false

# ─────────────────────────────────────────────────────────────────────────────
# Input Handling
# ─────────────────────────────────────────────────────────────────────────────

proc readKey(): int =
  try:
    result = getch().int
  except EOFError:
    return ord('q')  # Treat EOF as quit

  # Handle escape sequences (arrow keys, etc)
  if result == 27:  # ESC
    # Check if more bytes follow (escape sequence)
    try:
      let c2 = getch().int
      if c2 == 91:  # [
        let c3 = getch().int
        case c3
        of 65: return 1001  # Up
        of 66: return 1002  # Down
        of 67: return 1003  # Right
        of 68: return 1004  # Left
        of 72: return 1005  # Home
        of 70: return 1006  # End
        of 53:  # Page Up
          discard getch()  # consume ~
          return 1007
        of 54:  # Page Down
          discard getch()  # consume ~
          return 1008
        else: return result
      else:
        return result  # Plain ESC
    except EOFError:
      return result  # Plain ESC on EOF

proc handleInput(tui: var DebugTUI): bool =
  ## Returns false to quit
  let key = readKey()

  case tui.mode
  of vmNormal:
    case key
    of ord('q'), ord('Q'):
      return false

    # Navigation
    of 1004, ord('a'), ord('A'):  # Left arrow / A
      tui.stepBackward()
    of 1003, ord('l'):  # Right arrow / L
      tui.stepForward()
    of 1001, ord('w'), ord('k'):  # Up - scroll
      if tui.sourceScroll > 0:
        dec tui.sourceScroll
    of 1002, ord('s'), ord('j'):  # Down - scroll
      inc tui.sourceScroll
    of 1007:  # Page Up
      tui.jumpTo(max(0, tui.pos - 10))
    of 1008:  # Page Down
      tui.jumpTo(min(tui.entries.len - 1, tui.pos + 10))
    of 1005:  # Home
      tui.jumpTo(0)
    of 1006:  # End
      tui.jumpTo(tui.entries.len - 1)

    # Commands
    of ord('g'), ord('G'):  # Jump (goto)
      tui.mode = vmJump
      tui.inputBuffer = ""
    of ord('/'), ord('f'), ord('F'):  # Search
      tui.mode = vmSearch
      tui.inputBuffer = ""
    of ord('n'):  # Next search result
      tui.nextSearchResult()
    of ord('p'), ord('P'):  # Prev search result
      tui.prevSearchResult()
    of ord('b'), ord('B'):  # Breakpoint
      tui.mode = vmBreakpoint
      tui.inputBuffer = ""
    of ord('c'):  # Continue
      tui.continueToBreakpoint()
    of ord('r'):  # Reverse
      tui.reverseToBreakpoint()
    of ord('W'):  # Watch
      tui.toggleWatch()
    of ord('D'):  # Diff
      tui.showDiff()
    of ord('i'), ord('I'):  # Info
      tui.showInfo()
    of ord('h'), ord('H'), ord('?'):  # Help
      tui.mode = vmHelp
    of 27:  # ESC
      return false
    else:
      discard

  of vmSearch:
    case key
    of 27:  # ESC
      tui.mode = vmNormal
    of 13, 10:  # Enter
      tui.search(tui.inputBuffer)
      tui.mode = vmNormal
    of 127, 8:  # Backspace
      if tui.inputBuffer.len > 0:
        tui.inputBuffer = tui.inputBuffer[0..^2]
    else:
      if key >= 32 and key < 127:
        tui.inputBuffer.add(chr(key))

  of vmJump:
    case key
    of 27:  # ESC
      tui.mode = vmNormal
    of 13, 10:  # Enter
      try:
        let step = parseInt(tui.inputBuffer)
        tui.jumpTo(step)
      except:
        tui.message = "Invalid number"
        tui.messageIsError = true
      tui.mode = vmNormal
    of 127, 8:  # Backspace
      if tui.inputBuffer.len > 0:
        tui.inputBuffer = tui.inputBuffer[0..^2]
    else:
      if key >= ord('0') and key <= ord('9'):
        tui.inputBuffer.add(chr(key))

  of vmBreakpoint:
    case key
    of 27:  # ESC
      tui.mode = vmNormal
    of 13, 10:  # Enter
      tui.setBreakpoint(tui.inputBuffer)
      tui.mode = vmNormal
    of 127, 8:  # Backspace
      if tui.inputBuffer.len > 0:
        tui.inputBuffer = tui.inputBuffer[0..^2]
    else:
      if key >= 32 and key < 127:
        tui.inputBuffer.add(chr(key))

  of vmHelp:
    tui.mode = vmNormal

  else: discard
  return true

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

proc runTUI(tracePath: string) =
  var tui = DebugTUI(
    entries: loadTrace(tracePath),
    pos: 0,
    sourceCache: initTable[string, seq[string]](),
    breakpoints: @[],
    watched: @[],
    mode: vmNormal,
    inputBuffer: "",
    message: "",
    messageIsError: false,
    sourceScroll: 0,
    varsScroll: 0,
    selectedPanel: pSource,
    searchResults: @[],
    searchIdx: 0
  )

  if tui.entries.len == 0:
    echo "Error: No trace data found in " & tracePath
    echo "Run your program with debug: block first to generate a trace."
    return

  # Get terminal size
  tui.width = terminalWidth()
  tui.height = terminalHeight()

  if tui.width < MIN_SOURCE_WIDTH + VARS_PANEL_WIDTH + 1:
    echo "Terminal too narrow. Need at least " & $(MIN_SOURCE_WIDTH + VARS_PANEL_WIDTH + 1) & " columns."
    return

  # Setup terminal
  hideCursor()

  try:
    tui.message = &"Loaded {tui.entries.len} steps. Press H for help."
    tui.messageIsError = false

    while true:
      # Update terminal size in case of resize
      tui.width = terminalWidth()
      tui.height = terminalHeight()

      tui.draw()

      if not tui.handleInput():
        break
  finally:
    showCursor()
    clearScreen()
    echo "Goodbye!"

when isMainModule:
  let args = commandLineParams()
  let tracePath = if args.len > 0: args[0] else: ".debug.trace"
  runTUI(tracePath)
