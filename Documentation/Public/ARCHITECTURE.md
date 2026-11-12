# Architecture and measurement limits · Architektur und Messgrenzen

`WombatCore` reads interface counters, calculates rates and manages the SQLite history, timer and CSV export. `Wombat` presents the results in an AppKit menu bar item and a SwiftUI popover. `WombatProbe` is a developer tool that uses the same reader and rate calculation. The package has no external Swift dependencies.

The sampler reads 64-bit macOS counters on active physical Wi-Fi and Ethernet interfaces. It calculates deltas using monotonic time and resets its baseline across interface changes, implausible intervals and counter resets. Accepted deltas are assigned to UTC minutes, with hour totals derived from the recorded intervals. Calendar views use local time and report observation coverage. Sleep, downtime and rejected intervals leave gaps.

The counters include local traffic and can include VPN traffic carried on physical interfaces. A network usage total does not measure only internet payloads and is unsuitable as a billing record. The Programme tab runs bounded `nettop` queries while visible. Its snapshot has different coverage from interface counters and is not stored as per-app history.

## Deutsch

Der Messkern liest 64-Bit-Zähler aktiver physischer Schnittstellen. Ungültige Zeitabstände, Schnittstellenwechsel und Zählerrückgänge setzen die Messbasis neu. Akzeptierte Deltas werden auf UTC-Minuten verteilt und für Kalenderansichten nach Ortszeit ausgewertet. Erfassungslücken bleiben sichtbar.

Lokaler Verkehr und VPN-Transport auf physischen Schnittstellen können enthalten sein. Programme sind eine begrenzte `nettop`-Momentaufnahme. Diese Werte bilden den gesamten Schnittstellenverkehr nicht vollständig ab.
