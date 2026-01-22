## Debug Log Module
##
## Provides structured logging for the time-travel debugger.
## Writes execution traces to .debug.trace in JSON Lines format.

import std/[json, times, tables, os, exitprocs, strutils]
export tables  # Export for use in generated macro code

type
  DebugEntry* = object
    step*: int              ## Sequential step number
    ts*: float              ## Timestamp (epochTime)
    file*: string           ## Source filename
    line*: int              ## Line number
    col*: int               ## Column number
    desc*: string           ## Statement description
    depth*: int             ## Call stack depth
    scope*: string          ## Current proc/function name (or "<module>")
    vars*: Table[string, string]  ## All local variables: name -> value

# Global state
var debugLogFile* {.threadvar.}: File
var debugLogPath* {.threadvar.}: string
var debugStepCounter* {.threadvar.}: int
var debugStackDepth* {.threadvar.}: int
var debugLogInitialized* {.threadvar.}: bool
var debugCurrentScope* {.threadvar.}: string

# Ring buffer for summary output (last N entries)
const SUMMARY_TRACE_SIZE* = 15
var debugRecentEntries* {.threadvar.}: seq[DebugEntry]
var debugMaxDepthSeen* {.threadvar.}: int
var debugScopesEntered* {.threadvar.}: seq[string]

proc initVars() =
  debugLogFile = nil
  debugLogPath = ".debug.trace"
  debugStepCounter = 0
  debugStackDepth = 0
  debugLogInitialized = false
  debugCurrentScope = "<module>"
  debugRecentEntries = @[]
  debugMaxDepthSeen = 0
  debugScopesEntered = @[]
initVars()


import macros
macro noJs(body: untyped): untyped =
  var noJsBody = nnkStmtList.newTree()
  for node in body:
    if node.kind == nnkProcDef:
      let procName = $node[0]
      let newProc = nnkProcDef.newTree()
      for procItem in node:
        newProc.add(procItem)
      # replace body with "discard"
      newProc[6] = nnkStmtList.newTree(nnkDiscardStmt.newTree(newEmptyNode()))
      noJsBody.add newProc
  result = quote do:
    when not defined(js):
      `body`
    else:
      `noJsBody`
noJs:
  proc safeRepr*[T](v: T): string =
    ## Safely convert any value to string representation
    ## Note: Only uses $ operator to avoid repr exception tracking issues
    {.cast(gcsafe).}:
      try:
        when compiles($v):
          result = $v
        else:
          result = "<no $ operator>"
      except CatchableError:
        result = "<error>"
      except Defect:
        result = "<defect>"

  proc toJson*(entry: DebugEntry): JsonNode =
    ## Convert DebugEntry to JSON
    result = %*{
      "step": entry.step,
      "ts": entry.ts,
      "file": entry.file,
      "line": entry.line,
      "col": entry.col,
      "desc": entry.desc,
      "depth": entry.depth,
      "scope": entry.scope,
      "vars": entry.vars
    }

  proc fromJson*(node: JsonNode): DebugEntry =
    ## Parse DebugEntry from JSON
    result.step = node["step"].getInt()
    result.ts = node["ts"].getFloat()
    result.file = node["file"].getStr()
    result.line = node["line"].getInt()
    result.col = node["col"].getInt()
    result.desc = node["desc"].getStr()
    result.depth = node["depth"].getInt()
    result.scope = node["scope"].getStr()
    result.vars = initTable[string, string]()
    if node.hasKey("vars"):
      for key, val in node["vars"].pairs:
        result.vars[key] = val.getStr()

  proc initDebugLog*(path: string = ".debug.trace") {.gcsafe.} =
    ## Initialize the debug log file (truncates existing)
    debugLogPath = path
    debugLogFile = open(path, fmWrite)
    debugStepCounter = 0
    debugStackDepth = 0
    debugCurrentScope = "<module>"
    debugLogInitialized = true

  proc writeSummary*() =
    ## Write .debug.summary with compact trace info
    if debugRecentEntries.len == 0:
      return

    let summaryPath = debugLogPath.changeFileExt("summary")
    var f = open(summaryPath, fmWrite)

    # Header: total steps, max depth, scopes
    f.writeLine("# Debug Summary")
    f.writeLine("# Total steps: " & $debugStepCounter)
    f.writeLine("# Max depth: " & $debugMaxDepthSeen)
    f.writeLine("# Scopes: " & debugScopesEntered.join(" -> "))
    f.writeLine("")

    # Last N entries in compact format
    f.writeLine("# Last " & $debugRecentEntries.len & " steps:")
    for entry in debugRecentEntries:
      # Format: [step] file:line (scope) desc
      let filename = entry.file.extractFilename()
      var line = "[" & $entry.step & "] " & filename & ":" & $entry.line
      if entry.scope != "<module>":
        line &= " (" & entry.scope & ")"
      line &= " | " & entry.desc
      f.writeLine(line)

      # Only show variables that exist, compact format
      if entry.vars.len > 0:
        var varParts: seq[string] = @[]
        for k, v in entry.vars:
          let shortVal = if v.len > 30: v[0..27] & "..." else: v
          varParts.add(k & "=" & shortVal)
        f.writeLine("    vars: " & varParts.join(", "))

    f.close()

  proc closeDebugLog*() =
    ## Close the debug log file and write summary
    if debugLogInitialized:
      writeSummary()
      debugLogFile.close()
      debugLogInitialized = false

  proc debugNextStep*(): int =
    ## Get the next step number and increment counter
    result = debugStepCounter
    inc debugStepCounter

  proc debugLog*(entry: DebugEntry) {.gcsafe.} =
    ## Write a debug entry to the log file
    if not debugLogInitialized:
      initDebugLog()
    debugLogFile.writeLine($entry.toJson())
    debugLogFile.flushFile()  # Ensure immediate write

    # Track for AI-optimized output
    if entry.depth > debugMaxDepthSeen:
      debugMaxDepthSeen = entry.depth
    if entry.scope notin debugScopesEntered:
      debugScopesEntered.add(entry.scope)

    # Ring buffer - keep last N entries
    debugRecentEntries.add(entry)
    if debugRecentEntries.len > SUMMARY_TRACE_SIZE:
      debugRecentEntries.delete(0)

  proc debugLog*(file: string, line: int, col: int, desc: string,
                vars: Table[string, string] = initTable[string, string]()) {.gcsafe.} =
    ## Convenience overload to create and log an entry
    let entry = DebugEntry(
      step: debugNextStep(),
      ts: epochTime(),
      file: file,
      line: line,
      col: col,
      desc: desc,
      depth: debugStackDepth,
      scope: debugCurrentScope,
      vars: vars
    )
    debugLog(entry)

  proc enterScope*(name: string) =
    ## Called when entering a procedure/function
    debugCurrentScope = name
    inc debugStackDepth

  proc exitScope*() =
    ## Called when exiting a procedure/function
    dec debugStackDepth
    if debugStackDepth <= 0:
      debugStackDepth = 0
      debugCurrentScope = "<module>"

  proc loadTrace*(path: string = ".debug.trace"): seq[DebugEntry] =
    ## Load a trace file and return all entries
    result = @[]
    if not fileExists(path):
      return
    for line in lines(path):
      if line.len > 0:
        try:
          result.add(fromJson(parseJson(line)))
        except:
          discard  # Skip malformed lines

  proc getTraceStats*(entries: seq[DebugEntry]): tuple[
      totalSteps: int,
      uniqueFiles: int,
      maxDepth: int,
      duration: float] =
    ## Get summary statistics for a trace
    var files: seq[string] = @[]
    var maxDepth = 0
    var minTs, maxTs: float

    if entries.len == 0:
      return (0, 0, 0, 0.0)

    minTs = entries[0].ts
    maxTs = entries[0].ts

    for entry in entries:
      if entry.file notin files:
        files.add(entry.file)
      if entry.depth > maxDepth:
        maxDepth = entry.depth
      if entry.ts < minTs:
        minTs = entry.ts
      if entry.ts > maxTs:
        maxTs = entry.ts

    result = (entries.len, files.len, maxDepth, maxTs - minTs)

# Auto-cleanup on program exit
proc debugAtExit() {.noconv.} =
  closeDebugLog()

addExitProc(debugAtExit)
