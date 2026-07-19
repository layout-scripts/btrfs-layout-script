# snapper-layout-script

`setup-snapper.sh` convierte un servidor Debian, Ubuntu u otro basado en Debian cuyo sistema de archivos raíz ya se ejecuta desde un subvolumen Btrfs con nombre (por ejemplo mediante [btrfs-layout-script](https://github.com/layout-scripts/btrfs-layout-script)) en una configuración de Snapper al estilo SUSE: instantáneas de línea de tiempo automáticas, instantáneas alrededor de cada cambio de paquete `apt` e instantáneas arrancables directamente desde el menú de GRUB mediante `grub-btrfs`.

## Idiomas

- [English](README.md)
- [Deutsch](README.de.md)
- Español (este archivo)

## Qué hace el script

En un sistema Debian (o basado en Debian) cuyo `/` ya está en un subvolumen Btrfs con nombre, el script:

- Verifica que `/` sea Btrfs y se ejecute desde un subvolumen con nombre (p. ej. `@`); si no, aborta indicando que se ejecute antes `btrfs-layout-script`.
- Crea antes del primer cambio una instantánea Btrfs read-only del subvolumen raíz actual (p. ej. `@.before-snapper-setup-...`) como punto de recuperación manual si la configuración falla.
- Instala `snapper` e `inotify-tools` (necesario para que `grub-btrfsd` detecte nuevas instantáneas) si faltan.
- Pide confirmación explícita en una terminal interactiva (escribiendo "ja") antes de cambiar nada. Sin terminal, el script aborta salvo que `LAYOUT_SCRIPT_ASSUME_YES=1` esté definido.
- Crea la configuración `root` de Snapper (idempotente — se omite si ya existe), lo que crea `.snapshots` como subvolumen Btrfs anidado.
- Añade `.snapshots` como entrada propia en `/etc/fstab` y lo monta. La `fstab` anterior se guarda antes y se restaura automáticamente si falla `findmnt --verify` o `mount -a`.
- Establece una política de línea de tiempo al estilo SUSE en `/etc/snapper/configs/root` (`TIMELINE_CREATE`, `TIMELINE_CLEANUP`, `NUMBER_CLEANUP` y valores conservadores de `TIMELINE_LIMIT_*` para hora/día/semana/mes/año).
- Instala hooks propios de `apt` (`DPkg::Pre-Invoke`/`DPkg::Post-Invoke`) que crean un par de instantáneas pre/post en cada cambio de paquete — a diferencia del plugin `zypp` de openSUSE, Debian/Ubuntu no incluye esta integración, así que el script escribe pequeños scripts auxiliares para ello.
- Activa los temporizadores systemd `snapper-timeline.timer` y `snapper-cleanup.timer`.
- Instala `grub-btrfs` si está disponible en los repositorios APT configurados, activa `grub-btrfsd` y ejecuta `update-grub` (o `grub-mkconfig`) para que las instantáneas aparezcan como entradas arrancables de solo lectura en el menú de GRUB. Si el paquete no está disponible, la configuración de Snapper continúa sin integración en el menú de GRUB.

### Limitaciones

Examinar instantáneas, comparar archivos individuales y arrancar en modo solo lectura una instantánea desde el menú de GRUB (`grub-btrfs`) funcionan con esta configuración si `grub-btrfs` está disponible. La instantánea de guardia es read-only a propósito y sirve como punto de recuperación manual: arrancar un sistema de rescate, montar el top-level de Btrfs, crear desde ella una nueva instantánea raíz escribible y ajustar de nuevo bootloader/fstab. Una **reversión completa del sistema** arrancable como la que hace `snapper rollback` en openSUSE requiere además que root se ejecute desde dentro de un subvolumen `.snapshots/<N>/snapshot`; esto no ocurre automáticamente con un diseño `@` simple.

## Requisitos

- Sistema Debian o basado en Debian con `apt` y `systemd`.
- Sistema de archivos raíz ya en un subvolumen Btrfs **con nombre** (si no, ejecutar antes [btrfs-layout-script](https://github.com/layout-scripts/btrfs-layout-script)).
- Ejecutar el script como **root**.

El script instalará los siguientes paquetes si faltan: `snapper`, `inotify-tools`, opcionalmente `grub-btrfs`.

## Uso

1. Asegurarse de que `/` ya se ejecuta desde un subvolumen Btrfs con nombre (ver [btrfs-layout-script](https://github.com/layout-scripts/btrfs-layout-script)).

2. Clonar este repositorio:

   ```bash
   git clone https://github.com/layout-scripts/snapper-layout-script.git
   cd snapper-layout-script
   ```

3. Hacer el script ejecutable y ejecutarlo:

   ```bash
   chmod +x setup-snapper.sh
   sudo ./setup-snapper.sh
   ```

   Para ejecuciones automatizadas sin terminal:

   ```bash
   sudo LAYOUT_SCRIPT_ASSUME_YES=1 ./setup-snapper.sh
   ```

4. Verificar:

   ```bash
   snapper list-configs
   snapper create -d test && snapper list && snapper delete <número>
   systemctl status snapper-timeline.timer snapper-cleanup.timer grub-btrfsd
   ```

   Instalar/eliminar un paquete pequeño para confirmar que los hooks de `apt` crean un par de instantáneas pre/post, y reiniciar para confirmar que el menú de GRUB muestra un submenú de instantáneas.

## Licencia

Este proyecto está licenciado bajo la **GNU General Public License v3.0 o posterior (GPL-3.0-or-later)**.

Ver el archivo `LICENSE` para más detalles.
