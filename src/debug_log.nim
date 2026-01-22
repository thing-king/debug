## Debug Log Module
##
## Provides structured logging for the time-travel debugger.
## Writes execution traces to .debug.trace in JSON Lines format.

import std/[json, times, tables, os, exitprocs]
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
var debugLogFile*: File
var debugLogPath*: string = ".debug.trace"
var debugStepCounter*: int = 0
var debugStackDepth*: int = 0
var debugLogInitialized*: bool = false
var debugCurrentScope*: string = "<module>"

proc safeRepr*[T](v: T): string =
  ## Safely convert any value to string representation
  try:
    when compiles($v):
      result = $v
    else:
      result = repr(v)
  except:
    result = "<error>"

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

proc initDebugLog*(path: string = ".debug.trace") =
  ## Initialize the debug log file (truncates existing)
  debugLogPath = path
  debugLogFile = open(path, fmWrite)
  debugStepCounter = 0
  debugStackDepth = 0
  debugCurrentScope = "<module>"
  debugLogInitialized = true

proc closeDebugLog*() =
  ## Close the debug log file
  if debugLogInitialized:
    debugLogFile.close()
    debugLogInitialized = false

proc debugNextStep*(): int =
  ## Get the next step number and increment counter
  result = debugStepCounter
  inc debugStepCounter

proc debugLog*(entry: DebugEntry) =
  ## Write a debug entry to the log file
  if not debugLogInitialized:
    initDebugLog()
  debugLogFile.writeLine($entry.toJson())
  debugLogFile.flushFile()  # Ensure immediate write

proc debugLog*(file: string, line: int, col: int, desc: string,
               vars: Table[string, string] = initTable[string, string]()) =
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
