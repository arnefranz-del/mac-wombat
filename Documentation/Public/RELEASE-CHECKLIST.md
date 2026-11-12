# Release checks

## Source preview

- [ ] Fresh clone builds and passes tests.
- [ ] README documents what is measured, supported systems and how to report issues.
- [ ] Final tree excludes credentials, personal data, private Git history, local reports and runtime artifacts.
- [ ] License and asset provenance are documented.

## Public download

- [ ] Test on supported Intel and Apple Silicon versions, including first start, updates, rollbacks and saved history.
- [ ] Verify Sleep/Wake and optional launch at login on the signed artifact.
- [ ] Verify Developer ID, hardened runtime, notarization and a normal Gatekeeper first launch.
- [ ] Attach checksums and release notes to the exact source revision.
## Public website

- [ ] Confirm actual site operator and required privacy information.
- [ ] Verify both language routes, actual links and hosting headers.
