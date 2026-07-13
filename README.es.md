# btrfs-layout-script

`setup-btrfs.sh` ayuda a convertir un **servidor Debian, Ubuntu u otra distribución basada en Debian con una única partición root en Btrfs** en un sistema con una estructura clara de subvolúmenes, listo para Timeshift y cargas de trabajo con contenedores. Funciona tanto para el cambio único en una instalación nueva como, después, en un sistema ya en marcha y migrado, para añadir los subvolúmenes que aún falten (sin necesidad de reiniciar).

## Idiomas

- [English](README.md)
- [Deutsch](README.de.md)
- Español (este archivo)

## Qué hace el script

En un sistema basado en Debian con root en Btrfs, el script:

- Detecta el dispositivo root actual con `findmnt` (por ejemplo `/dev/vda2[/@rootfs]` → `/dev/vda2`).
- Monta el nivel superior de Btrfs (`subvolid=5`) en `/mnt/btrfs-root`.
- Comprueba el espacio libre de antemano (cada byte en `/` se duplica brevemente durante la migración) y aborta si el espacio es insuficiente.
- Detecta una migración ya (parcialmente) realizada y cambia automáticamente a un **modo incremental**: si `/` ya se ejecuta desde un subvolumen con nombre, root, GRUB y el subvolumen por defecto no se tocan — solo se añaden subvolúmenes para las rutas destino que aún no están montadas por separado, activos de inmediato, sin necesidad de reiniciar. Cada ruta destino se clasifica individualmente: ya configurada correctamente (se omite, ni siquiera aparece en el diálogo de selección), ocupada por otra cosa (se omite con una advertencia, nunca se sobrescribe), o aún pendiente (candidata para selección).
- Pide confirmación explícita en una terminal interactiva (escribir "ja") antes de cambiar nada, con una advertencia sobre lo que hace el script y que un fallo puede dejar el sistema sin arrancar. Se omite sin terminal (ejecuciones automatizadas).
- Muestra un diálogo de selección interactivo (`whiptail`) si se ejecuta en una terminal: los subvolúmenes universalmente útiles (`@root`, `@home`, `@log`, `@cache`, `@tmp_var`, `@tmp`) están preseleccionados, todo lo que depende de la pila de software (bases de datos, Docker/Podman, docroot de servidor web) empieza deseleccionado — ambos ajustables libremente. Las rutas deseleccionadas simplemente se quedan en `@` sin subvolumen propio. Sin terminal interactiva (por ejemplo, ejecuciones automatizadas), solo se crean los subvolúmenes universalmente útiles sin preguntar.
- Detiene servicios conocidos (`mongod`, `mysql`, `postgresql`, `docker`) antes de copiar sus datos si están activos, y los reinicia después — para una copia consistente en lugar de archivos a medio escribir.
- Crea (de forma idempotente) los siguientes subvolúmenes:

  - `@` (nuevo root)
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

- Copia el sistema root actual a `@` (excluyendo `/dev`, `/proc`, `/sys`, `/run`, `/mnt`, `/media`, `/lost+found`, además de — derivado automáticamente del mapeo de abajo — cada ruta que tenga su propio subvolumen).
- Copia el contenido de los directorios principales a sus subvolúmenes:

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

  Los subvolúmenes de bases de datos (`@mongodb`, `@mysql`, `@postgresql`) y los volúmenes nombrados de Docker/Podman (`@docker-volumes`, `@containers-volumes`) se montan con `nodatacow` en lugar de `compress=zstd`/`autodefrag` — copy-on-write y compresión no combinan bien con el patrón de escritura aleatoria de las bases de datos, y los volúmenes pueden contener cualquier carga de trabajo con el mismo comportamiento. Las capas de imagen y metadatos en `@docker`/`@containers` no se ven afectados y siguen comprimidos.

- Prepara los puntos de montaje dentro del nuevo root (`@`) para que los subvolúmenes se puedan montar allí.
- Modifica `/etc/fstab` en el sistema actual:

  - crea una copia de seguridad `fstab.backup-YYYY-MM-DD-HHMMSS`,
  - comenta las líneas antiguas de root Btrfs como `#OLD-ROOT …`,
  - añade nuevas entradas Btrfs para `/`, `/home`, `/var/log`, `/var/lib/docker`, `/var/www`, etc., usando los subvolúmenes `@…` correspondientes.

- Ajusta GRUB (si está presente):

  - reemplaza `@rootfs` por `@` en `/etc/default/grub` si es necesario,
  - ejecuta `update-grub` o `grub-mkconfig -o /boot/grub/grub.cfg` si están disponibles.

- Define el subvolumen por defecto de Btrfs como `@`, de modo que el sistema arranque desde `@`.
- Asegura que los puntos de montaje necesarios también existan en el root actual (`/home`, `/var/lib/docker`, …).
- Valida el nuevo `/etc/fstab` automáticamente con `findmnt --verify` (solo lectura, no remonta nada en caliente) y aborta antes de que reinicies por error con un fstab roto.

Resultado:

- Root se ejecuta desde `@` (compatible con Timeshift).
- Rutas importantes como `/home`, `/var/log`, `/var/lib/docker`, `/var/www` viven en subvolúmenes separados.

## Requisitos

- Sistema Debian o basado en Debian con:
  - `apt`
  - `systemd`
- Sistema de ficheros root en **Btrfs** sobre un único dispositivo (por ejemplo una partición Btrfs `/dev/vda2`).
- Ejecutar el script como **root**.

El script instalará automáticamente, si faltan:

- `rsync`
- `btrfs-progs`

> Lo más sencillo es usarlo en una **instalación nueva de servidor**, ya que ahí todos los directorios están vacíos o son pequeños. Pero el script también funciona en sistemas ya en producción, **siempre que haya suficiente espacio libre** (se comprueba automáticamente — cada byte en `/` se duplica brevemente durante la migración). Para una copia consistente, los servicios conocidos (`mongod`, `mysql`, `postgresql`, `docker`) se detienen automáticamente antes de copiar sus datos y se reinician después.
>
> Aun así, en un sistema en producción: haz una copia de seguridad antes, planifica una ventana de mantenimiento para el reinicio final, y ten en cuenta que las aplicaciones **fuera** de esta lista (por ejemplo Podman, o un proceso de servidor web propio con archivos abiertos en `/srv` o `/var/www`) siguen funcionando durante la copia y en teoría podrían acabar con una instantánea inconsistente en su subvolumen.

## Uso

1. Instala Debian de forma que tengas:

   - una pequeña partición EFI (por ejemplo `/dev/vda1`),
   - una partición grande en Btrfs como root (por ejemplo `/dev/vda2`).

2. Inicia sesión como root (o usa `sudo`).

3. Clona este repositorio:

   ```bash
   git clone https://github.com/<tu-usuario>/btrfs-layout-script.git
   cd btrfs-layout-script
   ```

4. Haz el script ejecutable:

   ```bash
   chmod +x setup-btrfs.sh
   ```

5. Ejecútalo:

   ```bash
   sudo ./setup-btrfs.sh
   ```

6. Revisa `/etc/fstab` y comprueba que:

   - `/` usa `subvol=@`,
   - las rutas adicionales (`/home`, `/var/log`, `/var/lib/docker`, `/var/www`, …) tienen entradas Btrfs con los subvolúmenes `@…` esperados.

7. Aplica y prueba los montajes:

   ```bash
   systemctl daemon-reload
   mount -a
   ```

   No debería mostrar errores.

8. Reinicia:

   ```bash
   reboot
   ```

9. Después del reinicio, verifica:

   ```bash
   findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS /
   findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS /home /var/log /var/lib/docker /var/www
   ```

   Deberías ver:

   - `/` desde `...[/@]` con `subvol=@`,
   - `/home` desde `...[/@home]`, etc.

En este punto, Timeshift puede usar `@` como subvolumen root y tu diseño está listo para snapshots y contenedores.

## Licencia

Este proyecto está licenciado bajo la **GNU General Public License versión 3 o posterior (GPL-3.0-or-later)**.

Consulta el archivo `LICENSE` para más detalles.
