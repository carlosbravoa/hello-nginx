# Serving a git repository

The snap can serve a site straight from a git repository instead of the
site built into it. No snap of your own, no build: install the snap, point
it at a repository, done.

```sh
sudo snap install hello-nginx
sudo hello-nginx deploy https://github.com/me/my-site.git
```

Use this to get a site online quickly, or for sites that change more often
than you want to publish snaps. When you want the site and the server
versioned and released together through store channels, build your own snap
from this template instead (see [README.md](../README.md)).

## Commands

```
sudo hello-nginx deploy <url> [--branch B] [--path P]
sudo hello-nginx update                   # fetch; deploy if there are new commits
sudo hello-nginx auto-update 15m          # or 1h, ...; off by default
sudo hello-nginx rollback                 # back to the previous deploy
sudo hello-nginx reset                    # back to the built-in site
     hello-nginx status                   # repository, commit, deploy time
```

- `--branch` takes a branch or a tag. Without it, the repository's default
  branch is used.
- `--path` serves a subfolder, for example `public` or `docs`.

## The same with settings

Everything is also a setting, which suits automation:

| Setting | Meaning |
|---|---|
| `git.repo` | `https://` (or `http://`) URL. Unset: serve the built-in site. |
| `git.branch` | Branch or tag. Default: the remote's default branch. |
| `git.path` | Subfolder to serve. Default: the repository root. |
| `git.auto-update` | `off` (default), or an interval of at least `5m`: `15m`, `1h`, ... |

```sh
sudo snap set hello-nginx git.repo=https://github.com/me/my-site.git git.branch=main
sudo snap unset hello-nginx git            # back to the built-in site
```

`snap set` deploys right away. If the repository can't be fetched, or the
folder doesn't exist, the `snap set` fails and nothing changes.

With cloud-init, a server comes up serving the repository:

```yaml
#cloud-config
snap:
  commands:
    - snap install hello-nginx
    - snap set hello-nginx port=80 git.repo=https://github.com/me/my-site.git git.auto-update=15m
```

## How a deploy works

1. The snap fetches the latest commit of the branch. It keeps a shallow
   copy of the repository under `/var/snap/hello-nginx/common/git/`.
2. The commit is checked out into a new folder **without `.git`**.
   Symbolic links become plain files, so a repository cannot make nginx
   serve files outside its checkout.
3. nginx is pointed at the new folder and reloaded. The command returns once
   the new site is being served. If anything fails, the previous site keeps
   being served.

The last 5 deploys are kept for `rollback`. Deploys are kept across snap
refreshes. A refresh does not fetch the repository again.

Branches work as environments. For example, staging servers can follow
`git.branch=staging` and production servers `main`.

## Rollback and auto-update

`rollback` serves the deploy before the current one, and points the
settings at it. If auto-update is on, rollback turns it off, so the next
check does not deploy the commit you rolled back from. When the repository
is fixed, run `sudo hello-nginx update`, then turn auto-update back on.

With auto-update on, a timer checks every 5 minutes whether the interval has
passed, then runs `update`. Its output goes to the journal:

```sh
sudo journalctl -u snap.hello-nginx.git-auto-update.service
```

## Limits

- **Static files only.** The snap serves files, it does not build them.
  For Hugo, Jekyll, Astro and so on, commit the built output (for example to
  a `public/` folder, served with `--path public`, or to a separate branch).
- **Public repositories only**, over `https://` (or `http://` on trusted
  networks). There is no support for credentials or SSH yet.
- **Submodules and Git LFS files** are not fetched.
- **Your nginx rules are not read from the repository.** Rules in
  `nginx/site.conf` and `nginx/http.conf` are built into the snap. To change
  them, build your own snap from the template.
- With a `path` that has no `index.html`, `/` returns 403 unless
  `autoindex` is on.
