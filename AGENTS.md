# Drizzle repository rules

- Do not modify any Xcode scheme settings without the user's permission
- Do not enable Debug Executable in any Xcode scheme without the user's permission
- Keep the app limited to Codex, Claude, Cursor, z.ai, OpenRouter, OpenCode Go, and DeepSeek
- Do not add test code, usage or cost history, cloud sync, plugins, notifications, shortcuts, or localization
- Keep update and release distribution work limited to the authorized Sparkle release flow, local installation with scripts/install.sh is also authorized
- Preserve existing uncommitted work and verify application changes with a build
- Do not launch the app during development verification. The user runs it from Xcode or runs scripts/install.sh, which builds Release, installs into /Applications, and launches the installed copy. Only run the installer when the user explicitly requests installation. Building, testing, and debugging are fine
