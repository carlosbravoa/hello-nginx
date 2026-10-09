#!/bin/bash
# Runs inside the test container (see tests/lxd-smoke.sh). Installs the snap
# and exercises the server, the CLI and the settings.
#
#   bash smoke-checks.sh /root/file.snap
#
# Exit status is the number of failed checks.
set -uo pipefail

SNAP_FILE=$1
FAILED=0

ok()   { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; FAILED=$((FAILED + 1)); }
warn() { echo "  warn $*"; }
section() { echo "--- $*"; }

# check "description" command...  (pass if the command succeeds)
check() {
    local desc=$1; shift
    if out=$("$@" 2>&1); then ok "$desc"; else fail "$desc"; echo "$out" | sed 's/^/         /' | tail -n 5; fi
}

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1"; }
expect_code() { # desc url code
    local got
    got=$(code "$2")
    if [ "$got" = "$3" ]; then ok "$1 ($3)"; else fail "$1: expected $3, got $got"; fi
}
wait_http() { # port
    for _ in $(seq 50); do
        [ "$(code "http://127.0.0.1:$1/")" != 000 ] && return 0
        sleep 0.2
    done
    return 1
}

section "install"
if out=$(snap install --dangerous "$SNAP_FILE" 2>&1); then
    N=$(echo "$out" | awk '/ installed$/ {print $1}' | tail -n1)
    ok "installed $N"
else
    fail "snap install"; echo "$out"; exit "$FAILED"
fi
SITE=/snap/$N/current/site
U=http://127.0.0.1:8080

check "service is active" sh -c "snap services $N.server | grep -q ' active'"
check "listening on 8080" wait_http 8080

section "site"
expect_code "GET /" "$U/" 200
if [ -f "$SITE/index.html" ]; then
    check "/ serves site/index.html" sh -c "curl -s $U/ | cmp -s - $SITE/index.html"
fi
# Every file in site/ should be reachable. Custom rules in nginx/site.conf
# (redirects, auth, ...) can legitimately change this, so only warn.
bad=0; total=0
while IFS= read -r f; do
    total=$((total + 1))
    path=${f#"$SITE"}
    c=$(code "$U$(printf '%s' "$path" | sed 's/ /%20/g')")
    [ "$c" = 200 ] || { warn "GET $path -> $c"; bad=$((bad + 1)); }
done < <(find "$SITE" -type f -not -path '*/.*' | head -n 300)
[ "$bad" -eq 0 ] && ok "all $total site files return 200"
expect_code "missing page" "$U/does-not-exist-$RANDOM" 404
expect_code "dotfiles hidden" "$U/.git/config" 404
expect_code "dev pages off by default" "$U/_hello/health" 404

section "developer pages"
check "dev-pages on" "$N" dev-pages on
expect_code "/_hello/" "$U/_hello/" 200
check "/_hello/health says ok" sh -c "curl -s $U/_hello/health | grep -qx ok"
check "/_hello/request is JSON" sh -c "curl -s $U/_hello/request | python3 -m json.tool"
check "/_hello/config is JSON" sh -c "curl -s $U/_hello/config | python3 -m json.tool"
check "/_hello/status has counters" sh -c "curl -s $U/_hello/status | grep -q 'Active connections'"
check "dev-pages off" "$N" dev-pages off
expect_code "dev pages gone" "$U/_hello/health" 404

section "settings"
check "port 9090" "$N" port 9090
expect_code "serving on 9090" "http://127.0.0.1:9090/" 200
expect_code "8080 closed" "$U/" 000
check "snap set port=8080" snap set "$N" port=8080
expect_code "back on 8080" "$U/" 200
check "rejects port=99999" sh -c "! snap set $N port=99999"
check "rejects dev-pages=maybe" sh -c "! snap set $N dev-pages=maybe"
check "CLI rejects port abc" sh -c "! $N port abc"
expect_code "still serving after rejected settings" "$U/" 200
# A port taken by another program must be refused, not half-applied.
python3 -m http.server 9999 >/dev/null 2>&1 &
busy=$!
sleep 1
check "CLI refuses a busy port" sh -c "! $N port 9999"
check "snap set refuses a busy port" sh -c "! snap set $N port=9999"
check "port unchanged" sh -c "$N config | grep -q 'port *8080'"
expect_code "still serving on 8080" "$U/" 200
kill "$busy" 2>/dev/null; wait "$busy" 2>/dev/null
check "autoindex on" "$N" autoindex on
check "autoindex off" "$N" autoindex off

section "service control"
check "stop" "$N" stop
check "stopped and disabled" sh -c "snap services $N.server | grep -q 'disabled  *inactive'"
check "check fails while stopped" sh -c "! $N check"
check "start" "$N" start
check "listening again" wait_http 8080
check "restart" "$N" restart
check "listening after restart" wait_http 8080
t0=$(date +%s%N)
check "reload" "$N" reload
ms=$(( ($(date +%s%N) - t0) / 1000000 ))
# server-reload waits for the new config to be live; ~1s is normal, hitting
# its 5s timeout means it could not confirm the reload.
if [ "$ms" -lt 4000 ]; then ok "reload confirmed in ${ms}ms"; else fail "reload took ${ms}ms (probe timed out?)"; fi
check "test" "$N" test
check "check" "$N" check
check "status" "$N" status
check "logs" "$N" logs -n 5

section "git deploy"
# A local repository served over plain HTTP (git's "dumb" protocol), so the
# test does not depend on the internet and can push new commits.
GW=/root/git-work; GS=/root/git-srv; R=http://127.0.0.1:8765/site.git
publish() { # message -> commit in $GW and update the served bare repo
    git -C "$GW" add -A && git -C "$GW" commit -qm "$1" &&
    git -C "$GW" push -q "$GS/site.git" --all && git -C "$GS/site.git" update-server-info
}
body() { curl -s --max-time 5 "$U/${1:-}"; }
serves() { body "${2:-}" | grep -q "$1"; }
if ! command -v git >/dev/null; then
    fail "git is not installed in the test container"
else
    rm -rf "$GW" "$GS"; mkdir -p "$GW/public" "$GS"
    git -C "$GW" init -q -b main
    git -C "$GW" config user.email test@example.com; git -C "$GW" config user.name test
    echo '<h1>git v1</h1>' > "$GW/index.html"
    echo '<h1>public folder</h1>' > "$GW/public/index.html"
    ln -s /etc/passwd "$GW/leak"
    git -C "$GW" add -A && git -C "$GW" commit -qm v1
    git clone -q --bare "$GW" "$GS/site.git" && git -C "$GS/site.git" update-server-info
    python3 -m http.server 8765 --bind 127.0.0.1 --directory "$GS" >/dev/null 2>&1 &
    gitsrv=$!
    sleep 1

    check "deploy" "$N" deploy "$R"
    check "serves the repository" serves 'git v1'
    check "symlinks are not followed" sh -c "! curl -s $U/leak | grep -q root:"
    check "status shows the repository" sh -c "$N status | grep -q '$R'"
    check "update with nothing new" sh -c "$N update | grep -q 'Already up to date'"
    echo '<h1>git v2</h1>' > "$GW/index.html"; publish v2
    check "update" "$N" update
    check "serves the new commit" serves 'git v2'

    check "deploy a subfolder" "$N" deploy "$R" --path public
    check "serves the subfolder" serves 'public folder'
    check "rejects a missing folder" sh -c "! $N deploy $R --path nope"
    check "rejects a non-http URL" sh -c "! $N deploy file:///etc"
    check "rejects '..' in the path" sh -c "! $N deploy $R --path ../x"
    check "rejects an unreachable repo" sh -c "! $N deploy http://127.0.0.1:1/x.git"
    check "still serves the subfolder" serves 'public folder'
    check "rollback" "$N" rollback
    check "serves the previous deploy" serves 'git v2'
    check "settings follow the rollback" sh -c "$N config | grep -q 'git.path *$'"

    git -C "$GW" checkout -q -b staging
    echo '<h1>git staging</h1>' > "$GW/index.html"; publish staging
    check "snap set git.branch=staging" snap set "$N" git.branch=staging
    check "serves the branch" serves 'git staging'
    check "snap set rejects a bad URL" sh -c "! snap set $N git.repo=nonsense"
    check "snap set rejects an unreachable repo" sh -c "! snap set $N git.repo=http://127.0.0.1:1/x.git"
    check "still serves the branch" serves 'git staging'

    check "auto-update 5m" "$N" auto-update 5m
    check "rejects auto-update 1m" sh -c "! $N auto-update 1m"
    check "rejects auto-update soon" sh -c "! $N auto-update soon"
    echo '<h1>git auto</h1>' > "$GW/index.html"; publish auto
    rm -f "/var/snap/$N/common/git/last-check"
    # `snap start` would only start the systemd timer; run the service itself.
    check "auto-update timer runs" systemctl start "snap.$N.git-auto-update.service"
    check "timer deployed the new commit" serves 'git auto'
    check "rollback turns auto-update off" sh -c "$N rollback | grep -q 'Auto-update turned off'"
    check "auto-update is off" sh -c "$N config | grep -q 'git.auto-update *off'"
    check "update" "$N" update
    check "refresh keeps the git site" snap install --dangerous "$SNAP_FILE"
    check "serves the git site after refresh" serves 'git auto'
    check "keeps at most 5 deploys" sh -c "[ \$(ls -d /var/snap/$N/common/git/deploys/*/ | wc -l) -le 5 ]"

    check "reset" "$N" reset
    check "serves the built-in site again" sh -c "curl -s $U/ | cmp -s - $SITE/index.html"
    check "git data removed" sh -c "[ ! -e /var/snap/$N/common/git ]"
    kill "$gitsrv" 2>/dev/null; wait "$gitsrv" 2>/dev/null

    # https and shallow fetch against a real host, when there is internet.
    if curl -s -o /dev/null --max-time 5 https://github.com; then
        check "deploy from GitHub over https" "$N" deploy https://github.com/carlosbravoa/hello-nginx --path site
        check "serves the GitHub site" serves 'Hello'
        check "reset" "$N" reset
    else
        warn "no internet: skipped the GitHub deploy"
    fi
fi

section "non-root user"
check "status works without sudo" su - ubuntu -c "$N status"
check "port refuses without sudo" sh -c "! su - ubuntu -c '$N port 9000'"
check "deploy refuses without sudo" sh -c "! su - ubuntu -c '$N deploy https://example.com/x.git'"

section "refresh"
check "port 8181 before refresh" "$N" port 8181
check "reinstall (refresh)" snap install --dangerous "$SNAP_FILE"
check "listening on 8181 after refresh" wait_http 8181
check "setting kept" sh -c "$N config | grep -q 'port *8181'"
check "port back to 8080" "$N" port 8080

section "error log"
errs=$(grep -E '\[(emerg|alert|crit)\]' "/var/snap/$N/common/logs/error.log" | grep -v 'initgroups(root, 0) failed' || true)
if [ -z "$errs" ]; then ok "no emerg/alert/crit entries"; else fail "error log:"; echo "$errs" | tail -n 5 | sed 's/^/         /'; fi

section "remove"
check "snap remove --purge" snap remove --purge "$N"

exit "$FAILED"
