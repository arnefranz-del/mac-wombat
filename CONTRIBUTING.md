# Contributing to Mac Wombat

Bug reports and pull requests are welcome. English and German both work.

- For a bug, include the Wombat build, macOS version, architecture, expected behavior and steps to reproduce with synthetic data.
- For an enhancement, open an issue and describe the problem and expected result before starting a large change.
- Run `./Scripts/test.sh` and the Python tests for any affected packaging or installation code. See the [build guide](README.md#build-locally).
- Use temporary databases, isolated preference suites and fake services in tests. Preserve recorded gaps and the meaning of local interface counts.
- Keep personal file paths, process names, traffic logs, IP addresses, credentials and SQLite files out of issues and pull requests. Report security problems [privately](SECURITY.md).

Project priorities and acceptance checks are in the [roadmap](ROADMAP.md).
