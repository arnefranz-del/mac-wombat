# Release checks

## Source preview

- [ ] Build and test the candidate revision from a fresh clone. Record macOS, architecture, SDK, and Swift version.
- [ ] Run the two-architecture GitHub workflow. Review skipped checks and runner capacity events.
- [ ] Check local sampling, saved measurements, CSV, and SQLite integrity using disposable data.
- [ ] Review measurement claims, build links, license, and asset provenance.
- [ ] Review the source tree for user data, credentials, and local artifacts.

## Website

- [ ] Test both languages by keyboard and at mobile and desktop widths.
- [ ] Assemble the product pages with the current operator pages using the [website guide](WEBSITE.md).
- [ ] After approved deployment, verify the legal and product routes, response headers, and differences between the staged and live content.

## Binary distribution, if planned

- [ ] Test first launch, sleep/wake, launch at login, local update, and rollback on physical Intel and Apple Silicon Macs.
- [ ] Verify Developer ID, hardened runtime, notarization, and a normal Gatekeeper first launch.
- [ ] Attach checksums and release notes to the exact source revision.
