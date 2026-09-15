# Codex connection verification — 2026-09-15

The configured `iMCP` stdio executable exists in `dist/iMCP.app`. The app registers
all nine `wechat_*` tools; a separate `wechat` server entry is unnecessary.

Desktop logs showed initialization failure (`-32603`, JSON decoding error), not
a missing executable. The pinned Swift MCP SDK
`6132fd4b5b4217ce4717c4775e4607f5c3120129` declared client experimental
capabilities as `[String: String]`. An initialize request containing an object
value reproduced exactly that error. This is a confirmed compatibility defect;
the desktop's exact initialize payload was not captured.

`Scripts/Patches/swift-sdk-experimental-json.patch` changes those values to MCP
`Value`, retaining nested JSON instead of stripping capabilities. The build
script applies this patch idempotently and refuses an unexpected SDK revision.
Existing string-valued extensions remain readable. When updating the SDK, review
and replace/remove this patch intentionally. Building directly through Xcode on
a freshly resolved checkout requires running `bash Scripts/patch-swift-sdk.sh`.

The development-signed app was rebuilt and restarted. Verification:

- `python3 Scripts/probe-imcp-handshake.py`: empty capabilities, nested JSON
  extensions with roots/elicitation, and legacy strings all initialize and list
  the nine WeChat tools successfully. No message contents are requested.
- `python3 Scripts/probe-codex-imcp.py`: the installed Codex app-server client
  lists all nine tools with `toolsError: null`. This inventory check also worked
  before the patch, so it alone does not prove the desktop task handshake.
- Existing failed desktop task connections may need a Codex reconnect/restart.
  The current model's tool inventory has not acquired iMCP during this turn;
  native discovery in a refreshed desktop task remains to be confirmed.

No Codex configuration, WeChat database, Keychain secret, or SIP setting was
changed. This fix concerns tool discovery only, not the outstanding real-time
synchronization compatibility work.
