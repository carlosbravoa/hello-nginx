# hello-nginx

A template for shipping a website as a **snap**: your files and a strictly
confined nginx in one package that you install on any Ubuntu (or other
snapd) server.

```sh
sudo snap install my-site      # serving on :8080 right away
sudo my-site port 80
```

Why package a site this way:

- **Atomic updates.** `snap refresh` swaps content and web server together;
  visitors never see a half-copied site.
- **One-command rollback.** `sudo snap revert my-site` brings back the
  previous version.
- **Channels as environments.** Release to `edge` for staging, promote the
  same revision to `stable` for production.
- **Hands-off servers.** Snaps refresh automatically, start at boot, and
  `snap install` is all cloud-init needs.
- **Sandboxed.** nginx runs under strict confinement and can only read the
  snap's own files.

The published [`hello-nginx`](https://snapcraft.io/hello-nginx) snap is this
template built as is: `sudo snap install hello-nginx --edge` shows what you
get.

## Quick start

Start a repository from this template: **Use this template** on
[GitHub](https://github.com/carlosbravoa/hello-nginx), or clone it:

```sh
git clone https://github.com/carlosbravoa/hello-nginx.git my-site && cd my-site
```

You need [snapcraft](https://snapcraft.io/snapcraft) and
[LXD](https://snapcraft.io/lxd) (for building and testing):

```sh
sudo snap install snapcraft --classic
sudo snap install lxd && sudo lxd init --auto
```

Then:

```sh
# 1. Name your snap (store names are global: check https://snapcraft.io/<name>)
scripts/rename.sh my-site "My Site"

# 2. Replace the demo content with your website
rm -r site/* && cp -r ~/my-website/. site/

# 3. Build and test in a throwaway container
snapcraft pack
tests/lxd-smoke.sh

# 4. Publish
snapcraft login
snapcraft register my-site
snapcraft upload my-site_*.snap --release=edge
```

Then on a server: `sudo snap install my-site --edge`.

Also edit `version`, `summary`, `description`, `license` and the links
(`contact`, `issues`, `source-code`, `website`) in `snap/snapcraft.yaml`.
Bump `version` for every release.

## What to edit

| Path | What it is |
|---|---|
| `site/` | **Your website.** Served as-is from the snap (read-only). Dotfiles are never served. |
| `nginx/site.conf` | **Your nginx rules** inside the `server {}` block: routing, redirects, headers, caching, proxying. |
| `nginx/http.conf` | **Your nginx rules** at `http {}` level: `upstream`, `map`, rate-limit zones. |
| `snap/snapcraft.yaml` | Snap metadata (name, version, description). |
| `snap/gui/icon.png` | Snap icon (512×512 PNG), shown in the Snap Store. Source: `assets/icon.svg`. |
| `src/` | The machinery: CLI, service scripts, config templates, developer pages. Normally untouched. |
| `snap/hooks/` | Install and settings hooks. Normally untouched. |
| `tests/` | `lxd-smoke.sh` builds a container, installs the snap and runs ~55 checks. |
| `scripts/rename.sh` | Renames the snap and its command. |

## On the server

The snap ships a command named after the snap:

```
sudo my-site start | stop | restart | reload
sudo my-site port <n>            # default 8080
sudo my-site autoindex on|off    # directory listings
sudo my-site dev-pages on|off    # /_hello/ developer pages (default off)
     my-site status | config | check | version
sudo my-site test                # validate the nginx configuration
sudo my-site logs [access|error] [-f] [-n N]
```

Settings also work through snapd, which is handy for automation:

```sh
sudo snap set my-site port=80 dev-pages=false
```

Invalid values are rejected and the previous ones stay in place.

## Documentation

- [docs/customizing.md](docs/customizing.md): content, static site
  generators, nginx recipes (single-page apps, caching, redirects, proxying),
  settings.
- [docs/deploying.md](docs/deploying.md): publishing, channels, servers,
  cloud-init, rollback, multiple architectures.
- [docs/troubleshooting.md](docs/troubleshooting.md): logs, failed installs,
  confinement, known harmless messages.
- [AGENTS.md](AGENTS.md): how the template works internally, its rules and
  how to verify changes. Written for coding agents, useful for humans too.

## License

The template is [MIT](LICENSE) licensed. Snaps built from it also contain
nginx from the Ubuntu archive, which is BSD-2-Clause, hence
`license: MIT AND BSD-2-Clause` in `snap/snapcraft.yaml`. Your own site
content is yours to license as you like.
