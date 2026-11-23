#!/bin/bash
# Store-to-server test: boot a fresh EC2 instance whose cloud-init user data
# installs the snap from a store channel, and wait for the page to go live
# from the internet. Run it after an upload, before promoting to stable.
#
#   tests/ec2-cloud-init.sh [channel]        # default: edge
#
# Uses launch-ubuntu (its config provides the subnet, security group and key
# pair). The security group must allow inbound TCP on $PORT. Environment:
#   SNAP_NAME   default: the name in snap/snapcraft.yaml
#   RELEASE     Ubuntu release for launch-ubuntu (default: 24.04LTS)
#   PORT        port the page is expected on (default: 8080)
#   KEEP=1      leave the instance running afterwards
#   LOG         log file (default: tests/logs/ec2-<channel>-<timestamp>.log)
#
# Exit status is the number of failed checks (0 = all good, 100 = setup error).
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CHANNEL=${1:-edge}
NAME=${SNAP_NAME:-$(sed -n 's/^name: *//p' "$ROOT/snap/snapcraft.yaml")}
RELEASE=${RELEASE:-24.04LTS}
PORT=${PORT:-8080}
LOG=${LOG:-$ROOT/tests/logs/ec2-$CHANNEL-$(date +%Y%m%d-%H%M%S).log}

for tool in launch-ubuntu aws snap curl ssh; do
    command -v "$tool" >/dev/null || { echo "error: $tool not found" >&2; exit 100; }
done
mkdir -p "$(dirname "$LOG")"
exec > >(tee "$LOG") 2>&1

failed=0
check() {   # check <description> <command...>
    local desc=$1; shift
    if "$@"; then echo "  ok   $desc"; else echo "  FAIL $desc"; failed=$((failed + 1)); fi
}

# The revision the store serves on this channel now, to compare with what
# the instance installs.
expected=$(snap info "$NAME" | sed -n "s|^ *latest/$CHANNEL: .*(\([0-9]*\)).*|\1|p")
[ -n "$expected" ] || { echo "error: nothing released to $NAME latest/$CHANNEL" >&2; exit 100; }
echo "==> $NAME latest/$CHANNEL is revision $expected"

work=$(mktemp -d)
cat > "$work/user-data.yaml" <<EOF
#cloud-config
snap:
  commands:
    - snap install $NAME --channel=$CHANNEL
EOF
echo "==> User data"
sed 's/^/    /' "$work/user-data.yaml"

# In-instance checks, run over SSH as ubuntu once the instance is up.
# Keep the AppArmor filter identical to tests/lxd-smoke.sh.
echo "==> Launching $RELEASE"
launch-ubuntu "$RELEASE" --user-data "$work/user-data.yaml" --diagnose keep \
    --test "cloud-init status --wait | tail -1 | grep -q 'status: done'" \
    --test "snap list $NAME | awk 'NR==2{print \$3, \$4}' | grep -qx '$expected latest/$CHANNEL'" \
    --test "snap services $NAME.server | grep -q ' active'" \
    --test "for i in \$(seq 60); do curl -fsS -o /dev/null http://localhost:$PORT/ && exit 0; sleep 5; done; exit 1" \
    --test "grep -E '^- nginx=' /snap/$NAME/current/snap/manifest.yaml || true" \
    --test "! sudo journalctl -k --no-pager | grep 'apparmor=\"DENIED\"' | grep 'profile=\"snap\.$NAME\.' | grep -v 'comm=\"git\".*capname=\"dac_override\"'" \
    > "$work/launch.log" 2>&1
launch_rc=$?
sed 's/\x1b\[[0-9;]*m//g' "$work/launch.log" > "$work/launch.txt"
sed -n '/Running custom tests/,$p' "$work/launch.txt"

ip=$(grep -oE 'ubuntu@[0-9.]+' "$work/launch.txt" | tail -1 | cut -d@ -f2)
id=$(grep -oE '"instanceId" *: *"i-[0-9a-f]+"' "$work/launch.txt" | grep -oE 'i-[0-9a-f]+' | head -1)
if [ -z "$ip" ] || [ -z "$id" ]; then
    echo "error: could not find the instance's IP or ID in the launch-ubuntu output:" >&2
    tail -30 "$work/launch.txt" >&2
    exit 100
fi
echo "==> Instance $id at $ip"

echo "==> Checks"
check "in-instance tests (launch-ubuntu exit $launch_rc)" [ "$launch_rc" = 0 ]
check "no in-instance test failed" bash -c "! sed -n '/Running custom tests/,\$p' '$work/launch.txt' | grep -q 'FAIL'"
code=
for _ in $(seq 24); do
    code=$(curl -s -o "$work/page.html" -w '%{http_code}' --max-time 5 "http://$ip:$PORT/") && [ "$code" = 200 ] && break
    sleep 5
done
check "http://$ip:$PORT/ from the internet answers 200 (got $code)" [ "$code" = 200 ]
check "page has a <title>: $(grep -o '<title>[^<]*' "$work/page.html" 2>/dev/null | cut -c8-)" \
    grep -q '<title>' "$work/page.html"
check "Server header hides the nginx version" \
    bash -c "curl -sSI 'http://$ip:$PORT/' | tr -d '\\r' | grep -qix 'server: nginx'"

if [ "${KEEP:-0}" = 1 ]; then
    echo "==> Keeping $id (launch-ubuntu terminate $id)"
else
    echo "==> Terminating $id"
    launch-ubuntu terminate "$id" --yes >/dev/null 2>&1 ||
        echo "  warning: terminate failed; run: launch-ubuntu terminate $id"
fi
rm -rf "$work"

echo
if [ "$failed" = 0 ]; then echo "ALL CHECKS PASSED"; else echo "$failed CHECK(S) FAILED"; fi
echo "Log: $LOG"
exit "$failed"
