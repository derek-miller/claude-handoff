# Security

Please report vulnerabilities privately through GitHub's advisory form, not in a public issue:

https://github.com/derek-miller/claude-handoff/security/advisories/new

## What the app reaches

- **Local moves** make no network calls.
- **Updates:** Sparkle fetches `appcast.xml` from this repository's latest GitHub release, about once a day and when you click Check for updates. It downloads only a DMG whose EdDSA signature matches the key built into the app.
- **`--cloud`, which the menu bar's Move always uses,** reads Claude Desktop's cookie database and its Safe Storage key from Keychain. Cookies are decrypted in memory, sent only to `https://claude.ai`, and never printed or written to disk. The source account's Remote Control copies are archived only after the local move is verified. Any change in authentication, organization, history or response shape stops the operation.
