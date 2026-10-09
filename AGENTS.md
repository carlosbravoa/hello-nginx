# AGENTS.md

Guidance for coding agents (and humans) working on this repository or on a
site built from it. Read this before changing anything under `src/`,
`snap/` or `tests/`.

## What this is

A template that packages a static website and nginx into one strictly
confined snap (core24). The site is baked into the snap at build time and
served read-only from `$SNAP/site`. Alternatively, the `git.*` settings make
the snap fetch a public git repository and serve that instead
(`docs/git-deploy.md`). A small bash runtime renders the nginx
configuration from settings and manages reloads. A CLI named after the
snap manages the server.

There are two kinds of work here:

1. **Using the template** (most requests): put content in `site/`, rules in
   `nginx/site.conf` / `nginx/http.conf`, metadata in `snap/snapcraft.yaml`.
   Don't touch `src/`.
2. **Changing the template**: the runtime in `src/` and `snap/hooks/`.
   Follow the rules below and run the full verification.

## Repository map

```
site/                    website content            -> $SNAP/site (web root)
nginx/site.conf          user rules, server{} level -> $SNAP/conf/user/site.conf
nginx/http.conf          user rules, http{} level   -> $SNAP/conf/user/http.conf
snap/snapcraft.yaml      metadata, apps, plugs, parts
snap/hooks/install       fresh install only: default settings
snap/hooks/configure     install, refresh, every `snap set`: validate, render, reload
src/lib/common.sh        settings getters/validators, render_config, apply_config
src/lib/git.sh           git.* settings, fetch/checkout/rollback, site_root
src/bin/cli              the management CLI (app named after the snap)
src/bin/server-launch    daemon: apply_config, record live port, exec nginx
src/bin/server-reload    reload-command: apply_config, HUP, confirm via probe
src/bin/git-auto-update  timer app (every 5 min): `<snap> update` when due
src/conf/nginx.conf.in   main nginx template (@PLACEHOLDERS@)
src/conf/dev-pages.conf.in  /_hello/ locations, included when dev-pages=true
src/www/hello/           developer dashboard (static HTML/JS)
scripts/rename.sh        rename the snap and its command
tests/lxd-smoke.sh       host driver: LXD container, push, run checks, AppArmor scan
tests/smoke-checks.sh    runs inside the container: ~55 checks
docs/                    user documentation
```

## Runtime flow

```
snap install
  -> install hook: snapctl set port=8080 autoindex=false dev-pages=false
  -> configure hook: validate_settings, apply_config
  -> server daemon: server-launch -> apply_config -> echo port > run/live-port -> exec nginx

sudo <snap> port 9000            (CLI, src/bin/cli)
  -> validate_port, validate_port_free
  -> set_and_apply: snapctl set; apply_config; snapctl restart --reload
       -> systemd ExecReload = server-reload:
            apply_config (new GENERATION) -> nginx -s reload
            -> poll probe server until 3 answers carry the new GENERATION
            -> write run/live-port, wait for the old port to close
  -> on any failure: restore old value, re-apply, die

sudo snap set <snap> port=9000
  -> configure hook (same validation; failure rejects the `snap set`)

sudo <snap> deploy <url>         (or snap set git.repo=<url>)
  -> git_sync: shallow fetch into $SNAP_COMMON/git/repo.git
     -> checkout into git/deploys/<id>/ (no .git, symlinks as files)
     -> git/current = <id>
  -> apply_config renders `root` from site_root(), then the confirmed reload
  -> on failure: git_restore <previous id>
```

The configure hook only fetches when `git.repo/branch/path` differ from
the current deploy, so refreshes never hit the network.

`apply_config` renders into a `mktemp` file, runs `nginx -t` on it, then
moves it into place. A configuration that fails `nginx -t` never goes live.

Paths: `$SNAP` is read-only and changes on every refresh (`/snap/<name>/x1`),
which is why the config is re-rendered at every start. `$SNAP_DATA` holds the
generated `nginx.conf`, `config.json`, the pid file and temp dirs.
`$SNAP_COMMON/logs/` holds the logs, kept across revisions.

## Rules

**Naming**
- Never hard-code the snap name in `src/` or `snap/hooks/`. Use
  `$SNAP_INSTANCE_NAME`. `scripts/rename.sh` only edits
  `snap/snapcraft.yaml` and `site/`.
- The CLI app key in `snapcraft.yaml` must equal the snap name, which gives
  a bare `<name>` command. Its `command:` stays `bin/cli`.

**nginx configuration**
- nginx does not expand environment variables. Every path in the templates
  is a placeholder (`@SNAP@`, `@SNAP_DATA@`, `@SNAP_COMMON@`) substituted in
  `render_config`. Escape substituted values with `sed_escape`.
- Users own `nginx/*.conf`. The generated part must keep working whatever
  they add, and must not define `location /` (theirs does).
- Keep `server_tokens off` and the dotfile rule
  (`location ~ /\.(?!well-known/)`) ahead of the user include.

**Confinement.** Each of these was hit and fixed. Don't reintroduce them.
- Any hook or app that runs `nginx -t` needs the `network-bind` plug:
  `nginx -t` opens the listening sockets.
- Anything that checks ports with bash `/dev/tcp` needs the `network` plug
  (the configure hook has it for `validate_port_free`).
- `nginx -t` ignores "address already in use". That's why
  `validate_port_free` exists.
- Don't inspect processes. The following are all denied by AppArmor:
  - `pgrep` (it reads `/proc/*/cgroup`)
  - reading other processes' `/proc/<pid>/stat` (a ptrace read)
  - `/proc/<pid>/task/*/children`
  - the service's `cgroup.procs`
  Reload confirmation therefore uses the HTTP probe server.
- Not every coreutils binary is executable in confinement (`comm` is
  denied). Prefer bash builtins. If you add a tool, run the smoke test and
  look at the AppArmor section.
- nginx workers log `initgroups(root, 0) failed` and the kernel logs
  `capname="setuid"`/`"setgid"` denials. Both are expected and harmless.
  The tests filter exactly these. Don't widen the filters.
- After an AppArmor-relevant interface connects, workers already running
  keep stale access until restarted. That matters if you ever add an
  interface such as `removable-media`: add a `connect-plug-<plug>` hook that
  restarts the service.
- Don't add interfaces that need Snap Store approval without asking the
  owner. This template must pass automatic review. That rules out:
  - `home` with `read: all`
  - `system-files`
  - `personal-files`
  - classic confinement
  The plain `home` plug doesn't help either: its rules are owner-only and
  the daemon runs as root.

**git**
- Always call git through the `git()` wrapper in `src/lib/git.sh`. It
  sets `LD_LIBRARY_PATH`, because libcurl (needed for https) is not in the
  base snap, and it isolates git from system and user configuration.
- `GIT_INDEX_FILE` must not exist beforehand: git rejects an empty file,
  so don't use `mktemp`.
- Keep `core.symlinks=false` on checkout. A symlink in a repository
  would otherwise let nginx serve files outside the checkout.
- git triggers an occasional `dac_override` capability denial. It's harmless
  (see `docs/troubleshooting.md`) and is filtered by exactly
  `comm="git".*capname="dac_override"`.
- Don't capture `git_sync` with `$(...)`. It takes a lock and sets an EXIT
  trap. Call it directly or in a `( )` subshell, then compare `git_current`.
- To run the timer service in a test, use `systemctl start
  snap.<name>.git-auto-update.service`. `snap start` only starts the timer.

**Reloads**
- `nginx -s reload` returns before the new workers serve. Anything that
  changes the config must go through `snapctl restart --reload`
  (`server-reload`), which waits for the new configuration to be live. Never
  report success before it returns.
- On a port change, old workers hold the old port until they exit.
  `server-reload` waits for it to close, using `run/live-port`, not
  `nginx.conf`, because the CLI renders the new config before the reload.

**Build**
- snapcraft caches parts. After deleting or renaming files in
  `snap/hooks/` or `src/`, run `snapcraft clean` before `snapcraft pack`,
  or stale files ship. Check with `unsquashfs -l <file>.snap`.

## Adding a setting

Example: a `server-name` setting.

1. `src/lib/common.sh`: add a `get_server_name` getter with its default and
   a validator, then call it from `validate_settings`.
2. `snap/hooks/install`: add the default to the `snapctl set` line.
3. `src/conf/nginx.conf.in`: add an `@SERVER_NAME@` placeholder.
   `render_config`: add the `sed -e` line, escaped with `sed_escape`.
4. `render_config`: add the setting to `config.json`.
5. `src/bin/cli`: add a verb that calls `set_and_apply`, a line in
   `cmd_config`, and the usage text.
6. `tests/smoke-checks.sh`: test setting it, rejection of a bad value, and
   its effect over HTTP.
7. `docs/customizing.md` (settings table) and `README.md` (CLI block).

## Verifying changes

Always, in this order:

```sh
for f in src/bin/* src/lib/common.sh snap/hooks/* tests/*.sh scripts/*.sh; do bash -n "$f"; done
snapcraft clean   # when files were removed or renamed
snapcraft pack
tests/lxd-smoke.sh
```

Expected last line: `ALL CHECKS PASSED`. If the default `ubuntu:24.04`
image is slow to download, use a cached one:
`lxc image list`, then `LXD_IMAGE=<fingerprint> tests/lxd-smoke.sh`.
`KEEP=1` keeps the container for debugging (`lxc shell <name>`).

When changing the runtime, also test a renamed fork. Copy the repo, run
`scripts/rename.sh some-name`, then pack and smoke-test it. That catches
hard-coded names.

Don't claim something works because it builds. The smoke test exercises
install, settings, reloads, refresh, removal and AppArmor; use it.

## Publishing

Uploading, registering names and releasing to channels are outward-facing.
Never do them without explicit confirmation from the owner. Workflow and
channels: `docs/deploying.md`.
