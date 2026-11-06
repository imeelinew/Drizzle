# Drizzle

Drizzle is a lightweight macOS menu bar quota viewer supporting Codex, Claude, Cursor, z.ai, OpenRouter, OpenCode Go, DeepSeek, and Google AI Pro.

## Build locally

Requires macOS 15 or later and Xcode with the macOS SDK.

```sh
xcodebuild -project Drizzle.xcodeproj -scheme Drizzle -configuration Debug -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
```

## Configuration

Choose **Configuration File...** from the menu to open `~/Library/Application Support/Drizzle/config.toml` in [CotEditor](https://coteditor.com). If CotEditor is unavailable, the system's default TOML editor is used; TextEdit is the fallback when there is no file association. Drizzle does not create a settings window.

On first launch, Drizzle creates a configuration file containing all fields and comments. Removing a line restores its default; changes take effect on save without restarting. See [docs/config.example.toml](docs/config.example.toml) for a complete example.

When upgrading from an older version with only `config.json`, the first launch migrates settings and credentials into `config.toml` and deletes the old JSON file. Thereafter `config.toml` is authoritative.

- `launchAtLogin`: launch at login.
- `refreshIntervalSeconds`: refresh interval; `0` (manual), `60`, `300`, `900`, or `1800`.
- `refreshOnOpen`: refresh when opening the menu.
- `enabledProviders`: enabled providers; an empty array disables all. List order does not change menu order.
- `providerOrder`: top-to-bottom provider order for tabs and quota cards. Enabled providers omitted from the list follow in their default order; listed but disabled providers are ignored.
- `menuBar.provider`: provider displayed in the menu bar.
- `menuBar.metric`: quota metric displayed for that provider; see the table below.
- `menuBar.percentMode`: `remaining` or `used`; balance displays are unaffected.
- `credentials`: API keys and Cursor Cookie; z.ai region supports `global` and `bigmodel-cn`.

Codex and Claude continue to use local login credentials. When the Cursor Cookie is empty, Drizzle uses Cursor's local login. When the OpenCode Go or DeepSeek API key is empty, it uses the previously supported environment variables. z.ai and OpenRouter API keys must be supplied in the file.

OpenCode Go supports two authentication methods; quota requests and parsing are adapted from CodexBar (`664311fc8`):

- **API**: set `credentials.openCodeGoKey`, or leave it empty to use `OPENCODE_API_KEY`. Displays the API's five-hour, weekly, and monthly quotas.
- **Console**: set `credentials.openCodeGoCookie` to a Cookie header or a browser-copied cURL request containing `__Host-console_session`. A nonempty value takes priority over API authentication. If it expires, an error is shown; sign in again to [OpenCode Console](https://opencode.ai/console) and update the Cookie.
- `credentials.openCodeGoWorkspaceID`: optional `org_…` or `wrk_…` workspace ID. If empty, the first workspace in the list is used, as in CodexBar. Accounts with multiple workspaces should specify the workspace containing the subscription.

The Console path reads live account quotas. When the API does not provide a monthly reset time, the subscription period end is used. Only quota windows actually returned by the API are shown; local usage and cost history are not read.

| Provider | `menuBar.metric` |
| --- | --- |
| `codex`, `claude`, `zai` | `session`, `weekly` |
| `cursor` | `total`, `cursor`, `thirdParty`, `grokBot` |
| `openrouter` | `keyLimit` |
| `opencodego` | `session`, `weekly`, `monthly` |
| `deepseek` | `balance` |
| `googleaipro` | `quota`, `session`, `weekly` |

Google AI Pro coding quotas are adapted from CodexBar `b9ba2da9a`'s Antigravity implementation. Google has migrated consumer AI Pro / Ultra accounts away from Gemini CLI OAuth. This provider shows **Antigravity coding quotas**, excluding Gemini web chat, image, and video generation limits. See [Google's migration notice](https://developers.google.com/gemini-code-assist/docs/deprecations/code-assist-individuals).

- Add `"googleaipro"` to `enabledProviders`. New configurations enable it by default; existing configurations keep their enabled provider list.
- Open the signed-in Antigravity app, or install Antigravity CLI and run `agy` in a terminal to sign in. CLI 1.1.11 or later supports `agy -p /usage --output-format json`, so the desktop app can remain closed.
- Displays the returned model groups, five-hour and weekly quotas, and reset countdowns. Older local interfaces expose per-model quotas instead. Disabled or unknown quotas are omitted rather than displayed as 100% remaining.
- Set `menuBar.provider = "googleaipro"` and `menuBar.metric = "quota"` to show the lowest remaining percentage across all returned quotas. `session` and `weekly` select the lowest remaining percentage within that cadence; unavailable cadences show no value. `percentMode = "used"` displays the corresponding used percentage.
- CLI queries only request usage reports and send no model prompts. Passive refreshes do not open browser sign-in or update the CLI. Google cookies and OAuth credentials are not stored in Drizzle configuration. `ANTIGRAVITY_CLI_PATH` can specify the CLI executable; invalid overrides produce an error.

Configuration uses TOML and supports `#` comments, `[sections]`, multiline arrays, and trailing commas. Strings can use `"…"`, `'…'`, or `"""…"""` (useful when pasting cURL). The parser implements only the syntax needed for configuration; inline tables, arrays of tables, floating-point values, and dates cause an error with a line number. Missing fields use defaults. Unknown fields are ignored and reported with their line numbers in the menu. Invalid types or values prevent loading; if a runtime edit is invalid, the last valid configuration remains active and the menu shows the error until the file is corrected and saved.

The configuration contains credentials. On creation, the directory is mode `700` and the file is mode `600`, accessible only to the current user. Errors do not print credentials.

## Updates and releases

Drizzle uses Sparkle 2 with EdDSA-signed updates; the appcast is [docs/appcast.xml](docs/appcast.xml).

On a Mac with an Apple Development certificate, the publisher runs `scripts/release.sh <version> <build-number>`. The script builds, verifies, and uploads an app ZIP. After the release is published, GitHub Actions signs the archive and updates the appcast.

Sparkle update signing does not require a paid Apple Developer Program membership. Developer ID signing and notarization do require a paid membership. macOS Gatekeeper may warn about or block the first download of an unnotarized app; EdDSA protects subsequent updates only.

## Third-party projects

Drizzle uses some implementation and assets from [CodexBar](https://github.com/steipete/CodexBar) and integrates [Sparkle](https://github.com/sparkle-project/Sparkle). See [NOTICE](NOTICE) and the [Sparkle license](THIRD_PARTY_LICENSES/Sparkle-LICENSE) for licenses and attribution.

Provider names and logos identify supported services only. Drizzle is not affiliated with those providers.
