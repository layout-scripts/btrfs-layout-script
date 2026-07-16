# snapper-layout-script

`setup-snapper.sh` turns a Debian, Ubuntu, or other Debian-based server that already runs its root filesystem from a named Btrfs subvolume (e.g. via [btrfs-layout-script](https://github.com/layout-scripts/btrfs-layout-script)) into a SUSE-style Snapper setup: automatic timeline snapshots, snapshots around every `apt` package change, and snapshots bootable straight from the GRUB menu via `grub-btrfs`.

## Languages

- English (this file)
- [Deutsch](README.de.md)
- [Español](README.es.md)

## What it does

On a Debian (or Debian-based) system with `/` already on a named Btrfs subvolume, the script:

- Verifies `/` is Btrfs and running from a named subvolume (e.g. `@`); aborts with a pointer to `btrfs-layout-script` if not.
- Installs `snapper` and `inotify-tools` (needed by `grub-btrfsd` to watch for new snapshots) if missing.
- Explicitly asks for confirmation in an interactive terminal (type "ja") before changing anything. Skipped without a terminal (automated runs).
- Creates the `root` Snapper configuration (idempotent — skipped if it already exists), which creates `.snapshots` as a nested Btrfs subvolume.
- Adds `.snapshots` as its own `/etc/fstab` entry and mounts it. This step is required: a nested subvolume stays an empty placeholder directory until it is mounted on its own, so without this, snapshot content wouldn't be browsable and `grub-btrfs` wouldn't find anything.
- Sets a SUSE-like timeline policy in `/etc/snapper/configs/root` (`TIMELINE_CREATE`, `TIMELINE_CLEANUP`, `NUMBER_CLEANUP`, and conservative `TIMELINE_LIMIT_*` values for hourly/daily/weekly/monthly/yearly).
- Installs custom `apt` hooks (`DPkg::Pre-Invoke`/`DPkg::Post-Invoke`) that create a paired pre/post snapshot around every package change — Debian/Ubuntu, unlike openSUSE's `zypp` plugin, doesn't ship this integration, so the script writes small wrapper scripts for it.
- Enables the `snapper-timeline.timer` and `snapper-cleanup.timer` systemd timers.
- Installs `grub-btrfs`, enables the `grub-btrfsd` service, and runs `update-grub` (or `grub-mkconfig`), so snapshots show up as bootable, read-only entries in the GRUB menu.

### Limitations

Snapshot browsing, diffing individual files, and read-only booting a snapshot via the GRUB menu (`grub-btrfs`) all work fully with this setup. A full bootable **system rollback** the way openSUSE's `snapper rollback` does it additionally requires root to run from inside a `.snapshots/<N>/snapshot` subvolume — that is not automatically the case with a plain `@` layout and would need to be set up manually if you ever need it (switch the default subvolume to the desired snapshot and update the bootloader).

## Requirements

- Debian or Debian-based system using `apt` and `systemd`.
- Root filesystem already on a **named** Btrfs subvolume (run [btrfs-layout-script](https://github.com/layout-scripts/btrfs-layout-script) first if it isn't).
- Run the script as **root**.

The script will install the following packages if missing: `snapper`, `inotify-tools`, `grub-btrfs`.

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
