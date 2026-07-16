# btrfs-layout-script

`setup-btrfs.sh` turns a **Debian, Ubuntu, or other Debian-based server with a single Btrfs root partition** into a system with a clean subvolume layout, ready for Timeshift and container workloads. Works both for the one-time switch on a fresh install and afterwards on an already-running, migrated system, to add subvolumes that are still missing (no reboot needed).

## Languages

- English (this file)
- [Deutsch](README.de.md)
- [Español](README.es.md)

## What it does

On a Debian (or Debian-based) system with a Btrfs root filesystem, the script:

- Detects the current root device via `findmnt` (e.g. `/dev/vda2[/@rootfs]` → `/dev/vda2`).
- Mounts the Btrfs top-level (`subvolid=5`) under `/mnt/btrfs-root`.
- Checks available disk space upfront (every byte on `/` is briefly duplicated during migration) and aborts if it's too tight.
- Detects a migration that's already (partly) done and automatically switches to an **incremental mode**: if `/` is already running from a named subvolume, root, GRUB, and the default subvolume are left untouched — only subvolumes for target paths that aren't separately mounted yet get added, active immediately, no reboot needed. Each target path is classified individually: already set up correctly (skipped, doesn't even show up in the selection dialog), occupied by something else (skipped with a warning, never overwritten), or still open (candidate for selection).
- Explicitly asks for confirmation in an interactive terminal (type "ja") before changing anything, with a warning about what the script does and that a failure can leave the system unbootable. Skipped without a terminal (automated runs).
- Shows an interactive selection dialog (`whiptail`) when run in a terminal: universally sensible subvolumes (`@root`, `@home`, `@log`, `@cache`, `@tmp_var`, `@tmp`) are pre-selected, everything that depends on the software stack (databases, ClamAV, Docker/Podman, web server docroot) starts deselected — both freely adjustable. Deselected paths simply stay part of `@` without their own subvolume. Without an interactive terminal (e.g. automated runs), only the universally sensible subvolumes are created without prompting.
- Stops known database, datastore, and container services before copying their data if they're currently running. In incremental mode they're restarted after the new mounts are active; in initial migration mode they stay stopped until the reboot — for a consistent copy instead of half-written files.
- Creates the following subvolumes (idempotent; if they already exist, they are reused):

  - `@` (new root)
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

- Copies the current root filesystem to `@` (excluding `/dev`, `/proc`, `/sys`, `/run`, `/mnt`, `/media`, `/lost+found`, plus — derived automatically from the mapping below — every path that gets its own subvolume).
- Copies the content of these directories into their matching subvolumes:

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

  Database and datastore subvolumes (`@mongodb`, `@mysql`, `@postgresql`, `@chroma`, `@clamav`, `@stalwart`, `@elasticsearch`, `@opensearch`, `@clickhouse`, `@cassandra`, `@couchdb`, `@neo4j`, `@rabbitmq`) as well as named Docker/Podman volumes (`@docker-volumes`, `@containers-volumes`) keep normal Btrfs mounts with CoW and checksums, but get `btrfs property set ... compression no` before data is copied. This avoids relying on per-subvolume `compress`/`nodatacow` fstab options, which Btrfs does not support reliably for mounts of the same filesystem. Image layers and metadata in `@docker`/`@containers` themselves stay on the normal compressed policy.

- Prepares empty mountpoints inside the new root (`@`) so that the subvolumes can be mounted there.
- Updates `/etc/fstab` in the running system:

  - Backs up the old file as `fstab.backup-YYYY-MM-DD-HHMMSS`.
  - Comments old Btrfs root lines as `#OLD-ROOT ...`.
  - Appends new Btrfs entries for `/`, `/home`, `/var/log`, `/var/lib/docker`, etc., pointing to the corresponding subvolumes.

- Adjusts GRUB (if present):

  - Replaces `@rootfs` with `@` in `/etc/default/grub` if needed.
  - Runs `update-grub` or `grub-mkconfig -o /boot/grub/grub.cfg` if available.

- Sets the Btrfs default subvolume to `@`, so the system boots from `@`.
- Ensures required mountpoints also exist in the current root (`/home`, `/var/lib/docker`, …).
- Validates the new `/etc/fstab` automatically with `findmnt --verify` (read-only, doesn't remount anything live) and aborts before you accidentally reboot into a broken fstab.

The end result:

- Root runs from `@` (Timeshift-compatible).
- Important paths like `/home`, `/var/log`, `/var/lib/docker`, `/var/www` live on their own subvolumes.

## Requirements

- Debian or Debian-based system using:
  - `apt`
  - `systemd`
- Root filesystem on **Btrfs** (single device), e.g. a single Btrfs partition like `/dev/vda2`; do **not** enable LVM for the root filesystem.
- Run the script as **root**.

The script will install the following packages if missing:

- `rsync`
- `btrfs-progs`

> Simplest on a **fresh server installation**, since every directory is small/empty there. The script also works on already-running systems, **provided there's enough free disk space** (checked automatically — every byte on `/` is briefly duplicated during migration). For a consistent copy, known database, datastore, and container services are automatically stopped before their respective data copy; in incremental mode they're restarted after `mount -a`, and in initial migration mode they stay stopped until the reboot.
>
> Still, on a running system: take a backup first, plan a maintenance window for the final reboot, and keep in mind that applications **outside** this list (e.g. a custom web server process with open files under `/srv` or `/var/www`) keep running during the copy and could in theory end up with an inconsistent snapshot in their subvolume.

## Usage

1. Install Debian with:
   - a small EFI partition (e.g. `/dev/vda1`)
   - one large Btrfs partition as root (e.g. `/dev/vda2`)
   - LVM disabled/not selected for the root filesystem

2. Log in as root (or use `sudo`).

3. Clone this repository:

   ```bash
   git clone https://github.com/<your-user>/btrfs-layout-script.git
   cd btrfs-layout-script
   ```

4. Make the script executable:

   ```bash
   chmod +x setup-btrfs.sh
   ```

5. Run it:

   ```bash
   sudo ./setup-btrfs.sh
   ```

6. Check `/etc/fstab` and verify that:

   - `/` uses `subvol=@`
   - the extra paths (`/home`, `/var/log`, `/var/lib/docker`, `/var/www`, …) have Btrfs entries with the expected `@…` subvolumes.

7. Apply and test mounts:

   ```bash
   systemctl daemon-reload
   mount -a
   ```

   There should be no errors.

8. Reboot:

   ```bash
   reboot
   ```

9. After reboot, verify:

   ```bash
   findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS /
   findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS /home /var/log /var/lib/docker /var/www
   ```

   You should see:

   - `/` from `...[/@]` with `subvol=@`
   - `/home` from `...[/@home]`, etc.

At this point, Timeshift can use `@` as the root subvolume and your layout is ready for snapshots and container workloads.

## License

This project is licensed under the **GNU General Public License v3.0 or later (GPL-3.0-or-later)**.

See the `LICENSE` file for full details.
