# Thermo

A tiny, live system monitor that lives **in your MacBook's notch**, or floats anywhere on any Mac.
It shows CPU, RAM, GPU and temperature, and when your Mac gets hot it tells you **what's slowing down, which app is causing it, how long cooling will take, and what to close**.

- **Notch HUD:** glowing ring gauges beside the notch. Hover to expand, click 📌 to pin.
- **Pull it out:** drag the notch down and it becomes a floating widget. Drop it back at the top centre to re-dock.
- **Floating mode** for Macs without a notch: drag it anywhere, with magnetic edges, a corner snap, and a horizontal or vertical layout.
- **Menu bar mode**, if you prefer.
- **Heat tab:** heat level, what's affected (throttling, slower builds, dropped frames), the top culprit apps (including the project folder for `node`/`python` processes), a cooldown estimate, and one-click quit.
- **Apps tab:** top apps by CPU or memory, with quit buttons.
- **No sudo, no kernel extensions, no dependencies.** It reads sensors through public and stable macOS APIs.

## Install

**Homebrew**
```bash
brew install --cask simarpreetsingh-019/thermo/thermo
```

**Direct download:** grab `Thermo.zip` from [Releases](https://github.com/simarpreetsingh-019/Thermo/releases), unzip it, and drag it into Applications.
Thermo isn't notarized yet, so on first launch right-click → **Open**, or run:
```bash
xattr -dr com.apple.quarantine /Applications/Thermo.app
```

**Build from source** (needs Xcode Command Line Tools):
```bash
git clone https://github.com/simarpreetsingh-019/Thermo && cd Thermo && ./build.sh --install
```

Requires macOS 13+. It's a universal app (Apple Silicon and Intel), but temperature sensors are read on Apple Silicon only.

## How light is it?

Measured on an M5 MacBook:

| | Thermo |
|---|---|
| App size | **1.9 MB** |
| Memory (physical footprint) | **~16 MB** |
| CPU, notch collapsed | **~2.7% of one core**, about 0.3% of the whole chip |
| GPU | none beyond normal window drawing |
| Disk / network | none: it writes only a few settings and never connects to the network |

How it stays light:
- It samples every 2 s, with timer tolerance so macOS can batch wake-ups.
- The full per-process scan runs only while the Apps or Heat list is open; otherwise it runs every 8 s.
- It's native Swift with no Electron, no web views and no helper daemons.

## How it works

| Metric | Source |
|---|---|
| CPU | `host_statistics` (Mach) |
| RAM | `host_statistics64` plus `vm.swapusage`, matching Activity Monitor's "Memory Used" |
| GPU | IORegistry `IOAccelerator` → `PerformanceStatistics` |
| Temperature | IOKit HID temperature sensors (Apple Silicon), no SMC access needed |
| Per-app usage | `proc_pid_rusage`; helper processes are grouped under their parent app |
| Throttling | `ProcessInfo.thermalState` |

## Credits and similar projects

Inspired by [Stats](https://github.com/exelban/stats), [Boring.Notch](https://github.com/TheBoredTeam/boring.notch), [Atoll](https://github.com/Ebullioscopic/Atoll) and [MacThrottle](https://github.com/angristan/MacThrottle).

## License

MIT
