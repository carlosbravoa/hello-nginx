#!/bin/bash
# End-to-end test of a built snap in a throwaway LXD container.
#
#   tests/lxd-smoke.sh [path/to/file.snap]
#
# Defaults to the newest *.snap in the repository root. Environment:
#   LXD_IMAGE   image to launch (default: ubuntu:24.04)
#   CONTAINER   container name (default: snap-smoke-<pid>)
#   KEEP=1      keep the container afterwards for debugging
#
# Exit status is the number of failed checks (0 = all good).
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SNAP_FILE=${1:-$(ls -t "$ROOT"/*.snap 2>/dev/null | head -n1)}
IMAGE=${LXD_IMAGE:-ubuntu:24.04}
CT=${CONTAINER:-snap-smoke-$$}

[ -n "$SNAP_FILE" ] && [ -f "$SNAP_FILE" ] || { echo "error: no .snap file found; run 'snapcraft pack' first" >&2; exit 100; }
command -v lxc >/dev/null || { echo "error: lxc not found (sudo snap install lxd && lxd init --auto)" >&2; exit 100; }

cleanup() {
    if [ "${KEEP:-0}" = 1 ]; then
        echo "Keeping container '$CT' (lxc shell $CT; lxc delete --force $CT)"
    else
        lxc delete --force "$CT" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

started=$(date '+%Y-%m-%d %H:%M:%S')
echo "==> Launching $IMAGE as $CT"
timeout 300 lxc launch "$IMAGE" "$CT" >/dev/null || { echo "error: lxc launch failed or timed out" >&2; exit 100; }
lxc exec "$CT" -- snap wait system seed.loaded >/dev/null 2>&1 || true

echo "==> Testing $(basename "$SNAP_FILE")"
lxc file push "$SNAP_FILE" "$CT/root/under-test.snap" >/dev/null || exit 100
lxc file push "$ROOT/tests/smoke-checks.sh" "$CT/root/smoke-checks.sh" >/dev/null || exit 100
lxc exec "$CT" -- bash /root/smoke-checks.sh /root/under-test.snap
failed=$?

# AppArmor denials are logged by the host kernel, not inside the container.
echo "==> AppArmor denials"
if journalctl -k -n 1 >/dev/null 2>&1; then
    # Harmless, see docs/troubleshooting.md:
    # - setuid/setgid: nginx workers dropping to root.
    # - dac_override from git: an optional capability check; the same git
    #   steps run without CAP_DAC_OVERRIDE unconfined with no failed syscall.
    denials=$(journalctl -k --since "$started" --no-pager 2>/dev/null |
        grep 'apparmor="DENIED"' | grep "lxd-${CT}_" | grep 'profile="snap\.' |
        grep -v -e 'capname="setuid"' -e 'capname="setgid"' |
        grep -v 'comm="git".*capname="dac_override"' || true)
    if [ -n "$denials" ]; then
        echo "  FAIL unexpected denials:"
        echo "$denials" | sed 's/.*apparmor=/    apparmor=/' | cut -c1-220 | sort | uniq -c
        failed=$((failed + 1))
    else
        echo "  ok   none"
    fi
else
    echo "  skip cannot read the kernel log (try: sudo usermod -aG adm \$USER)"
fi

echo
if [ "$failed" -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "$failed CHECK(S) FAILED"; fi
exit "$failed"
