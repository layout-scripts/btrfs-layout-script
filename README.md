# btrfs-layout-script

`setup-btrfs.sh` turns a **fresh Debian server with a single Btrfs root partition** into a system with a clean subvolume layout, ready for Timeshift and container workloads.

## Languages

- English (this file)
- [Deutsch](README.de.md)
- [Español](README.es.md)

## What it does

On a Debian (or Debian-based) system with a Btrfs root filesystem, the script:

- Detects the current root device via `findmnt` (e.g. `/dev/vda2[/@rootfs]` → `/dev/vda2`).
- Mounts the Btrfs top-level (`subvolid=5`) under `/mnt/btrfs-root`.
- Checks available disk space upfront (every byte on `/` is briefly duplicated during migration) and aborts if it's too tight.
- Shows an interactive selection dialog (`whiptail`) when run in a terminal: all subvolumes are pre-selected, you can deselect individual ones — deselected paths simply stay part of `@` without their own subvolume. Without an interactive terminal (e.g. automated runs), all subvolumes are created without prompting.
- Stops known services (`mongod`, `mysql`, `postgresql`, `docker`) before copying their data if they're currently running, and restarts them afterwards — for a consistent copy instead of half-written files.
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
  - `/var/lib/docker/volumes` → `@docker-volumes`
  - `/var/lib/containers/storage/volumes` → `@containers-volumes`
  - `/var/www` → `@www`

  Database subvolumes (`@mongodb`, `@mysql`, `@postgresql`) as well as named Docker/Podman volumes (`@docker-volumes`, `@containers-volumes`) are mounted with `nodatacow` instead of `compress=zstd`/`autodefrag` — copy-on-write and compression don't play well with databases' random-write patterns, and volumes can hold arbitrary workloads with the same characteristics. Image layers and metadata in `@docker`/`@containers` themselves are unaffected and stay compressed.

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
- Root filesystem on **Btrfs** (single device), e.g. a single Btrfs partition like `/dev/vda2`.
- Run the script as **root**.

The script will install the following packages if missing:

- `rsync`
- `btrfs-progs`

> Recommended usage: on a **fresh server installation** where reorganising the filesystem is acceptable. On a heavily used system, take extra care and ensure you have backups.

## Usage

1. Install Debian with:
   - a small EFI partition (e.g. `/dev/vda1`)
   - one large Btrfs partition as root (e.g. `/dev/vda2`)

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
