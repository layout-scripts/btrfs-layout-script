#!/usr/bin/env bash
set -euo pipefail

echo ">>> Btrfs-Setup: Root auf @ + alle Subvolumes/Mounts (final)"

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

need_pkg rsync rsync
need_pkg btrfs btrfs-progs

# --- Root-Quelle ermitteln, z.B. /dev/vda2[/@rootfs] ---
ROOT_SRC=$(findmnt -no SOURCE / || true)
if [[ -z "$ROOT_SRC" ]]; then
  echo "Konnte Root-Quelle nicht ermitteln." >&2
  exit 1
fi

ROOT_DEV=${ROOT_SRC%%[*}

FSTYPE=$(findmnt -no FSTYPE / || true)
if [[ "$FSTYPE" != "btrfs" ]]; then
  echo "/ ist kein Btrfs-Dateisystem (FSTYPE=$FSTYPE). Abbruch." >&2
  exit 1
fi

UUID=$(blkid -s UUID -o value "$ROOT_DEV" || true)
if [[ -z "$UUID" ]]; then
  echo "Konnte UUID von $ROOT_DEV nicht ermitteln. Abbruch." >&2
  exit 1
fi

MNT=/mnt/btrfs-root
if mount | grep -q " on $MNT "; then
  echo "$MNT ist bereits gemountet, bitte zuerst aushängen." >&2
  exit 1
fi
mkdir -p "$MNT"

echo ">>> Mount Top-Level (subvolid=5) von $ROOT_DEV nach $MNT"
mount -o subvolid=5 "$ROOT_DEV" "$MNT"

echo ">>> Vorhandene Subvolumes:"
btrfs subvolume list "$MNT" || true

# --- Speicherplatz-Check ---
# Jedes Byte auf / wird beim Migrieren einmal dupliziert: entweder landet es
# (unveraendert) in @, oder es landet zusaetzlich in seinem eigenen Subvolume,
# waehrend die Originalkopie bis zum Reboot weiter belegt bleibt. Der Gesamt-
# bedarf entspricht also ungefaehr der aktuell belegten Menge auf /, unabhaengig
# davon, wie sie sich auf @ und die einzelnen Subvolumes aufteilt.
echo ">>> Prüfe verfügbaren Speicherplatz"
USED_BYTES=$(df --output=used -B1 / | tail -1 | tr -d '[:space:]')
AVAIL_BYTES=$(df --output=avail -B1 / | tail -1 | tr -d '[:space:]')
REQUIRED_WITH_MARGIN=$(( USED_BYTES * 110 / 100 ))
if (( AVAIL_BYTES < REQUIRED_WITH_MARGIN )); then
  echo "FEHLER: Nicht genug freier Speicherplatz für die Migration." >&2
  echo "Benötigt (mit 10% Marge): ca. $(( REQUIRED_WITH_MARGIN / 1024 / 1024 )) MiB, verfügbar: $(( AVAIL_BYTES / 1024 / 1024 )) MiB." >&2
  echo "Grund: Während der Migration existieren alle Daten kurzzeitig doppelt (altes flaches Volume + neue Subvolumes)." >&2
  umount "$MNT"
  exit 1
fi
echo ">>> Speicherplatz-Check bestanden (${AVAIL_BYTES} Bytes frei, ca. ${REQUIRED_WITH_MARGIN} Bytes benötigt)."

create_subvol() {
  local name="$1"
  if btrfs subvolume list "$MNT" | awk '{print $NF}' | grep -qx "$name"; then
    echo "Subvolume $name existiert bereits – ok."
  else
    echo "Erzeuge Subvolume $name"
    btrfs subvolume create "$MNT/$name"
  fi
}

# --- Mapping Quelle -> Subvolume (für Daten); einzige Quelle der Wahrheit für
# Subvolume-Namen, Rsync-Ausschlüsse, Mountpoint-Vorbereitung, -Erzeugung und
# fstab-Einträge (siehe SUBVOL_OPTS weiter unten) ---
declare -a MAPS=(
"/root:@root"
"/home:@home"
"/var/spool:@spool"
"/var/log:@log"
"/var/cache:@cache"
"/var/tmp:@tmp_var"
"/srv:@srv"
"/tmp:@tmp"
"/opt:@opt"
"/var/lib/containers:@containers"
"/var/lib/docker:@docker"
"/var/lib/mongodb:@mongodb"
"/var/lib/mysql:@mysql"
"/var/lib/postgresql:@postgresql"
"/var/www:@www"
# Feste, versionsunabhaengige Pfade fuer benannte Volumes von Docker/Podman
# (getrennt von @docker/@containers, damit Volume-Daten nodatacow bekommen,
# waehrend Image-Layer/Metadaten weiterhin von compress=zstd profitieren).
"/var/lib/docker/volumes:@docker-volumes"
"/var/lib/containers/storage/volumes:@containers-volumes"
)

# Mount-Optionen je Subvolume (Datenbanken/Container-Volumes: nodatacow statt
# compress/autodefrag, da Copy-on-Write und Kompression sich schlecht mit
# Random-Write-Mustern vertragen).
declare -A SUBVOL_OPTS=(
  [@root]="noatime,compress=zstd,space_cache=v2"
  [@home]="noatime,compress=zstd,space_cache=v2,autodefrag"
  [@spool]="noatime,compress=zstd,space_cache=v2,autodefrag"
  [@log]="noatime,compress=zstd,space_cache=v2,autodefrag"
  [@cache]="noatime,compress=zstd,space_cache=v2"
  [@tmp_var]="noatime,compress=zstd,space_cache=v2"
  [@srv]="noatime,compress=zstd,space_cache=v2"
  [@tmp]="noatime,compress=zstd,space_cache=v2"
  [@opt]="noatime,compress=zstd,space_cache=v2"
  [@containers]="noatime,compress=zstd,space_cache=v2"
  [@docker]="noatime,compress=zstd,space_cache=v2"
  [@www]="noatime,compress=zstd,space_cache=v2"
  [@mongodb]="noatime,nodatacow,space_cache=v2"
  [@mysql]="noatime,nodatacow,space_cache=v2"
  [@postgresql]="noatime,nodatacow,space_cache=v2"
  [@docker-volumes]="noatime,nodatacow,space_cache=v2"
  [@containers-volumes]="noatime,nodatacow,space_cache=v2"
)

# --- Interaktive Auswahl: welche Subvolumes sollen angelegt werden? ---
# Alle sind vorausgewählt. Abgewählte Pfade bekommen kein eigenes Subvolume
# und bleiben einfach Teil von @ (Root) - das Skript braucht dafür keine
# Sonderbehandlung, da alles Weitere aus MAPS abgeleitet wird.
echo ">>> Geplante Subvolumes:"
for entry in "${MAPS[@]}"; do
  echo "    ${entry%%:*} -> ${entry##*:}"
done

if [[ -t 0 && -t 1 ]]; then
  need_pkg whiptail whiptail
  CHECKLIST_ARGS=()
  for entry in "${MAPS[@]}"; do
    CHECKLIST_ARGS+=("${entry##*:}" "${entry%%:*}" "ON")
  done
  SELECTED=$(whiptail --title "Btrfs-Subvolumes auswählen" \
    --checklist "Alle Subvolumes sind vorausgewählt. Leertaste = ab-/anwählen, Enter = bestätigen.\nAbgewählte Pfade bleiben einfach Teil von @ (Root)." \
    24 78 14 \
    "${CHECKLIST_ARGS[@]}" \
    3>&1 1>&2 2>&3) || { echo "Abgebrochen." >&2; umount "$MNT"; exit 1; }
  eval "SELECTED_ARR=($SELECTED)"

  FILTERED_MAPS=()
  for entry in "${MAPS[@]}"; do
    sub="${entry##*:}"
    for sel in "${SELECTED_ARR[@]}"; do
      if [[ "$sub" == "$sel" ]]; then
        FILTERED_MAPS+=("$entry")
        break
      fi
    done
  done
  MAPS=("${FILTERED_MAPS[@]}")
  echo ">>> Ausgewählt: ${#MAPS[@]} Subvolumes."
else
  echo ">>> Kein interaktives Terminal erkannt - alle Subvolumes werden angelegt (kein Auswahldialog)."
fi

# --- alle Subvolumes anlegen (Root @ wird später befüllt) ---
create_subvol "@"
for entry in "${MAPS[@]}"; do
  create_subvol "${entry##*:}"
done

sync_dir() {
  local src="$1"    # z.B. /home
  local subvol="$2" # z.B. @home
  shift 2
  local extra_excludes=("$@") # z.B. --exclude=/volumes/* fuer verschachtelte Subvolumes

  if [[ ! -d "$src" ]]; then
    echo "Quelle $src existiert nicht, überspringe."
    return
  fi

  echo ">>> Übertrage $src nach $subvol (überschreibend)"
  rsync -axHAX --delete "${extra_excludes[@]}" "$src"/ "$MNT/$subvol"/
}

# --- Bekannte Dienste vor der Kopie stoppen (konsistente Daten statt
# halbgeschriebener Dateien bei aktiv laufenden Datenbanken/Containern) ---
declare -A SRC_SERVICE=(
  ["/var/lib/mongodb"]="mongod"
  ["/var/lib/mysql"]="mysql"
  ["/var/lib/postgresql"]="postgresql"
  ["/var/lib/docker"]="docker"
  ["/var/lib/docker/volumes"]="docker"
)
declare -a STOPPED_SERVICES=()
declare -A ALREADY_HANDLED=()

for entry in "${MAPS[@]}"; do
  src="${entry%%:*}"
  svc="${SRC_SERVICE[$src]:-}"
  if [[ -n "$svc" && -z "${ALREADY_HANDLED[$svc]:-}" ]]; then
    ALREADY_HANDLED[$svc]=1
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      echo ">>> Stoppe $svc für eine konsistente Kopie"
      systemctl stop "$svc"
      STOPPED_SERVICES+=("$svc")
    fi
  fi
done

echo ">>> Übertrage /root, /home, /var/... in ihre Subvolumes"
for entry in "${MAPS[@]}"; do
  src="${entry%%:*}"
  sub="${entry##*:}"
  # /var/lib/docker/volumes und /var/lib/containers/storage/volumes bekommen
  # weiter unten ihr eigenes Subvolume - hier von der jeweiligen Elternkopie
  # ausschliessen, sonst landen sie doppelt (einmal hier, einmal separat).
  case "$src" in
    /var/lib/docker) sync_dir "$src" "$sub" --exclude=/volumes/* ;;
    /var/lib/containers) sync_dir "$src" "$sub" --exclude=/storage/volumes/* ;;
    *) sync_dir "$src" "$sub" ;;
  esac
done

for svc in "${STOPPED_SERVICES[@]}"; do
  echo ">>> Starte $svc wieder"
  systemctl start "$svc" || echo "WARNUNG: $svc konnte nicht neu gestartet werden – bitte manuell prüfen." >&2
done

# --- fstab im laufenden System anpassen ---
FSTAB="/etc/fstab"
backup="${FSTAB}.backup-$(date +%F-%H%M%S)"
echo ">>> Sicherung der aktuellen fstab nach $backup"
cp "$FSTAB" "$backup"

tmp="${FSTAB}.new"
echo ">>> Kommentiere alte Btrfs-Root-Zeile(n) aus"

awk '
  $0 !~ /^[[:space:]]*#/ && $2 == "/" && $3 == "btrfs" {
    print "#OLD-ROOT " $0
    next
  }
  { print }
' "$backup" > "$tmp"
mv "$tmp" "$FSTAB"

add_fstab_entry() {
  local mp="$1" sub="$2" opts="$3" pass="$4"
  if grep -Eq "^[^#[:space:]]+[[:space:]]+${mp}[[:space:]]+btrfs" "$FSTAB"; then
    echo ">>> fstab: Eintrag für ${mp} existiert bereits, überspringe."
  else
    echo "UUID=${UUID} ${mp} btrfs ${opts},subvol=${sub} 0 ${pass}" >> "$FSTAB"
    echo ">>> fstab: Eintrag für ${mp} hinzugefügt."
  fi
}

# Root mit subvol=@
add_fstab_entry / @ "noatime,compress=zstd,space_cache=v2" 1

# weitere Mounts (pass=2), Optionen aus SUBVOL_OPTS
for entry in "${MAPS[@]}"; do
  src="${entry%%:*}"
  sub="${entry##*:}"
  add_fstab_entry "$src" "$sub" "${SUBVOL_OPTS[$sub]}" 2
done

# --- GRUB-Konfiguration im laufenden System anpassen ---
if [[ -f /etc/default/grub ]]; then
  if grep -q "@rootfs" /etc/default/grub; then
    echo ">>> Ersetze @rootfs durch @ in /etc/default/grub"
    sed -i 's/@rootfs/@/g' /etc/default/grub
  else
    echo ">>> In /etc/default/grub kein @rootfs gefunden – ok."
  fi

  if command -v update-grub >/dev/null 2>&1; then
    echo ">>> update-grub ausführen"
    update-grub
  elif command -v grub-mkconfig >/dev/null 2>&1; then
    echo ">>> grub-mkconfig -o /boot/grub/grub.cfg ausführen"
    grub-mkconfig -o /boot/grub/grub.cfg
  else
    echo ">>> Hinweis: Weder update-grub noch grub-mkconfig gefunden – bitte ggf. manuell GRUB-Konfiguration aktualisieren."
  fi
else
  echo "WARNUNG: /etc/default/grub nicht gefunden – GRUB nicht angepasst." >&2
fi

# --- Root nach @ kopieren (JETZT, damit neue fstab & grub darin landen) ---
# Verzeichnisse, die ihr eigenes Subvolume bekommen, hier ausschliessen: sie
# wurden oben bereits per sync_dir befuellt und wuerden sonst redundant
# kopiert und per prepare_mp sofort wieder geloescht.
echo ">>> Kopiere aktuelles Root-Dateisystem nach @ (überschreibend)"
RSYNC_ROOT_EXCLUDES=(
  --exclude="$MNT/*"
  --exclude="/dev/*"
  --exclude="/proc/*"
  --exclude="/sys/*"
  --exclude="/run/*"
  --exclude="/mnt/*"
  --exclude="/media/*"
  --exclude="/lost+found"
)
for entry in "${MAPS[@]}"; do
  RSYNC_ROOT_EXCLUDES+=(--exclude="${entry%%:*}/*")
done
rsync -axHAX --delete "${RSYNC_ROOT_EXCLUDES[@]}" / "$MNT/@"

# --- Mountpoints im neuen Root (@) leeren, damit Subvolumes dort einhängen können ---
prepare_mp() {
  local mp="$1"             # z.B. /home
  local target="$MNT/@$mp"  # /mnt/btrfs-root/@/home
  mkdir -p "$target"
  rm -rf "$target"/* 2>/dev/null || true
}

echo ">>> Mountpoints im neuen Root (@) vorbereiten"
for entry in "${MAPS[@]}"; do
  prepare_mp "${entry%%:*}"
done

# --- Default-Subvolume auf @ setzen ---
echo ">>> Setze Default-Subvolume auf @"
set +e
SUBVOL_ID=$(btrfs subvolume list "$MNT" | awk '$NF=="@" {print $2}')
RET_LIST=$?
if [[ $RET_LIST -ne 0 ]]; then
  echo "WARNUNG: btrfs subvolume list hat einen Fehler geliefert (Code $RET_LIST). Default-Subvolume wird NICHT geändert."
else
  if [[ -n "$SUBVOL_ID" ]]; then
    if ! btrfs subvolume set-default "$SUBVOL_ID" "$MNT"; then
      echo "WARNUNG: btrfs subvolume set-default ist fehlgeschlagen – bitte manuell prüfen."
    fi
  else
    echo "WARNUNG: Konnte Subvolume-ID für @ nicht ermitteln – Default-Subvolume NICHT gesetzt."
  fi
fi
set -e

echo ">>> Erzeuge Mountpoints im laufenden System (falls noch nicht vorhanden)"
for entry in "${MAPS[@]}"; do
  mkdir -p "${entry%%:*}"
done

umount "$MNT"

# --- fstab validieren, ohne live umzumounten (kein Eingriff in laufende Dienste) ---
echo ">>> Validiere neue fstab mit 'findmnt --verify'"
if ! findmnt --verify; then
  echo "FEHLER: 'findmnt --verify' hat Probleme in der neuen fstab gefunden." >&2
  echo "Bitte ${FSTAB} pruefen, bevor du 'mount -a' ausfuehrst oder neu startest." >&2
  echo "Die alte fstab liegt gesichert unter ${backup}." >&2
  exit 1
fi
echo ">>> fstab-Validierung bestanden."

echo
echo ">>> FERTIG."
echo "Kontrolliere kurz mit:  cat /etc/fstab"
echo "Wenn dort die neuen Btrfs-Zeilen stehen, dann:"
echo "  mount -a"
echo "Wenn keine Fehler kommen:"
echo "  reboot"
echo
echo "Nach dem Reboot sollte / von subvol=@ und /home, /var/log, /var/lib/docker usw. von den jeweiligen Subvolumes kommen."
echo "Die alte fstab liegt gesichert unter ${FSTAB}.backup-<Datum>."
