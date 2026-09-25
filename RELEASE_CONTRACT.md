# Windows Release Contract

Der Windows-Runner liest für Updateprüfungen ausschließlich das veröffentlichte `latest.json` dieses Release-Repositories.

Pflichtfelder:

- `appName`: Produktbezeichnung.
- `version`: veröffentlichte Windows-Runner-Version.
- `versionCode`: monoton steigende numerische Release-ID.
- `downloadUrl`: direkte HTTPS-URL zum veröffentlichten EXE-Artefakt.
- `sha256`: SHA-256 der exakt veröffentlichten EXE.
- `notes`: kurze Release-Notiz.

Der Self-Updater muss vor einem Austausch mindestens Version, Download und SHA-256 prüfen. Der vorhandene Austausch-/Backup-/Rollback-Mechanismus bleibt alleiniger Installations-Owner.

Das Release-Repository enthält keine Secrets, privaten Schlüssel, Passwörter oder eingebetteten Zugangsdaten.
