#!/usr/bin/env bash
# Delete a Coolify project that the UI refuses to delete.
#
# Why this exists: Coolify's project delete requires Project::isEmpty(), which
# counts applications. So the applications have to go first -- and the UI's
# resource delete sits behind a Livewire password-confirmation modal that, for
# a duplicate project created by a second `terraform apply`, has repeatedly
# failed to complete. The applications stay, so the project stays, and the
# student is left with twice the resources and no way to clean up.
#
# This drives Coolify's own models (soft delete + DeleteResourceJob), so no
# orphaned rows are left behind -- the same code path the UI would run, without
# the modal.
#
# Usage:
#   scripts/delete-coolify-project.sh <project-uuid>          # show the plan
#   scripts/delete-coolify-project.sh <project-uuid> --yes    # do it
set -euo pipefail

COOLIFY_HOST="${COOLIFY_HOST:-rigel}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/coolify-backups}"
PSQL="docker exec -i coolify-db psql -U coolify -d coolify -At -F'~'"

uuid="${1:-}"
confirm="${2:-}"
if [[ -z "$uuid" ]]; then
    sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
fi
if [[ ! "$uuid" =~ ^[a-z0-9]{20,30}$ ]]; then
    echo "error: '$uuid' does not look like a Coolify project uuid" >&2
    exit 1
fi

run() { ssh -o BatchMode=yes "$COOLIFY_HOST" "$1"; }

# --- the project must exist, and we report whose it is before touching it
row=$(run "$PSQL -c \"
  SELECT p.id, p.name, t.name FROM projects p JOIN teams t ON t.id=p.team_id
  WHERE p.uuid='$uuid';\"")
if [[ -z "$row" ]]; then
    echo "error: no project with uuid $uuid" >&2
    exit 1
fi
pid=$(cut -d'~' -f1 <<<"$row")
pname=$(cut -d'~' -f2 <<<"$row")
tname=$(cut -d'~' -f3 <<<"$row")

echo "project : $pname  (id $pid, uuid $uuid)"
echo "team    : $tname"
echo
echo "applications that would be deleted:"
run "$PSQL -c \"
  SELECT a.id, a.uuid, e.name, a.status,
         (SELECT count(*) FROM application_deployment_queues q
          WHERE q.application_id=a.id::text)
  FROM applications a JOIN environments e ON e.id=a.environment_id
  WHERE e.project_id=$pid ORDER BY e.name;\"" \
  | awk -F'~' '{printf "  %-4s %-26s %-11s %-20s %s deploys\n",$1,$2,$3,$4,$5}'

echo
echo "domains on them (LOST on delete -- the student must redo lab step 10):"
doms=$(run "$PSQL -c \"
  SELECT COALESCE(a.docker_compose_domains,'') FROM applications a
  JOIN environments e ON e.id=a.environment_id WHERE e.project_id=$pid;\"" \
  | grep -oE '[a-z0-9.-]+\.ml-capstone\.cs\.byu\.edu' | sort -u || true)
if [[ -n "$doms" ]]; then sed 's/^/  /' <<<"$doms"; else echo "  (none)"; fi

# --- the team's other projects, so you can see you are keeping the right one.
# Keyed on team_id, not the team name: names like "Ashley Slade's Sandbox"
# carry an apostrophe that breaks the SQL string.
echo
echo "other projects in this team (NOT touched):"
run "$PSQL -c \"
  SELECT p.uuid, p.name, p.created_at, count(a.id)
  FROM projects p
  LEFT JOIN environments e ON e.project_id=p.id
  LEFT JOIN applications a ON a.environment_id=e.id
  WHERE p.team_id=(SELECT team_id FROM projects WHERE id=$pid)
    AND p.uuid<>'$uuid'
  GROUP BY p.uuid,p.name,p.created_at ORDER BY p.created_at;\"" \
  | awk -F'~' '{printf "  %-26s %-18s created %s  %s apps\n",$1,$2,$3,$4}'

if [[ "$confirm" != "--yes" ]]; then
    echo
    echo "Dry run. Re-run with --yes to delete."
    exit 0
fi

# --- backup before the irreversible part
mkdir -p "$BACKUP_DIR"
out="$BACKUP_DIR/project-$uuid-$(date +%Y%m%d-%H%M%S).json"
run "$PSQL -c \"
  SELECT json_build_object(
    'project', (SELECT row_to_json(p) FROM projects p WHERE p.id=$pid),
    'environments', (SELECT json_agg(row_to_json(e)) FROM environments e
                     WHERE e.project_id=$pid),
    'applications', (SELECT json_agg(row_to_json(a)) FROM applications a
                     JOIN environments e ON e.id=a.environment_id
                     WHERE e.project_id=$pid));\"" > "$out"
echo "backup: $out"

# --- delete through Coolify's own models.
#     Volumes and configurations are app-scoped, so those get cleaned up.
#     Connected networks and a docker prune are shared state on a host running
#     the whole class, so those are deliberately left alone.
ssh -o BatchMode=yes "$COOLIFY_HOST" 'docker exec -i coolify php artisan tinker' <<PHP
\$p = App\Models\Project::where('uuid', '$uuid')->first();
if (! \$p) { echo "ABORT: project vanished\n"; exit; }
foreach (\$p->applications()->get() as \$a) {
    \$id = \$a->id; \$u = \$a->uuid;
    \$a->delete();
    App\Jobs\DeleteResourceJob::dispatch(\$a, true, false, true, false);
    echo "deleted application \$id (\$u)\n";
}
\$p->refresh();
if (\$p->isEmpty()) { \$p->delete(); echo "deleted project $uuid\n"; }
else { echo "KEPT project: still reports resources, inspect by hand\n"; }
PHP

echo
echo "verifying:"
left=$(run "$PSQL -c \"SELECT count(*) FROM projects WHERE uuid='$uuid';\"")
if [[ "$left" == "0" ]]; then
    echo "  project $uuid is gone"
else
    echo "  project $uuid STILL PRESENT -- inspect by hand" >&2
    exit 1
fi
