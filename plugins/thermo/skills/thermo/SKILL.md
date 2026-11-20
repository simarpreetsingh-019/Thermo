---
name: thermo
description: Benchmark the CPU, GPU, memory and temperature impact of tests, builds and apps on macOS, and check the Mac's live load, temperatures, memory, battery and history with Thermo, and decide whether there is room before starting heavy work (ML training, large builds, renders, video export, local LLMs, big test suites). Use when the user asks why their Mac is slow, hot or out of memory, or before launching a GPU-, CPU- or memory-heavy job on macOS.
---

# Thermo: Mac load and heat for agents

Thermo (https://github.com/simarpreetsingh-019/Thermo) reads CPU, GPU, memory pressure, per-component
temperatures, battery health and a 24-hour history on macOS. Everything is read-only and local.

## Tools

If the `thermo` MCP server is connected, call its tools:

| Tool | Use it to |
|---|---|
| `start_benchmark` (`label`, `process`) → run the workload → `stop_benchmark` (`id`) | measure what a test, build, load test or app does to CPU, GPU, memory and temperatures (peaks, heat rise, throttling) |
| `check_headroom` (`kind`: any/gpu/cpu/memory, `memory_gb`) | decide go / wait / no before a heavy job |
| `wait_until_cool` (`target_celsius`, `timeout_seconds`) | pause until the Mac cools |
| `get_status` | one-call overview with a health summary |
| `get_temperatures` | per-part temps: CPU cores, GPU, memory, SSD, battery, Wi-Fi |
| `get_top_processes` (`limit`, `sort_by`) | find what's using CPU or memory |
| `get_battery` | health %, cycles, charge, watts |
| `get_history` (`range`: 1h/24h) | trends, averages and peaks |

Without MCP, use the command line (same JSON with `--json`):

```bash
thermo headroom --kind gpu --memory-gb 8 --json   # exit 0 go, 3 wait, 4 no
thermo wait-cool --target 70 --timeout 600
thermo status --json
thermo temps --json
thermo apps --sort memory --json
```

If `thermo` isn't on the PATH, run `/Applications/Thermo.app/Contents/MacOS/Thermo --cli <command> --json`.

## Benchmarking

When the user asks how heavy something is, or to compare before/after a change:
1. `start_benchmark` with a clear `label` and the `process` to track (e.g. `python`, `node`).
2. Run the workload with your normal shell tool.
3. `stop_benchmark`, then report the `summary` line plus what matters: peak CPU/GPU, heat rise, throttling seconds.
4. For before/after comparisons, benchmark both, then call `compare_benchmarks` (default: last two runs). Its `markdown` field is a ready-made table for a pull request description.

CLI: `thermo bench --process node -- npm test` (add `--json`).

## How to act on headroom

1. Before a heavy job, call `check_headroom` with the right `kind` (and `memory_gb` if you know it).
2. `go`: start the job.
3. `wait`: tell the user the reason in one line. Offer to wait with `wait_until_cool`, or to close one of
   `close_candidates`. Never quit apps yourself without the user's yes.
4. `no`: don't start; explain (usually not enough memory) and suggest a smaller batch/model or closing apps.
5. When the user asks "why is my Mac slow/hot", call `get_status`, then `get_top_processes`, and answer
   with the top cause in plain words.

## Not installed?

```bash
brew install --cask simarpreetsingh-019/thermo/thermo
```
No Homebrew: `curl -fsSL https://raw.githubusercontent.com/simarpreetsingh-019/Thermo/main/install.sh -o install.sh && bash install.sh`.
Guide: https://simarpreetsingh-019.github.io/Thermo/
