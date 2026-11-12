# Local build and updates · Lokaler Build und Updates

The source preview supports building on macOS 14 or newer with Swift 6 and Python 3. A public signed download is planned.

```sh
./Scripts/test.sh
python3 -m unittest discover -s Tests/InstallationTests -v
python3 -m unittest discover -s Tests/ReleasePreparationTests -v
./Scripts/build.sh
```

Open `build/products.noindex/Wombat.app` after the build. This is an ad hoc-signed local development build. Use the dedicated update workflow below for a Mac with an existing Wombat installation.

## Existing Wombat installation

Back up any measurements you want to preserve. Review the installer dry run before replacing the installed app.

```sh
python3 Scripts/install.py --source build/products.noindex/Wombat.app --dry-run
```

Without `--dry-run`, the installer backs up usage data, closes running Wombat instances, replaces the app and retains a rollback copy. It checks the bundle identity and rejects a change of signing method. App versions can have different login registrations, so verify the launch-at-login state after updating.

### Launch at login after an update

If launch at login was enabled and macOS stops recognizing the entry, the installer prints a recovery hint. Open **Wombat → Einstellungen → Allgemein** and enable **Beim Anmelden starten**. If macOS asks for approval, use **Anmeldeobjekte öffnen** and approve the entry. The installer leaves activation to you.

### Autostart nach dem Update

War der Autostart aktiv und macOS erkennt ihn nach dem Update nicht mehr als aktiv, weist der Installer darauf hin. Öffne **Wombat → Einstellungen → Allgemein** und aktiviere **Beim Anmelden starten**. Falls macOS eine Freigabe verlangt, nutze **Anmeldeobjekte öffnen**.

## Compatibility

| Platform | Status |
| --- | --- |
| Intel, macOS 14.7 | Local builds and automated tests verified. Isolated update, saved measurement and rollback tested on the preceding Mac-only candidate. |
| Apple Silicon | Native runtime verification for this preview is open. |
| Signed distribution | Developer ID, notarization, Gatekeeper and clean-system testing are pending. |

See the [roadmap](../../ROADMAP.md) for the public distribution checklist.
