# Local build and updates

## Build the source preview

The app’s deployment target is macOS 14.0. The Mac doing the build must also support the installed Apple Swift 6 toolchain. Check `xcrun swift --version` and `python3 --version`. Use Command Line Tools with Swift 6 or an Xcode version that supplies it. [Apple's Xcode system requirements](https://developer.apple.com/xcode/system-requirements/)

Clone the repository using the [build instructions](../../README.md#build-locally) and run the checks from the repository root.

```sh
./Scripts/test.sh
python3 -m unittest discover -s Tests/InstallationTests -v
python3 -m unittest discover -s Tests/ReleasePreparationTests -v
python3 -m unittest discover -s Tests/WebsiteTests -v
./Scripts/build.sh
```

On a fresh Mac, open `build/products.noindex/Wombat.app`. The script produces an ad hoc-signed local build. Keep Gatekeeper enabled. For an existing Wombat installation, follow the workflow below.

## Update an existing installation

Keep a copy of any data you want to preserve. Review the installed app, source bundle, and destination with the installer dry run. Pass `--destination` if the existing `Wombat.app` is outside `/Applications`.

```sh
python3 Scripts/install.py --source build/products.noindex/Wombat.app --dry-run
```

Once the paths and signing identity are confirmed, repeat without `--dry-run`. The installer takes consistent SQLite backups, closes Wombat, and verifies the replacement. It retains the preceding app bundle in the path under `previous_bundle_backup` in the result. It rejects a change of signing method or identity.

### Launch at login after updating

In **Wombat → Einstellungen → Allgemein**, check **Beim Anmelden starten**. If macOS requests approval, choose **Anmeldeobjekte öffnen** and approve it in System Settings. The installer reports when a previously enabled item needs attention.

### Restore the previous app

Use the exact `previous_bundle_backup` app path from the successful update as the installer’s source. Start with a dry run.

```sh
python3 Scripts/install.py --source "/path/to/the/previous/Wombat-backup.app" --dry-run
```

Review the identity and destination, then repeat without `--dry-run`. The procedure restores the application bundle and preserves the current SQLite history. Database recovery is a separate operation. The installer writes consistent data snapshots before replacement, and the app keeps a backup before a schema migration or manual history reset. Check launch at login again after restoring the app.

## Compatibility

| Environment | Evidence |
| --- | --- |
| Intel, macOS 14.7 | Swift 6.0.3 local build and full automated suite, including native bitmap capture. |
| Hosted Intel, macOS 15.7.9 | Build, Swift tests with four native bitmap tests skipped, and Python checks. A prior hosted Intel job hit a Metal driver abort during bitmap capture. |
| Hosted Apple Silicon, macOS 15.8.2 | Build and full Swift suite with Python checks in [run 43214835228](https://github.com/arnefranz-del/mac-wombat/actions/runs/43214835228). |
| Physical Apple Silicon | Interactive launch, sleep/wake, login and update or rollback remain to be checked. |

On the later [run 43223912165](https://github.com/arnefranz-del/mac-wombat/actions/runs/43223912165), Intel passed. GitHub did not assign the Apple Silicon job to a hosted runner, so that job ended before running any steps. See the [roadmap](../../ROADMAP.md) for the remaining validation.

## Deutsch

Die App ist für macOS 14.0 oder neuer ausgelegt. Der Build-Mac braucht zusätzlich Apples Swift-6-Werkzeuge und Python 3. Prüfe die Werkzeugversion mit `xcrun swift --version` und folge der [Build-Anleitung](../../README.de.md#lokal-bauen).

Bei einer bestehenden Installation prüfst du Quelle und Ziel zuerst mit `python3 Scripts/install.py --source build/products.noindex/Wombat.app --dry-run`. Der Standardpfad ist `/Applications/Wombat.app`. Bei einer Installation an einem anderen Ort gib diesen Pfad mit `--destination` an. Nach der Prüfung startest du den tatsächlichen Austausch mit demselben Befehl ohne `--dry-run`. Das Skript sichert die Statistik und meldet den Pfad des vorherigen App-Pakets unter `previous_bundle_backup`.

Für ein Rollback gibst du dieses ältere App-Paket als `--source` an und beginnst wieder mit einem Dry Run. Der App-Tausch erhält die aktuelle Statistik. Datenbank-Sicherungen werden gesondert wiederhergestellt. Prüfe danach unter **Einstellungen → Allgemein** die Option **Beim Anmelden starten** und bestätige sie in den Systemeinstellungen, wenn macOS darum bittet.
