# Contributing

## Layout

| Path | What it is |
|---|---|
| `Sources/HandoffCore` | the engine: account discovery, planning, moves, receipts, recovery, the CLI |
| `Sources/claude-handoff` | the CLI entry point |
| `Sources/ClaudeHandoff` | the menu bar app, which runs the bundled CLI for every operation |
| `Tests/HandoffCoreTests` | the engine behaviour suite (Swift Testing, under `Engine`) and the runtime unit tests |

## Tests

```bash
swift test --skip Engine                 # runtime unit tests
scripts/test-engine.sh                   # the engine behaviour suite
swift test --filter 'Engine/Receipts/'   # one suite while you work on it
```

The behaviour suite is the `Engine` suite in `Tests/HandoffCoreTests`, one nested suite per area (Accounts, Moves, Inventory, Receipts, Restarts, Cloud, CLI, MenuBar). `scripts/test-engine.sh` builds it once with optimisation and runs each suite as its own test process, several at a time (`JOBS` sets how many); CI's `engine` job runs the same script. The tables the tests swap (`fs`, `process`, `childProcess`, `cloudFetch`) are process-global, so suites run in parallel processes, never parallel threads.

Every test runs inside the `Sandboxed` trait, which gives it fresh native tables and a temporary `HOME`. Native Desktop commands and the keychain fail unless the test mocks them. `Support/` holds the fixture (`home()` and friends), the assertion helpers and the crash fence that stands in for a process killed mid-move.

Ground rules:
- Tests use a synthetic `HOME` and their own `TMPDIR`.
- Never point a test at real Desktop data.
- App control and cloud calls are mocked.
- Claims about macOS or Claude behaviour name the Claude Desktop and Claude Code versions they were checked against.

## Repository settings

`tools/github-setup` checks the GitHub repository against the standard settings and prints what it would change. Run it with `--apply` to make those changes.

## Releasing

1. Push a `vX.Y.Z` tag from `main`. Minor and patch must stay under 100.
2. `.github/workflows/release.yml` then:
   - runs the tests;
   - builds the universal app and signs it with Developer ID;
   - notarizes and staples the app and the DMG;
   - signs the DMG for Sparkle;
   - publishes a GitHub release with the DMG and `appcast.xml`.

The tag is the only place a version is set. In the repository, `Version.swift` stays at `0.0.0-dev`. The release build writes the tag's version into the app and its build number, `major×10000 + minor×100 + patch`, which Sparkle uses to tell that a release is newer. Installed apps read updates from `releases/latest/download/appcast.xml`.

Repository secrets:

| Secret | Holds |
|---|---|
| `DEVELOPER_ID_P12` | base64 of a `.p12` with the *Developer ID Application* certificate and its private key |
| `DEVELOPER_ID_P12_PASSWORD` | that `.p12`'s password |
| `APPLE_TEAM_ID` | the 10-character team ID |
| `NOTARY_KEY_P8` | base64 of an App Store Connect API key (Users and Access › Integrations › Team Keys, Developer role) |
| `NOTARY_KEY_ID` | that key's ID |
| `NOTARY_ISSUER_ID` | the issuer ID above the team keys list |
| `SPARKLE_ED_PRIVATE_KEY` | the EdDSA private key from Sparkle's `generate_keys -x` |

The `SPARKLE_PUBLIC_KEY` variable (not a secret) is built into the app as `SUPublicEDKey`. Changing it strands every installed copy, so back up the private key. Sparkle's tools are under `.build/artifacts/sparkle/Sparkle/bin` after a `swift build`.
