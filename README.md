<h1 align="center">Claude Handoff</h1>

<p align="center"><strong>Take your Claude Code history with you when you switch accounts in Claude Desktop.</strong></p>

<p align="center"><a href="https://github.com/derek-miller/claude-handoff/releases/latest"><img src="https://img.shields.io/github/v/release/derek-miller/claude-handoff" alt="latest release"></a> <a href="https://github.com/derek-miller/claude-handoff/actions/workflows/ci.yml"><img src="https://github.com/derek-miller/claude-handoff/actions/workflows/ci.yml/badge.svg" alt="CI"></a> <a href="LICENSE"><img src="https://img.shields.io/github/license/derek-miller/claude-handoff" alt="MIT license"></a></p>

Sign Claude Desktop into a different account and the Code sidebar goes blank. Nothing was deleted: Desktop files every Claude Code session under the account and organization that started it, and only shows the one you're signed into. Claude Handoff moves those sessions to the account you're using now, verifies the result, and can undo the whole move.

It's a native macOS menu bar app with a CLI inside. Unofficial, and not affiliated with Anthropic.

## Install

macOS 13 or newer, Apple silicon or Intel.

1. Download `Claude-Handoff-<version>.dmg` from the [latest release](https://github.com/derek-miller/claude-handoff/releases/latest).
2. Drag **Claude Handoff** to Applications and open it. It lives in the menu bar and opens at login (turn that off in System Settings › General › Login Items).
3. Updates install from inside the app. **Check for updates** in the panel looks right away; otherwise it checks about once a day, and never while a move is running.

The app is signed with a Developer ID and notarized by Apple.

## Use it

1. Open the panel from the menu bar.
2. Under **From**, tick the accounts whose sessions you want. Accounts with nothing to move show a grey *no sessions* tag.
3. Under **To**, pick the account you want them in, then click **Move**.
4. Sign Claude Desktop into that account. The sessions are in the sidebar.

Moves stay on your Mac. Tick **Also archive old copies on claude.ai** to archive the old accounts' Remote Control copies as well. Claude has to be signed in to each old account for that, so the move can wait for a sign-in.

If a session is open in Desktop, the panel asks before restarting Claude, or you can move everything else and leave that one for later. **Undo last move** puts everything back.

Desktop sometimes leaves empty folders behind when you switch logins, which show up as duplicate accounts. **Clean up empty folders** sets them aside, and the ⓧ on an empty account removes just that one.

### Command line

The same engine runs the CLI. Link it onto your `PATH`:

```bash
ln -s "/Applications/Claude Handoff.app/Contents/MacOS/claude-handoff" /usr/local/bin/claude-handoff
```

| Command | What it does |
|---|---|
| `claude-handoff` | pick accounts interactively, move, print a receipt |
| `claude-handoff --from <match> --to <match>` | no picker; match on email, org name or uuid prefix, repeat `--from` for several |
| `claude-handoff --dry-run` | show the plan and write nothing |
| `claude-handoff undo` | restore the last move |
| `claude-handoff accounts` | list accounts and their sessions (`--json` for scripts) |
| `claude-handoff tidy` | set aside empty folders Desktop left behind (`--pair <account>/<org>` for one) |
| `claude-handoff --cloud` | also archive the source account's Remote Control copies once the local move checks out |

`finish`, `sweep`, `restart` and `keep-local` deal with sessions held by a running Desktop. `claude-handoff --help` covers every flag.

## How a move works

A Claude Code session in Desktop is three things on disk:

- the transcript, in `~/.claude/projects`, which every account shares;
- a sidecar folder next to it;
- a small record under `~/Library/Application Support/Claude/claude-code-sessions/<account>/<organization>`, which is what puts it in one sidebar.

A move only touches the record. It writes the record into the destination with the same session id, checks the transcript and sidecars are unchanged, then parks the original in quarantine so undo can restore it. No transcript is copied, merged or uploaded, and a moved session continues where it left off under the new account.

A session moves only when it's safe to:

- no running worker owns it;
- its forks, parent and scheduled-task family can move together;
- the destination doesn't already hold a conflicting copy.

Anything that fails a check stays where it is and is listed with the reason.

A single receipt tracks each move. Records are written to a temp file and published with an atomic link, so they are never half-written. An interrupted move picks up where it stopped the next time you run anything.

### What it touches

- **Always:** its own folder, `~/Library/Application Support/claude-handoff`, which holds receipts, quarantine, a planning cache, a lock and diagnostics.
- **A move, undo or finish:** Desktop's session records and scheduled-task registries.
- **When you approve it:** quitting and reopening Claude Desktop.
- **Removing an empty account or cleaning up:** that account's folders under Desktop's session, agent, plugin-list, skills and scratch areas, moved into `leftovers/` in its own folder. A scratch folder that a session still works in stays put.
- **With `--cloud`, or the panel's *Also archive old copies on claude.ai* checkbox (off by default):** Desktop's claude.ai session, read from Keychain into memory and sent only to `claude.ai`, to archive the old account's Remote Control copies. It is never stored.
- **Updates:** the app reads `appcast.xml` from this repository's latest release, downloads the DMG it names, checks its EdDSA signature and swaps itself in.

Nothing else leaves your Mac, and a move uses no model tokens.

## FAQ

**Is it a move or a copy?** A move. Each session lives under one account at a time. To take it back, move it back.

**Can I keep chatting in a moved session?** Yes. It keeps its id, and your next message goes through the account you're signed into. History moved into a Team or Enterprise organization becomes that organization's data.

**My sessions vanished after an update or sign-out. Will this bring them back?** Only if their records still exist under another account. `claude --resume` in a terminal still lists every transcript either way.

**Does the CLI or VS Code have this problem?** The `claude` CLI doesn't; it reads the shared transcripts whoever is signed in. The VS Code extension keeps its own index, which this doesn't touch.

**Windows or Linux?** Not yet. Desktop uses the same folder layout there, so the engine needs only platform paths and process checks.

## Limits

- Remote Control and artifact ownership stay with the original account.
- The `--cloud` path uses private claude.ai endpoints and stops if their shape or auth changes.
- Desktop's file layout is undocumented and can change with any release.

## Build from source

```bash
swift build -c release                # CLI at .build/release/claude-handoff
VERSION=0.0.0 scripts/build-app.sh    # ad-hoc signed dist/Claude Handoff.app
swift test
```

[CONTRIBUTING.md](CONTRIBUTING.md) covers the test suite and releases.

## Credits

Inspired by [vitaliyhayda/claude-transplant](https://github.com/vitaliyhayda/claude-transplant), which worked out how Desktop stores sessions and how to move them safely. Claude Handoff's Swift engine began as a port of that project's Node engine, and its behaviour suite as a port of that engine's tests.

MIT licensed. See [LICENSE](LICENSE).
