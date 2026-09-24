#!/bin/bash
# ─────────────────────────────────────────────────────────────
# pm-status.sh — Informe legible del parque de proyectos, leyendo data/index.json
#
# Uso: pm-status.sh [--zone hot|cold|archive] [--client NOMBRE]
#                   [--state ESTADO] [--archivable] [--needs-attention]
#                   [--stale] [--json] [--top N]
#
# SOLO LECTURA.
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

ZONE=""; CLIENT=""; STATE=""; MODE="summary"; TOP=0; AS_JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --zone)   ZONE="$2"; shift ;;
    --client) CLIENT="$2"; shift ;;
    --state)  STATE="$2"; shift ;;
    --archivable)      MODE="archivable" ;;
    --needs-attention) MODE="attention" ;;
    --stale)           MODE="stale" ;;
    --top)    TOP="$2"; shift ;;
    --json)   AS_JSON=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) die "Opción desconocida: $1" ;;
  esac
  shift
done

[ -f "$INDEX_FILE" ] || die "No hay índice. Ejecuta primero: bin/pm-scan.sh"

FILTER='.projects'
[ -n "$ZONE" ]   && FILTER="$FILTER | map(select(.zone==\"$ZONE\"))"
[ -n "$CLIENT" ] && FILTER="$FILTER | map(select(.client==\"$CLIENT\"))"
[ -n "$STATE" ]  && FILTER="$FILTER | map(select(.git.state==\"$STATE\"))"

case "$MODE" in
  archivable) FILTER="$FILTER | map(select(.zone==\"hot\" and .archivable))" ;;
  attention)  FILTER="$FILTER | map(select(.zone==\"hot\" and (.archivable|not)))" ;;
  stale)      FILTER="$FILTER | map(select(.zone==\"hot\" and (.last_mtime // \"0\") < \"$(date -v-${STALE_DAYS}d +%Y-%m-%d)\"))" ;;
esac

if [ "$AS_JSON" -eq 1 ]; then
  jq "$FILTER" "$INDEX_FILE"; exit 0
fi

# ── Resumen global ──
if [ "$MODE" = "summary" ] && [ -z "$ZONE$CLIENT$STATE" ]; then
  printf '\n%s══ PARQUE DE PROYECTOS ══%s  %s\n\n' "$C_BLD" "$C_RST" "$(jq -r .generated_at "$INDEX_FILE")"
  jq -r '
    "  Total proyectos: \(.stats.total)",
    "  Por zona:  " + (.stats.by_zone | to_entries | map("\(.key)=\(.value)") | join("  ")),
    "",
    "  Caliente: \(.stats.hot_size_gb) GB  ·  regenerable (node_modules/.venv/…): \(.stats.hot_junk_gb) GB",
    ""
  ' "$INDEX_FILE"

  printf '  %sEstado git (solo zona caliente):%s\n' "$C_BLD" "$C_RST"
  jq -r '.projects | map(select(.zone=="hot")) | group_by(.git.state)
         | map("    \(.[0].git.state)|\(length)") | .[]' "$INDEX_FILE" \
  | while IFS='|' read -r s c; do
      case "${s// /}" in
        clean_synced)      col="$C_GRN" ;;
        clean_local_only|no_upstream) col="$C_YEL" ;;
        not_git)           col="$C_YEL" ;;
        *)                 col="$C_RED" ;;
      esac
      printf '%s%-56s%s %s\n' "$col" "$s" "$C_RST" "$c"
    done
  printf '\n'
fi

# ── Listado ──
jq -r "$FILTER"' | sort_by(-.size_kb) | .[]
  | [ .zone, .git.state, .git.kind, (.size_kb/1048576*100|round/100|tostring)+"G",
      (.last_mtime // .last_commit // "-")[0:10], .rel_path,
      (if .git.dirty_files>0 then "±\(.git.dirty_files)" else "" end),
      (if .git.ahead>0 then "↑\(.git.ahead)" else "" end),
      (if .git.behind>0 then "↓\(.git.behind)" else "" end) ]
  | @tsv' "$INDEX_FILE" \
| { [ "$TOP" -gt 0 ] && head -n "$TOP" || cat; } \
| while IFS=$'\t' read -r zone state kind size date rel d a b; do
    case "$state" in
      clean_synced) col="$C_GRN" ;;
      clean_local_only|no_upstream|not_git) col="$C_YEL" ;;
      *) col="$C_RED" ;;
    esac
    printf '%-4s %s%-20s%s %-9s %7s  %s  %-56s %s%s%s\n' \
      "$zone" "$col" "$state" "$C_RST" "$kind" "$size" "$date" "$rel" "$d" "$a" "$b"
  done
