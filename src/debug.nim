## Debug Module - Time-Travel Debugger
##
## Provides the `debug:` macro that instruments code with:
## - Structured execution logging to .debug.trace
## - Variable state capture at each step
## - Stack depth tracking for call tracing

import macros2
from macros as stdmacros import nil
import macros except newStmtList
import strutils
import std/sets
import std/os

import ./debug/debug_log
export debug_log

proc describe(node: Node): string =
  ## Generate a human-readable description of what a node is doing
  result = node.repr.split("\n")[0]
  if result.len > 80:
    result = result[0..76] & "..."

proc isNoDebugCommand(node: Node): bool =
  ## Check if node is a noDebug: command
  node.kind == nkCommand and node.len >= 2 and
  node[0].kind == nkIdent and node[0].strVal == "noDebug"

proc extractVarNames(section: Node, vars: var HashSet[string]) =
  ## Extract variable names from var/let/const sections
  for identDef in section:
    if identDef.kind == nkIdentDefs and identDef.len >= 3:
      for i in 0..<(identDef.len - 2):
        let nameNode = identDef[i]
        case nameNode.kind
        of nkIdent:
          # Skip _ discard identifier - can't be captured
          if nameNode.strVal != "_":
            vars.incl(nameNode.strVal)
        of nkPostfix:
          if nameNode.len >= 2 and nameNode[1].kind == nkIdent:
            if nameNode[1].strVal != "_":
              vars.incl(nameNode[1].strVal)
        of nkPragmaExpr:
          if nameNode.len >= 1:
            let inner = nameNode[0]
            if inner.kind == nkIdent:
              if inner.strVal != "_":
                vars.incl(inner.strVal)
            elif inner.kind == nkPostfix and inner.len >= 2:
              if inner[1].kind == nkIdent and inner[1].strVal != "_":
                vars.incl(inner[1].strVal)
        else:
          discard

proc extractForVars(forStmt: Node, vars: var HashSet[string]) =
  ## Extract loop variables from for statement
  if forStmt.len >= 3:
    for i in 0..<(forStmt.len - 2):
      let varNode = forStmt[i]
      if varNode.kind == nkIdent and varNode.strVal != "_":
        vars.incl(varNode.strVal)

proc extractProcParams(procDef: Node, vars: var HashSet[string]) =
  ## Extract parameter names from proc definition
  if procDef.len > 3 and procDef[3].kind == nkFormalParams:
    let params = procDef[3]
    for i in 1..<params.len:
      let identDef = params[i]
      if identDef.kind == nkIdentDefs and identDef.len >= 3:
        for j in 0..<(identDef.len - 2):
          let nameNode = identDef[j]
          if nameNode.kind == nkIdent and nameNode.strVal != "_":
            vars.incl(nameNode.strVal)

proc getProcName(procDef: Node): string =
  ## Get the name of a procedure
  if procDef.len > 0:
    let nameNode = procDef[0]
    case nameNode.kind
    of nkIdent:
      return nameNode.strVal
    of nkPostfix:
      if nameNode.len >= 2 and nameNode[1].kind == nkIdent:
        return nameNode[1].strVal
    of nkPragmaExpr:
      if nameNode.len >= 1:
        let inner = nameNode[0]
        if inner.kind == nkIdent:
          return inner.strVal
        elif inner.kind == nkPostfix and inner.len >= 2 and inner[1].kind == nkIdent:
          return inner[1].strVal
    else:
      discard
  return "<anon>"

proc buildVarsCapture(vars: HashSet[string]): Node =
  ## Build a table constructor that captures all variables
  if vars.len == 0:
    var bracketExpr = newNode(nkBracketExpr)
    bracketExpr.add(macros2.ident("initTable"))
    bracketExpr.add(macros2.ident("string"))
    bracketExpr.add(macros2.ident("string"))
    return newCall(bracketExpr)

  var pairs = newNode(nkBracket)
  for varName in vars:
    var tup = newNode(nkTupleConstr)
    tup.add(macros2.newLit(varName))
    tup.add(newCall(macros2.ident("safeRepr"), macros2.ident(varName)))
    pairs.add(tup)

  result = newCall(newDotExpr(pairs, macros2.ident("toTable")))

proc buildDebugLogCall(filename: string, line: int, col: int, desc: string, vars: HashSet[string]): Node =
  ## Build the debugLog call for a statement with explicit location
  result = newCall(
    macros2.ident("debugLog"),
    macros2.newLit(filename),
    macros2.newLit(line),
    macros2.newLit(col),
    macros2.newLit(desc),
    buildVarsCapture(vars)
  )

proc describeMacroNode(node: Node): string =
  ## Generate a human-readable description for macro instrumentation
  result = node.repr.split("\n")[0]
  if result.len > 60:
    result = result[0..56] & "..."

proc buildMacroEcho(scopeName: string, filename: string, line: int, desc: string): Node =
  ## Build an echo call for compile-time macro logging
  let shortFile = filename.split("/")[^1]
  let msg = "[MACRO] " & scopeName & " @ " & shortFile & ":" & $line & " - " & desc
  result = newCall(macros2.ident("echo"), macros2.newLit(msg))

proc instrumentMacroBody(stmtList: Node, scopeName: string, parentFile: string = "", parentLine: int = 0): Node =
  ## Instrument macro/template body with compile-time echo calls
  result = newStmtList()

  for i, child in stmtList:
    let lineInfo = child.lineInfoObj
    var filename = lineInfo.filename
    var line = lineInfo.line.int

    if filename.len == 0 or line == 0:
      filename = parentFile
      line = parentLine

    let desc = describeMacroNode(child)

    # Add echo before each statement
    result.add(buildMacroEcho(scopeName, filename, line, desc))

    # Copy and recurse
    var instrumentedChild = child.copyNodeTree()

    case child.kind
    of nkStmtList, nkStmtListExpr:
      instrumentedChild = instrumentMacroBody(child, scopeName, filename, line)

    of nkIfStmt:
      for j in 0..<child.len:
        let branch = child[j]
        if branch.kind in {nkElifBranch, nkElse}:
          let bodyIdx = if branch.kind == nkElse: 0 else: 1
          if branch[bodyIdx].kind in {nkStmtList, nkStmtListExpr}:
            instrumentedChild[j][bodyIdx] = instrumentMacroBody(branch[bodyIdx], scopeName, filename, line)

    of nkCaseStmt:
      for j in 1..<child.len:
        let branch = child[j]
        if branch.kind in {nkOfBranch, nkElse}:
          let bodyIdx = if branch.kind == nkElse: 0 else: branch.len - 1
          if branch[bodyIdx].kind in {nkStmtList, nkStmtListExpr}:
            instrumentedChild[j][bodyIdx] = instrumentMacroBody(branch[bodyIdx], scopeName, filename, line)

    of nkWhileStmt:
      if child[1].kind in {nkStmtList, nkStmtListExpr}:
        instrumentedChild[1] = instrumentMacroBody(child[1], scopeName, filename, line)

    of nkForStmt:
      let lastIdx = child.len - 1
      if child[lastIdx].kind in {nkStmtList, nkStmtListExpr}:
        instrumentedChild[lastIdx] = instrumentMacroBody(child[lastIdx], scopeName, filename, line)

    of nkBlockStmt:
      if child[1].kind in {nkStmtList, nkStmtListExpr}:
        instrumentedChild[1] = instrumentMacroBody(child[1], scopeName, filename, line)

    else:
      discard

    result.add(instrumentedChild)

proc instrumentStmtList(stmtList: Node, knownVars: var HashSet[string], scopeName: string,
                        parentFile: string = "", parentLine: int = 0): Node =
  ## Recursively walk AST and inject trace statements between each statement
  ## parentFile/parentLine are used as fallback when child has no line info
  result = newStmtList()

  for i, child in stmtList:
    # Check for noDebug: command
    if child.isNoDebugCommand():
      let noDebugBody = child[1]
      if noDebugBody.kind in {nkStmtList, nkStmtListExpr}:
        for stmt in noDebugBody:
          result.add(stmt.copyNodeTree())
      else:
        result.add(noDebugBody.copyNodeTree())
      continue

    # Get line info from ORIGINAL node (before any copying)
    let lineInfo = child.lineInfoObj
    var filename = lineInfo.filename
    var line = lineInfo.line.int
    var col = lineInfo.column.int

    # Use parent location as fallback if this node has no location
    if filename.len == 0 or line == 0:
      filename = parentFile
      line = parentLine
      col = 0

    let desc = describe(child)

    # Add trace log before each statement
    result.add(buildDebugLogCall(filename, line, col, desc, knownVars))

    # Track new variable declarations AFTER logging
    case child.kind
    of nkVarSection, nkLetSection, nkConstSection:
      extractVarNames(child, knownVars)
    else:
      discard

    # Build instrumented version - recurse on ORIGINAL children to preserve line info
    var instrumentedChild = child.copyNodeTree()

    case child.kind
    of nkStmtList, nkStmtListExpr:
      instrumentedChild = instrumentStmtList(child, knownVars, scopeName, filename, line)

    of nkWhileStmt:
      if child[1].kind in {nkStmtList, nkStmtListExpr}:
        var loopVars = knownVars
        # Recurse on ORIGINAL child[1], not instrumentedChild[1]
        instrumentedChild[1] = instrumentStmtList(child[1], loopVars, scopeName, filename, line)

    of nkForStmt:
      var loopVars = knownVars
      extractForVars(child, loopVars)
      let lastIdx = child.len - 1
      if child[lastIdx].kind in {nkStmtList, nkStmtListExpr}:
        instrumentedChild[lastIdx] = instrumentStmtList(child[lastIdx], loopVars, scopeName, filename, line)

    of nkBlockStmt:
      if child[1].kind in {nkStmtList, nkStmtListExpr}:
        var blockVars = knownVars
        instrumentedChild[1] = instrumentStmtList(child[1], blockVars, scopeName, filename, line)

    of nkProcDef, nkFuncDef, nkMethodDef, nkIteratorDef:
      let procName = getProcName(child)
      var procVars: HashSet[string]
      extractProcParams(child, procVars)

      let bodyIdx = 6
      if child[bodyIdx].kind in {nkStmtList, nkStmtListExpr}:
        var newBody = newStmtList()
        newBody.add(newCall(macros2.ident("enterScope"), macros2.newLit(procName)))

        var deferStmt = newNode(nkDefer)
        deferStmt.add(newCall(macros2.ident("exitScope")))
        newBody.add(deferStmt)

        let instrumentedBody = instrumentStmtList(child[bodyIdx], procVars, procName, filename, line)
        for stmt in instrumentedBody:
          newBody.add(stmt)

        instrumentedChild[bodyIdx] = newBody

    of nkMacroDef, nkTemplateDef:
      # Macros/templates run at compile-time, use echo-based logging
      let procName = getProcName(child)
      let bodyIdx = 6
      if child[bodyIdx].kind in {nkStmtList, nkStmtListExpr}:
        var newBody = newStmtList()
        # Add entry echo
        let entryMsg = "[MACRO] >> " & procName
        newBody.add(newCall(macros2.ident("echo"), macros2.newLit(entryMsg)))

        # Instrument body with echo calls
        let instrumentedBody = instrumentMacroBody(child[bodyIdx], procName, filename, line)
        for stmt in instrumentedBody:
          newBody.add(stmt)

        instrumentedChild[bodyIdx] = newBody

    of nkIfStmt:
      for j in 0..<child.len:
        let branch = child[j]
        if branch.kind in {nkElifBranch, nkElse}:
          let bodyIdx = if branch.kind == nkElse: 0 else: 1
          if branch[bodyIdx].kind in {nkStmtList, nkStmtListExpr}:
            var branchVars = knownVars
            # Recurse on ORIGINAL branch body
            instrumentedChild[j][bodyIdx] = instrumentStmtList(branch[bodyIdx], branchVars, scopeName, filename, line)

    of nkCaseStmt:
      for j in 1..<child.len:
        let branch = child[j]
        if branch.kind in {nkOfBranch, nkElse}:
          let bodyIdx = if branch.kind == nkElse: 0 else: branch.len - 1
          if branch[bodyIdx].kind in {nkStmtList, nkStmtListExpr}:
            var branchVars = knownVars
            instrumentedChild[j][bodyIdx] = instrumentStmtList(branch[bodyIdx], branchVars, scopeName, filename, line)

    of nkTryStmt:
      if child[0].kind in {nkStmtList, nkStmtListExpr}:
        var tryVars = knownVars
        instrumentedChild[0] = instrumentStmtList(child[0], tryVars, scopeName, filename, line)
      for j in 1..<child.len:
        let branch = child[j]
        if branch.kind == nkExceptBranch:
          let bodyIdx = if branch.len == 1: 0 else: 1
          if branch[bodyIdx].kind in {nkStmtList, nkStmtListExpr}:
            var exceptVars = knownVars
            instrumentedChild[j][bodyIdx] = instrumentStmtList(branch[bodyIdx], exceptVars, scopeName, filename, line)
        elif branch.kind == nkFinally:
          if branch[0].kind in {nkStmtList, nkStmtListExpr}:
            var finallyVars = knownVars
            instrumentedChild[j][0] = instrumentStmtList(branch[0], finallyVars, scopeName, filename, line)

    of nkWhenStmt:
      for j in 0..<child.len:
        let branch = child[j]
        if branch.kind in {nkElifBranch, nkElse}:
          let bodyIdx = if branch.kind == nkElse: 0 else: 1
          if branch[bodyIdx].kind in {nkStmtList, nkStmtListExpr}:
            var whenVars = knownVars
            instrumentedChild[j][bodyIdx] = instrumentStmtList(branch[bodyIdx], whenVars, scopeName, filename, line)

    else:
      discard

    result.add(instrumentedChild)

proc debugNode*(node: Node): Node =
  var knownVars: HashSet[string]
  let instrumented = instrumentStmtList(node, knownVars, "<module>")
  result = instrumented

# Helper operators
proc `==`*(c: char, i: int): bool =
  result = ord(c) == i

proc add*(s: var string, i: int) =
  s.add(chr(i))

proc contains*(s: set[0..255], c: char): bool =
  result = ord(c) in s

converter toInt*(i: int64): int =
  result = int(i)

converter toChar*(i: int): char =
  result = chr(i)

converter toChar*(i: int64): char =
  result = chr(int(i))

macro debug*(body: untyped): untyped =
  ## Main debug macro - instruments all code with trace statements
  ## and logs execution to .debug.trace for time-travel debugging
  ##
  ## All debug: blocks across all packages write to the SAME trace file:
  ## - Current working directory + ".debug.trace" (default)
  ## - Or DEBUG_TRACE_PATH environment variable if set
  let bodyNode = body.toNode
  var knownVars: HashSet[string]

  # Get the file location from the macro call site
  let callInfo = stdmacros.lineInfoObj(body)
  let instrumented = instrumentStmtList(bodyNode, knownVars, "<module>",
                                        callInfo.filename, callInfo.line.int)

  # initDebugLog() will determine the shared path at runtime
  result = stdmacros.newStmtList()
  stdmacros.add(result, stdmacros.newCall(stdmacros.bindSym"initDebugLog"))
  stdmacros.add(result, instrumented.toNimNode())
  stdmacros.add(result, stdmacros.newCall(stdmacros.bindSym"closeDebugLog"))

  when defined(debugMacroOutput):
    echo stdmacros.treeRepr(result)

macro noDebug*(body: untyped): untyped =
  ## Pass-through macro for use outside debug blocks.
  ## Inside debug blocks, noDebug: is handled specially to skip instrumentation.
  result = body

# =============================================================================
# COMPILE-TIME DEBUG LOGGING
# =============================================================================
# Use these for debugging macros and compile-time code.
# Output goes to stdout during compilation.

proc log*(msg: string) =
  ## Simple compile-time log - just prints message
  echo "[DEBUG] " & msg

proc log*(label: string, value: string) =
  ## Compile-time log with label and value
  echo "[DEBUG] " & label & ": " & value

proc log*(label: string, value: int) =
  ## Compile-time log with label and int value
  echo "[DEBUG] " & label & ": " & $value

template here*() =
  ## Print current file:line at compile-time
  const info = instantiationInfo()
  echo "[DEBUG] @ " & info.filename & ":" & $info.line

template here*(msg: string) =
  ## Print current file:line with message at compile-time
  const info = instantiationInfo()
  echo "[DEBUG] @ " & info.filename & ":" & $info.line & " - " & msg

