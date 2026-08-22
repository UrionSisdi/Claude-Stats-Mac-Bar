# Claude Stats

A minimal macOS menu bar app for Claude Code: subscription limits and what your usage
would have cost at API prices.

## What it shows

**Subscription limits** — from `https://api.anthropic.com/api/oauth/usage`, the same source as
`/usage` in the CLI: the 5-hour session window, the weekly cap, and per-model weekly windows
(Opus, Fable, …) with reset times. The session percentage also sits next to the menu bar icon.

**Cost at API prices** — from local `~/.claude/projects/**/*.jsonl` logs: today, 7 days, 30 days,
all time, plus a per-month breakdown and the top models over 30 days. Input, output, cache reads
and cache writes (5-minute and 1-hour separately) are all counted.

English and Russian, following the system language by default. Costs show in USD or RUB —
by default matching the language — with the USD/RUB rate pulled once a day from the
Central Bank of Russia (falling back to `open.er-api.com`). Both are switchable in the menu.

## Install

```bash
./scripts/make-signing-cert.sh   # once: self-signed code signing certificate
./build.sh install               # build, install to /Applications, launch
./build.sh                       # build only, into build/ClaudeStats.app
```

The certificate matters: with an ad-hoc signature macOS cannot remember "Always Allow" for the
keychain, so it asks on every single read. With a stable signature you approve access once.

On first launch macOS asks for access to the `Claude Code-credentials` keychain item — choose
**Always Allow**. The token is read only; the app never refreshes or rewrites it. If the token
expires, the last known limits stay on screen until `claude` refreshes the login itself.

Launch at login is enabled on first run (`SMAppService`) and can be turned off in the menu.
Data refreshes every 10 minutes and when the menu opens.

## Debugging

```bash
./build/ClaudeStats.app/Contents/MacOS/ClaudeStats --dump            # local stats to stdout
./build/ClaudeStats.app/Contents/MacOS/ClaudeStats --dump --limits   # also fetch limits
```

## Layout

| File | Purpose |
| --- | --- |
| `LocalUsage.swift` | jsonl parsing, dedup by `message.id`, aggregation |
| `ScanCache.swift` | parse cache in `~/Library/Application Support/ClaudeStats` |
| `Pricing.swift` | per-model prices per 1M tokens |
| `UsageAPI.swift` | subscription limits request |
| `Credentials.swift` | OAuth token from the keychain |
| `Currency.swift` | currency preference and daily USD/RUB rate |
| `L10n.swift` | language preference and strings |
| `MenuView.swift` | the dropdown |

## License

[MIT](LICENSE)
