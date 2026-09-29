#!/bin/bash
# ─────────────────────────────────────────────────────────────
# pm-consolidate.sh — Convierte proyectos ya archivados como árboles sueltos
#                     (COLD_ROOT) al formato sellado (ARCHIVE_ROOT).
#
# Uso: pm-consolidate.sh [<ruta relativa>] [opciones]
#      pm-consolidate.sh --all
#      pm-consolidate.sh --client Cliente
#
# Opciones:
#   --execute        Ejecuta de verdad. Sin ella SOLO SIMULA.
#   --keep-source    No borra el árbol original tras verificar.
#   --all            Procesa toda la zona legada.
#   --client NOMBRE  Procesa solo ese primer nivel de ruta.
#   --max-gb N       Se detiene tras procesar N GB (para trabajar por lotes).
#
# DIFERENCIA CON pm-archive: estos proyectos YA están fuera del disco de trabajo.
# No hay trabajo vivo que perder, así que el estado git NO bloquea: se registra en
# el manifiesto como información. Lo que sí se mantiene es que nada se borra sin
# pasar las cuatro verificaciones.
# ─────────────────────────────────────────────────────────────
set -uo pipefail
_pm_src="${BASH_SOURCE[0]:-$0}"
while [ -L "$_pm_src" ]; do
  _pm_dir="$(cd -P "$(dirname "$_pm_src")" && pwd)"
  _pm_src="$(readlink "$_pm_src")"
  case "$_pm_src" in /*) ;; *) _pm_src="$_pm_dir/$_pm_src" ;; esac
done
_PM_BIN="$(cd -P "$(dirname "$_pm_src")" && pwd)"
source "$_PM_BIN/pm-lib.sh"

REL=""; EXECUTE=0; KEEP_SRC=0; ALL=0; CLIENT=""; MAX_GB=0
while [ $# -gt 0 ]; do
  case "$1" in
    --execute)     EXECUTE=1 ;;
    --keep-source) KEEP_SRC=1 ;;
    --all)         ALL=1 ;;
    --client)      CLIENT="$2"; shift ;;
    --max-gb)      MAX_GB="$2"; shift ;;
    -h|--help)     sed -n '2,24p' "$0"; exit 0 ;;
    -*)            die "Opción desconocida: $1" ;;
    *)             REL="${1%/}" ;;
  esac
  shift
done
pm_require_mounts
[ -d "$COLD_ROOT" ] || die "No existe la zona legada: $COLD_ROOT"

# ── Selección de proyectos ─────────────────────────────────
# Un proyecto legado es un directorio con .git, o uno de primer/segundo nivel
# que no contenga ningún .git por debajo.
list_legacy() {
  find "$COLD_ROOT" -maxdepth "$MAX_DEPTH" -name .git -not -path '*/node_modules/*' 2>/dev/null \
    | sed 's|/\.git$||'
  find "$COLD_ROOT" -mindepth 1 -maxdepth 2 -type d -not -name '.*' 2>/dev/null \
    | while IFS= read -r d; do
        [ -e "$d/.git" ] && continue
        p="$(dirname "$d")"; skip=0
        while [ "$p" != "$COLD_ROOT" ] && [ "$p" != "/" ]; do
          [ -e "$p/.git" ] && { skip=1; break; }; p="$(dirname "$p")"
        done
        [ "$skip" -eq 1 ] && continue
        [ -n "$(find "$d" -maxdepth 4 -name .git -print -quit 2>/dev/null)" ] && continue
        printf '%s\n' "$d"
      done
}

TARGETS=""
if [ -n "$REL" ]; then
  [ -d "$COLD_ROOT/$REL" ] || die "No existe: $COLD_ROOT/$REL"
  TARGETS="$COLD_ROOT/$REL"
elif [ "$ALL" -eq 1 ] || [ -n "$CLIENT" ]; then
  TARGETS="$(list_legacy | sort -u)"
  [ -n "$CLIENT" ] && TARGETS="$(printf '%s\n' "$TARGETS" | grep "^$COLD_ROOT/$CLIENT/\|^$COLD_ROOT/$CLIENT$")"
else
  die "Indica una ruta, --client NOMBRE o --all"
fi
[ -n "$TARGETS" ] || die "Ningún proyecto seleccionado"

# Descartar proyectos anidados: si un padre se empaqueta, ya contiene a sus hijos.
# (Los .git de los hijos viajan dentro del tarball y se conservan.)
TARGETS="$(printf '%s\n' "$TARGETS" | sort | awk '
  NR==1 { prev=$0; print; next }
  index($0, prev "/") == 1 { next }   # es descendiente del último aceptado
  { prev=$0; print }
')"

N="$(printf '%s\n' "$TARGETS" | grep -c .)"
[ "$EXECUTE" -eq 1 ] && MODE="${C_RED}EJECUCIÓN REAL${C_RST}" || MODE="${C_YEL}DRY-RUN${C_RST}"
printf '\n%s══ CONSOLIDAR ZONA LEGADA ══%s  [%s]  %s proyecto(s)\n\n' "$C_BLD" "$C_RST" "$MODE" "$N"

TOTAL_KB=0; DONE=0; FAILED=0; SKIPPED=0; PROCESSED_KB=0
LIMIT_KB=$(( MAX_GB * 1048576 ))

while IFS= read -r SRC; do
  [ -n "$SRC" ] || continue
  rel="${SRC#"$COLD_ROOT"/}"
  name="$(basename "$rel")"
  DEST="$ARCHIVE_ROOT/$rel"
  TARBALL="$DEST/$name.tar.zst"

  if [ -e "$TARBALL" ]; then
    printf '  %s—%s %-52s ya consolidado\n' "$C_DIM" "$C_RST" "$rel"
    SKIPPED=$((SKIPPED+1)); continue
  fi

  kind="$(pm_git_kind "$SRC")"
  IFS='|' read -r state branch remote ahead behind dirty <<< "$(pm_git_state "$SRC")"
  size_kb="$(pm_size_kb "$SRC")"
  secrets="$(pm_detect_secrets "$SRC")"
  if [ -z "$secrets" ]; then nsec=0; else nsec="$(printf '%s\n' "$secrets" | grep -c .)"; fi

  case "$state" in
    clean_synced) col="$C_GRN" ;;
    worktree_orphan|not_git) col="$C_YEL" ;;
    *) col="$C_RED" ;;
  esac
  printf '  %s%-20s%s %-44s %6s MB' "$col" "$state" "$C_RST" "$rel" "$((size_kb/1024))"
  [ "$nsec" -gt 0 ] && printf ' %s[%s secretos]%s' "$C_YEL" "$nsec" "$C_RST"

  if [ "$EXECUTE" -eq 0 ]; then printf '\n'; TOTAL_KB=$((TOTAL_KB+size_kb)); DONE=$((DONE+1)); continue; fi

  if [ "$LIMIT_KB" -gt 0 ] && [ "$PROCESSED_KB" -ge "$LIMIT_KB" ]; then
    printf '  %s(límite de %s GB alcanzado, parando)%s\n' "$C_DIM" "$MAX_GB" "$C_RST"; break
  fi

  mkdir -p "$DEST" || { printf ' %sERROR mkdir%s\n' "$C_RED" "$C_RST"; FAILED=$((FAILED+1)); continue; }
  BUNDLE="$DEST/$name.bundle"
  if [ "$kind" = "repo" ]; then
    git -C "$SRC" bundle create "$BUNDLE" --all >/dev/null 2>&1 || rm -f "$BUNDLE"
  fi

  if ! tar --exclude-from="$PM_ROOT/config/exclude.txt" --no-mac-metadata \
           -C "$SRC" -cf - . 2>/dev/null \
       | zstd -"$COMPRESS_LEVEL" -T"$COMPRESS_THREADS" -q -o "$TARBALL" -f 2>/dev/null; then
    printf ' %sERROR al empaquetar%s\n' "$C_RED" "$C_RST"; FAILED=$((FAILED+1)); continue
  fi
  ( cd "$DEST" && shasum -a 256 "$name.tar.zst" > "$name.tar.zst.sha256" )

  VOK=1
  zstd -t "$TARBALL" 2>/dev/null || VOK=0
  nfiles="$(zstd -dc "$TARBALL" 2>/dev/null | tar -tf - 2>/dev/null | wc -l | tr -d ' ')"
  [ "${nfiles:-0}" -gt 0 ] || VOK=0
  ( cd "$DEST" && shasum -a 256 -c "$name.tar.zst.sha256" >/dev/null 2>&1 ) || VOK=0
  [ -f "$BUNDLE" ] && { pm_verify_bundle "$BUNDLE" || VOK=0; }

  tar_kb="$(pm_size_kb "$TARBALL")"
  jq -n --arg rel "$rel" --arg name "$name" --arg src "$SRC" --arg stamp "$(date -Iseconds)" \
        --arg kind "$kind" --arg state "$state" --arg branch "$branch" --arg remote "$remote" \
        --arg head "$(git -C "$SRC" rev-parse HEAD 2>/dev/null)" --arg secrets "$secrets" \
        --argjson size "$size_kb" --argjson tarkb "$tar_kb" --argjson nfiles "${nfiles:-0}" \
        --argjson ok "$VOK" '{
    schema_version:1, archived_at:$stamp, rel_path:$rel, name:$name, source_path:$src,
    origin:"legacy-consolidation",
    git:{kind:$kind, state:$state,
         branch:(if $branch == "" then null else $branch end),
         remote:(if $remote == "" then null else $remote end),
         head:(if $head == "" then null else $head end)},
    size_kb_original:$size, size_kb_archive:$tarkb, files_in_tarball:$nfiles,
    verified:($ok==1),
    secrets_in_archive: ($secrets | if . == "" then [] else split("\n") end),
    artifacts:{tarball:($name+".tar.zst"), checksum:($name+".tar.zst.sha256"), bundle:($name+".bundle")}
  }' > "$DEST/manifest.json"

  # Un manifiesto ilegible deja el archivo sin metadatos: cuenta como fallo.
  if ! jq -e . "$DEST/manifest.json" >/dev/null 2>&1; then
    printf ' %smanifiesto inválido%s' "$C_RED" "$C_RST"; VOK=0
  fi

  if [ "$VOK" -eq 0 ]; then
    printf ' %sVERIFICACIÓN FALLIDA — original intacto%s\n' "$C_RED" "$C_RST"
    FAILED=$((FAILED+1)); continue
  fi

  if [ "$size_kb" -gt 0 ] && [ "$tar_kb" -le "$size_kb" ]; then
    pct=$(( 100 - (tar_kb * 100 / size_kb) ))
    printf ' %s->%s %s MB (-%s%%)' "$C_DIM" "$C_RST" "$((tar_kb/1024))" "$pct"
  else
    printf ' %s->%s %s KB' "$C_DIM" "$C_RST" "$tar_kb"
  fi
  if [ "$KEEP_SRC" -eq 0 ]; then
    rm -rf "$SRC" && printf ' %sliberado%s' "$C_GRN" "$C_RST"
  fi
  printf '\n'
  echo "$(date -Iseconds)  CONSOLIDATE  $rel  state=$state  files=$nfiles  keep_source=$KEEP_SRC" >> "$LOG_DIR/operations.log"
  DONE=$((DONE+1)); TOTAL_KB=$((TOTAL_KB+size_kb)); PROCESSED_KB=$((PROCESSED_KB+size_kb))
done <<< "$TARGETS"

printf '\n  procesados: %s · ya estaban: %s · fallidos: %s · volumen: %s GB\n' \
  "$DONE" "$SKIPPED" "$FAILED" "$((TOTAL_KB/1048576))"
if [ "$EXECUTE" -eq 0 ]; then
  printf '\n'; info "DRY-RUN. Nada se ha modificado. Añade --execute para ejecutar."
else
  pm_write_archive_readme "$ARCHIVE_ROOT"
fi
[ "$FAILED" -gt 0 ] && exit 3 || exit 0
