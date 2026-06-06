# minibash : un Linux piloté par une base de données

## La thèse

Linux classique = **« tout est fichier »**, éparpillé : `/etc/fstab`, `/etc/passwd`,
`modprobe.d`, des scripts d'init, `crontab`, `sysctl.conf`, `resolv.conf`…
L'état du système est dispersé dans des dizaines de formats de fichiers.

minibash = **un Linux HYBRIDE**. On **garde le vrai Linux dessous** (Debian, le
kernel, les fichiers, les syscalls) et on pose une **base de données comme plan
de contrôle au-dessus**. Le moteur **`bdbc`** (C natif, format binaire `BDB1`)
détient l'état *désiré* du système ; des **réconciliateurs** **actionnent** le
Linux réel (`modprobe`, `mount`, `ip`, fork de daemons…) pour converger vers ce
désiré, puis **réécrivent le `status` réel** dans la base.

> ⚠️ **Hybride, pas puriste.** La base ne *remplace* pas les fichiers — elle les
> **pilote**. `/etc`, les modules, les FS restent là (c'est Linux). La base est
> la **façade unique** (source de vérité + API d'admin) ; les fichiers/syscalls
> sont la **couche d'actionnement** dessous, et restent une **trappe de secours**
> (on peut toujours descendre au fichier si besoin). « Entre Windows et Linux. »

On **interroge** l'OS (`bdb select`), on le **modifie** (`bdb update`), il se
**reconfigure tout seul**. C'est l'idée de Kubernetes (état désiré déclaratif +
boucle de réconciliation), mais pour **un OS, en local, en quelques Ko de C**.

## Le modèle

```
   bdb (tables)            réconciliateurs                réel
  ┌──────────────┐        ┌────────────────┐           ┌──────────┐
  │ desired=up   │ ─────► │ minit / kmod / │ ────────► │ process, │
  │ status=...   │ ◄───── │ netmgr / ...   │ ◄──────── │ modules, │
  └──────────────┘ write  └────────────────┘  observe  │ mounts…  │
       back status                                      └──────────┘
```

- Chaque **domaine** du système = une **table** (l'état désiré).
- Un **réconciliateur** par domaine lit la table, applique, **réécrit le `status` réel**.
- `minit` (PID 1, Rust) est le réconciliateur central des services ; il déclenche les autres.

## Le schéma de l'OS (les tables = l'OS)

| Table        | Remplace (fichiers Linux)        | Réconciliateur | État |
|--------------|----------------------------------|----------------|------|
| `services`   | systemd / init.d / rc            | `minit`        | ✅   |
| `modules`    | `/etc/modules`, `modprobe.d`     | `kmod`         | 🆕 conçu |
| `network`    | `/etc/network`, NetworkManager   | `netmgr`       | ✅   |
| `users`      | `/etc/passwd`, `/etc/shadow`     | `login`        | ✅   |
| `packages`   | état dpkg                        | `pkgd`         | ✅   |
| `mounts`     | `/etc/fstab`                     | `mountd` 🆕    | à faire |
| `cron`       | `crontab`                        | `cron`         | ✅   |
| `sysctl`     | `/etc/sysctl.conf`               | `sysctld` 🆕   | à faire |
| `hosts`      | `/etc/hosts`                     | `hostsd` 🆕    | à faire |
| `env`        | `/etc/environment`               | (au login)     | à faire |
| `firewall`   | `iptables` / `nft`               | `fwd` 🆕       | à faire |
| `logs`       | journald / syslog                | `syslog`       | ✅   |

## Pourquoi c'est mieux que des fichiers

- **Requêtable** : l'état complet du système en **une** requête, filtrable
  (`bdb select services --where desired=up`). Impossible en « tout fichier ».
- **Déclaratif + convergent** : tu déclares `desired`, le système **converge**.
  Pas de « j'ai édité le fichier mais le service tourne encore avec l'ancien ».
- **Atomique** : écritures sous verrou + `tmp`+`rename` (déjà dans `bdbc`).
- **Introspectable** : le `status` réel est **réécrit** → on voit ce qui a marché
  ou échoué. Ex : `modules.status=failed` aurait crié « ccm pas chargé » dès le
  1er jour (au lieu de 3 jours de faux « WRONG_KEY » wifi).
- **Source unique de vérité** : fini `/etc` dispersé ; un `bdb dump` = tout l'OS.
- **Scriptable / API** : `bdb` EST l'API d'admin. Pas de parsing de 15 formats.

## Le « wow »

Un OS qu'on administre avec des **UPDATE** et qui se reconfigure seul :

```sh
bdb update services --where name=graphical desired=up   # le bureau démarre
bdb insert  modules  name=ccm params="" stage=crypto autoload=true status=unloaded description="cle CCMP"
bdb update network  --where ssid=Livebox-E130 psk=...    # change le wifi en vivant
bdb insert  mounts   src=/dev/sdb1 dst=/mnt/data fstype=ext4 opts=rw desired=mounted status=...
```

Le bug `ccm` des 3 jours wifi devient **une ligne de base**, visible et éditable,
au lieu d'une liste `modprobe` codée en dur dans un script.

## Ce qui reste à construire (ordre proposé)

1. **`kmod`** (fait) : réconcilie `modules` → `modprobe` + status. Le câbler 1er service.
2. **Boucle de réconciliation générique** dans minit : `desired` vs `status` pour
   N'IMPORTE quelle table « domaine » (pas juste `services`).
3. **`mountd`** (`mounts` → `mount`/`umount`) — le plus parlant après les services.
4. **`sysctld`**, **`hostsd`**, **`fwd`** — au fil de l'eau.
5. **Transactions** dans `bdbc` (`begin`/`commit`) pour changer plusieurs tables
   d'un coup atomiquement (ex : ajouter un user + son mount + son service).

## Garde-fous (sinon on se tire une balle)

- La base vit sur disque persistant (`/var/bdb`) ; un seed idempotent la
  reconstruit si vide (`seed.sh`).
- Les réconciliateurs doivent être **idempotents** et **sans état caché** : tout
  l'état dans la table, rien en mémoire.
- Un mode « observe-only » (dump) pour debugger sans rien appliquer.
