# snapper-layout-script

`setup-snapper.sh` turns a Debian, Ubuntu, or other Debian-based server that already runs its root filesystem from a named Btrfs subvolume (e.g. via [btrfs-layout-script](https://github.com/layout-scripts/btrfs-layout-script)) into a SUSE-style Snapper setup: automatic timeline snapshots, snapshots around every `apt` package change, and snapshots bootable straight from the GRUB menu via `grub-btrfs`.

## Languages

- English (this file)
- [Deutsch](README.de.md)
- [Español](README.es.md)

## What it does

On a Debian (or Debian-based) system with `/` already on a named Btrfs subvolume, the script:

- Verifies `/` is Btrfs and running from a named subvolume (e.g. `@`); aborts with a pointer to `btrfs-layout-script` if not.
- Creates a read-only Btrfs guard snapshot of the current root subvolume before the first change (e.g. `@.before-snapper-setup-...`) as a manual recovery point if setup fails.
- Installs `snapper` and `inotify-tools` (needed by `grub-btrfsd` to watch for new snapshots) if missing.
- Explicitly asks for confirmation in an interactive terminal (type "ja") before changing anything. Without a terminal, the script aborts unless `LAYOUT_SCRIPT_ASSUME_YES=1` is set.
- Creates the `root` Snapper configuration (idempotent — skipped if it already exists), which creates `.snapshots` as a nested Btrfs subvolume.
- Adds `.snapshots` as its own `/etc/fstab` entry and mounts it. The old `fstab` is backed up first and restored automatically if `findmnt --verify` or `mount -a` fails.
- Sets a SUSE-like timeline policy in `/etc/snapper/configs/root` (`TIMELINE_CREATE`, `TIMELINE_CLEANUP`, `NUMBER_CLEANUP`, and conservative `TIMELINE_LIMIT_*` values for hourly/daily/weekly/monthly/yearly).
- Installs custom `apt` hooks (`DPkg::Pre-Invoke`/`DPkg::Post-Invoke`) that create a paired pre/post snapshot around every package change — Debian/Ubuntu, unlike openSUSE's `zypp` plugin, doesn't ship this integration, so the script writes small wrapper scripts for it.
- Enables the `snapper-timeline.timer` and `snapper-cleanup.timer` systemd timers.
- Installs `grub-btrfs` if it is available from the configured APT repositories, enables `grub-btrfsd`, and runs `update-grub` (or `grub-mkconfig`) so snapshots show up as bootable, read-only entries in the GRUB menu. If the package is unavailable, Snapper setup continues without GRUB menu integration.

### Limitations

Snapshot browsing, diffing individual files, and read-only booting a snapshot via the GRUB menu (`grub-btrfs`) work with this setup if `grub-btrfs` is available. The guard snapshot is intentionally read-only and is a manual recovery point: boot a rescue system, mount the Btrfs top level, create a new writable root snapshot from the guard snapshot, and point the bootloader/fstab back to that restored state. A full bootable **system rollback** the way openSUSE's `snapper rollback` does it additionally requires root to run from inside a `.snapshots/<N>/snapshot` subvolume — that is not automatically the case with a plain `@` layout.

## Requirements

- Debian or Debian-based system using `apt` and `systemd`.
- Root filesystem already on a **named** Btrfs subvolume (run [btrfs-layout-script](https://github.com/layout-scripts/btrfs-layout-script) first if it isn't).
- Run the script as **root**.

The script will install the following packages if missing: `snapper`, `inotify-tools`, optionally `grub-btrfs`.

## Usage

1. Make sure `/` already runs from a named Btrfs subvolume (see [btrfs-layout-script](https://github.com/layout-scripts/btrfs-layout-script)).

2. Clone this repository:

   ```bash
   git clone https://github.com/layout-scripts/snapper-layout-script.git
   cd snapper-layout-script
   ```

3. Make the script executable and run it:

   ```bash
   chmod +x setup-snapper.sh
   sudo ./setup-snapper.sh
   ```

   For automated runs without a terminal:

   ```bash
   sudo LAYOUT_SCRIPT_ASSUME_YES=1 ./setup-snapper.sh
   ```

4. Verify:

   ```bash
   snapper list-configs
   snapper create -d test && snapper list && snapper delete <number>
   systemctl status snapper-timeline.timer snapper-cleanup.timer grub-btrfsd
   ```

   Install/remove a small package to confirm the `apt` hooks create a pre/post snapshot pair, and reboot to confirm the GRUB menu shows a snapshot submenu.

## License

This project is licensed under the **GNU General Public License v3.0 or later (GPL-3.0-or-later)**.

See the `LICENSE` file for full details.
