"""Thermo client for Python. Copy this one file into your project; standard library only.

    from thermo_client import Thermo
    t = Thermo()
    if t.headroom(kind="gpu", memory_gb=8)["verdict"] != "go":
        t.wait_until_cool(target=70)

Uses Thermo's local API when it's turned on (faster, live data), otherwise runs the Thermo app's
command line. Both return the same JSON. Docs: https://simarpreetsingh-019.github.io/Thermo/
"""
import json, os, subprocess, urllib.parse, urllib.request

INFO = os.path.expanduser("~/Library/Application Support/Thermo/api.json")
APPS = ["/Applications/Thermo.app", os.path.expanduser("~/Applications/Thermo.app")]


class Thermo:
    def __init__(self, app_path=None):
        self.bin = next((os.path.join(a, "Contents/MacOS/Thermo") for a in ([app_path] if app_path else APPS)
                         if os.path.exists(os.path.join(a, "Contents/MacOS/Thermo"))), None)

    def _api(self, path, params):
        try:
            info = json.load(open(INFO))
        except (OSError, ValueError):
            return None
        q = urllib.parse.urlencode({k: v for k, v in params.items() if v is not None})
        req = urllib.request.Request(f"{info['url']}{path}{'?' + q if q else ''}",
                                     headers={"Authorization": f"Bearer {info['token']}"})
        try:
            with urllib.request.urlopen(req, timeout=3) as r:
                return json.load(r)
        except OSError:
            return None   # app not running: fall back to the command line

    def _cli(self, *args):
        if not self.bin:
            raise RuntimeError("Thermo.app not found. Install: https://github.com/simarpreetsingh-019/Thermo#install")
        out = subprocess.run([self.bin, "--cli", *map(str, args), "--json"], capture_output=True, text=True)
        return json.loads(out.stdout)

    def _get(self, path, cmd, **params):
        args = [cmd] + [x for k, v in params.items() if v is not None for x in (CLI_FLAGS[k], v)]
        return self._api(path, params) or self._cli(*args)

    def status(self):              return self._get("/v1/status", "status")
    def temperatures(self):        return self._get("/v1/temperatures", "temps")
    def battery(self):             return self._get("/v1/battery", "battery")
    def processes(self, limit=8, sort="cpu"):
        return self._get("/v1/processes", "apps", limit=limit, sort=sort)
    def history(self, range="1h"): return self._get("/v1/history", "history", range=range)
    def headroom(self, kind="any", memory_gb=None):
        """{'verdict': 'go'|'wait'|'no', 'advice': ..., 'reasons': [...], ...}"""
        return self._get("/v1/headroom", "headroom", kind=kind, memory_gb=memory_gb)
    def wait_until_cool(self, target=70, timeout=600):
        return self._cli("wait-cool", "--target", target, "--timeout", timeout)


CLI_FLAGS = {"limit": "--limit", "sort": "--sort", "range": "--range", "kind": "--kind", "memory_gb": "--memory-gb"}

if __name__ == "__main__":
    print(json.dumps(Thermo().headroom(kind="gpu"), indent=2))
