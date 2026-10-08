# Customizing

Everything here is a build-time change: edit, `snapcraft pack`,
`tests/lxd-smoke.sh`, publish. Settings (port, ...) are the exception: they
change at runtime on each server.

## Site content

`site/` is copied into the snap as `$SNAP/site` (`/snap/<name>/current/site`)
and served as the web root.

- `index.html` (or `index.htm`) is served for directory URLs.
- `404.html` is the error page for missing files (configured in
  `nginx/site.conf`). Delete the `error_page` line if you don't want it.
- Dotfiles and dot-directories (`.git`, `.env`, ...) are never served; they
  return 404. `/.well-known/` is the exception.
- Files are read-only at runtime. To change content, publish a new revision.

### Building the site during the snap build

Instead of committing generated files to `site/`, let snapcraft run your
static site generator. Replace the `site` part in `snap/snapcraft.yaml`.
These are starting points and haven't been tested in this repository.

**npm-based (Vite, Astro, Next.js static export, ...)**, with the project
in `web/`:

```yaml
  site:
    plugin: nil
    source: web
    build-snaps: [node/22/stable]
    override-build: |
      npm ci
      npm run build
      mkdir -p "$CRAFT_PART_INSTALL/site"
      cp -a dist/. "$CRAFT_PART_INSTALL/site/"    # dist/, build/, out/: whatever your tool emits
```

**Hugo**, with the project in `web/`:

```yaml
  site:
    plugin: nil
    source: web
    build-snaps: [hugo]
    override-build: |
      hugo --minify --destination "$CRAFT_PART_INSTALL/site"
```

The smoke test checks that every file in the built `site/` returns HTTP 200,
so it also catches an empty or misplaced build output.

## nginx rules

Two files are included in the generated nginx configuration:

| File | Included inside | Use it for |
|---|---|---|
| `nginx/site.conf` | `server { }` | `location` blocks, headers, redirects, `error_page`, `proxy_pass` |
| `nginx/http.conf` | `http { }` | `upstream`, `map`, `limit_req_zone`, `log_format` |

The rest of the configuration is generated: listen ports, root, logs, gzip,
temp paths, dotfile protection, developer pages. If an included file is
invalid, `nginx -t` fails during install and **the snap refuses to install**
(snapd rolls back to the previous revision on refresh). Always run
`tests/lxd-smoke.sh` before publishing.

To read the full generated configuration on a test machine:
`sudo cat /var/snap/<name>/current/nginx.conf`.

`site.conf` ships with the default `location /` block. Replace it, don't
add a second one: nginx rejects duplicate locations.

### Recipes

**Single-page app** (client-side routing): unknown paths get `index.html`.

```nginx
location / {
    try_files $uri $uri/ /index.html;
}
```

**Long-lived caching** for fingerprinted assets, no caching for HTML:

```nginx
location /assets/ {
    expires 1y;
    add_header Cache-Control "public, immutable";
}
location ~* \.html$ {
    add_header Cache-Control "no-cache";
}
```

**Redirects**

```nginx
location = /old-page.html { return 301 /new-page.html; }
location /blog/ { return 301 https://blog.example.com$request_uri; }
```

**Security headers**

```nginx
add_header X-Content-Type-Options nosniff always;
add_header Referrer-Policy strict-origin-when-cross-origin always;
add_header X-Frame-Options SAMEORIGIN always;
add_header Content-Security-Policy "default-src 'self'" always;
```

nginx inheritance rule: a `location` with its own `add_header` drops every
`add_header` from the server level. Repeat them inside such locations.

**Reverse proxy** to an API running on the same host or elsewhere. The
server already has the `network` plug, which allows outgoing connections.

```nginx
# nginx/http.conf
upstream api {
    server 127.0.0.1:3000;
}

# nginx/site.conf
location /api/ {
    proxy_pass http://api/;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

**Rate limiting**

```nginx
# nginx/http.conf
limit_req_zone $binary_remote_addr zone=perip:10m rate=10r/s;

# nginx/site.conf, inside the location to protect
limit_req zone=perip burst=20 nodelay;
```

### HTTPS

The simplest setup is to terminate TLS in front of the snap: a load
balancer, a CDN, or a reverse proxy on the host. Keep the snap on plain
HTTP behind it.

Terminating TLS in the snap is possible, but needs more care, and this
template does not do it for you. You need a `listen 443 ssl;` plus
`ssl_certificate` lines in `site.conf`, pointing at files under
`/var/snap/<name>/common/`. nginx refuses to start if those files are
missing, so they must exist before the snap is installed or refreshed. You
also have to handle certificate renewal yourself.

## Settings

Runtime settings, per server, kept across refreshes:

| Setting | Default | CLI | snapd |
|---|---|---|---|
| `port` | `8080` | `sudo <name> port 80` | `sudo snap set <name> port=80` |
| `autoindex` | `false` | `sudo <name> autoindex on` | `sudo snap set <name> autoindex=true` |
| `dev-pages` | `false` | `sudo <name> dev-pages on` | `sudo snap set <name> dev-pages=true` |

To change a default, edit `DEFAULT_PORT` / the getters in
`src/lib/common.sh` and the `snapctl set` line in `snap/hooks/install`.
Defaults only apply to fresh installs.

To add a setting of your own (say, `server-name`), follow the checklist in
[AGENTS.md](../AGENTS.md#adding-a-setting).

## Developer pages

With `dev-pages` on, these are served under `/_hello/`:

| URL | Content |
|---|---|
| `/_hello/` | Dashboard: live connections, requests/s, settings, your request |
| `/_hello/status` | nginx `stub_status` counters |
| `/_hello/request` | Your request as JSON (IPs, headers, protocol) |
| `/_hello/health` | `ok` |
| `/_hello/config` | Active settings as JSON |

They reveal server details, so they are off by default. Turn them on for
debugging proxies and load balancers, then turn them off again.
