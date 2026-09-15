# WeChat integration — implementation status

This is a development build, not a completed real-time synchronization product.
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

## Blocking gaps (not acceptance passes)

1. **Live synchronization is disabled.** `live_sync_ready` is false. A session
   sort timestamp is not established as a durable modification sequence.
   Equal/backdated timestamps, summaries that do not change, and late writes
   cannot be proved discoverable from this watermark alone. A finite overlap
   window cannot guarantee arbitrarily late writes.
2. **No verified logarithmic shard router or k-way live merger exists yet.**
   Upstream shard timestamp metadata is not proof of disjoint actual message
   ranges. Overlapping or mutable historical shards can invalidate a binary
   search. No fallback scans are enabled.
3. Initial import now uses a separate rowid-keyset reader (128 rows per batch).
   It does not require the live sort-sequence composite index. A one-time cursor
   migration restarts incomplete imports without replacing first-seen bodies.
   Optional TEXT/BLOB storage is supported for packed/compressed fields.
4. Full nickname history, persistent runtime counters, full complexity CI,
   live sleep/restart/late-write tests and performance budgets remain incomplete.
5. Live MCP status now confirms `source_available:true`, but reports
   `incompatible_session_range_index`. One user-approved group has completed
   historical indexing and is queryable; real-time ingestion remains disabled.
   The user reported disabling SIP themselves; no agent SIP modification was
   performed. Key lifetime depends on account/key/encryption changes, not a
   guarantee that extraction is needed exactly once forever.
6. Local-signature TCC/Keychain continuity, sandbox helper execution and MCP
   media clients require installed UI validation. WeatherKit is disabled in
   the ad hoc build; official capabilities must not be assumed preserved.

The complexity target remains `O(1 + log S + C + Δ log F)`, without steady
`O(A)` or `O(M)`. Tests must not replace that target with current behavior.
The ordinary upstream monitor and cache code remains vendored but is not used
as the production synchronization path.

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
