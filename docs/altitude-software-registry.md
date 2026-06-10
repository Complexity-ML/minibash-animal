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
- login/session APIs through `elogind` while `systemd-logind` is disabled;
- systemd unit files when a package benefits from shipping them.

The default desktop image boots through the tiny Altitude initramfs and then
switches to systemd as PID 1. BusyBox init remains available as a bootloader
fallback, but the normal registry state is systemd:

```text
/system/init/provider = systemd
/system/init/systemd/required = true
/system/systemd/runtime/present = true
/system/systemd/runtime/pid1 = true
```

That means the registry must not block systemd-shaped package data. It decides
what Altitude starts by default; it does not forbid packages from carrying
systemd units, D-Bus activation files, AppStream metadata, or other standard
Linux files.

The same rule applies to services, but the target architecture is stricter:
the BDB must not become a service manager. Services live outside the BDB.
When systemd is available, systemd owns lifecycle control.

```text
/system/systemd/audit/enabled = true
/system/systemd/audit/table = systemd_audit
/system/systemd/audit/control = false
/system/systemd/runtime/present = true
/system/systemd/runtime/pid1 = true
```

In that model, `systemd-audit` may run `systemctl list-units`, `systemctl show`
and journal queries, then write normalized observed state into BDB. Admin tools
can read BDB for a fast unified view, but service mutations remain systemd
operations or unit files. The BDB is audit and registry, not service control.

`Altitude Software` is the first GNOME-facing package manager shell. It calls
`pkg refresh`, `pkg search`, `pkg info`, `pkg install`, and shows native desktop
applications discovered from `.desktop` files. Later registry work should add
package categories, app screenshots, permissions, service declarations and
remote repository channels without changing the package archive contract.
