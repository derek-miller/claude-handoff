# Contributing

## Layout

| Path | What it is |
|---|---|
| `Sources/HandoffCore` | the engine: account discovery, planning, moves, receipts, recovery, the CLI |
| `Sources/claude-handoff` | the CLI entry point |
| `Sources/ClaudeHandoff` | the menu bar app, which runs the bundled CLI for every operation |
| `Sources/handoff-parity` | a debug server that lets the Node test suite drive the Swift engine |
| `Tests/HandoffCoreTests` | Swift unit tests for the runtime |
| `Tests/Reference` | the Node reference engine and its test suite |
| `Tests/Parity` | the harness that runs that suite against the Swift engine |

## Tests

```bash
swift build --build-tests && swift test
```

The behavioural suite lives in `Tests/Reference/engine.test.js`. CI runs it twice: once against the Node reference engine, and once with every engine call served by Swift.

```bash
(cd Tests/Reference && npm test)
swift build -c release -Xswiftc -enable-testing --product handoff-parity
node Tests/Parity/run.mjs .build/release/handoff-parity        # add 1/6 … 6/6 to run a shard
```

A change to engine behaviour goes into both engines in the same pull request, or the parity job fails. Set `PARITY_STATS=/tmp/parity.jsonl` to record which calls ran in Swift and which fell back to Node.

Ground rules:
- Tests use a synthetic `HOME` and their own `TMPDIR`.
- Never point a test at real Desktop data.
- App control and cloud calls are mocked.
- Claims about macOS or Claude behaviour name the Claude Desktop and Claude Code versions they were checked against.

## Repository settings

`tools/github-setup` checks the GitHub repository against the standard settings and prints what it would change. Run it with `--apply` to make those changes.

## Releasing

1. Bump `Tests/Reference/package.json` and `Sources/HandoffCore/Engine/Version.swift` together. Parity checks the receipt writer version.
2. Push a `vX.Y.Z` tag.
3. `.github/workflows/release.yml` then:
   - runs the tests;
   - builds the universal app and signs it with Developer ID;
   - notarizes and staples the app and the DMG;
   - signs the DMG for Sparkle;
   - publishes a GitHub release with the DMG and `appcast.xml`.

Installed apps read updates from `releases/latest/download/appcast.xml`.

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
