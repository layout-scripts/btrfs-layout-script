# snapper-layout-script

`setup-snapper.sh` macht aus einem Debian-, Ubuntu- oder anderen Debian-basierten Server, dessen Root-Dateisystem bereits von einem benannten Btrfs-Subvolume läuft (z.B. via [btrfs-layout-script](https://github.com/layout-scripts/btrfs-layout-script)), ein SUSE-artiges Snapper-Setup: automatische Timeline-Snapshots, Snapshots rund um jede `apt`-Paketänderung und Snapshots, die direkt aus dem GRUB-Menü über `grub-btrfs` bootbar sind.

## Sprachen

- [English](README.md)
- Deutsch (diese Datei)
- [Español](README.es.md)

## Was das Skript tut

Auf einem Debian(-basierten) System, dessen `/` bereits auf einem benannten Btrfs-Subvolume liegt, macht das Skript Folgendes:

- Prüft, dass `/` Btrfs ist und von einem benannten Subvolume läuft (z.B. `@`); bricht mit Hinweis auf `btrfs-layout-script` ab, falls nicht.
- Installiert `snapper` und `inotify-tools` (von `grub-btrfsd` benötigt, um neue Snapshots zu erkennen), falls nicht vorhanden.
- Fragt in einem interaktiven Terminal ausdrücklich nach Bestätigung (Eingabe von "ja"), bevor irgendetwas verändert wird. Ohne Terminal (automatisierte Läufe) wird das übersprungen.
- Legt die Snapper-Konfiguration `root` an (idempotent — wird übersprungen, falls schon vorhanden); dabei entsteht `.snapshots` als nested Btrfs-Subvolume.
- Trägt `.snapshots` als eigenen Eintrag in `/etc/fstab` ein und mountet es. Dieser Schritt ist notwendig: Ein nested Subvolume bleibt ein leeres Platzhalterverzeichnis, bis es selbst gemountet wird — ohne diesen Schritt wären weder Snapshot-Inhalte durchsuchbar, noch würde `grub-btrfs` etwas finden.
- Setzt eine SUSE-artige Timeline-Policy in `/etc/snapper/configs/root` (`TIMELINE_CREATE`, `TIMELINE_CLEANUP`, `NUMBER_CLEANUP` sowie konservative `TIMELINE_LIMIT_*`-Werte für stündlich/täglich/wöchentlich/monatlich/jährlich).
- Installiert eigene `apt`-Hooks (`DPkg::Pre-Invoke`/`DPkg::Post-Invoke`), die rund um jede Paketänderung ein Pre-/Post-Snapshot-Paar anlegen — Debian/Ubuntu liefert diese Integration anders als das `zypp`-Plugin von openSUSE nicht mit, weshalb das Skript dafür kleine Wrapper-Skripte schreibt.
- Aktiviert die systemd-Timer `snapper-timeline.timer` und `snapper-cleanup.timer`.
- Installiert `grub-btrfs`, aktiviert den Dienst `grub-btrfsd` und führt `update-grub` (bzw. `grub-mkconfig`) aus, damit Snapshots als bootbare, read-only-Einträge im GRUB-Menü erscheinen.

### Grenzen

Snapshot-Browsing, das Diffen einzelner Dateien und ein read-only-Boot eines Snapshots über das GRUB-Menü (`grub-btrfs`) funktionieren mit diesem Setup vollständig. Ein vollständiger bootbarer **System-Rollback**, wie ihn `snapper rollback` unter openSUSE macht, setzt zusätzlich voraus, dass Root aus einem `.snapshots/<N>/snapshot`-Subvolume läuft — das ist bei einem einfachen `@`-Layout nicht automatisch der Fall und müsste bei Bedarf manuell nachgezogen werden (Default-Subvolume auf den gewünschten Snapshot umstellen und Bootloader aktualisieren).

## Voraussetzungen

- Debian oder Debian-basiertes System mit `apt` und `systemd`.
- Root-Dateisystem bereits auf einem **benannten** Btrfs-Subvolume (falls nicht, zuerst [btrfs-layout-script](https://github.com/layout-scripts/btrfs-layout-script) ausführen).
- Das Skript als **root** ausführen.

Das Skript installiert bei Bedarf folgende Pakete: `snapper`, `inotify-tools`, `grub-btrfs`.

## Verwendung

1. Sicherstellen, dass `/` bereits von einem benannten Btrfs-Subvolume läuft (siehe [btrfs-layout-script](https://github.com/layout-scripts/btrfs-layout-script)).

2. Repository klonen:

   ```bash
   git clone https://github.com/layout-scripts/snapper-layout-script.git
   cd snapper-layout-script
   ```

3. Skript ausführbar machen und starten:

   ```bash
   chmod +x setup-snapper.sh
   sudo ./setup-snapper.sh
   ```

4. Prüfen:

   ```bash
   snapper list-configs
   snapper create -d test && snapper list && snapper delete <Nummer>
   systemctl status snapper-timeline.timer snapper-cleanup.timer grub-btrfsd
   ```

   Ein kleines Paket installieren/entfernen, um zu prüfen, dass die `apt`-Hooks ein Pre-/Post-Snapshot-Paar erzeugen, und neu starten, um zu prüfen, dass das GRUB-Menü ein Snapshot-Untermenü zeigt.

## Lizenz

Dieses Projekt steht unter der **GNU General Public License v3.0 oder später (GPL-3.0-or-later)**.

Details siehe Datei `LICENSE`.
