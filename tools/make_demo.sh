#!/bin/bash
# Renders docs/demo.gif from the app's real SwiftUI views with scripted data.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/demo docs
cp tools/demo.swift build/demo/main.swift   # top-level code must live in a file named main.swift
swiftc -O -target "$(uname -m)-apple-macos13.0" $(ls Sources/*.swift | grep -v main.swift) build/demo/main.swift -o build/thermo-demo 2> >(grep -v "ld: warning" >&2)
./build/thermo-demo docs/demo.gif
