#!/bin/bash
# ─────────────────────────────────────────────────────────────
# pm-restore.sh — Restaura un proyecto de la zona sellada a caliente.
#
# Uso: pm-restore.sh <rel_path> [--execute] [--to RUTA] [--from-bundle]
#
# Opciones:
#   --execute      Ejecuta de verdad. Sin ella solo simula (dry-run).
#   --to RUTA      Destino alternativo (por defecto HOT_ROOT/<rel_path>).
#   --from-bundle  Restaura clonando el git bundle en vez del tarball
#                  (devuelve la historia git limpia, sin ficheros ignorados).
#
# Nunca sobrescribe un destino existente.
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

REL=""; EXECUTE=0; DEST_OVERRIDE=""; FROM_BUNDLE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --execute)     EXECUTE=1 ;;
    --to)          DEST_OVERRIDE="$2"; shift ;;
    --from-bundle) FROM_BUNDLE=1 ;;
    -h|--help)     sed -n '2,16p' "$0"; exit 0 ;;
    -*)            die "Opción desconocida: $1" ;;
    *)             REL="${1%/}" ;;
  esac
  shift
done
[ -n "$REL" ] || die "Falta <rel_path>."

pm_require_mounts
SRC="$ARCHIVE_ROOT/$REL"
NAME="$(basename "$REL")"
TARBALL="$SRC/$NAME.tar.zst"
BUNDLE="$SRC/$NAME.bundle"
DEST="${DEST_OVERRIDE:-$HOT_ROOT/$REL}"

[ -d "$SRC" ] || die "No hay archivo sellado en: $SRC"
[ -f "$SRC/manifest.json" ] || warn "Sin manifest.json (archivo antiguo o incompleto)"

[ "$EXECUTE" -eq 1 ] && MODE="${C_RED}EJECUCIÓN REAL${C_RST}" || MODE="${C_YEL}DRY-RUN${C_RST}"
printf '\n%s══ RESTAURAR: %s ══%s  [%s]\n\n' "$C_BLD" "$REL" "$C_RST" "$MODE"

if [ -f "$SRC/manifest.json" ]; then
  jq -r '"  archivado:  \(.archived_at)",
         "  estado git: \(.git.state) · rama \(.git.branch // "—")",
         "  remoto:     \(.git.remote // "— (SIN REMOTO: copia única)")",
         "  ficheros:   \(.files_in_tarball)",
         "  verificado: \(.verified)"' "$SRC/manifest.json"
fi

if [ -e "$DEST" ]; then
  err "El destino YA existe: $DEST"
  die "Elimínalo o usa --to con otra ruta. No se sobrescribe nada."
fi

# Espacio disponible
NEED_KB="$(jq -r '.size_kb_original // 0' "$SRC/manifest.json" 2>/dev/null || echo 0)"
AVAIL_KB="$(df -k "$(dirname "$DEST")" 2>/dev/null | awk 'NR==2{print $4}')"
printf '\n  necesita: ~%s MB   ·   libre en destino: %s MB\n' "$((NEED_KB/1024))" "$((AVAIL_KB/1024))"
[ "${AVAIL_KB:-0}" -lt "${NEED_KB:-0}" ] && warn "Puede que NO haya espacio suficiente."

printf '\n  %sPlan:%s\n' "$C_BLD" "$C_RST"
if [ "$FROM_BUNDLE" -eq 1 ]; then
  [ -f "$BUNDLE" ] || die "No existe el bundle: $BUNDLE"
  printf '    1. git bundle verify %s\n    2. git clone %s %s\n' "$BUNDLE" "$BUNDLE" "$DEST"
else
  [ -f "$TARBALL" ] || die "No existe el tarball: $TARBALL"
  printf '    1. shasum -c %s.sha256\n    2. mkdir -p %s\n    3. zstd -dc | tar -x -C %s\n' \
         "$NAME.tar.zst" "$DEST" "$DEST"
fi

if [ "$EXECUTE" -eq 0 ]; then
  printf '\n'; info "DRY-RUN. Nada se ha modificado. Añade --execute para ejecutar."; exit 0
fi

printf '\n'
if [ "$FROM_BUNDLE" -eq 1 ]; then
  info "Verificando bundle…"
  pm_verify_bundle "$BUNDLE" || die "Bundle corrupto. Abortado."
  mkdir -p "$(dirname "$DEST")"
  git clone "$BUNDLE" "$DEST" || die "git clone falló"
  info "Recuerda reapuntar el remoto: git -C $DEST remote set-url origin <URL>"
else
  info "Verificando checksum…"
  ( cd "$SRC" && shasum -a 256 -c "$NAME.tar.zst.sha256" >/dev/null 2>&1 ) \
    || die "Checksum NO coincide. Archivo corrupto. Abortado."
  mkdir -p "$DEST"
  info "Extrayendo…"
  zstd -dc "$TARBALL" | tar -xf - -C "$DEST" || die "Extracción falló"
fi

echo "$(date -Iseconds)  RESTORE  $REL -> $DEST  from_bundle=$FROM_BUNDLE" >> "$LOG_DIR/operations.log"
ok "Restaurado en: $DEST"
IFS='|' read -r st br rm a b d <<< "$(pm_git_state "$DEST")"
printf '  estado tras restaurar: %s (rama %s)\n' "$st" "${br:-—}"
