#!/bin/sh
# Keeps every Docker Compose app on this server up to date, without anyone
# running a script: every $INTERVAL seconds it finds each running compose project
# (by the folder it was started from), pulls newer images, and recreates only the
# containers whose image changed. Apps with nothing new are left alone.
#
# Needs (see docker-compose.yml): the Docker socket, the app folders mounted at the
# same path as on the server (/opt:/opt), and the server's ghcr.io login.
set -u

INTERVAL=${INTERVAL:-900}              # seconds between checks (default 15 minutes)
SKIP_PROJECTS=${SKIP_PROJECTS:-}       # compose project names to leave alone, space-separated
SELF=$(cat /etc/hostname)

log() { echo "[$(date '+%F %T')] $*"; }

own_project() {
    docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$SELF" 2>/dev/null
}

update_project() {   # $1 = project name, $2 = working directory, $3 = config files
    name=$1; dir=$2; files=$3
    case " $SKIP_PROJECTS " in *" $name "*) log "$name: skipped (SKIP_PROJECTS)"; return ;; esac
    if [ ! -d "$dir" ]; then
        log "$name: folder $dir isn't visible to the updater (mount it at the same path) - skipped"
        return
    fi
    # Use exactly the compose file(s) the project was started with
    set --
    for f in $(echo "$files" | tr ',' ' '); do set -- "$@" -f "$f"; done

    before=$(docker compose --project-directory "$dir" -p "$name" "$@" images -q 2>/dev/null | sort)
    if ! out=$(docker compose --project-directory "$dir" -p "$name" "$@" pull -q 2>&1); then
        log "$name: pull failed: $(echo "$out" | tail -2 | tr '\n' ' ')"
        return
    fi
    # Only the services that are running now; never this updater itself
    services=$(docker compose --project-directory "$dir" -p "$name" "$@" ps --services --status running 2>/dev/null)
    if [ "$name" = "$PROJECT" ]; then
        services=$(echo "$services" | grep -vx "${SELF_SERVICE:-updater}")
    fi
    [ -n "$services" ] || return
    # shellcheck disable=SC2086
    if ! out=$(docker compose --project-directory "$dir" -p "$name" "$@" up -d --no-deps --no-build $services 2>&1); then
        log "$name: update failed: $(echo "$out" | tail -2 | tr '\n' ' ')"
        return
    fi
    after=$(docker compose --project-directory "$dir" -p "$name" "$@" images -q 2>/dev/null | sort)
    if [ "$before" != "$after" ]; then
        log "$name: updated to the newest image"
    fi
    # A newer image of this updater itself: a container can't recreate itself, so a
    # short-lived helper container (same image, same mounts) does it.
    if [ "$name" = "$PROJECT" ]; then
        mine=$(docker inspect -f '{{.Image}}' "$SELF" 2>/dev/null)
        newest=$(docker image inspect -f '{{.Id}}' "$(docker inspect -f '{{.Config.Image}}' "$SELF")" 2>/dev/null)
        if [ -n "$newest" ] && [ "$mine" != "$newest" ]; then
            log "$name: newer updater image - restarting the updater"
            docker run -d --rm --name "${SELF_SERVICE:-updater}-restart-$$" \
                -v /var/run/docker.sock:/var/run/docker.sock -v "$dir:$dir" \
                --entrypoint docker "$newest" \
                compose --project-directory "$dir" -p "$name" "$@" up -d --no-deps --no-build "${SELF_SERVICE:-updater}" >/dev/null
        fi
    fi
}

PROJECT=$(own_project)
SELF_SERVICE=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$SELF" 2>/dev/null)
log "updater started: checking every ${INTERVAL}s (own project: ${PROJECT:-none}, skipping: ${SKIP_PROJECTS:-nothing})"

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
