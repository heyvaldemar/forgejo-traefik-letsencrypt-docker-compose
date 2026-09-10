#!/bin/bash

# Restore Forgejo's data directory from one of the archives the `backups`
# container has taken.
#
# That directory is the whole instance: the git repositories themselves, the
# SQLite database holding users, issues, pull requests, access tokens and
# webhooks, app.ini, avatars, attachments and the LFS store.
#
#     chmod +x forgejo-restore-data.sh
#     ./forgejo-restore-data.sh
#
# Note what a git host does and does not need this for. The commits are already
# on every machine that has cloned them — that is what the tool is. What only
# lives here is everything around them: who the users are, what the issues say,
# which pull requests were reviewed, and the instance configuration itself.
set -euo pipefail
cd "$(dirname "$0")"

COMPOSE_FILE="${DOCKER_COMPOSE_FILE:-forgejo-traefik-letsencrypt-docker-compose.yml}"
PROJECT="${COMPOSE_PROJECT_NAME:-forgejo}"
BACKUP_PATH="${DATA_BACKUPS_PATH:-/srv/forgejo-data/backups}"
RESTORE_PATH="${DATA_PATH:-/data}"

dc() { docker compose -f "$COMPOSE_FILE" -p "$PROJECT" "$@"; }

APP_CONTAINER="$(dc ps -aq forgejo | head -n 1)"
BACKUPS_CONTAINER="$(dc ps -aq backups | head -n 1)"
[ -n "$APP_CONTAINER" ] || { echo "the forgejo container was not found — is the stack up?" >&2; exit 1; }
[ -n "$BACKUPS_CONTAINER" ] || { echo "the backups container was not found — is the stack up?" >&2; exit 1; }

echo "--> All available data backups:"
docker exec "$BACKUPS_CONTAINER" sh -c "ls -1 $BACKUP_PATH" || true

echo "--> Copy and paste the backup name from the list above and press [ENTER]
--> Example: forgejo-data-backup-YYYY-MM-DD_hh-mm.tar.gz"
echo -n "--> "
read -r SELECTED
[ -n "$SELECTED" ] || { echo "nothing selected, nothing restored" >&2; exit 1; }

if ! docker exec "$BACKUPS_CONTAINER" sh -c "tar -tzf '${BACKUP_PATH}/${SELECTED}' > /dev/null"; then
  echo "that file is not a readable tar archive — nothing has been stopped or deleted" >&2
  exit 1
fi
echo "--> $SELECTED was selected and reads as a valid archive"

echo "--> Stopping Forgejo..."
docker stop "$APP_CONTAINER" > /dev/null

echo "--> Restoring the data directory..."
# The archive stores paths relative to /, so it extracts there. The directory
# is emptied first: a merge would leave the database describing repositories
# from one point in time and the disk holding them from another, which is the
# one failure mode a restore exists to avoid.
docker exec "$BACKUPS_CONTAINER" sh -c "rm -rf '${RESTORE_PATH:?}'/* && tar -zxpf '${BACKUP_PATH}/${SELECTED}' -C /"
echo "--> Data recovery completed."

echo "--> Starting Forgejo..."
docker start "$APP_CONTAINER" > /dev/null
echo "--> Forgejo answers once it has opened the restored database."
echo "--> Check Site Administration -> Repositories afterwards: it reports any"
echo "--> repository the database knows about and the disk does not."
