#!/bin/sh
# Keeps every Docker Compose app on this server in step with GitHub, without anyone
# running a script. Every $INTERVAL seconds, for each running compose project (found
# by the folder it was started from):
#
#   1. Config from GitHub: if the folder is a git checkout, it fetches the repo and
#      makes the tracked files match GitHub exactly. Hand edits to tracked files on
#      the server are put back (and logged); untracked/ignored files such as .env,
#      certs and reports are never touched. If anything changed, the app is
#      recreated with the new config.
#   2. Images from GitHub: it pulls newer images (built by each repo's GitHub
#      Actions) and recreates only the containers whose image changed.
#
# Needs (see docker-compose.yml): the Docker socket, the app folders mounted at the
# same path as on the server (/opt:/opt), the server's ghcr.io login, and a read-only
# GitHub token for private repos (github-token next to the proxy's docker-compose.yml).
set -u

INTERVAL=${INTERVAL:-900}              # seconds between checks (default 15 minutes)
SKIP_PROJECTS=${SKIP_PROJECTS:-}       # compose project names to leave alone, space-separated
SELF=$(cat /etc/hostname)

log() { echo "[$(date '+%F %T')] $*"; }
label() { docker inspect -f "{{index .Config.Labels \"$1\"}}" "$SELF" 2>/dev/null; }

PROJECT=$(label com.docker.compose.project)
SELF_SERVICE=$(label com.docker.compose.service)
SELF_DIR=$(label com.docker.compose.project.working_dir)
TOKEN_FILE=${GITHUB_TOKEN_FILE:-$SELF_DIR/github-token}

# git, never prompting, with the read-only token for github.com if there is one
git_in() {   # $1 = folder, rest = git arguments
    d=$1; shift
    if [ -s "$TOKEN_FILE" ]; then
        auth=$(printf 'x-access-token:%s' "$(tr -d ' \r\n' < "$TOKEN_FILE")" | base64 | tr -d '\n')
        GIT_TERMINAL_PROMPT=0 git -c safe.directory='*' -c "http.https://github.com/.extraHeader=Authorization: Basic $auth" -C "$d" "$@"
    else
        GIT_TERMINAL_PROMPT=0 git -c safe.directory='*' -C "$d" "$@"
    fi
}

# Files git manages (and .git itself) go back to the folder's owner, so they stay
# editable by that user. Nothing else in the folder (.env, certs, reports) is touched.
give_back() {   # $1 = folder
    d=$1; top=$(git_in "$d" rev-parse --show-toplevel); owner=$(stat -c '%u:%g' "$top")
    chown -R "$owner" "$top/.git"
    (cd "$top" && git -c safe.directory='*' ls-files -z | xargs -0 -r chown -h "$owner")
}

# Make the folder's tracked files match GitHub. Prints "changed" if they changed.
sync_config() {   # $1 = project name, $2 = folder
    name=$1; dir=$2
    [ "$(git_in "$dir" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] || return 0
    branch=$(git_in "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
    [ -n "$branch" ] && [ "$branch" != HEAD ] || branch=main
    out=$(git_in "$dir" fetch -q origin "$branch" 2>&1); ok=$?
    give_back "$dir"   # fetch writes inside .git
    if [ $ok -ne 0 ]; then
        log "$name: couldn't fetch config from GitHub: $(echo "$out" | tail -1)" >&2
        return 0
    fi
    here=$(git_in "$dir" rev-parse HEAD)
    github=$(git_in "$dir" rev-parse "origin/$branch")
    edits=$(git_in "$dir" --no-optional-locks status --porcelain --untracked-files=no | awk '{print $2}' | tr '\n' ' ')
    [ "$here" = "$github" ] && [ -z "$edits" ] && return 0
    [ -n "$edits" ] && log "$name: put back to GitHub's version (edited on the server): $edits" >&2
    if out=$(git_in "$dir" reset -q --hard "origin/$branch" 2>&1); then
        give_back "$dir"
        log "$name: config from GitHub: $(git_in "$dir" log -1 --format='%h %s' | cut -c1-70)" >&2
        echo changed
    else
        log "$name: couldn't apply GitHub's config: $(echo "$out" | tail -1)" >&2
    fi
}

update_project() {   # $1 = project name, $2 = working directory, $3 = config files
    name=$1; dir=$2; files=$3
    case " $SKIP_PROJECTS " in *" $name "*) return ;; esac
    if [ ! -d "$dir" ]; then
        log "$name: folder $dir isn't visible to the updater (mount it at the same path) - skipped"
        return
    fi
    changed=$(sync_config "$name" "$dir")

    # Use exactly the compose file(s) the project was started with
    set --
    for f in $(echo "$files" | tr ',' ' '); do set -- "$@" -f "$f"; done
    dc() { docker compose --project-directory "$dir" -p "$name" "$@"; }

    before=$(dc "$@" images -q 2>/dev/null | sort)
    if ! out=$(dc "$@" pull -q 2>&1); then
        log "$name: pull failed: $(echo "$out" | tail -2 | tr '\n' ' ')"
        return
    fi
    if [ -n "$changed" ]; then
        # New config: bring up every (non-profile) service as GitHub now defines it
        services=$(dc "$@" config --services 2>/dev/null)
    else
        # Same config: only the services that are running now
        services=$(dc "$@" ps --services --status running 2>/dev/null)
    fi
    # Never recreate this updater from inside itself (see below)
    [ "$name" = "$PROJECT" ] && services=$(echo "$services" | grep -vx "$SELF_SERVICE")
    if [ -n "$services" ]; then
        # shellcheck disable=SC2086
        if ! out=$(dc "$@" up -d --no-deps --no-build $services 2>&1); then
            log "$name: update failed: $(echo "$out" | tail -2 | tr '\n' ' ')"
            return
        fi
    fi
    after=$(dc "$@" images -q 2>/dev/null | sort)
    [ "$before" != "$after" ] && log "$name: updated to the newest image"

    # This updater itself (new image or new config): a container can't recreate
    # itself, so a short-lived helper container (same image, same mounts) does it.
    if [ "$name" = "$PROJECT" ]; then
        mine=$(docker inspect -f '{{.Image}}' "$SELF" 2>/dev/null)
        newest=$(docker image inspect -f '{{.Id}}' "$(docker inspect -f '{{.Config.Image}}' "$SELF")" 2>/dev/null)
        if [ -n "$changed" ] || { [ -n "$newest" ] && [ "$mine" != "$newest" ]; }; then
            log "$name: restarting the updater with the new version"
            docker run -d --rm --name "$SELF_SERVICE-restart-$$" \
                -v /var/run/docker.sock:/var/run/docker.sock -v "$dir:$dir" \
                --entrypoint docker "${newest:-$mine}" \
                compose --project-directory "$dir" -p "$name" "$@" up -d --no-deps --no-build "$SELF_SERVICE" >/dev/null
        fi
    fi
}

log "updater started: checking every ${INTERVAL}s (own project: ${PROJECT:-none}; skipping: ${SKIP_PROJECTS:-nothing}; GitHub token: $([ -s "$TOKEN_FILE" ] && echo "$TOKEN_FILE" || echo "none - public repos only"))"

while :; do
    # One line per running compose project: name|folder|compose files
    docker ps --filter label=com.docker.compose.project \
        --format '{{.Label "com.docker.compose.project"}}|{{.Label "com.docker.compose.project.working_dir"}}|{{.Label "com.docker.compose.project.config_files"}}' \
        | sort -u > /tmp/projects
    while IFS='|' read -r name dir files; do
        [ -n "$name" ] && update_project "$name" "$dir" "$files"
    done < /tmp/projects
    # Remove image layers no container uses any more (old versions), to save disk
    docker image prune -f >/dev/null 2>&1
    sleep "$INTERVAL"
done
