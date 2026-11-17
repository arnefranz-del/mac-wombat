# Mac Wombat roadmap · Fahrplan

Use [GitHub Issues](https://github.com/arnefranz-del/mac-wombat/issues) for individual work and [milestones](https://github.com/arnefranz-del/mac-wombat/milestones) to track progress. The [19 November 2026 source-preview checkpoint](https://github.com/arnefranz-del/mac-wombat/milestone/1) is an internal review date.

| Priority | Work | Done when |
| --- | --- | --- |
| P0 | Keep clean source builds and data handling reliable | Test Intel and Apple Silicon on the candidate commit. Verify CSV, SQLite backup, and reset behavior with disposable fixtures. Record runner failures separately from test failures. |
| P1 | Review the DE/EN website and publish after approval | The staging build includes all four operator pages. Canonicals, language switches, build links, and response headers are checked on the published routes. |
| P1 | Exercise the app on physical Intel and Apple Silicon Macs | Record OS and hardware, sleep/wake, Wi-Fi/Ethernet transitions, restart continuity, CSV, login approval, and local update/rollback. |
| P1 | Collect source-preview feedback | Log independent build results and reproductions in the issue tracker. Acknowledge, label, and resolve reports with test evidence. |
| P2 | Validate long recordings and recovery | Measure CPU, resident memory, database growth, and export latency over extended runs. Define recovery behavior after persistent storage failures. |
| P2 | Add English UI localization | Localize the embedded UI, accessibility text, and help. Verify on-device language switching, dates, and units. |

Mac Wombat is the source preview in this repository. Home Wombat is a separate experiment. Work on a signed download would require a separate distribution decision and verified signing, notarization, and Gatekeeper checks. The [release checklist](Documentation/Public/RELEASE-CHECKLIST.md) captures those checks.

## Zusammenarbeit

Bitte Hardware, macOS-Version und Quellstand zu unabhängigen Tests angeben. Öffentliche Fehlerberichte sollten synthetische Messdaten verwenden. Die zugehörigen Issues halten Abnahmekriterien und Ergebnisse fest.
