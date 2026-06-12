# Altitude IDE

Altitude IDE is the native development surface for building Altitude Linux
from inside Altitude itself. It is not Vim with branding and it is not a VS
Code fork. The direction is an Altitude-owned IDE with a scriptable agentic
core, a simple graphical shell, and standard Linux integration points.

The upstream IDE repository is:

```text
https://github.com/Complexity-ML/Altitude-IDE
```

## Distribution contract

Altitude Linux currently embeds the IDE in `altitude-dev-tools` while the
runtime contract stabilizes. The files are:

```text
/bin/alt-ide
/bin/altitude-ide-ui
/usr/share/applications/altitude-ide.desktop
```

`alt-ide` is the stable command interface. Graphical tools, SSH sessions and
future agents should call it instead of duplicating IDE logic.

Required command groups:

```text
alt-ide workspace status
alt-ide files list
alt-ide files open PATH
alt-ide actions list
alt-ide actions run ACTION_ID [ARGS...]
alt-ide diagnostics run
alt-ide session start NAME
alt-ide session run ACTION_ID [ARGS...]
alt-ide session tail
alt-ide agent context [PATH...]
alt-ide language bash lint PATH
alt-ide language bash run PATH [ARGS...]
```

Session logs default to `/var/log/altitude/ide.log`; volatile session state
defaults to `/run/altitude-ide`. Those paths make SSH work observable without
forcing the IDE to become a service manager.

## Desktop contract

`altitude-ide-ui` is the first GNOME-facing IDE shell. It provides a workspace
file browser, a monospace text editor, save support, Bash lint/run shortcuts,
agent actions, and an output panel. It discovers files with `alt-ide files
list`, discovers actions with `alt-ide actions list`, and executes workflows
with `alt-ide session run`.

The UI must stay light: workflows belong in the CLI so they remain testable,
usable over SSH, and portable to later frontends. Large features should become
modules before the UI grows into an opaque JavaScript bundle. Electron is
allowed later if it stays readable and modular; it must remain an app shell
over the `alt-ide` backend rather than swallowing the whole IDE logic.

Vim can remain installed as an editor fallback, but it must not be the default
Altitude IDE experience. Desktop launchers should expose `altitude-ide` and
hide legacy Vim wrappers with `NoDisplay=true`.

## Package split

Once the IDE API is stable enough, `altitude-dev-tools` should stop owning the
IDE sources directly. The target package split is:

```text
altitude-ide
  source: https://github.com/Complexity-ML/Altitude-IDE
  payload:
    /bin/alt-ide
    /bin/altitude-ide-ui
    /usr/share/applications/altitude-ide.desktop

altitude-dev-tools
  payload:
    agent helpers
    diagnostics wrappers
    fallback editor configuration
```

That keeps the distro clean: Altitude Linux packages and boots the IDE, while
the IDE repo can evolve its own UI, actions and agentic workflows.

## Registry boundary

The registry may audit IDE state, package metadata and session health. It
should not become the editor, service manager or package transaction engine.
The IDE talks to the standard Altitude command interfaces (`pkg`, `altreg`,
`systemctl` through audit helpers when present) and records useful state for
humans and agents to inspect.
