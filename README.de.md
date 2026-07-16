# btrfs-layout-script

`setup-btrfs.sh` hilft dabei, einen **Debian-, Ubuntu- oder anderen Debian-basierten Server mit einer einzelnen Btrfs-Root-Partition** in ein System mit sauberer Subvolume-Struktur zu verwandeln – geeignet für Timeshift und Container-Workloads. Funktioniert sowohl beim einmaligen Umstieg auf einer frischen Installation als auch nachträglich auf einem bereits laufenden, migrierten System, um dort noch fehlende Subvolumes zu ergänzen (kein Neustart nötig).

## Sprachen

- [English](README.md)
- Deutsch (diese Datei)
- [Español](README.es.md)

## Was das Skript macht

Auf einem Debian- (oder Debian-basierten) System mit Btrfs-Root führt das Skript im Wesentlichen aus:

- Ermittelt das aktuelle Root-Device per `findmnt` (z. B. `/dev/vda2[/@rootfs]` → `/dev/vda2`).
- Mountet das Btrfs-Top-Level (`subvolid=5`) nach `/mnt/btrfs-root`.
- Prüft vorab den freien Speicherplatz (jedes Byte auf `/` wird während der Migration kurzzeitig dupliziert) und bricht ab, wenn es eng wird.
- Erkennt eine schon (teilweise) durchgeführte Migration und wechselt automatisch in einen **inkrementellen Modus**: Läuft `/` bereits von einem benannten Subvolume, werden Root, GRUB und das Default-Subvolume nicht mehr angefasst — es werden nur noch fehlende Subvolumes für noch nicht separat gemountete Pfade ergänzt, sofort aktiv, ohne Neustart. Jeder Zielpfad wird einzeln klassifiziert: bereits korrekt eingerichtet (übersprungen, taucht im Auswahldialog gar nicht erst auf), anderweitig belegt (übersprungen mit Warnung, wird nicht überschrieben), oder noch offen (Kandidat für die Auswahl).
- Fragt in einem interaktiven Terminal ausdrücklich nach ("ja" eintippen), bevor irgendetwas verändert wird — samt Warnhinweis, was das Skript tut und dass ein Fehlschlag das System unbootbar machen kann. Ohne Terminal (automatisierte Läufe) wird die Abfrage übersprungen.
- Zeigt in einem interaktiven Terminal einen Auswahldialog (`whiptail`): universell sinnvolle Subvolumes (`@root`, `@home`, `@log`, `@cache`, `@tmp_var`, `@tmp`) sind vorausgewählt, alle vom Software-Stack abhängigen (Datenbanken, ClamAV, Docker/Podman, Webserver-Docroot) starten abgewählt — beides frei änderbar. Abgewählte Pfade bekommen kein eigenes Subvolume und bleiben einfach Teil von `@`. Ohne interaktives Terminal (z.B. bei automatisierter Ausführung) werden nur die universell sinnvollen Subvolumes ohne Nachfrage angelegt.
- Stoppt bekannte Datenbank-, Datastore- und Container-Dienste vor deren Datenkopie, falls sie gerade laufen. Im inkrementellen Modus werden sie nach aktiven neuen Mounts neu gestartet; im initialen Migrationsmodus bleiben sie bis zum Reboot gestoppt — für eine konsistente Kopie statt halbgeschriebener Dateien.
- Legt (idempotent) folgende Subvolumes an:

  - `@` (neues Root)
  - `@root`
  - `@home`
  - `@spool`
  - `@log`
  - `@cache`
  - `@tmp_var`
  - `@srv`
  - `@tmp`
  - `@opt`
  - `@containers`
  - `@docker`
  - `@mongodb`
  - `@mysql`
  - `@postgresql`
  - `@chroma`
  - `@clamav`
  - `@stalwart`
  - `@elasticsearch`
  - `@opensearch`
  - `@clickhouse`
  - `@cassandra`
  - `@couchdb`
  - `@neo4j`
  - `@rabbitmq`
  - `@docker-volumes`
  - `@containers-volumes`
  - `@www`

- Kopiert das aktuelle Root-Dateisystem nach `@` (mit Ausschlüssen für `/dev`, `/proc`, `/sys`, `/run`, `/mnt`, `/media`, `/lost+found` sowie – automatisch aus dem Mapping unten abgeleitet – allen Pfaden, die ein eigenes Subvolume bekommen).
- Kopiert die Inhalte wichtiger Verzeichnisse in ihre Subvolumes:

  - `/root` → `@root`
  - `/home` → `@home`
  - `/var/spool` → `@spool`
  - `/var/log` → `@log`
  - `/var/cache` → `@cache`
  - `/var/tmp` → `@tmp_var`
  - `/srv` → `@srv`
  - `/tmp` → `@tmp`
  - `/opt` → `@opt`
  - `/var/lib/containers` → `@containers`
  - `/var/lib/docker` → `@docker`
  - `/var/lib/mongodb` → `@mongodb`
  - `/var/lib/mysql` → `@mysql`
  - `/var/lib/postgresql` → `@postgresql`
  - `/var/lib/chroma` → `@chroma`
  - `/var/lib/clamav` → `@clamav`
  - `/var/lib/stalwart` → `@stalwart`
  - `/var/lib/elasticsearch` → `@elasticsearch`
  - `/var/lib/opensearch` → `@opensearch`
  - `/var/lib/clickhouse` → `@clickhouse`
  - `/var/lib/cassandra` → `@cassandra`
  - `/var/lib/couchdb` → `@couchdb`
  - `/var/lib/neo4j` → `@neo4j`
  - `/var/lib/rabbitmq` → `@rabbitmq`
  - `/var/lib/docker/volumes` → `@docker-volumes`
  - `/var/lib/containers/storage/volumes` → `@containers-volumes`
  - `/var/www` → `@www`

  Datenbank- und Datastore-Subvolumes (`@mongodb`, `@mysql`, `@postgresql`, `@chroma`, `@clamav`, `@stalwart`, `@elasticsearch`, `@opensearch`, `@clickhouse`, `@cassandra`, `@couchdb`, `@neo4j`, `@rabbitmq`) sowie die benannten Docker-/Podman-Volumes (`@docker-volumes`, `@containers-volumes`) behalten normale Btrfs-Mounts mit CoW und Prüfsummen, bekommen aber vor der Datenkopie `btrfs property set ... compression no`. Damit verlässt sich das Skript nicht auf per-Subvolume gesetzte `compress`-/`nodatacow`-fstab-Optionen, die Btrfs für Mounts desselben Dateisystems nicht zuverlässig getrennt unterstützt. Image-Layer und Metadaten in `@docker`/`@containers` selbst bleiben auf der normalen komprimierten Policy.

- Bereitet im neuen Root (`@`) die Mountpoints vor, damit die Subvolumes dort eingehängt werden können.
- Passt `/etc/fstab` im laufenden System an:

  - legt ein Backup als `fstab.backup-YYYY-MM-DD-HHMMSS` an,
  - kommentiert alte Btrfs-Root-Zeilen als `#OLD-ROOT …` aus,
  - fügt neue Btrfs-Einträge für `/`, `/home`, `/var/log`, `/var/lib/docker`, `/var/www` usw. mit den entsprechenden `@…`-Subvolumes hinzu.

- Passt GRUB an (falls vorhanden):

  - ersetzt ggf. `@rootfs` durch `@` in `/etc/default/grub`,
  - ruft `update-grub` oder `grub-mkconfig -o /boot/grub/grub.cfg` auf (sofern vorhanden).

- Setzt das Btrfs-Default-Subvolume auf `@`, sodass das System von `@` bootet.
- Stellt sicher, dass die benötigten Mountpoints auch im aktuellen Root existieren (`/home`, `/var/lib/docker`, …).
- Validiert die neue `/etc/fstab` automatisch mit `findmnt --verify` (rein lesend, mountet nichts live um) und bricht bei Problemen ab, bevor du versehentlich mit einer kaputten fstab neu startest.

Das Ergebnis:

- Root läuft von `@` (Timeshift-kompatibel).
- Wichtige Pfade wie `/home`, `/var/log`, `/var/lib/docker`, `/var/www` liegen auf eigenen Subvolumes.

## Voraussetzungen

- Debian oder Debian-basiertes System mit:
  - `apt`
  - `systemd`
- Root-Dateisystem ist **Btrfs** auf einem einzelnen Device (z. B. eine Btrfs-Partition `/dev/vda2`); **LVM nicht** für das Root-Dateisystem aktivieren.
- Das Skript wird als **root** ausgeführt.

Bei Bedarf installiert das Skript automatisch:

- `rsync`
- `btrfs-progs`

> Am unkompliziertesten auf einer **frischen Server-Installation**, da dort alle Verzeichnisse klein/leer sind. Das Skript funktioniert aber auch auf bereits laufenden Systemen, **sofern genug freier Speicherplatz vorhanden ist** (wird automatisch geprüft – jedes Byte auf `/` wird während der Migration kurzzeitig dupliziert). Für eine konsistente Kopie werden bekannte Datenbank-, Datastore- und Container-Dienste vor ihrer jeweiligen Datenkopie automatisch gestoppt; im inkrementellen Modus nach `mount -a` neu gestartet und im initialen Migrationsmodus bis zum Reboot gestoppt gelassen.
>
> Trotzdem gilt auf laufenden Systemen: mach vorher ein Backup, plane ein Wartungsfenster für den abschließenden Neustart ein, und bedenke, dass Anwendungen **außerhalb** dieser Liste (z. B. ein eigener Webserver-Prozess mit offenen Dateien in `/srv` oder `/var/www`) während der Kopie weiterlaufen und dadurch theoretisch eine inkonsistente Momentaufnahme in ihr Subvolume bekommen könnten.

## Verwendung

1. Debian so installieren, dass du erhältst:

   - eine kleine EFI-Partition (z. B. `/dev/vda1`)
   - eine große Btrfs-Partition als Root (z. B. `/dev/vda2`)
   - LVM für das Root-Dateisystem nicht ausgewählt/aktiviert ist

2. Als root anmelden (oder `sudo` verwenden).

3. Repository klonen:

   ```bash
   git clone https://github.com/<dein-user>/btrfs-layout-script.git
   cd btrfs-layout-script
   ```

4. Skript ausführbar machen:

   ```bash
   chmod +x setup-btrfs.sh
   ```

5. Skript ausführen:

   ```bash
   sudo ./setup-btrfs.sh
   ```

6. `/etc/fstab` prüfen und sicherstellen, dass:

   - `/` mit `subvol=@` eingetragen ist,
   - die zusätzlichen Pfade (`/home`, `/var/log`, `/var/lib/docker`, `/var/www`, …) passende Einträge mit den erwarteten `@…`-Subvolumes haben.

7. Mounts anwenden und testen:

   ```bash
   systemctl daemon-reload
   mount -a
   ```

   Es sollten keine Fehler erscheinen.

8. Neustart:

   ```bash
   reboot
   ```

9. Nach dem Neustart prüfen:

   ```bash
   findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS /
   findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS /home /var/log /var/lib/docker /var/www
   ```

   Erwartung:

   - `/` von `...[/@]` mit `subvol=@`
   - `/home` von `...[/@home]` usw.

Damit ist das Layout für Timeshift und Container-Workloads vorbereitet.

## Lizenz

Dieses Projekt steht unter der **GNU General Public License Version 3 oder neuer (GPL-3.0-or-later)**.

Details findest du in der Datei `LICENSE`.
