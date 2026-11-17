# Contributing to Mac Wombat

Bug reports and pull requests are welcome in English and German.

## Report an issue

Include the commit or build number, macOS version, hardware architecture, expected result, and minimal steps with synthetic data. Use [GitHub Issues](https://github.com/arnefranz-del/mac-wombat/issues) for bugs and proposals. Describe the problem before starting a large change.

Keep process names, personal paths, IP addresses, traffic logs, credentials, and SQLite files out of public reports. Use [private reporting](SECURITY.md) for security issues.

## Make a change

- Start with the [local build guide](README.md#build-locally) and [architecture overview](Documentation/Public/ARCHITECTURE.md).
- Use temporary databases, isolated preference suites, and test services in automated checks. Preserve the difference between measured zero and an observation gap.
- Run `./Scripts/test.sh` for Swift changes. Run the relevant Python suites from the [installation guide](Documentation/Public/INSTALLATION.md) for packaging or installer changes.
- If you edit the website, update both language pages and run `python3 -m unittest discover -s Tests/WebsiteTests -v`. Check the [local preview](Documentation/Public/WEBSITE.md) with a keyboard and at desktop and mobile widths.
- In the pull request, list what you verified and which hardware or macOS combinations still need a check. Include a native screenshot using synthetic data for app UI changes.

GitHub runs checks on both Intel and Apple Silicon. Hosted Intel skips four bitmap capture tests because the virtual graphics driver aborts in Metal. Run the full suite on a physical Mac for UI work.

See the [roadmap](ROADMAP.md) for priorities and acceptance checks.
