#!/bin/bash
# ─────────────────────────────────────────────────────────────
# pm-scan.sh — Recorre las zonas caliente y fría, clasifica cada proyecto
#              y genera data/index.json
#
# Uso: pm-scan.sh [--hot-only] [--cold-only] [--no-size] [--quiet]
#
# SOLO LECTURA: este script nunca modifica un proyecto.
# ─────────────────────────────────────────────────────────────
set -uo pipefail
# Resolver la ruta real del script aunque se invoque a través de un symlink
# (macOS no tiene `readlink -f` fiable, así que se sigue la cadena a mano).
_pm_src="${BASH_SOURCE[0]:-$0}"
while [ -L "$_pm_src" ]; do
  _pm_dir="$(cd -P "$(dirname "$_pm_src")" && pwd)"
  _pm_src="$(readlink "$_pm_src")"
  case "$_pm_src" in /*) ;; *) _pm_src="$_pm_dir/$_pm_src" ;; esac
done
_PM_BIN="$(cd -P "$(dirname "$_pm_src")" && pwd)"
source "$_PM_BIN/pm-lib.sh"

SCAN_HOT=1; SCAN_COLD=1; DO_SIZE=1; QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --hot-only)  SCAN_COLD=0 ;;
    --cold-only) SCAN_HOT=0 ;;
    --no-size)   DO_SIZE=0 ;;
    --quiet|-q)  QUIET=1 ;;
    -h|--help)   sed -n '2,12p' "$0"; exit 0 ;;
    *) die "Opción desconocida: $1" ;;
  esac
  shift
done

TSV="$(mktemp -t pmscan)"; trap 'rm -f "$TSV"' EXIT

# Descubre unidades de proyecto bajo una raíz.
# Un proyecto es: (a) cualquier dir con .git, o
#                 (b) un dir de nivel 1 o 2 que NO esté dentro de un proyecto git,
#                     no contenga ningún .git en su subárbol y no sea un dir basura.
# La condición "no dentro de un proyecto" es imprescindible: en la zona fría hay
# proyectos a distintos niveles (raíz, cliente/proyecto, cliente/línea/proyecto).
JUNK_NAMES='node_modules|\.venv|venv|__pycache__|dist|build|target|tmp|test-results|\.pnpm-store|coverage|Untitled|\.obsidian'

# ¿El directorio cuelga de un proyecto git ya existente?
inside_project() {
  local d="$1" root="$2" p
  p="$(dirname "$d")"
  while [ "$p" != "$root" ] && [ "$p" != "/" ] && [ -n "$p" ]; do
    [ -e "$p/.git" ] && return 0
    p="$(dirname "$p")"
  done
  return 1
}

discover() {
  local root="$1"
  [ -d "$root" ] || return 0
  # (a) repos, worktrees y submódulos
  find "$root" -maxdepth "$MAX_DEPTH" -name .git -not -path '*/node_modules/*' 2>/dev/null \
    | sed 's|/\.git$||'
  # (b) proyectos sin git
  find "$root" -mindepth 1 -maxdepth 2 -type d -not -name '.*' 2>/dev/null \
    | grep -v '/\.' \
    | grep -Ev "/($JUNK_NAMES)$" \
    | while IFS= read -r d; do
        [ -e "$d/.git" ] && continue
        inside_project "$d" "$root" && continue
        [ -n "$(find "$d" -maxdepth 4 -name .git -print -quit 2>/dev/null)" ] && continue
        printf '%s\n' "$d"
      done
}

scan_zone() {
  local zone="$1" root="$2" n=0 total
  [ -d "$root" ] || { warn "Zona '$zone' no disponible: $root"; return 0; }
  local list; list="$(discover "$root" | sort -u)"
  total="$(printf '%s\n' "$list" | grep -c . )"
  [ "$QUIET" -eq 1 ] || info "Zona $zone: $total proyectos en $root"

  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    n=$((n+1))
    [ "$QUIET" -eq 1 ] || printf '\r  [%s] %d/%d %-50.50s' "$zone" "$n" "$total" "${dir##*/}" >&2

    local rel client name kind st state branch remote ahead behind dirty
    rel="${dir#"$root"/}"
    client="${rel%%/*}"
    name="${rel##*/}"
    kind="$(pm_git_kind "$dir")"
    st="$(pm_git_state "$dir")"
    IFS='|' read -r state branch remote ahead behind dirty <<< "$st"

    local parent=""
    [ "$kind" = "worktree" ] || [ "$kind" = "submodule" ] && parent="$(pm_worktree_parent "$dir")"

    local size_kb=0 junk_kb=0
    if [ "$DO_SIZE" -eq 1 ]; then
      size_kb="$(pm_size_kb "$dir")"
      junk_kb="$(find "$dir" -maxdepth 6 \( -name node_modules -o -name .venv -o -name venv \
                  -o -name __pycache__ -o -name dist -o -name build -o -name target \) \
                  -type d -prune -print0 2>/dev/null \
                | xargs -0 du -sk 2>/dev/null | awk '{s+=$1} END {print s+0}')"
    fi

    local lastc lastm
    lastc="$(pm_last_commit "$dir")"
    lastm="$(pm_last_mtime "$dir")"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$zone" "$rel" "$client" "$name" "$dir" "$kind" "$state" "$branch" \
      "$remote" "$ahead" "$behind" "$dirty" "$size_kb" "$junk_kb" "$lastc|$lastm" "$parent" >> "$TSV"
  done <<< "$list"
  [ "$QUIET" -eq 1 ] || printf '\r%-70s\r' "" >&2
}

pm_require_mounts
[ "$SCAN_HOT"  -eq 1 ] && scan_zone hot     "$HOT_ROOT"
[ "$SCAN_COLD" -eq 1 ] && scan_zone cold    "$COLD_ROOT"
[ "$SCAN_COLD" -eq 1 ] && scan_zone archive "$ARCHIVE_ROOT"

mkdir -p "$(dirname "$INDEX_FILE")"
jq -R -s --arg gen "$(date -Iseconds)" \
        --arg hot "$HOT_ROOT" --arg cold "$COLD_ROOT" --arg arch "$ARCHIVE_ROOT" '
  def nn: if . == "" then null else . end;
  {
    schema_version: 1,
    generated_at: $gen,
    roots: { hot: $hot, cold: $cold, archive: $arch },
    projects: (
      split("\n") | map(select(length>0)) | map(split("\t")) | map({
        id:      (.[0] + ":" + .[1]),
        zone:     .[0],
        rel_path: .[1],
        client:   .[2],
        name:     .[3],
        path:     .[4],
        git: {
          kind:        .[5],
          state:       .[6],
          branch:     (.[7] | nn),
          remote:     (.[8] | nn),
          ahead:      (.[9] | tonumber),
          behind:     (.[10]| tonumber),
          dirty_files:(.[11]| tonumber),
          worktree_parent: (.[15] // "" | nn)
        },
        size_kb:      (.[12]| tonumber),
        junk_kb:      (.[13]| tonumber),
        size_clean_kb:((.[12]|tonumber) - (.[13]|tonumber)),
        last_commit:  (.[14]| split("|")[0] | nn),
        last_mtime:   (.[14]| split("|")[1] | nn),
        archivable:   (.[6] == "clean_synced"),
        tags: []
      })
    )
  }
  | .stats = {
      total:    (.projects|length),
      by_zone:  (.projects|group_by(.zone)|map({key:.[0].zone, value:length})|from_entries),
      by_state: (.projects|group_by(.git.state)|map({key:.[0].git.state,value:length})|from_entries),
      hot_size_gb:  ((.projects|map(select(.zone=="hot"))|map(.size_kb)|add // 0)/1048576*100|round/100),
      hot_junk_gb:  ((.projects|map(select(.zone=="hot"))|map(.junk_kb)|add // 0)/1048576*100|round/100)
    }
' "$TSV" > "$INDEX_FILE" || die "Fallo generando el índice"

# Snapshot histórico para poder comparar en el tiempo
mkdir -p "$SNAPSHOT_DIR"
cp "$INDEX_FILE" "$SNAPSHOT_DIR/index-$(date +%Y%m%d-%H%M%S).json"

ok "Índice generado: $INDEX_FILE"
jq -r '"  proyectos: \(.stats.total)  |  caliente: \(.stats.hot_size_gb) GB (basura: \(.stats.hot_junk_gb) GB)"' "$INDEX_FILE" >&2
