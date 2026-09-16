# WeChat integration — implementation status

The WeChat integration uses explicit manual synchronization of approved conversations.
Do not replace a working iMCP installation on the strength of a successful build.

## Implemented

- MIT wx-cli fork/submodule based on revision `2abe708f55bfe135539a385df856fdc58f97fc74`.
- Separate Rust backend and Swift WeChat service; length-framed stdin/stdout RPC.
- Read-only SQLCipher source connection, local authorized archive, external-content
  FTS5, combined filters, signed account/filter/authorization-bound cursors.
- Local conversation approval, directory bookmark, account-specific Keychain key,
  explicit Terminal key bootstrap over a token-authenticated private Unix socket.
- First-seen message semantics and revoke-with-retention / explicit deletion.
- On-demand media extraction with opaque resource IDs, authorization rechecks,
  size limits, expiry and next-start cleanup.
- Indexed source-query guards; incompatible plans fail instead of scanning.
- Release packaging script, inherited-sandbox Rust child, disabled Sparkle feed.

## Manual synchronization (issue #3)

Use `wechat_sync(conversation)` or the per-conversation **手动同步** button.
Approval alone does not import data. First sync imports history; later syncs
resume the persisted `(conversation, shard, rowid)` positions. Existing archives
and completed import positions are reused. There are no background import ticks
or long-poll loops. `wait_seconds` is removed from the MCP schema; nonzero legacy
values receive an explicit migration error.

All source shard read transactions are pinned before message ingestion starts.
Each transaction observes committed rows at its own snapshot establishment time;
SQLite cannot provide a single atomic instant across independent database files.
Writes after a shard snapshot is pinned are left for the next manual sync, so an
active chat cannot extend the operation indefinitely. `snapshot_started_at` is
an observation time, not a filter on message `create_time`: delayed/backdated
messages appended with new rowids must still be imported. New numbered shards
are discovered on each explicit sync, without consulting session timestamps.

The archive and positions commit atomically. Failure leaves both unchanged;
restart/retry resumes from the last successful commit. `get_updates` only reads
the archive and explicitly returns `sync_mode: manual`, `source_checked: false`,
`sync_required: true` and `last_synced_at` (null until a successful manual sync).
`sync_required` means another explicit sync is needed to check source freshness,
not that the source is known to contain new messages. `live_sync_ready` remains
false by design; a missing session range index no longer blocks manual sync.

### Complexity and source contract

For one requested conversation, only the Δ appended message rows are decoded
and inserted, in 128-row keyset pages. SQL plan guards require indexed rowid
range searches and reject full scans / temporary sorting. There is no historical
message COUNT, OFFSET, rescan or re-decryption. Work is independent of historical
message count except B-tree seeks/inserts: `O(F + F log N + Δ log N)` including
shard discovery/seeks and archive/FTS maintenance; row visits/decoding are `O(Δ)`.
F is the number of source shards. Strict total `O(Δ)` with zero shard/index
metadata cost is not possible without a source change log. First import costs
O(history), and the archive adds its update-query index once during migration.

This is append synchronization with first-observed retention. Increasing rowids
capture equal/older timestamps and new rows in old shards, but do not discover
in-place edits, deletion/reinsertion with reused rowids, or a replaced source DB.
Lossless mutation capture would require a durable source change log. The upstream
watch/serve monitors remain vendored and are not used by the iMCP app.

Full native authorization/sandbox/media acceptance and performance budgets remain
separate from component tests. Manual sync has a 300-second client timeout;
a timed-out transaction is rolled back and can be retried. Very large initial
imports may still require a future resumable snapshot job API.

## Build and test

Use native macOS/Xcode for app and sandbox validation (Docker cannot validate
macOS entitlements, Keychain or WeChat process access). Rust fixtures do not
access actual chats.

```sh
cargo test --manifest-path Backends/WeChat/Cargo.toml --locked -p imcp-wechat -p wx-db
bash Scripts/build-wechat.sh
```

Set `CARGO_BIN` when cargo is not on PATH. `SIGNING_IDENTITY` must identify a
valid Apple Development certificate (`security find-identity -v -p codesigning`).
Ad hoc signing is rejected: the hardened-runtime app failed at launch loading
Sparkle under library validation even though static signature verification passed.
Artifacts are staged under `dist/`, not installed automatically. The script
keeps a previous staged app when rebuilding. No upstream release upload occurs.

## Setup validation (user-controlled)

Open the staged app only after quitting another iMCP instance to avoid identity
and server-port conflicts. Open Settings → WeChat; choose the account directory
containing `db_storage`. Import an existing key or explicitly run the generated
Terminal command after arranging SIP changes yourself. Never paste a key into
a chat, issue, shell argument or environment variable. Restore SIP after capture.

Approval candidates stay in the local dialog. Check status before requesting
messages: an archive result does not imply live synchronization is running.
Do not use this development build as the sole record of new group messages.

## Local protocol verification (2026-09-15)

- TCP initialization and tools/list passed against running iMCP 1.4.1.
- The bundled `imcp-server` stdio/Bonjour bridge also passed initialization and
  exposed all nine `wechat_*` tools, which is the transport used by Codex.
- Existing Codex `[mcp_servers.iMCP]` pointed to an absent application under
  `/Applications`; its command was updated to this workspace's staged binary.
  No duplicate WeChat server or tool allowlist was added.
- `wechat_find_conversations` returned an empty authorized list.
- A synthetic unapproved conversation request returned `conversation_unavailable`.
- A synthetic nonexistent media request returned `message_unavailable`.
- `wechat_status` confirmed a readable source, no quota warning and disabled
  live sync due to the source range-index compatibility guard.

These are protocol and denial-path checks, not full native UI or positive
message/media acceptance. Current-chat tool discovery refresh is not verified.

## Authorized-group verification after historical-import fixes

The user approved the test group locally. `Scripts/probe-wechat.py` then verified
through the actual bundled stdio bridge:

- Historical index reached `ready`; nonempty query returned 10 sampled messages.
- Adjacent pages had no duplicate stable message IDs.
- Combined time/member/type filters and exclusive end boundary passed.
- File, link and image each had real samples and correct type filtering.
- Keyword search returned results; member listing returned 500 entries.
- Context included its anchor; repeated updates requests were identical.

Remaining gaps are NOT passes: no voice sample; member results currently have a
500-entry cap without pagination; keyword-result relevance and full nickname
history are not comprehensively validated. The image retrieval attempt failed
with `V2 AES key required but not provided`. Upstream derivation accesses shared
`app_data/radium/ilink/.../kvcomm/config.ini` outside the selected account folder.
The sandbox scope may prevent that read; separate user-approved, narrowly scoped
configuration access is needed before verifying the cause or deriving its key.
No scope expansion, SIP change or shared-config read was performed by the probe.

### Explicit image configuration authorization

Settings → WeChat now includes “选择图片配置 config.ini（只读）” and a revoke
button. The system picker grants access to one file, saved as a read-only
security-scoped bookmark per account. Swift reads at most 64 KiB and validates
the Base64 last_uin field; neither file content nor UIN is persisted in defaults
or emitted to logs. The UIN travels only in the existing private stdin frame;
Rust derives the image key in memory using the selected account's canonical ID.
The backend no longer probes shared directories automatically for image keys.

Status exposes only `image_key_configured` and `image_config_unavailable`.
Configured means derivation succeeded, not that an actual image was decrypted.
Stale or unreadable config does not disable text queries. Revoke discards the
bookmark, stops the child and clears its issued temporary media resources.
User selection and successful real-image decryption still require UI validation.

### WXGF conversion

After explicit configuration authorization, a real sample decrypted successfully
to WXGF and was readable over MCP, but failed the standard-image signature check.
The media path now invokes wx-cli's WXGF converter: embedded PNG/JPEG is extracted;
HEVC is decoded to PNG for a single frame or GIF for multiple frames.

`Scripts/build-wechat-ffmpeg.sh` builds pinned FFmpeg n8.0.1 from a SHA-256-checked
source archive with network disabled and only HEVC/PNG/GIF conversion components.
The private ffmpeg/ffprobe executables are signed with inherited App Sandbox and
resolved relative to the backend executable, not the user's PATH. Their source,
LGPL license and rebuild script ship inside the application. Each conversion
subprocess has a 10-second timeout and bounded stdout/stderr capture. A missing
converter fails explicitly instead of returning raw HEVC as a successful image.

Real-sample verification passed after backend reload: the previously returned
17,177-byte WXGF now returns 142,588 bytes with MIME `image/png`, a PNG signature,
and a successful MCP resources/read response. Existing query/pagination/filter
checks also passed. This does not validate animated GIF conversion, all WXGF
variants, expiry/revocation or live message synchronization.

## Exact live-sync blocker and member pagination follow-up

The actual source schema diagnostic now confirms only these SessionTable indexes:
`SessionTable_TYPE(type)`, `SessionTable_LSENDER(last_msg_sender)` and the unique
username index. EXPLAIN for the specified watermark query returns
`SCAN SessionTable` and `USE TEMP B-TREE FOR ORDER BY`. Thus the approved plan's
required source index is absent, not just a generic initialization error.
No source indexes were created and no periodic scan fallback was enabled.
Making live sync work on this database requires a user-approved design change;
for example read-only WAL parsing with a different, explicitly accounted cost
model. Merely creating an index would also violate the source read-only rule
and would not make sort_timestamp a durable change sequence.

Member listing now groups aliases by stable ID and uses account/auth/query-bound
signed keyset cursors with a rowid snapshot. Real validation found 309 unique
members across four pages without duplicates. A 1,001-member regression covers
aliases, new inserts during pagination, query-scope changes and revocation.
Grant and authorization-generation writes now commit atomically. Current versus
historical nickname provenance is still incomplete; seen_names must not be
presented as a verified current nickname history.

Rust regressions passed, including the new missing-sort-index history pagination
test with equal/decreasing sort sequences and optional TEXT fields. The running
WeChat backend was restarted to load the signed repair; WeChat itself was not.
