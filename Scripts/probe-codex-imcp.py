"""Ask the installed Codex client to discover iMCP; no model turn or chat reads."""
import json
import selectors
import subprocess
import sys
import time

p = subprocess.Popen(["/Applications/ChatGPT.app/Contents/Resources/codex",
                      "app-server", "--stdio"], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
s = selectors.DefaultSelector()
s.register(p.stdout, selectors.EVENT_READ)

def request(i, method, params):
    p.stdin.write((json.dumps(dict(id=i, method=method, params=params))+"\n").encode())
    p.stdin.flush()
    deadline = time.monotonic()+45
    while time.monotonic() < deadline:
        if not s.select(max(0, deadline-time.monotonic())):
            raise TimeoutError(method)
        line = p.stdout.readline()
        if not line:
            raise RuntimeError("Codex diagnostic process exited")
        response = json.loads(line)
        if response.get("id") == i:
            return response

try:
    r = request(1, "initialize", {"clientInfo": {"name": "imcp_connection_probe", "version": "1.0"}})
    if "error" in r:
        raise RuntimeError(r["error"])
    p.stdin.write(b'{"method":"initialized"}\n'); p.stdin.flush()
    params = {"detail": "toolsAndAuthOnly"}
    if len(sys.argv) > 1:
        params["threadId"] = sys.argv[1]
    r = request(2, "mcpServerStatus/list", params)
    if "error" in r:
        print(json.dumps(r["error"]))
    else:
        found = [x for x in r["result"].get("data", []) if x.get("name") == "iMCP"]
        for entry in found:
            print(json.dumps({"name": entry["name"], "runtimeStatus": entry.get("runtimeStatus"),
                "toolsError": entry.get("toolsError"), "wechat_tools": sorted(
                    k for k in entry.get("tools", {}) if k.startswith("wechat_"))}, ensure_ascii=False))
        if not found:
            print("iMCP not present in Codex inventory")
finally:
    p.terminate()
    try:
        p.wait(timeout=3)
    except subprocess.TimeoutExpired:
        p.kill(); p.wait()
    s.close()
