# minibash-linux

# minibash-hack

Mini distro Linux hybride (Rust + Bash). **v0.8**

```text
Linux kernel (stable ISO: Debian vmlinuz connu-good; lab: bzImage custom)
  -> initramfs minimal
    -> /init = minit (Rust, PID 1)
         · mount fs · hostname · lo up
         · persistance : monte le disque /dev/vda (ext2) sur /var/bdb (format si vierge)
         · seed BDD conditionnel (garde les donnees si le disque en a deja)
         · reaper        : waitpid(-1) moissonne TOUS les enfants (zombies inclus)
         · reconciler    : applique l'etat "desired" de la BDD (start/stop)
         · watchdog       : relance les services restart=true qui crashent
         · signaux        : SIGTERM/SIGINT -> shutdown propre (sync+umount+reboot)
         · console        : lance /bin/login (supervise, respawn)
         · log shipper    : recopie les logs services dans la table BDD `logs`
    -> bdbboot (Rust)     : resume des services au boot
    -> login (Bash)       : auth contre la table `users` de la BDD (+ autologin kernel)
    -> bashsvc (Bash)     : client de controle (ne lance plus rien lui-meme)
    -> bdb (Bash)         : la BDD, source de verite unique (base64 en Bash pur)
    -> services Bash      : clock, web, metrics, cron, netd, syslog, healthd,
                             pkgd, updated, sshd, desktopd, worker, installer
```

## Architecture

Le PID 1 est **minit**, écrit en Rust sans dépendance externe (syscalls déclarés
en `extern "C"`). Il fait ce qu'un PID 1 en Bash ne peut pas faire : moissonner
les orphelins ré-attachés, gérer les signaux, arrêter proprement la machine.

La **base de données `bdb` reste la seule source de vérité**, et elle est
**persistante** : minit monte un disque sur `/var/bdb`, donc services, état
`desired`, utilisateurs et logs survivent aux reboots.

### Persistance disque

minit cherche un disque (`/dev/vda`, virtio), le formate en ext2 au premier boot
(`busybox mke2fs`) puis le monte sur `/var/bdb`. Le seed n'est appliqué que si le
disque est vierge ; sinon les données existantes sont conservées. Sans disque, on
retombe sur un `/var/bdb` volatile (ramdisk).

### Login

La console lance `/bin/login`, qui authentifie contre la table `users` de la BDD
(`root` / `root`, et `minibash` / `minibash`). Options de boot kernel, comme
`agetty --autologin` :

```text
minibash.user=NAME        pré-remplit le nom de login
minibash.autologin=NAME   connecte NAME sans mot de passe (console dev)
```

### Schéma `services`

```
name  command  autostart  restart  desired  status  pid  description
```

- `desired=up`   → minit garde le service vivant
- `restart=true` → relancé s'il crashe (watchdog)
- `restart=false`→ one-shot : minit le passe `desired=down` après sa sortie

Services seedés : `clock`, `web` (serveur HTTP), `metrics` (monitoring), `cron`
(scheduler), `netd` (état réseau), `syslog` (logs système), `healthd`
(audit santé), `pkgd` (package daemon), `updated` (watcher upgrades),
`sshd` (Dropbear, désactivé par défaut), `desktopd` (Weston/Wayland minimal,
désactivé par défaut), `worker` (one-shot), `installer` (helper manuel).

## Packages et upgrades

```bash
pkg list
pkg install NAME VERSION /path/pkg.tar [sha256]
pkg remove NAME

minibash-update list
minibash-update slots
minibash-update stage VERSION /path/bzImage /path/initramfs.cpio.gz [sha256]
minibash-update commit UPDATE_ID
minibash-update mark-good SLOT
minibash-update rollback
```

`updated` utilise maintenant une table `boot_slots` A/B persistante. `stage`
copie un kernel+initramfs vers le slot inactif, `commit` marque ce slot
`pending` et réécrit `/boot/extlinux/extlinux.conf`.

## SSH

Le service `sshd` utilise Dropbear si le binaire est présent dans l'image. Il
est seedé en `desired=down` volontairement :

```bash
bashsvc enable sshd
```

## Desktop minimal

La clé USB garde un initramfs mini et stable. Le runtime graphique Weston/foot
est transporté à côté, dans une deuxième partition ext2 `MINIBASHDATA`, sous la
forme d'un payload `minibash-desktop/desktop-root.tar.gz`.

Pour tester le desktop après boot :

```bash
desktop-install
bashsvc enable desktopd
```

`desktopd` tente aussi `desktop-install --auto` si Weston n'est pas encore
présent. Le dashboard `/bin/desktop` reste utilisable dans une TTY même sans
interface graphique : état services, logs récents, shell interactif.

## Installation disque et bootloader

La distro sait déjà utiliser un disque persistant pour `/var/bdb`. La première
brique installateur pose maintenant un layout A/B + extlinux :

```bash
minibash-install \
  --target /dev/DEVICE \
  --kernel /path/bzImage \
  --initramfs /path/minibash-linux-initramfs.cpio.gz \
  --yes
```

Il formate la cible en ext2, seed la BDD, copie le kernel+initramfs dans les
slots `/boot/minibash/A` et `/boot/minibash/B`, écrit
`/boot/extlinux/extlinux.conf`, lance `extlinux --install`, puis écrit le MBR
Syslinux si `mbr.bin` est disponible.

## Build

```bash
cd /Users/boris/Dev/minibash-linux
./run-docker-build.sh
./run-docker-iso.sh
```

`run-docker-iso.sh` produit deux images :

```text
out/minibash-linux.iso                 # ISO stable, kernel Debian connu-good
out/minibash-linux-custom-kernel.iso   # ISO lab, kernel custom minibash
out/minibash-linux-usb.img             # USB native UEFI + partition desktop data
```

La V1 stable utilise un kernel Debian extrait de `linux-image-amd64`, parce qu'il
boote correctement sur le HP OMEN avec notre initramfs. Le kernel custom reste
dans `kernel/bzImage` et sert de laboratoire. Pour le recompiler :
`BUILD_KERNEL=1`.

Le script `scripts/fetch-debian-kernel.sh` télécharge le paquet kernel Debian et
extrait seulement `vmlinuz`, sans installer le paquet ni générer d'initrd Debian.

Le script `build-desktop-payload.sh` construit le payload desktop séparé, sans
le gonfler dans l'initramfs. `build-usb.sh` peut l'embarquer dans une deuxième
partition :

```bash
DESKTOP_PAYLOAD_TAR=out/minibash-desktop-root.tar.gz \
DESKTOP_PAYLOAD_MANIFEST=out/minibash-desktop-MANIFEST \
./build-usb.sh
```

## Boot

```bash
./run-qemu-docker.sh
```

Crée un disque persistant `out/minibash-disk.img` (256 MiB) au premier lancement
et le réutilise ensuite. Login : `root` / `root`.

## Utilisation (dans la console, après login)

```bash
bashsvc status            # services + pids live (verifies via /proc)
bashsvc logs metrics      # lignes de log capturees dans la BDD
bashsvc start worker      # lance le job one-shot
bashsvc restart web
bashsvc stop cron
busybox wget -qO- http://127.0.0.1/   # le vrai serveur HTTP (toujours sur lo)
bashsvc poweroff          # arret propre (QEMU se ferme)
```

Avec `-p 8080:8080` (dans `run-qemu-docker.sh`) le web est joignable depuis
l'hôte sur `http://localhost:8080/`.

## Test

```bash
./tests/boot-smoke.sh
```

Pour tester le kernel Debian connu-good avec notre initramfs en QEMU :

```bash
docker run --rm --platform linux/amd64 -v /Users/boris/Dev:/work \
  minibash-linux-builder \
  qemu-system-x86_64 -m 512M -nographic \
  -kernel /work/minibash-linux/out/debian-vmlinuz \
  -initrd /work/minibash-linux/out/minibash-linux-initramfs.cpio.gz \
  -append 'console=ttyS0 init=/init panic=0 loglevel=7 minibash.tty=ttyS0 minibash.autologin=root'
```

## Pièces importantes

- `rust/minit`        : PID 1 (init + superviseur + persistance) en Rust.
- `rust/bdbboot`      : résumé des services au boot.
- `rootfs/bin/login`  : login Bash (table `users` + autologin kernel).
- `rootfs/bin/bashsvc`: client de contrôle du superviseur.
- `rootfs/bin/minibash-install`: première brique installateur disque.
- `rootfs/bin/pkg`    : package manager minimal.
- `rootfs/bin/minibash-update`: staging metadata d'upgrades.
- `rootfs/bin/desktop`: dashboard console/terminal pour le desktop minimal.
- `rootfs/bin/desktop-install`: installe le payload desktop depuis la partition data USB.
- `rootfs/bin/bdb`    : la BDD Bash relationnelle (base64 en Bash pur, sans fork).
- `rootfs/etc/minibash/bdb`: seed de la BDD (tables `services`, `users`, `logs`).
- `rootfs/services`   : services pilotés par la BDD.
- `docs/legacy-init.bash`: l'ancien PID 1 en Bash (v0.1), pour référence.
