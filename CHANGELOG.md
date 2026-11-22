# Changelog

All notable changes to Thermo for Mac. Newest first. `./release.sh X.Y.Z` copies the section for the version
being released into the GitHub release notes under "What's new".
Mark a release as a security update with `./release.sh X.Y.Z --security`: the updaters then show a stronger notice.

## [Unreleased]

### Changed
- Releases use the full shipcrate pipeline: a quality gate before every release, CI on every push and pull request, and signed build provenance (SBOM + Sigstore) for every release.

## [1.10.0-beta.1] - 2026-11-22

- **New update system (shipcrate):** beta channel for testers, staged rollouts, safe rollback of a bad release, and messages from the maintainer.
- Updates now work even if you renamed the app (e.g. "Thermo 2.app").
- Menu: **Get beta updates first (testers)**.

## [1.9.0] - 2026-11-20

- **Benchmarks in the app:** History → Benchmarks. Press Record, run your app or tests, press Stop. See CPU and heat over the run
- **Compare before vs after:** `thermo bench compare` (add `--markdown` for a pull-request table) and the MCP tool `compare_benchmarks`. Every run is saved; export with `thermo bench show --csv`
- Fixed tab names wrapping in the notch panel
- New demo GIF and launch video

## [1.8.0] - 2026-11-20

- **Benchmark with your AI agent:** new MCP tools `start_benchmark` / `stop_benchmark` record CPU, GPU, memory and every temperature while your tests, builds or apps run, then report peaks, heat rise and throttling
- **`thermo bench -- <command>`** does the same from Terminal (add `--process node` to track one app)
- Share Thermo from the ⚙ menu
- New website look with share previews, an AI agents page and a guide to checking your Mac's temperature

## [1.7.1] - 2026-11-19

- **thermo command for everyone:** downloaded the zip? Use ⚙ → Connections → Install thermo command in Terminal. The installer script also offers it
- Clearer first-launch guide for the macOS warning, plus a contributing guide and security policy

## [1.7.0] - 2026-11-19

- **Connect AI agents:** Thermo now includes an MCP server, so Claude, Codex, Cursor, VS Code and any MCP client can check your Mac before heavy work (`check_headroom`, `wait_until_cool`, temperatures, processes, battery, history)
- **Terminal readings:** `thermo status`, `temps`, `apps`, `battery`, `history`, `headroom`, `wait-cool`, with `--json` for scripts
- **Local API** for your own apps (off by default; ⚙ → Connections): read-only, 127.0.0.1 only, token-protected
- One-file clients for Python, JavaScript and Swift, a Claude Code plugin, and a GitHub Action
- New guide site: https://simarpreetsingh-019.github.io/Thermo/

## [1.6.0] - 2026-11-19

- **Battery tab:** health, condition, cycle count, charge rate and time left, a 24-hour charge graph, and daily health tracking
- **History tab:** CPU, memory, GPU and temperature graphs for the last hour or 24 hours, with a shared hover line
- **Heat tab:** separate temperatures for CPU performance and efficiency cores, GPU, memory, SSD, battery, Wi-Fi and palm rest
- Alert cards now close on their own after 45 seconds (hover to keep one open); they stay in the 🔔 inbox
- New installer script for people without Homebrew, which verifies the download before installing
- Every release zip now has a GitHub attestation you can verify

## [1.5.1] - 2026-11-19

- **Alerts inbox** (🔔): every alert and update card is kept, with details
- Notch stays centred, with a one-time tip to move it left or right
- Homebrew installs now add a `thermo` command (open, quit, restart, update, version)
- Slimmer notch margins and small fixes

## [1.5.0] - 2026-11-19

- Memory tab: real memory pressure and swap, plus which apps to quit to free RAM
- Smart alerts when your Mac stays hot, memory stays tight, or an app gets stuck
- One-line health summary: all good, or exactly what to close
- Memory bar now follows pressure, not just % used

## [1.4.2] - 2026-11-18

- Update notifications: see what's new before and after updating
- Welcome card with one-click Open at login
- Menu-bar panel springs open like the Dock, right under the menu bar
- Notch gauges split evenly and sit snugly beside the notch

## [1.4.1] - 2026-11-18

- Fixed portfolio link in the About menu
- Notch gauges sized to fit the notch, with clear space beside it
- New launch video and demo in the README

## [1.4.0] - 2026-11-18

- 🔄 **Automatic updates:** Thermo checks for new versions daily and updates itself with one click (each download is verified with SHA-256 and codesign)
- 💬 **Send Feedback** right from the app
- Friendlier install message

## [1.3.1] - 2026-11-18

- Security hardening: process stopping re-verifies the target, session-critical processes are protected, hardened runtime enabled
- New minimalist icon
- Fixed notch ring sizing/overlap

## [1.3] - 2026-11-18

- See the release page.

## [1.2] - 2026-11-18

- See the release page.
