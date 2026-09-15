"""Read-only handshake regression: no tool calls, keys, or conversation data."""
import json
import pathlib
import selectors
import subprocess

binary = pathlib.Path(__file__).resolve().parents[1] / "dist/iMCP.app/Contents/MacOS/imcp-server"
expected = {"wechat_"+name for name in (
    "status", "find_conversations", "request_access", "list_members", "get_messages",
    "search_messages", "get_message_context", "get_updates", "get_media")}
cases = {
    "empty": {},
    "nested_extensions": {"experimental": {
        "example/object": {},
        "example/nested": {"enabled": True, "formats": ["image/png"], "limit": 100},
    }, "elicitation": {"form": {}, "url": {}}, "roots": {"listChanged": True}},
    "legacy_string": {"experimental": {"example/legacy": "enabled"}},
}
for label, capabilities in cases.items():
    p = subprocess.Popen([str(binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL)
    s = selectors.DefaultSelector(); s.register(p.stdout, selectors.EVENT_READ)
    def send(value):
        p.stdin.write((json.dumps(value)+"\n").encode()); p.stdin.flush()
    def request(i, method, params):
        send(dict(jsonrpc="2.0", id=i, method=method, params=params))
        while s.select(15):
            line = p.stdout.readline()
            if not line:
                raise RuntimeError("connection closed")
            response = json.loads(line)
            if response.get("id") == i:
                assert "error" not in response, (label, response.get("error"))
                return response["result"]
        raise TimeoutError(label)
    try:
        request(1, "initialize", dict(protocolVersion="2025-03-26", capabilities=capabilities,
            clientInfo=dict(name="iMCP Diagnostic Probe", version="1.0")))
        send(dict(jsonrpc="2.0", method="notifications/initialized"))
        result = request(2, "tools/list", {})
        names = {t["name"] for t in result["tools"]}
        assert expected <= names, expected-names
        print(label, "PASS", "wechat_tools", len(expected), flush=True)
    finally:
        p.stdin.close()
        p.terminate()
        try:
            p.wait(timeout=2)
        except subprocess.TimeoutExpired:
            p.kill(); p.wait()
        s.close()
