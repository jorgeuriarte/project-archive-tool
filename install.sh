#!/bin/bash
# ─────────────────────────────────────────────────────────────
# install.sh — Instala pm-archive en este equipo.
#
# Separa CÓDIGO (este repo) de INSTANCIA (tu configuración y tus datos):
#   código    → donde esté clonado el repo
#   instancia → $PM_HOME (por defecto ~/.config/pm-archive)
#
# Uso:
#   ./install.sh                      # instala y crea la instancia por defecto
#   ./install.sh --prefix ~/bin       # dónde poner los symlinks (por defecto /usr/local/bin)
#   ./install.sh --home /ruta/inst    # dónde vive la instancia
#   ./install.sh --no-link            # solo crea la instancia, sin tocar el PATH
# ─────────────────────────────────────────────────────────────
set -euo pipefail
CODE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PREFIX="/usr/local/bin"
INST="${PM_HOME:-$HOME/.config/pm-archive}"
DO_LINK=1

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)  PREFIX="$2"; shift ;;
    --home)    INST="$2"; shift ;;
    --no-link) DO_LINK=0 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "Opción desconocida: $1" >&2; exit 1 ;;
  esac
  shift
done

echo "código:     $CODE_ROOT"
echo "instancia:  $INST"

# --- Dependencias ---
MISSING=()
for t in git jq tar zstd shasum; do command -v "$t" >/dev/null 2>&1 || MISSING+=("$t"); done
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "[x] Faltan herramientas: ${MISSING[*]}" >&2
  echo "    macOS: brew install ${MISSING[*]}" >&2
  exit 1
fi
echo "[v] Dependencias presentes"

# --- Instancia ---
mkdir -p "$INST"/{config,data/snapshots,logs}
if [ -f "$INST/config/pm.conf" ]; then
  echo "[i] config/pm.conf ya existe, no se toca"
else
  sed "s|^PM_HOME=.*|PM_HOME=\"$INST\"|" "$CODE_ROOT/config/pm.conf.example" > "$INST/config/pm.conf"
  echo "[v] Creado $INST/config/pm.conf  — EDÍTALO: define HOT_ROOT y ARCHIVE_ROOT"
fi
for f in exclude.txt secrets.txt; do
  [ -f "$INST/config/$f" ] || { cp "$CODE_ROOT/config/$f" "$INST/config/$f"; echo "[v] Creado $INST/config/$f"; }
done

# --- Puntero a la instancia ---
# Los scripts buscan la instancia en ~/.config/pm-archive cuando no hay $PM_HOME.
# Si la instancia está en otro sitio, se deja ahí un symlink para que la encuentren.
DEFAULT_HOME="$HOME/.config/pm-archive"
if [ "$INST" != "$DEFAULT_HOME" ]; then
  if [ -e "$DEFAULT_HOME" ] && [ ! -L "$DEFAULT_HOME" ]; then
    echo "[!] $DEFAULT_HOME existe y no es un enlace: exporta PM_HOME=\"$INST\" a mano"
  else
    mkdir -p "$(dirname "$DEFAULT_HOME")"
    ln -sfn "$INST" "$DEFAULT_HOME"
    echo "[v] $DEFAULT_HOME -> $INST"
  fi
fi

# --- PATH ---
if [ "$DO_LINK" -eq 1 ]; then
  if [ -w "$PREFIX" ]; then
    for s in "$CODE_ROOT"/bin/pm-*.sh; do
      n="$(basename "$s" .sh)"
      [ "$n" = "pm-lib" ] && continue   # es una librería, no un comando
      ln -sf "$s" "$PREFIX/$n"
    done
    echo "[v] Symlinks en $PREFIX: pm-scan, pm-status, pm-archive, pm-restore"
  else
    echo "[!] $PREFIX no es escribible. Opciones:"
    echo "    sudo ./install.sh              # instalar en /usr/local/bin"
    echo "    ./install.sh --prefix ~/bin    # instalar en tu \$HOME"
  fi
fi

cat <<TXT

Siguiente paso:
  1. Edita $INST/config/pm.conf  (HOT_ROOT y ARCHIVE_ROOT)
  2. pm-scan          # inventario inicial
  3. pm-status        # informe

Si los binarios no están en el PATH, invócalos por ruta:
  $CODE_ROOT/bin/pm-scan.sh
TXT
