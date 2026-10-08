# Shared helpers for the CLI, the daemon scripts and the hooks.
# Source, don't execute. Everything is derived from $SNAP_INSTANCE_NAME, so
# renaming the snap needs no change here.

DEFAULT_PORT=8080
SERVICE="$SNAP_INSTANCE_NAME.server"

SITE_DIR="$SNAP/site"
NGINX_CONF="$SNAP_DATA/nginx.conf"
CONFIG_JSON="$SNAP_DATA/config.json"
LOG_DIR="$SNAP_COMMON/logs"
LIVE_PORT="$SNAP_DATA/run/live-port"   # port the running nginx listens on

die() { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }

# ---------------------------------------------------------------- settings
# Defaults live here and in the install hook. To add a setting, see AGENTS.md.

get_port()      { v=$(snapctl get port);      echo "${v:-$DEFAULT_PORT}"; }
get_autoindex() { v=$(snapctl get autoindex); echo "${v:-false}"; }
get_devpages()  { v=$(snapctl get dev-pages); echo "${v:-false}"; }

validate_port() {
    case "$1" in
        ''|*[!0-9]*) die "port must be a number, got '$1'" ;;
    esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ] || die "port must be between 1 and 65535, got '$1'"
}

validate_bool() { # name value
    case "$2" in
        true|false) ;;
        *) die "$1 must be 'true' or 'false', got '$2'" ;;
    esac
}

port_open() { # port -> 0 if something accepts connections on 127.0.0.1:port
    { exec 4<>"/dev/tcp/127.0.0.1/$1"; } 2>/dev/null || return 1
    exec 4<&-
}

# `nginx -t` ignores "address in use", so check before switching ports.
# Our own current port is fine. Skipped before the first start (no live
# port yet) so a busy 8080 cannot block installation.
validate_port_free() { # port
    local live
    live=$(cat "$LIVE_PORT" 2>/dev/null || true)
    [ -n "$live" ] && [ "$1" != "$live" ] || return 0
    ! port_open "$1" || die "port $1 is already in use by another program"
}

validate_settings() {
    validate_port "$(get_port)"
    validate_port_free "$(get_port)"
    validate_bool autoindex "$(get_autoindex)"
    validate_bool dev-pages "$(get_devpages)"
}

# ---------------------------------------------------------------- rendering

sed_escape() { printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'; }

ensure_dirs() {
    mkdir -p "$SNAP_DATA/run" "$SNAP_DATA/tmp" "$LOG_DIR"
}

render_config() { # out_conf
    local out="$1" port autoindex devpages ai v6 dev dev_snippet nginx_version json_tmp
    port=$(get_port)
    autoindex=$(get_autoindex)
    devpages=$(get_devpages)

    if [ "$autoindex" = true ]; then ai=on; else ai=off; fi

    if [ -e /proc/net/if_inet6 ]; then
        v6="        listen [::]:$port default_server;"
    else
        v6="        # IPv6 not available on this host"
    fi

    dev_snippet="$SNAP_DATA/dev-pages.conf"
    if [ "$devpages" = true ]; then
        sed -e "s|@SNAP@|$(sed_escape "$SNAP")|g" \
            -e "s|@SNAP_DATA@|$(sed_escape "$SNAP_DATA")|g" \
            "$SNAP/conf/dev-pages.conf.in" > "$dev_snippet"
        dev="        include $dev_snippet;"
    else
        dev="        # developer pages disabled (dev-pages=false)"
    fi

    sed -e "s|@SNAP@|$(sed_escape "$SNAP")|g" \
        -e "s|@SNAP_DATA@|$(sed_escape "$SNAP_DATA")|g" \
        -e "s|@SNAP_COMMON@|$(sed_escape "$SNAP_COMMON")|g" \
        -e "s|@PORT@|$port|g" \
        -e "s|@AUTOINDEX@|$ai|g" \
        -e "s|@LISTEN_V6@|$(sed_escape "$v6")|" \
        -e "s|@DEV_PAGES@|$(sed_escape "$dev")|" \
        -e "s|@GENERATION@|$GENERATION|g" \
        "$SNAP/conf/nginx.conf.in" > "$out"

    nginx_version=$("$SNAP/usr/sbin/nginx" -v 2>&1 | sed 's|.*nginx/||')
    json_tmp=$(mktemp "$CONFIG_JSON.XXXXXX")
    cat > "$json_tmp" <<EOF
{
  "snap": "$SNAP_INSTANCE_NAME",
  "snap_version": "$SNAP_VERSION",
  "snap_revision": "$SNAP_REVISION",
  "nginx_version": "$nginx_version",
  "port": $port,
  "site": "$SITE_DIR",
  "autoindex": $autoindex,
  "dev_pages": $devpages,
  "access_log": "$LOG_DIR/access.log",
  "error_log": "$LOG_DIR/error.log",
  "rendered_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    chmod 644 "$json_tmp"
    mv "$json_tmp" "$CONFIG_JSON"
}

nginx_run() {
    "$SNAP/usr/sbin/nginx" -p "$SNAP_DATA/" -e "$LOG_DIR/error.log" "$@"
}

nginx_test() { # conf
    nginx_run -t -q -c "$1"
}

# Render into a temp file, validate it, then atomically swap it in.
# Each caller gets its own temp file: the configure hook and the daemon can
# render at the same time during install.
apply_config() {
    local tmp out
    ensure_dirs
    GENERATION="$(date +%s%N)-$RANDOM"
    tmp=$(mktemp "$NGINX_CONF.XXXXXX")
    render_config "$tmp"
    if ! out=$(nginx_test "$tmp" 2>&1); then
        rm -f "$tmp"
        die "generated nginx configuration is invalid:
$out"
    fi
    chmod 644 "$tmp"
    mv "$tmp" "$NGINX_CONF"
}

service_active() {
    snapctl services "$SERVICE" | awk 'NR==2 {print $3}' | grep -qx active
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "this command changes the server; run it with sudo:  sudo $SNAP_INSTANCE_NAME $*"
}
