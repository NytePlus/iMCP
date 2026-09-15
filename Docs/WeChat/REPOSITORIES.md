# Forks and backend submodule

| Repository | Upstream | Integration branch |
| --- | --- | --- |
| `NytePlus/iMCP` | `mattt/iMCP` | `codex/wechat-integration` |
| `NytePlus/wx-cli` | `pandorafuture/wx-cli` | `codex/imcp-wechat` |

The existing `Backends/WeChat` directory is the wx-cli submodule; its Cargo
workspace also contains `crates/imcp-wechat`. Swift remains in
`App/Services/WeChat`. Build paths are unchanged. The parent records an exact
backend commit. Cloning normally leaves the submodule detached at that commit;
this is intentional for reproducible builds.

## Clone and verify

```sh
git clone --recurse-submodules --branch codex/wechat-integration https://github.com/NytePlus/iMCP.git
cd iMCP
git submodule status
cargo test --manifest-path Backends/WeChat/Cargo.toml --locked -p imcp-wechat -p wx-db
SIGNING_IDENTITY='your Apple Development identity' bash Scripts/build-wechat.sh
```

Native macOS/Xcode is required for packaging. The build resolves pinned Swift
packages on first use and applies the checked-in MCP SDK compatibility patch.
Rust/FFmpeg build outputs, packaged apps and source-package caches are ignored.
Do not commit account databases, bookmarks, media, keys or private test output.

## Change the backend

```sh
git -C Backends/WeChat switch codex/imcp-wechat
# Edit and test; commit only intended source changes inside the submodule.
git -C Backends/WeChat add <changed-files>
git -C Backends/WeChat commit -m 'Describe backend change'
git -C Backends/WeChat push origin codex/imcp-wechat
# Only after the backend commit is available remotely:
git add Backends/WeChat
git commit -m 'Update WeChat backend revision'
git push origin codex/wechat-integration
```

`origin` points to each fork; `upstream` points to its official repository in
the development checkout. A fresh clone configures only `origin`: add the
corresponding upstream remote if needed. Fetch upstream explicitly, review and
test updates on the integration branches, then update the parent gitlink.
Do not use `git submodule update --remote` in release builds: it replaces the
reviewed pinned revision with a moving branch tip.
