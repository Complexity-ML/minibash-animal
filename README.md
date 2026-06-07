# Altitude Linux

**Altitude Linux 0.1 "Basecamp"** est une distribution hybride Rust + C + Bash,
pilotée par BDB. Le système livré est assemblé uniquement depuis le dépôt signé
Altitude et utilise son propre gestionnaire `pkg`, son init, son registre, son
graphe de services, sa console d'administration et son cycle d'évolution.

```bash
altitude
altitude --health
```

```text
Linux 7.0.10-altitude (paquet `altitude-kernel`, compilé par la forge Altitude)
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
    -> bdb/bdbc (C)       : moteur BDB natif, source de verite unique
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

Le moteur C publie chaque mutation via un WAL synchronisé sur disque. Après une
coupure, la première commande rejoue le journal et récupère automatiquement un
verrou laissé par le processus interrompu. `bdb check [TABLE]` vérifie la
structure, les types et l'unicité des clés primaires.

### Console d'administration

`bdbctl` rassemble les vues opérateur et les actions du système :

```bash
bdbctl summary
bdbctl health
bdbctl network
bdbctl service restart sshd
bdbctl shell
```

Le mode interactif est aussi lancé par `/bin/desktop`. Les profils réseau et les
comptes sont affichés sans exposer les PSK ni les hash de mots de passe.

### Registry et unités

La table `registry` stocke des valeurs typées dans une hiérarchie de chemins,
par exemple `/system/desktop/enabled`. `bdbreg` permet de les administrer :

```bash
bdbreg list /system
bdbreg set /apps/demo/enabled bool true demo
bdbreg get /apps/demo/enabled
```

`minit` lit déjà le réglage du bureau dans ce registre, et `keymap` y lit la
disposition clavier. La table `service_dependencies` fournit les relations
`requires`, `after` et `before` :

```bash
bdbctl dependencies
bdbctl dependency add graphical requires dbus
```

`minit` trie les unités, bloque les cycles et arrête les dépendants avant leurs
prérequis.

### Configuration versionnée

`bdbconf` fait le pont entre un fichier texte Git et l'état central BDB :

```bash
bdbconf export machine.conf
bdbconf check machine.conf
bdbconf diff machine.conf
bdbconf apply machine.conf
```

`apply` reconstruit les tables gérées dans une base temporaire, valide les types,
les clés et les services référencés, puis publie `registry` et
`service_dependencies` dans une seule transaction WAL. Une erreur ne modifie
rien. Le manifeste de référence est `/etc/minibash/system.conf`.

```text
bdbconf 1
registry /system/desktop/enabled bool system true
dependency graphical requires dbus
```

Le fichier texte représente l'intention versionnée; BDB représente l'état
runtime atomique; `minit` applique cet état au Linux réel.

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
pkg search [TERM]
pkg info NAME
pkg refresh
pkg check-updates
pkg install NAME
pkg upgrade [NAME]
pkg install-file /path/package.altpkg
pkg verify [NAME]
pkg remove NAME

altrepo init
altrepo keygen
altrepo add /path/package.altpkg
altrepo verify

minibash-update list
minibash-update slots
minibash-update stage VERSION /path/bzImage /path/initramfs.cpio.gz [sha256]
minibash-update commit UPDATE_ID
minibash-update mark-good SLOT
minibash-update rollback
```

Les composants propres à Altitude utilisent le format `.altpkg` v1 : manifeste
strict, payload, sommes SHA-256, dépôt indexé et signatures Ed25519. Le rootfs
installe actuellement `altitude-identity`, `altitude-core` et
`altitude-services`, ainsi que `altitude-access` pour la politique SSH, plus les
snapshots `altitude-base`, `altitude-kernel` et `altitude-firmware`, depuis le
dépôt Altitude embarqué. Une forge de bootstrap fournit encore certains
binaires tiers; le rootfs livré ne contient ni APT, ni dpkg, ni état Debian et
est reconstruit uniquement depuis le snapshot signé Altitude.

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

La clé USB garde un boot mini stable par défaut. Le runtime graphique Weston/foot
est transporté dans un deuxième initramfs `desktop.cpio.gz`, chargé uniquement
si l'entrée GRUB `minibash-linux desktop lab` est choisie.

Pour tester le desktop, choisir dans GRUB :

```text
minibash-linux desktop lab
```

Le boot par défaut reste `minibash-linux live`. Le dashboard `/bin/desktop`
reste utilisable dans une TTY même sans interface graphique : état services,
logs récents, shell interactif.

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
out/altitude-linux.iso                 # ISO Altitude stable
out/altitude-linux-usb.img             # image USB native UEFI
out/altitude-linux-disk.img            # image disque installable
```

La V1 stable utilise `7.0.10-altitude`, compilé depuis une source Linux
verrouillée par la forge et empaqueté avec ses modules signés. Son profil
générique x86_64 couvre les familles courantes de GPU, Wi-Fi, Ethernet,
stockage, USB, audio, Bluetooth et HID : il n'est pas spécifique au HP OMEN.
Les autres architectures auront leurs propres profils Altitude.

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

Pour tester le kernel de compatibilité avec notre initramfs en QEMU :

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
- `rootfs/bin/bdbctl` : console unifiée (services, réseau, stockage, noyau, mises à jour).
- `rootfs/bin/minibash-install`: première brique installateur disque.
- `rootfs/bin/pkg`    : gestionnaire de paquets Altitude.
- `rootfs/bin/altpkg-build`: constructeur du format `.altpkg`.
- `rootfs/bin/altrepo`: indexation et signature du dépôt Altitude.
- `rootfs/bin/minibash-update`: staging metadata d'upgrades.
- `rootfs/bin/desktop`: dashboard console/terminal pour le desktop minimal.
- `rootfs/bin/desktop-install`: installe le payload desktop depuis la partition data USB.
- `rootfs/bin/bdb`    : frontal du moteur BDB natif `bdbc` écrit en C.
- `rootfs/etc/minibash/bdb`: seed de la BDD (tables `services`, `users`, `logs`).
- `rootfs/services`   : services pilotés par la BDD.
- `docs/legacy-init.bash`: l'ancien PID 1 en Bash (v0.1), pour référence.
