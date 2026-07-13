# btrfs-layout-script

`setup-btrfs.sh` hilft dabei, einen **frisch installierten Debian-Server mit einer einzelnen Btrfs-Root-Partition** in ein System mit sauberer Subvolume-Struktur zu verwandeln – geeignet für Timeshift und Container-Workloads.

## Sprachen

- [English](README.md)
- Deutsch (diese Datei)
- [Español](README.es.md)

## Was das Skript macht

Auf einem Debian- (oder Debian-basierten) System mit Btrfs-Root führt das Skript im Wesentlichen aus:

- Ermittelt das aktuelle Root-Device per `findmnt` (z. B. `/dev/vda2[/@rootfs]` → `/dev/vda2`).
- Mountet das Btrfs-Top-Level (`subvolid=5`) nach `/mnt/btrfs-root`.
- Prüft vorab den freien Speicherplatz (jedes Byte auf `/` wird während der Migration kurzzeitig dupliziert) und bricht ab, wenn es eng wird.
- Zeigt in einem interaktiven Terminal einen Auswahldialog (`whiptail`): alle Subvolumes sind vorausgewählt, du kannst einzelne abwählen — abgewählte Pfade bekommen kein eigenes Subvolume und bleiben einfach Teil von `@`. Ohne interaktives Terminal (z.B. bei automatisierter Ausführung) werden alle Subvolumes ohne Nachfrage angelegt.
- Stoppt bekannte Dienste (`mongod`, `mysql`, `postgresql`, `docker`) vor deren Datenkopie, falls sie gerade laufen, und startet sie danach wieder — für eine konsistente Kopie statt halbgeschriebener Dateien.
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
  - `/var/lib/docker/volumes` → `@docker-volumes`
  - `/var/lib/containers/storage/volumes` → `@containers-volumes`
  - `/var/www` → `@www`

  Datenbank-Subvolumes (`@mongodb`, `@mysql`, `@postgresql`) sowie die benannten Docker-/Podman-Volumes (`@docker-volumes`, `@containers-volumes`) werden mit `nodatacow` statt `compress=zstd`/`autodefrag` gemountet – Copy-on-Write und Kompression vertragen sich schlecht mit dem Random-Write-Verhalten von Datenbanken und beliebigen Volume-Workloads. Image-Layer und Metadaten in `@docker`/`@containers` selbst bleiben davon unberührt und weiterhin komprimiert.

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
- Root-Dateisystem ist **Btrfs** auf einem einzelnen Device (z. B. eine Btrfs-Partition `/dev/vda2`).
- Das Skript wird als **root** ausgeführt.

Bei Bedarf installiert das Skript automatisch:

- `rsync`
- `btrfs-progs`

> Am unkompliziertesten auf einer **frischen Server-Installation**, da dort alle Verzeichnisse klein/leer sind. Das Skript funktioniert aber auch auf bereits laufenden Systemen, **sofern genug freier Speicherplatz vorhanden ist** (wird automatisch geprüft – jedes Byte auf `/` wird während der Migration kurzzeitig dupliziert). Für eine konsistente Kopie werden bekannte Dienste (`mongod`, `mysql`, `postgresql`, `docker`) vor ihrer jeweiligen Datenkopie automatisch gestoppt und danach wieder gestartet.
>
> Trotzdem gilt auf laufenden Systemen: mach vorher ein Backup, plane ein Wartungsfenster für den abschließenden Neustart ein, und bedenke, dass Anwendungen **außerhalb** dieser Liste (z. B. Podman, ein eigener Webserver-Prozess mit offenen Dateien in `/srv` oder `/var/www`) während der Kopie weiterlaufen und dadurch theoretisch eine inkonsistente Momentaufnahme in ihr Subvolume bekommen könnten.

## Verwendung

1. Debian so installieren, dass du erhältst:

   - eine kleine EFI-Partition (z. B. `/dev/vda1`)
   - eine große Btrfs-Partition als Root (z. B. `/dev/vda2`)

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
