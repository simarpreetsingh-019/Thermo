// Thermo client for Node.js (18+). Copy this one file into your project; no dependencies.
//
//   import { Thermo } from "./thermo.mjs";
//   const t = new Thermo();
//   const h = await t.headroom({ kind: "gpu", memoryGb: 8 });
//   if (h.verdict !== "go") await t.waitUntilCool({ target: 70 });
//
// Uses Thermo's local API when it's on, otherwise the Thermo app's command line. Same JSON either way.
// Docs: https://simarpreetsingh-019.github.io/Thermo/
import { readFileSync, existsSync } from "node:fs";
import { execFile } from "node:child_process";
import { homedir } from "node:os";

const INFO = `${homedir()}/Library/Application Support/Thermo/api.json`;
const FLAGS = { limit: "--limit", sort: "--sort", range: "--range", kind: "--kind", memoryGb: "--memory-gb" };
const QUERY = { limit: "limit", sort: "sort", range: "range", kind: "kind", memoryGb: "memory_gb" };

export class Thermo {
  constructor(appPath) {
    const apps = appPath ? [appPath] : ["/Applications/Thermo.app", `${homedir()}/Applications/Thermo.app`];
    this.bin = apps.map((a) => `${a}/Contents/MacOS/Thermo`).find(existsSync);
  }

  async #api(path, params) {
    let info;
    try { info = JSON.parse(readFileSync(INFO, "utf8")); } catch { return null; }
    const q = new URLSearchParams(Object.entries(params).filter(([, v]) => v != null).map(([k, v]) => [QUERY[k], String(v)]));
    try {
      const r = await fetch(`${info.url}${path}${q.size ? "?" + q : ""}`, {
        headers: { Authorization: `Bearer ${info.token}` }, signal: AbortSignal.timeout(3000) });
      return r.ok ? await r.json() : null;
    } catch { return null; }   // app not running: fall back to the command line
  }

  #cli(args) {
    if (!this.bin) throw new Error("Thermo.app not found. Install: https://github.com/simarpreetsingh-019/Thermo#install");
    return new Promise((ok, fail) => execFile(this.bin, ["--cli", ...args.map(String), "--json"], (err, out) => {
      try { ok(JSON.parse(out)); } catch { fail(err ?? new Error("bad output from Thermo")); }
    }));
  }

  async #get(path, cmd, params = {}) {
    const args = [cmd, ...Object.entries(params).filter(([, v]) => v != null).flatMap(([k, v]) => [FLAGS[k], v])];
    return (await this.#api(path, params)) ?? this.#cli(args);
  }

  status() { return this.#get("/v1/status", "status"); }
  temperatures() { return this.#get("/v1/temperatures", "temps"); }
  battery() { return this.#get("/v1/battery", "battery"); }
  processes({ limit = 8, sort = "cpu" } = {}) { return this.#get("/v1/processes", "apps", { limit, sort }); }
  history({ range = "1h" } = {}) { return this.#get("/v1/history", "history", { range }); }
  /** { verdict: "go" | "wait" | "no", advice, reasons, ... } */
  headroom({ kind = "any", memoryGb } = {}) { return this.#get("/v1/headroom", "headroom", { kind, memoryGb }); }
  waitUntilCool({ target = 70, timeout = 600 } = {}) { return this.#cli(["wait-cool", "--target", target, "--timeout", timeout]); }
}
