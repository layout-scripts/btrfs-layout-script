#!/usr/bin/env bash
set -euo pipefail

echo ">>> Snapper-Setup: root-Konfiguration + Timeline + apt-Hooks + grub-btrfs"

if [[ $EUID -ne 0 ]]; then
  echo "Bitte als root ausführen." >&2
  exit 1
fi

# --- Abhängigkeiten sicherstellen (Debian/apt) ---
need_pkg() {
  local cmd="$1" pkg="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo ">>> Installiere benötigtes Paket: $pkg"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
  else
    echo ">>> Abhängigkeit $pkg ($cmd) ist bereits vorhanden."
  fi
}

need_pkg snapper snapper
# grub-btrfsd beobachtet .snapshots per inotify auf neue/gelöschte Snapshots.
need_pkg inotifywait inotify-tools

# --- Vorbedingung: / muss Btrfs sein und von einem benannten Subvolume laufen ---
# Ein benanntes Root-Subvolume (z.B. @) ist Voraussetzung dafür, dass .snapshots
# als eigenes, separat mountbares Subvolume danebenliegen kann. Ohne dieses
# Layout (z.B. auf einem frischen Debian-Standardinstall mit subvolid=5-Root)
# zuerst btrfs-layout-script/setup-btrfs.sh ausführen.
FSTYPE=$(findmnt -no FSTYPE / || true)
if [[ "$FSTYPE" != "btrfs" ]]; then
  echo "/ ist kein Btrfs-Dateisystem (FSTYPE=$FSTYPE). Abbruch." >&2
  exit 1
fi

ROOT_SRC=$(findmnt -no SOURCE / || true)
if [[ -z "$ROOT_SRC" || "$ROOT_SRC" != *"["* ]]; then
  echo "FEHLER: / läuft nicht von einem benannten Subvolume (aktuell: ${ROOT_SRC:-unbekannt})." >&2
  echo "Bitte zuerst layout-scripts/btrfs-layout-script/setup-btrfs.sh ausführen." >&2
  exit 1
fi

ROOT_DEV=${ROOT_SRC%%[*}
UUID=$(blkid -s UUID -o value "$ROOT_DEV" || true)
if [[ -z "$UUID" ]]; then
  echo "Konnte UUID von $ROOT_DEV nicht ermitteln. Abbruch." >&2
  exit 1
fi

# Klammerinhalt von z.B. /dev/vda2[/@] ist der Pfad des Root-Subvolumes von
# der Btrfs-Top-Level aus gesehen ("/@" -> ohne führenden Slash "@"). Der
# nested .snapshots-Subvolume-Pfad setzt sich daraus zusammen.
ROOT_SUBVOL=$(echo "$ROOT_SRC" | sed -E 's/.*\[\/(.*)\]/\1/')
SNAPSHOTS_SUBVOL="${ROOT_SUBVOL}/.snapshots"

echo ">>> Root-Subvolume: ${ROOT_SUBVOL}, geplantes Snapshot-Subvolume: ${SNAPSHOTS_SUBVOL}"

# --- Ausdrückliche Bestätigung, bevor irgendetwas verändert wird ---
echo
echo "!!! ACHTUNG !!!"
echo "Dieses Skript legt ein snapper-Subvolume .snapshots an, trägt es in"
echo "/etc/fstab ein, richtet Timeline-Snapshots samt Aufräum-Timern ein,"
echo "installiert apt-Hooks für Pre-/Post-Snapshots und macht Snapshots über"
echo "grub-btrfs im GRUB-Menü bootbar (update-grub wird ausgeführt)."
echo
if [[ -t 0 ]]; then
  read -r -p "Backup vorhanden? Zum Fortfahren exakt 'ja' eingeben: " CONFIRM
  if [[ "$CONFIRM" != "ja" ]]; then
    echo "Abgebrochen." >&2
    exit 1
  fi
else
  echo ">>> Kein interaktives Terminal erkannt – Bestätigung übersprungen (automatisierter Lauf)."
fi

# --- snapper-Konfiguration "root" anlegen (idempotent) ---
if [[ -f /etc/snapper/configs/root ]]; then
  echo ">>> snapper-Konfiguration 'root' existiert bereits, überspringe create-config."
else
  echo ">>> Erzeuge snapper-Konfiguration 'root' (legt .snapshots als Subvolume an)"
  snapper -c root create-config /
fi

# --- .snapshots in fstab eintragen, damit der Subvolume-Inhalt sichtbar wird ---
# Ein frisch erzeugtes nested Subvolume ist innerhalb des bereits gemounteten
# Root-Subvolumes nur als leeres Platzhalterverzeichnis sichtbar, solange es
# nicht selbst gemountet ist (gleiches Prinzip wie @docker-volumes im
# btrfs-layout-script). Ohne eigenen Mount sieht weder "snapper list" die
# Snapshot-Inhalte vollständig, noch findet grub-btrfs sie beim Booten.
FSTAB=/etc/fstab
if grep -Eq '^[^#[:space:]]+[[:space:]]+/\.snapshots[[:space:]]+btrfs' "$FSTAB"; then
  echo ">>> fstab: Eintrag für /.snapshots existiert bereits, überspringe."
else
  backup="${FSTAB}.backup-$(date +%F-%H%M%S)"
  echo ">>> Sicherung der aktuellen fstab nach $backup"
  cp "$FSTAB" "$backup"
  echo "UUID=${UUID} /.snapshots btrfs noatime,compress=zstd,space_cache=v2,subvol=${SNAPSHOTS_SUBVOL} 0 0" >> "$FSTAB"
  echo ">>> fstab: Eintrag für /.snapshots hinzugefügt."
fi

mkdir -p /.snapshots
echo ">>> Aktiviere den neuen Mount"
systemctl daemon-reload
if ! findmnt --verify; then
  echo "FEHLER: 'findmnt --verify' hat Probleme in der neuen fstab gefunden." >&2
  echo "Bitte ${FSTAB} prüfen. Die alte fstab liegt gesichert (siehe oben)." >&2
  exit 1
fi
mount -a
findmnt -no TARGET,SOURCE,OPTIONS /.snapshots

# --- SUSE-artige Timeline-Policy in der root-Konfiguration setzen ---
# sed statt "snapper set-config", weil set-config bei mehreren Werten
# mehrere Aufrufe braeuchte; ein Schluessel, der im Standardtemplate von
# snapper bereits existiert, wird per sed idempotent ueberschrieben.
set_snapper_config() {
  local key="$1" value="$2"
  sed -i "s|^${key}=.*|${key}=\"${value}\"|" /etc/snapper/configs/root
}

echo ">>> Setze Timeline-Policy in /etc/snapper/configs/root"
set_snapper_config TIMELINE_CREATE yes
set_snapper_config TIMELINE_CLEANUP yes
set_snapper_config NUMBER_CLEANUP yes
set_snapper_config NUMBER_LIMIT 50
set_snapper_config TIMELINE_LIMIT_HOURLY 10
set_snapper_config TIMELINE_LIMIT_DAILY 10
set_snapper_config TIMELINE_LIMIT_WEEKLY 4
set_snapper_config TIMELINE_LIMIT_MONTHLY 6
set_snapper_config TIMELINE_LIMIT_YEARLY 2

# --- apt-Hooks fuer automatische Pre-/Post-Snapshots bei Paketaenderungen ---
# Anders als SUSE (zypp-Plugin) liefert Debian/Ubuntu keine fertige
# Snapper-Integration fuer den Paketmanager mit. Wir schreiben sie selbst als
# zwei kleine Wrapper-Skripte, die apt per DPkg::Pre-Invoke/Post-Invoke
# aufruft.
install_apt_hooks() {
  local pre_script="/usr/local/sbin/snapper-apt-pre"
  local post_script="/usr/local/sbin/snapper-apt-post"
  local hook_conf="/etc/apt/apt.conf.d/80snapper"

  if [[ -f "$hook_conf" ]]; then
    echo ">>> apt-Hooks für snapper existieren bereits ($hook_conf), überspringe."
    return 0
  fi

  echo ">>> Installiere apt-Hooks für Pre-/Post-Snapshots: $pre_script, $post_script, $hook_conf"

  # Die Pre-Nummer wird unter /run zwischengespeichert (tmpfs, nach Reboot
  # ohnehin leer): apt haelt beim Paketaendern seinen eigenen dpkg-Lock, ein
  # echt paralleler zweiter apt-Lauf ist also ausgeschlossen - die einfache
  # Datei reicht damit aus, ohne z.B. den Prozess-PID im Dateinamen zu fuehren.
  # Bewusst kein "set -e" in den Wrapper-Skripten: ein Fehlschlag beim
  # Snapshot darf apt niemals blockieren, deshalb wird jeder riskante Aufruf
  # explizit abgefangen und das Skript beendet sich trotzdem mit Exit-Code 0.
  cat > "$pre_script" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

NUMBER_FILE="/run/snapper-apt-pre-number"

number=$(snapper -c root create -t pre --print-number \
  --description "apt: $(date '+%F %T')" 2>/dev/null) || {
  echo "snapper-apt-pre: konnte keinen Pre-Snapshot anlegen, apt läuft trotzdem weiter." >&2
  rm -f "$NUMBER_FILE"
  exit 0
}

echo "$number" > "$NUMBER_FILE"
exit 0
EOF
  chmod 755 "$pre_script"

  cat > "$post_script" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

NUMBER_FILE="/run/snapper-apt-pre-number"

[[ -f "$NUMBER_FILE" ]] || exit 0

pre_number=$(cat "$NUMBER_FILE")
rm -f "$NUMBER_FILE"

snapper -c root create -t post --pre-number "$pre_number" \
  --description "apt: $(date '+%F %T')" >/dev/null 2>&1 || \
  echo "snapper-apt-post: konnte keinen Post-Snapshot zu Pre #$pre_number anlegen." >&2

exit 0
EOF
  chmod 755 "$post_script"

  cat > "$hook_conf" <<EOF
DPkg::Pre-Invoke {"$pre_script";};
DPkg::Post-Invoke {"$post_script";};
EOF
}

install_apt_hooks

# --- Timeline- und Aufräum-Timer aktivieren ---
for unit in snapper-timeline.timer snapper-cleanup.timer; do
  if systemctl list-unit-files "$unit" >/dev/null 2>&1 && systemctl list-unit-files "$unit" | grep -q "$unit"; then
    echo ">>> Aktiviere $unit"
    systemctl enable --now "$unit"
  else
    echo "WARNUNG: Unit $unit nicht gefunden – bitte snapper-Paketversion prüfen." >&2
  fi
done

# --- grub-btrfs: Snapshots im GRUB-Menü bootbar machen ---
need_pkg grub-mkconfig grub-common 2>/dev/null || true
if apt-cache show grub-btrfs >/dev/null 2>&1; then
  need_pkg grub-btrfsd grub-btrfs
  echo ">>> Aktiviere grub-btrfsd (beobachtet .snapshots und aktualisiert GRUB automatisch)"
  systemctl enable --now grub-btrfsd

  if command -v update-grub >/dev/null 2>&1; then
    echo ">>> update-grub ausführen"
    update-grub
  elif command -v grub-mkconfig >/dev/null 2>&1; then
    echo ">>> grub-mkconfig -o /boot/grub/grub.cfg ausführen"
    grub-mkconfig -o /boot/grub/grub.cfg
  else
    echo "WARNUNG: Weder update-grub noch grub-mkconfig gefunden – GRUB-Menü nicht aktualisiert." >&2
  fi
else
  echo "WARNUNG: Paket grub-btrfs ist nicht verfügbar – Snapshots werden nicht bootbar gemacht." >&2
fi

echo
echo ">>> FERTIG."
echo "Kontrolle:"
echo "  snapper list-configs"
echo "  snapper create -d test && snapper list && snapper delete <Nummer>"
echo "  systemctl status snapper-timeline.timer snapper-cleanup.timer grub-btrfsd"
echo
echo "Hinweis zu den Grenzen dieses Setups:"
echo "Snapshot-Browsing, Diff und ein read-only-Boot einzelner Snapshots über"
echo "das GRUB-Menü (grub-btrfs) funktionieren vollständig. Ein vollständiger"
echo "bootbarer System-Rollback wie unter openSUSE ('snapper rollback') setzt"
echo "zusätzlich voraus, dass root direkt aus einem .snapshots/<N>/snapshot-"
echo "Subvolume läuft; das ist mit diesem @-Layout nicht automatisch der Fall"
echo "und müsste bei Bedarf manuell nachgezogen werden (Default-Subvolume auf"
echo "den gewünschten Snapshot umstellen und Bootloader aktualisieren)."
