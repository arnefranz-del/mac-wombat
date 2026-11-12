# Security policy

Please [report vulnerabilities privately on GitHub](https://github.com/arnefranz-del/mac-wombat/security/advisories/new). Include the affected revision, macOS version, expected behavior and a minimal synthetic example. Keep network identifiers, personal paths, credentials, exports and databases out of public reports.

The active source-preview branch is `main`. There is currently no supported public binary release.

Mac Wombat reads counters and makes bounded local `nettop` queries. It has no system extension or firewall. It runs under the logged-in user account. Source-built bundles are ad hoc signed for local development. Leave Gatekeeper settings in place.
