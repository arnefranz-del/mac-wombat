# Privacy · Datenschutz

Mac Wombat has no account, telemetry, cloud sync or automatic uploads. The app reads physical interface counters. It does not capture packet payloads or browser history.

- Usage rows, observation times and saved measurement names are stored in `~/Library/Application Support/Wombat/usage.sqlite`.
- macOS preferences store display settings and the selected tab. The optional launch-at-login setting is managed by macOS.
- The Apps view uses a limited `nettop` snapshot while visible. Process names and counters can be sensitive. They are not stored as per-app history.
- Exported CSV files are independent copies. Reset, database migration and local update operations can leave backups. Removing the app leaves preferences, usage data, backups and exported files in place.

GitHub is a separate service. Avoid attaching production data to issues. [GitHub privacy statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement)

## Deutsch

Die Statistik, Aufzeichnungszeiten und gespeicherten Messungen liegen im lokalen Datenordner. Mac Wombat erfasst Schnittstellenzähler ohne Paketnutzlasten. Die Programme-Ansicht verarbeitet bei Sichtbarkeit eine begrenzte Momentaufnahme. Sie speichert keine Programm-Zeitreihe.

CSV-Dateien sind eigenständige Kopien. Zurücksetzen, Datenbankmigration und lokale Updates können Sicherungen anlegen. Beim Entfernen der App bleiben Statistik, Sicherungen, Einstellungen und Exporte erhalten. Vor einem öffentlichen Fehlerbericht bitte personenbezogene Angaben und echte Messdaten entfernen.
