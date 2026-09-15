# WeChat acceptance coverage

## Latest protocol evidence

Member follow-up: 309 unique real member IDs across four pages, no duplicates;
1,001-member synthetic pagination/alias/scope/revocation regression passed.
Exact source query-plan evidence is `SCAN SessionTable` plus temporary ORDER BY
B-tree: the required timestamp index is absent. C-LIVE remains blocked under
the approved read-only/no-scan contract. This is not an expected-pass live test.

WXGF follow-up: after the user selected the configuration file, the real image
sample now successfully converts to PNG (142,588 bytes), with `image/png`, valid
PNG signature and MCP resources/read success. C-MEDIA positive single-image path
is covered by the protocol probe; animated GIF, expiry/revocation and size-limit
UI acceptance remain gaps. Prior missing-key/WXGF failures below are historical.

After the user's local approval, `Scripts/probe-wechat.py` passed positive
history reads, adjacent-page ID separation, combined time/member/type filters,
exclusive end, real file/link/image samples, context anchor and updates retry.
Keyword results and 500 member entries were observed; full relevance and member
pagination remain unverified/incomplete. Voice has no sample. Image extraction
failed with missing V2 AES key, so C-MEDIA is still a gap, not a pass. These are
MCP fact-checks after user actions, not automated native UI test completion.

| Condition | New evidence | Remaining gap |
|---|---|---|
| C-INDEX | Real approved group reached ready after rowid/TEXT fixes | Restart/large-history performance budgets |
| C-FILTER | Combined AND, multiple types and half-open time checks pass | Comprehensive keyword relevance and voice positive case |
| C-CURSOR | Real adjacent pages and retry checked | Concurrent new source writes/live path |
| C-MEDIA | Missing V2 key reproduced | Narrow config authorization and successful resource/read |
| C-LIVE | Still explicitly disabled | Source session range index and durable change routing |

Role: owner of the local WeChat account. Existing Rust tests provide component
evidence only. The native UI journeys below are **not run**; no API call stands
in for choosing a directory, granting access, revoking or deleting in the UI.

| Condition ID | Goal / condition | Positive test | Negative test | User action | API support | Acceptance signal | Gap / risk |
|---|---|---|---|---|---|---|---|
| C-ACCESS | Only approved chats visible | ST-01 approve | ST-01 cancel/revoke | Local approval dialog | fact-check MCP | Denied IDs/content absent | UI not run; Rust revocation tested |
| C-KEY | Reuse key without repeated SIP changes | ST-02 valid key/restart | ST-02 invalid key | Directory picker and setup | fact-check status | Valid key works with SIP enabled | Real key unavailable |
| C-FILTER | AND categories, OR members/types | ST-03 match | ST-03 excluded boundaries | MCP client request | fixtures setup | Exact expected IDs | Component test only; type matrix incomplete |
| C-CURSOR | No drift or unauthorized cursor reuse | ST-04 new inserts | ST-04 forge/account/revoke | MCP client pagination | external-event insert | Stable IDs; invalid cursors rejected | Component tests; cross-shard source missing |
| C-INDEX | No partial keyword results | ST-05 import complete | ST-05 import pending | Approve and search | fact-check state | `indexing` until complete | UI/source not run |
| C-LIVE | Discover every eligible source update | ST-06 new/same-time/late | ST-06 idle/incompatible | Receive actual WeChat messages | external-event sender | No loss; strict query counts | BLOCKED: live engine incomplete |
| C-SCALE | No steady A/M scan | ST-07 A/M/F scale | ST-07 bad source indexes | Monitor status | fixture setup/counters | Contract and no fallback | Guard unit test only; scale CI absent |
| C-MEDIA | Approved, bounded expiring media | ST-08 valid media | ST-08 revoked/expired/oversize | Request/open resource | fixture setup | Resource usable only while allowed | Path unit test only; client/UI absent |
| C-RETENTION | Preserve seen messages | ST-09 revoke/regrant | ST-09 explicit delete | Settings revoke/delete | fact-check archive | Retain or remove as selected | Full source/UI absent |
| C-PACKAGE | Usable sandboxed app | ST-10 launch/restart | ST-10 helper failure | Open app/settings | codesign fact-check | UI/helper work; no updater | Build/signing not runtime proof |

## Native system-test procedures

All journeys use the owner account and staged app, with no production installation
replacement until acceptance. Record screenshots and sanitized logs in a local
evidence directory; do not include keys or unrelated conversation content.

- ST-01: approve one local candidate; cancel another; query both; revoke first.
  Expect only the approved chat before revoke and neither after it.
- ST-02: select a source directory and enter a valid test key; restart with SIP
  enabled. Repeat with an invalid key. Expect reuse vs clear setup error.
- ST-03: seed text/file/link/image/member/time fixtures; submit combined MCP
  filters. Expect OR within lists, AND between categories and `[start,end)`.
- ST-04: fetch a page, receive a newer message, continue/retry; modify the cursor,
  change account and revoke/regrant. Expect stable pagination and rejected reuse.
- ST-05: approve a large group and search immediately, then after completion.
  Expect progress / indexing first and complete results later.
- ST-06: receive ordinary, equal-sort, late and old-shard messages; sleep/restart.
  Expect eventual exactly indexed stable IDs (updates may redeliver). Currently
  blocked by missing live engine, not marked expected-pass.
- ST-07: repeat fixed Δ for A=1/100/10000, M=1000/1000000 and increasing F;
  inspect counters/plans, then remove fixture indexes. Expect strict bounded
  work or explicit incompatibility, never full-scan fallback.
- ST-08: retrieve image/audio/file; wait for expiry; revoke; try path escape and
  oversized media. Expect authorized native resource or clear denial.
- ST-09: delete a source message, revoke/regrant, then explicitly clear archive
  in Settings. Expect first-seen content retained until explicit deletion.
- ST-10: launch signed app, enable service, quit/restart and sleep/wake; inspect
  helper sandbox and resources. Expect functioning app, no official auto-update.

No recording or UI pass evidence has been collected. Relevant component tests:
`imcp-wechat::tests`, `imcp-wechat::media::tests`,
`wx-db::incremental::tests`. Passing upstream decoding tests does not prove
real-time complexity, source compatibility or installed application usability.
