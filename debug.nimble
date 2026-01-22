# Package

version       = "0.2.0"
author        = "savannt"
description   = "Time-travel debugger with execution tracing and interactive CLI replay"
license       = "MIT"
srcDir        = "src"
bin           = @["debug_cli"]
binDir        = "bin"

# Dependencies

requires "nim >= 1.0.0"
requires "https://github.com/thing-king/colors"
requires "https://github.com/thing-king/macros2"
