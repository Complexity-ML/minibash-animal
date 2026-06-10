# Altitude Software and Registry

Altitude has three separate layers:

1. `altpkg` installs signed `.altpkg` archives.
2. `altrepo` publishes a signed package repository.
3. The BDB registry stores Altitude configuration and package metadata.

The registry is not a replacement for every Linux runtime API. It is the native
Altitude control plane. Packages may still expose standard Linux integration
points when software expects them:

- D-Bus services in `/usr/share/dbus-1`;
- desktop launchers in `/usr/share/applications`;
- login/session APIs through `elogind` or a future `systemd-logind` provider;
- systemd unit files when a package benefits from shipping them.

The default desktop image keeps BusyBox init as PID 1 and uses `elogind` for the
GNOME login1 API, but it explicitly records systemd compatibility in the
registry:

```text
/system/init/provider = busybox-init
/system/init/systemd/compatible = true
/system/init/systemd/required = false
```

That means the registry must not block systemd-shaped package data. It decides
what Altitude starts by default; it does not forbid packages from carrying
systemd units, D-Bus activation files, AppStream metadata, or other standard
Linux files.

`Altitude Software` is the first GNOME-facing package manager shell. It calls
`pkg refresh`, `pkg search`, `pkg info`, `pkg install`, and shows native desktop
applications discovered from `.desktop` files. Later registry work should add
package categories, app screenshots, permissions, service declarations and
remote repository channels without changing the package archive contract.
