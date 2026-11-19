# Connect Thermo to agents and apps

Thermo must be installed on the Mac (`brew install --cask simarpreetsingh-019/thermo/thermo`, or the
[installer script](../README.md#install)). Full guide: https://simarpreetsingh-019.github.io/Thermo/#connect

The MCP server is the Thermo app itself: `/Applications/Thermo.app/Contents/MacOS/Thermo --mcp`.

| Tool | Setup |
|---|---|
| **Claude Code** | `/plugin marketplace add simarpreetsingh-019/Thermo` then `/plugin install thermo@thermo` (MCP server + skill). Or only MCP: `claude mcp add thermo -- /Applications/Thermo.app/Contents/MacOS/Thermo --mcp` |
| **Claude Desktop** | Settings → Developer → Edit Config, add the JSON below |
| **Codex CLI** | `codex mcp add thermo -- /Applications/Thermo.app/Contents/MacOS/Thermo --mcp`; optional: paste [codex/AGENTS.md](codex/AGENTS.md) into your AGENTS.md, or copy the [skill](../plugins/thermo/skills/thermo) to `~/.codex/skills/thermo/` |
| **Cursor** | add the JSON below to `~/.cursor/mcp.json`; optional rule: [cursor/thermo.mdc](cursor/thermo.mdc) → `.cursor/rules/` |
| **VS Code (Copilot)** | `.vscode/mcp.json`: `{"servers": {"thermo": {"command": "/Applications/Thermo.app/Contents/MacOS/Thermo", "args": ["--mcp"]}}}` |
| **Windsurf, Zed, others** | any MCP client: command `/Applications/Thermo.app/Contents/MacOS/Thermo`, args `["--mcp"]` |
| **GitHub Actions** | `uses: simarpreetsingh-019/Thermo@v1` on a macOS runner (see below) |
| **Your own app** | [clients/](../clients): Python, JavaScript, Swift. Or the local HTTP API / `thermo … --json` |

```json
{
  "mcpServers": {
    "thermo": { "command": "/Applications/Thermo.app/Contents/MacOS/Thermo", "args": ["--mcp"] }
  }
}
```

## GitHub Actions

```yaml
jobs:
  build:
    runs-on: macos-latest
    steps:
      - uses: simarpreetsingh-019/Thermo@v1
        with:
          kind: gpu        # any | gpu | cpu | memory
          memory-gb: 6
          fail-on: never   # never | wait | no
```

It writes a status and temperature table to the job summary and outputs `verdict` (go/wait/no).
Hosted runners are virtual machines, so some temperature sensors may be missing; it is most useful on
self-hosted Mac runners.
