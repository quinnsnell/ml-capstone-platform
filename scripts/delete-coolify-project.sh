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
#   scripts/delete-coolify-project.sh <student>               # list their projects
#   scripts/delete-coolify-project.sh --list                  # every team with extra projects
#   scripts/delete-coolify-project.sh <project-uuid>          # show the delete plan
#   scripts/delete-coolify-project.sh <project-uuid> --yes    # do it
#
# Always pick by uuid: a repeated `terraform apply` produces two projects
# identical in every field except uuid and creation time.
#
# --list reports two separate things, and they need different handling:
#
#   - REPEATED NAME inside one team: a `terraform apply` against a lost or
#     discarded state file. Their state tracks the newer one, so keep that and
#     delete the older -- but the older is usually the one carrying the real
#     domains, so they must redo lab step 10 afterwards.
#   - A team holding projects with DIFFERENT names: not a duplicate at all.
#     Either they changed project_name in terraform.tfvars (their state tracks
#     the new name and terraform will recreate whichever you delete -- ask
#     which name they want), or they made one by hand in the UI, which
#     terraform knows nothing about and is safe to remove.
set -euo pipefail

COOLIFY_HOST="${COOLIFY_HOST:-rigel}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/coolify-backups}"
PSQL="docker exec -i coolify-db psql -U coolify -d coolify -At -F'~'"

arg="${1:-}"
confirm="${2:-}"
if [[ -z "$arg" ]]; then
    sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
fi

run() { ssh -o BatchMode=yes "$COOLIFY_HOST" "$1"; }

# SQL string literals: double any apostrophe. Team names carry them
# ("Ashley Slade's Sandbox") and an unescaped one is a syntax error.
sqlq() { printf '%s' "${1//\'/\'\'}"; }

# ---------------------------------------------------------------- listing mode
# Anything that is not a uuid is a search term, so the uuid never has to be
# known in advance -- which is the whole problem when two projects share a name.
list_projects() {
    local where="$1" header="$2"
    echo "$header"
    echo
    local rows
    # The dupname flag is what separates the two situations: a project whose
    # name repeats inside the same team is a lost terraform state file; a
    # second project with a different name is a rename or a hand-made one.
    rows=$(run "$PSQL -c \"
      SELECT t.name, p.uuid, p.name, p.created_at,
             count(DISTINCT a.id),
             string_agg(DISTINCT a.status, ' ' ORDER BY a.status),
             COALESCE(string_agg(DISTINCT a.docker_compose_domains, ' '), ''),
             (SELECT count(*) FROM projects p2
              WHERE p2.team_id=p.team_id AND p2.name=p.name)
      FROM projects p JOIN teams t ON t.id=p.team_id
      LEFT JOIN environments e ON e.project_id=p.id
      LEFT JOIN applications a ON a.environment_id=e.id
      WHERE $where
      GROUP BY t.name, p.uuid, p.name, p.created_at, p.team_id
      ORDER BY t.name, p.created_at;\"")
    if [[ -z "$rows" ]]; then
        echo "  no projects matched"
        return 1
    fi

    local team last_team="" puuid pname created napps statuses blob ndup doms tag
    while IFS='~' read -r team puuid pname created napps statuses blob ndup; do
        [[ -z "$puuid" ]] && continue
        if [[ "$team" != "$last_team" ]]; then
            [[ -n "$last_team" ]] && echo
            echo "${team/\'s Sandbox/}"
            last_team="$team"
        fi
        # Only hostnames the student chose: Coolify's own are sslip.io or
        # <service>-<uuid>.<host IP>, and neither means anything was configured.
        doms=$(grep -oE '[A-Za-z0-9.-]+\.ml-capstone\.cs\.byu\.edu' <<<"$blob" \
               | sort -u | paste -sd' ' - || true)
        tag=""
        [[ "${ndup:-1}" -gt 1 ]] && tag="  <- SAME NAME as another project"
        printf '  %-26s %-9s %-14s created %s\n' \
               "$puuid" "${napps} apps" "${statuses:--}" "${created%%.*}"
        printf '      name    %s%s\n' "$pname" "$tag"
        printf '      domains %s\n' "${doms:-(none -- never configured)}"
    done <<<"$rows"
    echo
}

explain_choice() {
    cat <<'TXT'
A project marked SAME NAME is a repeated `terraform apply` against a lost
state file. Their state tracks the newer one, so keep that and delete the
older -- the older usually holds the real domains, so they redo lab step 10.

Projects with DIFFERENT names in one team are not that. Either the student
changed project_name in terraform.tfvars (their state tracks the new name
and terraform will recreate whichever you delete -- ask them which name they
want), or they made one by hand in the UI, which terraform knows nothing
about and is safe to remove.

TXT
}

if [[ "$arg" == "--list" || "$arg" == "-l" ]]; then
    # Two different things, and conflating them is how you delete the wrong
    # one: a repeated name inside a team, versus a team simply holding more
    # than one project.
    dupes=$(run "$PSQL -c \"
      SELECT count(*) FROM (SELECT team_id, name FROM projects
        GROUP BY team_id, name HAVING count(*) > 1) x;\"")
    if [[ "${dupes:-0}" != "0" ]]; then
        list_projects "p.team_id IN (
            SELECT team_id FROM projects GROUP BY team_id, name
            HAVING count(*) > 1)" \
          "Repeated project names — a lost terraform state file:" || true
    else
        echo "No team has two projects with the same name."
        echo
    fi

    list_projects "p.team_id IN (
        SELECT team_id FROM projects GROUP BY team_id HAVING count(*) > 1)" \
      "Teams holding more than one project (any names):" || exit 1
    explain_choice
    echo "Then:"
    echo "  $0 <project-uuid>         # dry run"
    echo "  $0 <project-uuid> --yes   # delete"
    exit 0
fi

if [[ ! "$arg" =~ ^[a-z0-9]{20,30}$ ]]; then
    # A student name, team name or project name. List and stop -- deleting
    # needs a uuid, because duplicates share every other field.
    term=$(sqlq "$arg")
    list_projects "t.name ILIKE '%${term}%' OR p.name ILIKE '%${term}%'" \
      "Projects matching '$arg':" || exit 1
    explain_choice
    echo "Pick the uuid to remove, then:"
    echo "  $0 <project-uuid>         # dry run"
    echo "  $0 <project-uuid> --yes   # delete"
    exit 0
fi

uuid="$arg"

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
