# Contributing to Thermo

Thanks for helping! Thermo is a small, open-source Mac app by [Simarpreet Singh](https://simarpreetsingh-019.github.io), and every idea, bug report and pull request makes it better.

## Ways to help

- ⭐ **Star the repo** and share it. It's the biggest help: more stars means more people (and AI agents) find Thermo.
- 🐞 **Report a bug:** [open a bug report](https://github.com/simarpreetsingh-019/Thermo/issues/new?template=bug.yml). In the app, ⚙ → **Send Feedback…** fills in your Thermo version, macOS and Mac model.
- 💡 **Suggest a feature or upgrade:** [open a feedback issue](https://github.com/simarpreetsingh-019/Thermo/issues/new?template=feedback.yml).
- 🛠 **Send a pull request:** fixes, new sensors, new agent integrations, docs, translations.
- 🪟🐧 **Help with Windows and Linux:** on the [roadmap](README.md#roadmap). Open an issue first so we can plan it together.

## Build and run

Needs macOS 13+ and the Xcode Command Line Tools (`xcode-select --install`). No Xcode project, no dependencies.

```bash
git clone https://github.com/simarpreetsingh-019/Thermo && cd Thermo
./build.sh --install          # build, copy to /Applications, open
./build.sh --no-connect       # build without the CLI/MCP/API (Sources/Connect.swift)
build/Thermo.app/Contents/MacOS/Thermo --cli status   # try the CLI from the build
```

## Where things are

| Path | What |
|---|---|
| `Sources/Metrics.swift` | CPU, RAM, GPU, temperature sensors (HID + SMC) |
| `Sources/Processes.swift` | per-app usage, heat advisor |
| `Sources/Health.swift` | memory advisor, health line, smart alerts |
| `Sources/Battery.swift`, `History.swift` | battery health, history graphs |
| `Sources/Views.swift`, `Windows.swift`, `main.swift` | UI, notch and floating windows, app setup |
| `Sources/Toast.swift`, `Updater.swift` | notification cards, inbox, self-updater |
| `Sources/Connect.swift` | CLI JSON, MCP server, local API |
| `clients/`, `integrations/`, `plugins/`, `action.yml` | helpers for apps, agents and CI |
| `docs/` | the GitHub Pages site |

## Pull request checklist

- Keep it light: Thermo aims for about 16 MB of memory and 2–3% of one CPU core. Mention any change to that.
- No admin rights, no kernel extensions, no telemetry, no new dependencies.
- `./build.sh` builds with no errors, and you tried the change in the app.
- One topic per pull request, with a short description and a screenshot for UI changes.
- By contributing, you agree your work is released under the [MIT License](LICENSE).

## Security

Please don't report security problems in public issues. See [SECURITY.md](SECURITY.md).

Thanks for being here! 🌡️
