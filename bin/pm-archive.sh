#!/bin/bash
# ─────────────────────────────────────────────────────────────
# pm-archive.sh — Archiva un proyecto de caliente a frío (zona sellada).
#
# Uso: pm-archive.sh <rel_path> [opciones]
#   <rel_path>     Ruta relativa a HOT_ROOT, p.ej. "Claude/cauce"
#
# Opciones:
#   --execute      Ejecuta de verdad. SIN ESTA OPCIÓN SOLO SIMULA (dry-run).
#
# POLÍTICA DE SEGURIDAD (no hay opción para saltársela):
#   Un proyecto con trabajo que sólo existe en caliente NO SE ARCHIVA JAMÁS.
#   Estados con bloqueo duro: dirty_uncommitted, dirty_unpushed, diverged,
#   unpushed_no_upstream, worktree_orphan, worktree con padre, repo con worktrees.
#   Primero se salva el trabajo (commit + push); después se archiva.
#
#   --accept-single-copy  Permite archivar un repo limpio SIN REMOTO. El archivo
#                         pasa a ser la única copia; se exige bundle verificado.
#   --accept-no-git       Permite archivar contenido que no es repositorio git.
#   --accept-secrets      Permite archivar aunque viajen ficheros con pinta de
#                         secreto (claves, .env, credenciales) EN CLARO al disco frío.
#   --keep-hot     No borra el original de caliente tras archivar.
#   --no-bundle    No genera git bundle (no recomendado).
#   --gc           Ejecuta `git gc` antes de empaquetar (reduce tamaño; MODIFICA el repo).
#
# El original NUNCA se borra si la verificación posterior falla.
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

REL=""; EXECUTE=0; ACCEPT_SINGLE=0; ACCEPT_NOGIT=0; ACCEPT_SECRETS=0; KEEP_HOT=0; DO_BUNDLE=1; DO_GC=0
while [ $# -gt 0 ]; do
  case "$1" in
    --execute)   EXECUTE=1 ;;
    --accept-single-copy) ACCEPT_SINGLE=1 ;;
    --accept-no-git)      ACCEPT_NOGIT=1 ;;
    --accept-secrets)     ACCEPT_SECRETS=1 ;;
    --keep-hot)  KEEP_HOT=1 ;;
    --no-bundle) DO_BUNDLE=0 ;;
    --gc)        DO_GC=1 ;;
    -h|--help)   sed -n '2,30p' "$0"; exit 0 ;;
    -*)          die "Opción desconocida: $1" ;;
    *)           REL="${1%/}" ;;
  esac
  shift
done
[ -n "$REL" ] || die "Falta <rel_path>. Ejemplo: pm-archive.sh Claude/cauce"

pm_require_mounts
SRC="$HOT_ROOT/$REL"
[ -d "$SRC" ] || die "No existe en caliente: $SRC"

DEST="$ARCHIVE_ROOT/$REL"
NAME="$(basename "$REL")"
TARBALL="$DEST/$NAME.tar.zst"
BUNDLE="$DEST/$NAME.bundle"
STAMP="$(date -Iseconds)"

[ "$EXECUTE" -eq 1 ] && MODE="${C_RED}EJECUCIÓN REAL${C_RST}" || MODE="${C_YEL}DRY-RUN (simulación)${C_RST}"
printf '\n%s══ ARCHIVAR: %s ══%s  [%s]\n\n' "$C_BLD" "$REL" "$C_RST" "$MODE"

# ── 1. Estado git ──────────────────────────────────────────
KIND="$(pm_git_kind "$SRC")"
IFS='|' read -r STATE BRANCH REMOTE AHEAD BEHIND DIRTY <<< "$(pm_git_state "$SRC")"
printf '  tipo:    %s\n  estado:  %s\n  rama:    %s\n  remoto:  %s\n' \
  "$KIND" "$STATE" "${BRANCH:-—}" "${REMOTE:-—(sin remoto)}"
[ "$AHEAD" != "0" ] && printf '  %s↑ %s commits sin pushear%s\n' "$C_RED" "$AHEAD" "$C_RST"
[ "$DIRTY" != "0" ] && printf '  %s± %s ficheros sin commitear%s\n' "$C_RED" "$DIRTY" "$C_RST"

HARD=()   # bloqueos sin escape posible
SOFT=()   # riesgos que exigen reconocimiento explícito
case "$STATE" in
  clean_synced)
    ;;
  dirty_uncommitted)
    HARD+=("$DIRTY fichero(s) sin commitear: ese trabajo sólo existe aquí.") ;;
  dirty_unpushed)
    HARD+=("$AHEAD commit(s) sin pushear: ese trabajo sólo existe aquí.") ;;
  diverged)
    HARD+=("Rama divergente (↑$AHEAD ↓$BEHIND): resuelve la divergencia antes de archivar.") ;;
  unpushed_no_upstream)
    HARD+=("Rama '$BRANCH' sin upstream y su HEAD no está en ningún remoto: trabajo no publicado.") ;;
  worktree_orphan)
    HARD+=("Worktree huérfano: su repo padre no existe. Consolídalo antes (git clone / copia).") ;;
  clean_local_only)
    SOFT+=("Sin remoto configurado: el archivo será la ÚNICA copia del proyecto.") ;;
  not_git)
    SOFT+=("No es un repositorio git: no hay historia ni red de seguridad.") ;;
  *)
    HARD+=("Estado '''$STATE''' no reconocido: se bloquea por prudencia.") ;;
esac

# ── 2. Worktrees: unidad atómica ───────────────────────────
if [ "$KIND" = "repo" ]; then
  WTS="$(git -C "$SRC" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | tail -n +2)"
  if [ -n "$WTS" ]; then
    printf '\n  %sEste repo tiene worktrees vinculados:%s\n' "$C_YEL" "$C_RST"
    printf '    %s\n' $WTS
    HARD+=("Tiene $(printf '%s\n' $WTS | grep -c .) worktree(s) vinculados. Archivar el padre los deja INUTILIZABLES.")
  fi
elif [ "$KIND" = "worktree" ]; then
  PARENT="$(pm_worktree_parent "$SRC")"
  printf '\n  %sEs un worktree de:%s %s\n' "$C_YEL" "$C_RST" "${PARENT:-desconocido}"
  HARD+=("Es un worktree: su .git apunta al repo padre. Consolídalo antes (git worktree remove, o clonar aparte).")
fi

# ── 3. Colisiones mayúsculas/minúsculas (origen case-sensitive → destino case-insensitive) ──
COLL="$(find "$SRC" -not -path '*/node_modules/*' 2>/dev/null | tr 'A-Z' 'a-z' | sort | uniq -d | head -5)"
if [ -n "$COLL" ]; then
  printf '\n  %sColisiones de mayúsculas detectadas (destino es case-insensitive):%s\n' "$C_RED" "$C_RST"
  printf '    %s\n' $COLL
  warn "El tarball las preserva, pero una restauración a APFS case-insensitive fallará."
fi

# ── 3b. Secretos que viajarían en claro ────────────────────
SECRETS="$(pm_detect_secrets "$SRC")"
if [ -n "$SECRETS" ]; then
  NSEC="$(printf '%s\n' "$SECRETS" | grep -c .)"
  printf '\n  %sSECRETOS DETECTADOS (%s) — viajarían EN CLARO al disco frío:%s\n' "$C_RED" "$NSEC" "$C_RST"
  printf '%s\n' "$SECRETS" | sed 's/^/    · /'
fi

# ── 4. Tamaños ─────────────────────────────────────────────
SIZE_KB="$(pm_size_kb "$SRC")"
JUNK_KB="$(find "$SRC" -maxdepth 6 \( -name node_modules -o -name .venv -o -name venv \
            -o -name __pycache__ -o -name dist -o -name build -o -name target \) -type d -prune -print0 2>/dev/null \
          | xargs -0 du -sk 2>/dev/null | awk '{s+=$1} END {print s+0}')"
printf '\n  tamaño total:     %s MB\n  excluido (basura): %s MB\n  a empaquetar:     %s MB\n' \
  "$((SIZE_KB/1024))" "$((JUNK_KB/1024))" "$(((SIZE_KB-JUNK_KB)/1024))"

# ── 5. Política de seguridad ───────────────────────────────
if [ ${#HARD[@]} -gt 0 ]; then
  printf '\n  %sBLOQUEO DURO — no se archiva:%s\n' "$C_RED" "$C_RST"
  for b in "${HARD[@]}"; do printf '    · %s\n' "$b"; done
  printf '\n  %sQué hacer:%s\n' "$C_BLD" "$C_RST"
  case "$STATE" in
    dirty_uncommitted) printf '    git -C %s add -A && git -C %s commit -m "wip" && git -C %s push\n' "$SRC" "$SRC" "$SRC" ;;
    dirty_unpushed)    printf '    git -C %s push\n' "$SRC" ;;
    diverged)          printf '    git -C %s pull --rebase   # revisa y resuelve, luego push\n' "$SRC" ;;
    unpushed_no_upstream) printf '    git -C %s push -u origin %s\n' "$SRC" "$BRANCH" ;;
  esac
  printf '\n'
  err "No hay opción para saltarse este bloqueo. Salva el trabajo primero."
  exit 2
fi

[ -n "$SECRETS" ] && SOFT+=("$NSEC fichero(s) con pinta de secreto viajarían sin cifrar al disco frío.")

if [ ${#SOFT[@]} -gt 0 ]; then
  printf '\n  %sRIESGO RECONOCIBLE:%s\n' "$C_YEL" "$C_RST"
  for b in "${SOFT[@]}"; do printf '    · %s\n' "$b"; done
  NEED=()
  [ "$STATE" = "clean_local_only" ] && [ "$ACCEPT_SINGLE"  -eq 0 ] && NEED+=("--accept-single-copy")
  [ "$STATE" = "not_git" ]          && [ "$ACCEPT_NOGIT"   -eq 0 ] && NEED+=("--accept-no-git")
  [ -n "$SECRETS" ]                 && [ "$ACCEPT_SECRETS" -eq 0 ] && NEED+=("--accept-secrets")
  if [ ${#NEED[@]} -gt 0 ]; then
    printf '\n'
    err "Requiere reconocimiento explícito: añade ${NEED[*]}"
    [ -n "$SECRETS" ] && [ "$ACCEPT_SECRETS" -eq 0 ] && \
      info "Alternativa: mueve los secretos fuera del proyecto, o añádelos a config/exclude.txt."
    exit 2
  fi
  warn "Riesgo reconocido explícitamente. Continuando."
fi

# ── 6. Plan ────────────────────────────────────────────────
printf '\n  %sPlan:%s\n' "$C_BLD" "$C_RST"
printf '    1. mkdir -p %s\n' "$DEST"
[ "$DO_GC" -eq 1 ]     && printf '    2. git -C %s gc --prune=now\n' "$SRC"
[ "$DO_BUNDLE" -eq 1 ] && printf '    3. git bundle create %s --all\n' "$BUNDLE"
printf '    4. tar --exclude-from=config/exclude.txt -c . | zstd -%s > %s\n' "$COMPRESS_LEVEL" "$TARBALL"
printf '    5. shasum -a 256 + manifest.json\n'
printf '    6. VERIFICAR (zstd -t, tar -tf, git bundle verify)\n'
[ "$KEEP_HOT" -eq 0 ] && printf '    7. %srm -rf %s%s  (solo si 6 pasa)\n' "$C_RED" "$SRC" "$C_RST" \
                      || printf '    7. (--keep-hot: se conserva el original)\n'

if [ "$EXECUTE" -eq 0 ]; then
  printf '\n'; info "DRY-RUN. Nada se ha modificado. Añade --execute para ejecutar."; exit 0
fi

# ── 7. EJECUCIÓN ───────────────────────────────────────────
printf '\n'
mkdir -p "$DEST" || die "No se pudo crear $DEST"

if [ "$DO_GC" -eq 1 ] && [ "$KIND" = "repo" ]; then
  info "git gc…"; git -C "$SRC" gc --prune=now --quiet || warn "git gc falló (se continúa)"
fi

if [ "$DO_BUNDLE" -eq 1 ] && [ "$KIND" = "repo" ]; then
  info "Creando git bundle (historia completa)…"
  git -C "$SRC" bundle create "$BUNDLE" --all 2>/dev/null || { warn "bundle falló"; rm -f "$BUNDLE"; }
fi

info "Empaquetando con tar + zstd -${COMPRESS_LEVEL}…"
tar --exclude-from="$PM_ROOT/config/exclude.txt" --no-mac-metadata \
    -C "$SRC" -cf - . 2>/dev/null \
  | zstd -"$COMPRESS_LEVEL" -T"$COMPRESS_THREADS" -q -o "$TARBALL" -f \
  || die "Fallo al empaquetar. El original NO se ha tocado."

info "Calculando checksum…"
( cd "$DEST" && shasum -a 256 "$NAME.tar.zst" > "$NAME.tar.zst.sha256" )

# ── 8. VERIFICACIÓN (imprescindible antes de borrar) ───────
info "Verificando integridad…"
VERIFY_OK=1
zstd -t "$TARBALL" 2>/dev/null || { err "zstd -t FALLÓ"; VERIFY_OK=0; }
NFILES="$(zstd -dc "$TARBALL" 2>/dev/null | tar -tf - 2>/dev/null | wc -l | tr -d ' ')"
[ "${NFILES:-0}" -gt 0 ] || { err "El tarball no lista ficheros"; VERIFY_OK=0; }
( cd "$DEST" && shasum -a 256 -c "$NAME.tar.zst.sha256" >/dev/null 2>&1 ) || { err "checksum FALLÓ"; VERIFY_OK=0; }
if [ -f "$BUNDLE" ]; then
  pm_verify_bundle "$BUNDLE" || { err "git bundle verify FALLÓ"; VERIFY_OK=0; }
fi

# ── 9. Manifiesto ──────────────────────────────────────────
jq -n --arg rel "$REL" --arg name "$NAME" --arg src "$SRC" --arg stamp "$STAMP" \
      --arg kind "$KIND" --arg state "$STATE" --arg branch "$BRANCH" --arg remote "$REMOTE" \
      --arg lastc "$(pm_last_commit "$SRC")" --arg head "$(git -C "$SRC" rev-parse HEAD 2>/dev/null)" \
      --argjson size "$SIZE_KB" --argjson junk "$JUNK_KB" --argjson nfiles "${NFILES:-0}" \
      --argjson ok "$VERIFY_OK" --arg tarsz "$(pm_size_kb "$TARBALL")" \
      --arg secrets "$SECRETS" '{
  schema_version:1, archived_at:$stamp, rel_path:$rel, name:$name, source_path:$src,
  git:{kind:$kind, state:$state, branch:$branch, remote:$remote, head:$head, last_commit:$lastc},
  size_kb_original:$size, size_kb_excluded:$junk, size_kb_archive:($tarsz|tonumber),
  files_in_tarball:$nfiles, verified:($ok==1),
  secrets_in_archive: ($secrets | if . == "" then [] else split("\n") end),
  artifacts:{tarball:($name+".tar.zst"), checksum:($name+".tar.zst.sha256"), bundle:($name+".bundle")},
  restore_hint:("bin/pm-restore.sh " + $rel)
}' > "$DEST/manifest.json"

if [ "$VERIFY_OK" -eq 0 ]; then
  err "VERIFICACIÓN FALLIDA. El original en caliente NO se ha borrado."
  exit 3
fi
TAR_KB="$(pm_size_kb "$TARBALL")"
if [ "$TAR_KB" -ge 1024 ]; then TAR_H="$((TAR_KB/1024)) MB"; else TAR_H="$TAR_KB KB"; fi
ok "Verificación correcta: $NFILES ficheros, $TAR_H comprimidos (original $((SIZE_KB/1024)) MB)."

if [ "$KEEP_HOT" -eq 0 ]; then
  warn "Borrando original: $SRC"
  rm -rf "$SRC" && ok "Original eliminado. Espacio liberado: $((SIZE_KB/1024)) MB"
else
  info "--keep-hot: el original permanece en caliente."
fi

echo "$STAMP  ARCHIVE  $REL  state=$STATE  files=$NFILES  keep_hot=$KEEP_HOT" >> "$LOG_DIR/operations.log"
ok "Archivado completo: $DEST"
