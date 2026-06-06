# Altitude package system

## Scope of version 1

Altitude packages own Altitude-specific files. Debian `debootstrap` remains a
temporary bootstrap provider for the kernel, libc and third-party software.
Moving a component into an Altitude package removes it from the direct overlay;
the bootstrap can then shrink without changing the installed-system contract.

## Package format

An `.altpkg` file is a tar archive with exactly two roots:

```text
ALTITUDE/MANIFEST
ALTITUDE/files.sha256
payload/...
```

The manifest is declarative and is never sourced as shell code. Required
fields are `Name`, `Version`, `Architecture` and `Description`. Every regular
payload file is covered by `files.sha256`. `pkg` rejects absolute paths,
parent-directory traversal, invalid metadata and checksum mismatches.

## Repository and trust

`altrepo` publishes packages under `packages/`, creates the stanza-based
`INDEX`, and signs both packages and index with Ed25519. Installed systems only
contain the public key in `/etc/altitude/keys/repository.pem`. The private key
stays in the release environment and is excluded from git and images.

The default repository is local and embedded:

```text
file:///var/lib/altitude/repository
```

The same format supports HTTPS. A production server only needs to serve the
repository directory as static files.

## Release policy

Altitude uses semantic versions for owned packages and named OS releases:

```text
0.1 Basecamp
0.2 Ridgeline
1.0 Summit
```

Each published package is immutable. A changed payload requires a new version.
Repository signing keys are offline release assets. Security fixes receive a
new package version, are published to a staging repository, pass package and
boot tests, then are promoted to stable. Kernel and initramfs updates continue
to use the existing A/B boot slots so a failed boot can roll back.

## Next migration layers

1. Package every Altitude service and configuration file.
2. Build a package dependency solver and an upgrade transaction.
3. Repackage the kernel, firmware and base userspace.
4. Generate the rootfs only from an Altitude repository snapshot.
5. Operate separate stable, testing and security repositories.
