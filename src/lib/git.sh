# Serving a site from a git repository instead of the built-in one.
# Source after common.sh. Settings (all optional, unset = built-in site):
#
#   git.repo         https:// or http:// URL of the repository
#   git.branch       branch or tag to deploy (default: the remote HEAD)
#   git.path         subfolder to serve (default: the repository root)
#   git.auto-update  off | <n>m | <n>h   (checked every 5 minutes)
#
# Layout under $SNAP_COMMON/git (kept across refreshes):
#
#   repo.git/            bare, shallow copy of the remote
#   deploys/<id>/        one checkout per deployed commit, without .git
#   deploys/<id>.info    repo/branch/path/commit/date of that deploy
#   current              id of the deploy being served (absent = built-in)
#   history              ids in deploy order, for rollback
#
# A deploy only prepares files and moves `current`. Callers then run
# apply_config and reload, and call git_restore on failure.

GIT_DIR_ROOT="$SNAP_COMMON/git"
GIT_REPO="$GIT_DIR_ROOT/repo.git"
GIT_DEPLOYS="$GIT_DIR_ROOT/deploys"
GIT_CURRENT="$GIT_DIR_ROOT/current"
GIT_HISTORY="$GIT_DIR_ROOT/history"
GIT_LOCK="$GIT_DIR_ROOT/lock"
GIT_LAST_CHECK="$GIT_DIR_ROOT/last-check"
GIT_KEEP=5   # deploys kept on disk for rollback

get_git_repo()       { snapctl get git.repo; }
get_git_branch()     { snapctl get git.branch; }
get_git_path()       { snapctl get git.path; }
get_git_autoupdate() { v=$(snapctl get git.auto-update); echo "${v:-off}"; }

# git from the snap, isolated from any system or user configuration.
# libcurl (for https) is not in the base snap, hence LD_LIBRARY_PATH.
git() {
    LD_LIBRARY_PATH="$SNAP/usr/lib/$(uname -m)-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    GIT_EXEC_PATH="$SNAP/usr/lib/git-core" \
    GIT_TEMPLATE_DIR="$SNAP/usr/share/git-core/templates" \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    GIT_TERMINAL_PROMPT=0 GIT_SSL_CAINFO=/etc/ssl/certs/ca-certificates.crt \
    "$SNAP/usr/bin/git" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 "$@"
}

# ---------------------------------------------------------------- validation

validate_git_repo() {
    [ -z "$1" ] && return 0
    case "$1" in
        https://?*|http://?*) ;;
        *) die "git.repo must be an https:// (or http://) URL, got '$1'" ;;
    esac
    case "$1" in
        *[[:space:]\'\"\\\`]*) die "git.repo contains invalid characters" ;;
    esac
}

validate_git_branch() {
    [ -z "$1" ] && return 0
    git check-ref-format --allow-onelevel "$1" && [ "${1#-}" = "$1" ] ||
        die "git.branch is not a valid branch or tag name: '$1'"
}

validate_git_path() {
    [ -z "$1" ] && return 0
    case "$1" in
        *[!A-Za-z0-9._/-]*) die "git.path may only contain letters, digits, '.', '_', '-' and '/', got '$1'" ;;
        /*) die "git.path must be relative to the repository root, got '$1'" ;;
    esac
    case "/$1/" in
        */../*|*/./*) die "git.path must not contain '.' or '..' components, got '$1'" ;;
    esac
}

autoupdate_seconds() { # off|<n>m|<n>h -> seconds (0 = off)
    local n=${1%[mh]}
    case "$1" in off|false|'') echo 0; return 0 ;; esac
    case "$n" in ''|*[!0-9]*) return 1 ;; esac
    case "$1" in
        *m) echo $(( 10#$n * 60 )) ;;
        *h) echo $(( 10#$n * 3600 )) ;;
        *) return 1 ;;
    esac
}

validate_git_autoupdate() {
    local s
    s=$(autoupdate_seconds "$1") || die "git.auto-update must be 'off' or an interval like 15m or 1h, got '$1'"
    [ "$s" -eq 0 ] || [ "$s" -ge 300 ] || die "git.auto-update must be at least 5m, got '$1'"
}

validate_git_settings() {
    validate_git_repo "$(get_git_repo)"
    validate_git_branch "$(get_git_branch)"
    validate_git_path "$(get_git_path)"
    validate_git_autoupdate "$(get_git_autoupdate)"
}

# ---------------------------------------------------------------- state

git_current() { cat "$GIT_CURRENT" 2>/dev/null || true; }

git_info() { # id key -> value from deploys/<id>.info
    local k v
    [ -n "$1" ] && [ -f "$GIT_DEPLOYS/$1.info" ] || return 0
    while IFS='=' read -r k v; do
        [ "$k" = "$2" ] && { printf '%s\n' "$v"; return 0; }
    done < "$GIT_DEPLOYS/$1.info"
}

write_atomic() { # file content
    local tmp
    tmp=$(mktemp "$1.XXXXXX")
    printf '%s\n' "$2" > "$tmp"
    mv "$tmp" "$1"
}

git_set_current() { # id ("" = built-in)
    if [ -n "$1" ]; then write_atomic "$GIT_CURRENT" "$1"; else rm -f "$GIT_CURRENT"; fi
}

# Web root for nginx: the current deploy, or the built-in site.
site_root() {
    local id path
    id=$(git_current)
    if [ -n "$id" ] && [ -d "$GIT_DEPLOYS/$id" ]; then
        path=$(git_info "$id" path)
        echo "$GIT_DEPLOYS/$id${path:+/$path}"
    else
        echo "$SITE_DIR"
    fi
}

# Only one deploy at a time (CLI, configure hook, auto-update timer).
git_lock() {
    local pid
    mkdir -p "$GIT_DIR_ROOT"
    if ! mkdir "$GIT_LOCK" 2>/dev/null; then
        pid=$(cat "$GIT_LOCK/pid" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            die "another deploy is in progress (pid $pid)"
        fi
        rm -rf "$GIT_LOCK"
        mkdir "$GIT_LOCK" || die "cannot take the deploy lock $GIT_LOCK"
    fi
    echo $$ > "$GIT_LOCK/pid"
    trap 'rm -rf "$GIT_LOCK"' EXIT
}

git_unlock() { rm -rf "$GIT_LOCK"; trap - EXIT; }

# ---------------------------------------------------------------- deploy

# Fetch the configured repo/branch and print the commit id.
git_fetch() {
    local repo=$1 branch=$2 ref out
    ref=${branch:-HEAD}
    if [ ! -d "$GIT_REPO" ]; then
        git init -q --bare "$GIT_REPO"
        git --git-dir="$GIT_REPO" remote add origin "$repo"
    else
        git --git-dir="$GIT_REPO" remote set-url origin "$repo"
    fi
    # Shallow first; servers without shallow support (dumb http) get a full fetch.
    if ! out=$(git --git-dir="$GIT_REPO" fetch -q --depth 1 --no-tags origin "$ref" 2>&1) &&
       ! out=$(git --git-dir="$GIT_REPO" fetch -q --no-tags origin "$ref" 2>&1); then
        die "cannot fetch '$ref' from $repo:
$out"
    fi
    git --git-dir="$GIT_REPO" rev-parse --verify -q 'FETCH_HEAD^{commit}' ||
        die "'$ref' in $repo is not a commit"
}

# Check out a commit into a new deploy folder and make it current.
# Prints the new id. Symlinks become plain files (core.symlinks=false), so
# a repository cannot point nginx outside its own checkout.
git_checkout() { # repo branch path commit
    local repo=$1 branch=$2 path=$3 commit=$4 id dir index out
    id="$(date -u +%Y%m%dT%H%M%SZ)-${commit:0:12}"
    dir="$GIT_DEPLOYS/$id"
    mkdir -p "$dir"
    # A throwaway index: git refuses an existing empty file, so no mktemp.
    index="$GIT_DIR_ROOT/index.$$"
    rm -f "$index"
    if ! out=$(GIT_INDEX_FILE="$index" git --git-dir="$GIT_REPO" --work-tree="$dir" \
            -c core.symlinks=false checkout -q -f "$commit" -- . 2>&1); then
        rm -rf "$dir" "$index"
        die "cannot check out ${commit:0:12}:
$out"
    fi
    rm -f "$index"
    if [ -n "$path" ] && [ ! -d "$dir/$path" ]; then
        rm -rf "$dir"
        die "folder '$path' does not exist in $repo at ${commit:0:12}"
    fi
    [ -f "$dir${path:+/$path}/index.html" ] ||
        warn "no index.html in ${path:-the repository root}; / will return 403 unless autoindex is on"
    printf 'repo=%s\nbranch=%s\npath=%s\ncommit=%s\ndate=%s\n' \
        "$repo" "$branch" "$path" "$commit" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$GIT_DEPLOYS/$id.info"
    echo "$id" >> "$GIT_HISTORY"
    git_set_current "$id"
    echo "$id"
}

# Delete old deploys, keeping the newest $GIT_KEEP and the current one.
git_prune() {
    local cur ids n=0 id
    cur=$(git_current)
    # Ids start with a UTC timestamp, so a reverse sort is newest first.
    mapfile -t ids < <(cd "$GIT_DEPLOYS" 2>/dev/null && for d in */; do echo "${d%/}"; done | sort -r)
    for id in "${ids[@]}"; do
        [ "$id" = '*' ] && continue
        n=$((n + 1))
        [ "$n" -le "$GIT_KEEP" ] || [ "$id" = "$cur" ] && continue
        rm -rf "${GIT_DEPLOYS:?}/$id" "$GIT_DEPLOYS/$id.info"
    done
    # Forget history entries whose files are gone.
    if [ -f "$GIT_HISTORY" ]; then
        local tmp
        tmp=$(mktemp "$GIT_HISTORY.XXXXXX")
        while read -r id; do [ -d "$GIT_DEPLOYS/$id" ] && echo "$id"; done < "$GIT_HISTORY" > "$tmp" || true
        mv "$tmp" "$GIT_HISTORY"
    fi
}

# Bring the served site in line with the git.* settings. Prints a message
# describing what changed. Callers remember git_current beforehand and pass
# it to git_restore if applying the result fails. Modes:
#   sync    deploy only if repo/branch/path differ from the current deploy
#   update  also fetch and deploy when the branch has new commits
git_sync() { # sync|update
    local mode=$1 repo branch path cur commit
    repo=$(get_git_repo); branch=$(get_git_branch); path=$(get_git_path)
    cur=$(git_current)

    if [ -z "$repo" ]; then
        [ -n "$cur" ] || return 0
        git_set_current ""
        echo "Serving the built-in site."
        return 0
    fi

    if [ "$mode" = sync ] && [ -n "$cur" ] && [ -d "$GIT_DEPLOYS/$cur" ] &&
       [ "$(git_info "$cur" repo)" = "$repo" ] &&
       [ "$(git_info "$cur" branch)" = "$branch" ] &&
       [ "$(git_info "$cur" path)" = "$path" ]; then
        return 0
    fi

    git_lock
    commit=$(git_fetch "$repo" "$branch")
    date +%s > "$GIT_LAST_CHECK"
    if [ -n "$cur" ] && [ "$(git_info "$cur" commit)" = "$commit" ] &&
       [ "$(git_info "$cur" repo)" = "$repo" ] && [ "$(git_info "$cur" branch)" = "$branch" ] &&
       [ "$(git_info "$cur" path)" = "$path" ]; then
        git_unlock
        echo "Already up to date at ${commit:0:12}."
        return 0
    fi
    git_checkout "$repo" "$branch" "$path" "$commit" >/dev/null
    git_prune
    git_unlock
    echo "Deployed $repo${branch:+ ($branch)}${path:+, folder $path} at ${commit:0:12}."
}

# Undo a git_sync whose configuration or reload failed.
git_restore() { # previous id
    local failed
    failed=$(git_current)
    git_set_current "$1"
    if [ -n "$failed" ] && [ "$failed" != "$1" ]; then
        rm -rf "${GIT_DEPLOYS:?}/$failed" "$GIT_DEPLOYS/$failed.info"
        git_prune
    fi
}

# Previous deploy in history, for rollback.
git_previous_id() {
    local cur prev= id
    cur=$(git_current)
    [ -f "$GIT_HISTORY" ] || return 0
    while read -r id; do
        [ "$id" = "$cur" ] && break
        [ -d "$GIT_DEPLOYS/$id" ] && prev=$id
    done < "$GIT_HISTORY"
    echo "$prev"
}

git_forget_all() { rm -rf "$GIT_DIR_ROOT"; }
