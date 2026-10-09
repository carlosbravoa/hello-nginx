# Troubleshooting

## First look

```sh
<name> status                        # running? which port? which revision?
<name> check                         # does / answer?
sudo <name> logs error -n 50
sudo <name> logs -f                  # access log, live
sudo <name> test                     # nginx -t on the generated config
journalctl -u snap.<name>.server -n 50
sudo cat /var/snap/<name>/current/nginx.conf
```

For a quick look at what a client sees, through proxies and load balancers
too: `sudo <name> dev-pages on`, open `/_hello/request`, then turn them
off again.

## The snap refuses to install or refresh

```
error: cannot perform the following tasks:
- Run configure hook of "<name>" snap (run hook "configure":
error: generated nginx configuration is invalid:
nginx: [emerg] ... in /snap/<name>/x1/conf/user/site.conf:12
```

`nginx/site.conf` or `nginx/http.conf` contains an error. The message gives
the file and line. Fix it, rebuild and run `tests/lxd-smoke.sh`. On a
refresh, snapd keeps the previous revision running.

Common causes:

- A second `location /`. Replace the existing one instead.
- An `http`-only directive (`upstream`, `map`, `limit_req_zone`) in
  `site.conf`. It belongs in `http.conf`.
- A file path outside the snap (certificates, includes). The server can
  only read `/snap/<name>/`, `/var/snap/<name>/` and its own logs.

## Port problems

- **`bind() to 0.0.0.0:80 failed (98: Address already in use)`**: something
  else listens there (`sudo ss -ltnp | grep :80`). Stop it or pick another
  port. The setting is rejected and the old one stays.
- **Ports below 1024** work: the server runs as root inside its sandbox.
- **Reachable locally but not from outside**: check the firewall
  (`sudo ufw status`) and your cloud security group.

## Files return 404

- Check the file is in the snap: `ls /snap/<name>/current/site/`.
- Dotfiles and dot-directories always return 404, except `/.well-known/`.
- With a custom `location /` in `site.conf`, check its `try_files`.

## Files outside the snap

By design, the server cannot read `/home`, `/srv`, `/var/www` or any other
host path. Strict confinement limits it to the snap's own directories. Ship
content inside the snap (`site/`), or proxy to a service that has access to
it (see the reverse proxy recipe in
[customizing.md](customizing.md#recipes)).

## Known harmless messages

- **`[emerg] ... initgroups(root, 0) failed (1: Operation not permitted)`**
  in the error log, once per worker per (re)start. nginx tries to reset
  supplementary groups when starting workers; the sandbox forbids it, and
  nginx carries on. The smoke test ignores this line.
- **`apparmor="DENIED" ... capname="setuid"` / `"setgid"`** in the kernel log
  for `snap.<name>.server`: the same thing seen from AppArmor.
- **`[notice] ... signal process started`**: logged by every reload.
- **`apparmor="DENIED" ... comm="git" ... capname="dac_override"`** for
  `snap.<name>.<name>` or `snap.<name>.git-auto-update`, during a git
  deploy. This is an optional capability check: the same git steps run
  unconfined without `CAP_DAC_OVERRIDE` with no failed system call, and the
  deploy succeeds. The kernel only logs it now and then.

## Git deploys

- `cannot fetch ...`: the URL is wrong, the repository is private (not
  supported yet), or the server can't reach it. The previous site keeps
  being served.
- `/` returns 403 after a deploy: there is no `index.html` in the served
  folder. Check `--path`, or turn on `autoindex`.
- Auto-update doesn't seem to run:
  `sudo journalctl -u snap.<name>.git-auto-update.service`.
  `<name> rollback` turns auto-update off on purpose.

Any other AppArmor denial for `snap.<name>.*` is worth a look:

```sh
sudo journalctl -k | grep 'apparmor="DENIED"' | grep 'snap\.<name>\.'
sudo snap install snappy-debug && sudo snappy-debug   # explains denials live
```
