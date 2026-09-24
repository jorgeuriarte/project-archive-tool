#!/bin/bash
# ─────────────────────────────────────────────────────────────
# pm-lib.sh — funciones comunes. No ejecutar directamente; hacer source.
# ─────────────────────────────────────────────────────────────

# Resolver la ruta real del script aunque se invoque a través de un symlink
# (macOS no tiene `readlink -f` fiable, así que se sigue la cadena a mano).
_pm_src="${BASH_SOURCE[0]:-$0}"
while [ -L "$_pm_src" ]; do
  _pm_dir="$(cd -P "$(dirname "$_pm_src")" && pwd)"
  _pm_src="$(readlink "$_pm_src")"
  case "$_pm_src" in /*) ;; *) _pm_src="$_pm_dir/$_pm_src" ;; esac
done
_PM_BIN="$(cd -P "$(dirname "$_pm_src")" && pwd)"
PM_LIB_DIR="$_PM_BIN"
PM_CODE_ROOT="$(dirname "$PM_LIB_DIR")"

# La herramienta (código) y la instancia (tu configuración y tus datos) pueden
# vivir en sitios distintos. Orden de resolución de la instancia:
#   1. $PM_HOME              — variable de entorno explícita
#   2. ~/.config/pm-archive  — instalación estándar
#   3. junto al código       — repo autocontenido (modo desarrollo)
if [ -n "${PM_HOME:-}" ] && [ -f "$PM_HOME/config/pm.conf" ]; then
  PM_ROOT="$PM_HOME"
elif [ -f "$HOME/.config/pm-archive/config/pm.conf" ]; then
  PM_ROOT="$HOME/.config/pm-archive"
elif [ -f "$PM_CODE_ROOT/config/pm.conf" ]; then
  PM_ROOT="$PM_CODE_ROOT"
else
  echo "[x] No encuentro config/pm.conf. Define PM_HOME o ejecuta install.sh" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$PM_ROOT/config/pm.conf"

# --- Colores (se desactivan si no hay TTY) ---
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[34m'
  C_DIM=$'\033[2m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_BLD=""; C_RST=""
fi

log()  { printf '%s\n' "$*" >&2; }
info() { printf '%s[i]%s %s\n' "$C_BLU" "$C_RST" "$*" >&2; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
ok()   { printf '%s[v]%s %s\n' "$C_GRN" "$C_RST" "$*" >&2; }
die()  { err "$*"; exit 1; }

# --- Comprobación de montaje: nunca operar sobre un volumen desmontado ---
pm_require_mounts() {
  [ -d "$HOT_ROOT" ]  || die "Volumen caliente no montado: $HOT_ROOT"
  [ -d "$(dirname "$ARCHIVE_ROOT")" ] || die "Volumen frío no montado: $(dirname "$ARCHIVE_ROOT")"
}

# --- Tipo de repositorio ---
# Salida: repo | worktree | submodule | none
pm_git_kind() {
  local d="$1"
  if [ -d "$d/.git" ]; then echo "repo"; return; fi
  if [ -f "$d/.git" ]; then
    local gd; gd="$(sed -n 's/^gitdir: //p' "$d/.git" 2>/dev/null | head -1)"
    case "$gd" in
      *"/.git/worktrees/"*) echo "worktree" ;;
      *"/.git/modules/"*)   echo "submodule" ;;
      *)                    echo "worktree" ;;
    esac
    return
  fi
  echo "none"
}

# --- Repo padre de un worktree (ruta absoluta) o "" ---
pm_worktree_parent() {
  local d="$1" gd
  gd="$(sed -n 's/^gitdir: //p' "$d/.git" 2>/dev/null | head -1)" || return
  [ -n "$gd" ] || return
  # Ruta relativa (submódulos) -> absolutizar
  case "$gd" in /*) ;; *) gd="$d/$gd" ;; esac
  printf '%s' "${gd%%/.git/*}"
}

# --- Estado git de un directorio ---
# Salida: estado|rama|remoto|ahead|behind|n_cambios
# Estados: clean_synced clean_local_only dirty_uncommitted dirty_unpushed
#          diverged no_upstream worktree_orphan not_git
pm_git_state() {
  local d="$1" kind state branch remote ahead=0 behind=0 dirty=0 upstream

  kind="$(pm_git_kind "$d")"
  if [ "$kind" = "none" ]; then echo "not_git|||0|0|0"; return; fi

  if [ "$kind" = "worktree" ] || [ "$kind" = "submodule" ]; then
    local parent; parent="$(pm_worktree_parent "$d")"
    # Roto si falta el repo padre, o si el padre existe pero ya no registra este worktree.
    if [ -z "$parent" ] || [ ! -e "$parent/.git" ] || ! git -C "$d" rev-parse HEAD >/dev/null 2>&1; then
      echo "worktree_orphan|||0|0|0"; return
    fi
  fi

  # Un directorio sin .git propio nunca debe heredar el repo de un ancestro.
  branch="$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null)" || { echo "not_git|||0|0|0"; return; }
  remote="$(git -C "$d" remote get-url origin 2>/dev/null)"
  dirty="$(git -C "$d" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  upstream="$(git -C "$d" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)"

  if [ -n "$upstream" ]; then
    local counts; counts="$(git -C "$d" rev-list --left-right --count "$upstream...HEAD" 2>/dev/null)"
    behind="$(echo "$counts" | awk '{print $1+0}')"
    ahead="$(echo "$counts"  | awk '{print $2+0}')"
  fi

  # Sin upstream declarado, el HEAD puede estar igualmente publicado en el remoto.
  # Comprobarlo evita marcar como peligroso lo que en realidad ya está a salvo.
  local head_on_remote=0
  if [ -n "$remote" ] && [ -z "$upstream" ]; then
    if [ -n "$(git -C "$d" branch -r --contains HEAD 2>/dev/null | head -1)" ]; then
      head_on_remote=1
    fi
  fi

  # Prioridad: lo más peligroso primero
  if   [ "$dirty" -gt 0 ];                        then state="dirty_uncommitted"
  elif [ "$ahead" -gt 0 ] && [ "$behind" -gt 0 ]; then state="diverged"
  elif [ "$ahead" -gt 0 ];                        then state="dirty_unpushed"
  elif [ -z "$remote" ];                          then state="clean_local_only"
  elif [ -n "$upstream" ];                        then state="clean_synced"
  elif [ "$head_on_remote" -eq 1 ];               then state="clean_synced"
  else                                                 state="unpushed_no_upstream"
  fi

  printf '%s|%s|%s|%s|%s|%s\n' "$state" "$branch" "$remote" "$ahead" "$behind" "$dirty"
}

# --- ¿Es archivable sin intervención? ---
pm_is_safe_to_archive() {
  case "$1" in
    clean_synced) return 0 ;;
    *)            return 1 ;;
  esac
}

# --- Tamaño en KB de un directorio ---
pm_size_kb() { du -sk "$1" 2>/dev/null | awk '{print $1+0}'; }

# --- Fecha del último commit (ISO) o "" ---
pm_last_commit() { git -C "$1" log -1 --format=%cI 2>/dev/null; }

# --- Fecha de modificación más reciente ignorando basura (ISO) ---
# Nota: macOS usa BSD awk (sin strftime) y BSD stat; se convierte con `date -r`.
pm_last_mtime() {
  local epoch
  epoch="$(find "$1" -maxdepth 4 -type f \
             -not -path '*/node_modules/*' -not -path '*/.git/*' \
             -not -path '*/.venv/*' -not -name '.DS_Store' -print0 2>/dev/null \
           | xargs -0 stat -f '%m' 2>/dev/null | sort -rn | head -1)"
  [ -n "$epoch" ] && date -r "$epoch" +%Y-%m-%dT%H:%M:%S 2>/dev/null
}

# --- Compresor disponible ---
pm_compressor() {
  if command -v zstd >/dev/null 2>&1; then echo "zstd"; else echo "gzip"; fi
}

# --- Verificar un git bundle ---
# `git bundle verify` exige estar dentro de un repositorio, aunque el bundle
# sea autocontenido. Se usa un repo temporal vacío como contexto.
pm_verify_bundle() {
  local bundle="$1" tmp rc
  [ -f "$bundle" ] || return 1
  tmp="$(mktemp -d -t pmbundle)" || return 1
  git -C "$tmp" init -q >/dev/null 2>&1
  git -C "$tmp" bundle verify "$bundle" >/dev/null 2>&1; rc=$?
  rm -rf "$tmp"
  return $rc
}

# --- Detección de secretos ---
# Lista los ficheros con pinta de secreto que VIAJARÍAN al archivo, es decir,
# ignorando lo que exclude.txt ya deja fuera. Rutas relativas al proyecto.
# Limitación: detecta por NOMBRE de fichero. Un secreto pegado dentro de un
# fichero de código, o ya commiteado en la historia git, no se detecta aquí.
pm_detect_secrets() {
  local d="$1" pats=() first=1 p
  [ -f "$PM_ROOT/config/secrets.txt" ] || return 0
  while IFS= read -r p; do
    case "$p" in ''|'#'*) continue ;; esac
    if [ $first -eq 1 ]; then pats+=( -name "$p" ); first=0
    else pats+=( -o -name "$p" ); fi
  done < "$PM_ROOT/config/secrets.txt"
  [ ${#pats[@]} -eq 0 ] && return 0
  find "$d" \( -name node_modules -o -name venv -o -name .venv -o -name .git \
             -o -name __pycache__ -o -name .mypy_cache -o -name .pytest_cache \
             -o -name dist -o -name build -o -name target \) -prune \
        -o -type f \( "${pats[@]}" \) -print 2>/dev/null \
    | sed "s|^$d/||"
}
