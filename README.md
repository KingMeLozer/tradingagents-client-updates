# tradingagents-client-updates

Public, read-only update feed for the TradingAgents Windows setup sold by Sina Gharavi.

- `manifest.json` - the current release: version, pinned TradingAgents commit, SHA-256 of every file, release notes.
- `manifest.json.minisig` - minisign (Ed25519) signature over `manifest.json`.
- `update-pubkey.pub` - the public key. The same key is baked into each client's installer.
- `releases/<version>/` - the changed files for each release after the baseline. Release 1.0.0 is the baseline that ships inside the installer, so its files are not hosted here.

A client PC reads this feed only when its user double-clicks "Check for updates". The script checks the signature and each file's SHA-256, shows the release notes and asks for confirmation before changing anything. Nothing here can reach into anyone's computer; there is no inbound connection, no telemetry and no secrets in this repo.

Verify a manifest yourself: `minisign -Vm manifest.json -p update-pubkey.pub`
