# Deploying

## Build

```sh
snapcraft pack                 # -> <name>_<version>_<arch>.snap
```

snapcraft builds in an LXD container, so the host doesn't need nginx or any
build dependencies. After deleting or renaming files under `snap/hooks/` or
`src/`, run `snapcraft clean` first: snapcraft caches parts and keeps files
that no longer exist in the source.

### Other architectures

By default you get a snap for the machine you build on. To also ship
`arm64` (Raspberry Pi, Graviton, Ampere), add to `snap/snapcraft.yaml`:

```yaml
platforms:
  amd64:
  arm64:
```

and build on Launchpad's builders with `snapcraft remote-build`, which needs
a Launchpad account. The snap contains no compiled code of its own, but
nginx comes from each architecture's Ubuntu archive.

## Test

```sh
tests/lxd-smoke.sh                       # newest *.snap in the repo
tests/lxd-smoke.sh path/to/file.snap
KEEP=1 tests/lxd-smoke.sh                # keep the container to poke around
LXD_IMAGE=ubuntu:22.04 tests/lxd-smoke.sh
```

It installs the snap in a fresh container and checks:

- the site and every file in it
- 404s and hidden dotfiles
- the developer pages
- every setting, including rejection of invalid values
- start/stop/restart/reload
- what works without `sudo`
- that settings survive a refresh
- the nginx error log
- AppArmor denials, read from the host kernel log (needs permission to read
  it, e.g. membership of the `adm` group)

It ends with `ALL CHECKS PASSED`; the exit status is the number of failures.

## Publish

One-time setup:

```sh
snapcraft login
snapcraft register <name>          # add --private to hide it from search
```

Every release:

```sh
# bump `version` in snap/snapcraft.yaml, then
snapcraft pack
tests/lxd-smoke.sh
snapcraft upload <name>_<version>_amd64.snap --release=edge
```

The strict-confinement interfaces this template uses (`network`,
`network-bind`) pass the store's automatic review, so a revision is
installable within minutes.

### Channels as environments

Use the same revision for every environment and move it forward:

| Channel | Typical use |
|---|---|
| `edge` | Every build: staging servers, previews |
| `beta` / `candidate` | Optional extra stages |
| `stable` | Production |

```sh
snapcraft status <name>                       # what's where
snapcraft release <name> <revision> stable    # promote, no rebuild
```

Servers follow a channel: `sudo snap install <name> --channel=edge` on
staging, `--channel=stable` (the default) in production. To keep major
versions apart, ask the store for a track (e.g. `2.x`) on the
[snapcraft forum](https://forum.snapcraft.io/c/store-requests).

## Install on a server

```sh
sudo snap install <name>
sudo <name> port 80                  # or: sudo snap set <name> port=80
sudo ufw allow 80/tcp                # if ufw is enabled
```

The server starts at boot. Logs are under `/var/snap/<name>/common/logs/`
and the service is `snap.<name>.server` (`journalctl -u snap.<name>.server`).

### Updates and rollback

snapd checks for new revisions about four times a day and refreshes
automatically: the server restarts on the new revision with the same
settings.

```sh
sudo snap refresh <name>             # update now
sudo snap revert <name>              # back to the previous revision
sudo snap refresh --hold=72h <name>  # pause updates for this snap
sudo snap set system refresh.timer=sat,03:00   # refresh window, all snaps
```

If a new revision's nginx configuration is invalid, its configure hook
fails and snapd keeps the server on the old revision.

### cloud-init

```yaml
#cloud-config
snap:
  commands:
    - snap install <name>
    - snap set <name> port=80
```

The `snap` module runs during first boot, and the server starts as soon as
the snap is installed. Add `--channel=edge` for staging machines.

## Remove

```sh
sudo snap remove <name>              # keeps a snapshot of settings and logs
sudo snap remove --purge <name>      # no snapshot
```
