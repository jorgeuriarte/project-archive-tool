# pm-archive

Archiva y restaura proyectos de desarrollo entre un disco de trabajo ("caliente") y
un disco de archivo ("frío"), **usando el estado de git como condición de seguridad**:
un proyecto con trabajo que solo existe en el disco de trabajo no se archiva.

Pensado para macOS con herramientas estándar (`git`, `tar`, `zstd`, `jq`). Sin dependencias exóticas.

## Qué hace

- **Inventaría** los proyectos de ambas zonas en un `index.json` consultable, detectando repos,
  worktrees, submódulos y directorios sin git, a cualquier profundidad.
- **Clasifica** el estado de cada uno: sincronizado, con cambios sin commitear, con commits sin
  pushear, divergente, sin remoto, worktree huérfano.
- **Archiva** produciendo un `.tar.zst` + `.sha256` + `git bundle` + `manifest.json`, verificando
  las cuatro cosas antes de borrar nada del disco de trabajo.
- **Restaura** desde el tarball (árbol completo) o desde el bundle (solo historia git limpia).

## Por qué tar+zstd y no restic

Un archivo frío se abre años después, con prisa y sin contexto. Un `.tar.zst` se abre con
herramientas que estarán ahí siempre; un repositorio restic necesita restic y una contraseña que,
si se pierde, cuesta el proyecto entero. Se renuncia a la deduplicación a cambio de que el formato
sobreviva a las herramientas.

El `git bundle` que acompaña a cada archivo es autocontenido: `git clone proyecto.bundle destino`
reconstruye el repositorio aunque el tarball se pierda.

## Política de seguridad

**Un proyecto con trabajo que solo existe en caliente no se archiva.** No hay `--force`.

| Estado | Resultado | Cómo desbloquear |
|---|---|---|
| `clean_synced` | Archiva | — |
| `dirty_uncommitted` | Bloqueo duro | `git add -A && git commit && git push` |
| `dirty_unpushed` | Bloqueo duro | `git push` |
| `diverged` | Bloqueo duro | `git pull --rebase`, resolver, `git push` |
| `unpushed_no_upstream` | Bloqueo duro | `git push -u origin <rama>` |
| `worktree_orphan` | Bloqueo duro | Consolidar el worktree |
| worktree, o repo con worktrees | Bloqueo duro | Consolidar: son unidad atómica |
| `clean_local_only` (sin remoto) | Riesgo reconocible | `--accept-single-copy` |
| `not_git` | Riesgo reconocible | `--accept-no-git` |
| Secretos detectados | Riesgo reconocible | `--accept-secrets` |

Los tres últimos no pueden "estar al día" porque no hay remoto contra el que estarlo. En vez de
bloquearlos para siempre, exigen un flag explícito que deja constancia de que asumes el riesgo.

## Instalación

```bash
git clone https://github.com/jorgeuriarte/project-archive-tool.git
cd project-archive-tool
./install.sh                    # symlinks en /usr/local/bin, instancia en ~/.config/pm-archive
# o, sin tocar el PATH:
./install.sh --no-link
```

Después edita `~/.config/pm-archive/config/pm.conf` y define al menos:

```bash
HOT_ROOT="/Volumes/TuDiscoRapido/Projects"
ARCHIVE_ROOT="/Volumes/TuDiscoArchivo/ProjectArchive"
```

**Código e instancia están separados**: este repo es el código; tu configuración, tu índice y tus
logs viven en `$PM_HOME` (por defecto `~/.config/pm-archive`) y nunca entran en el repo.

## Uso

```bash
pm-scan                          # inventario -> $PM_HOME/data/index.json
pm-status                        # resumen del parque
pm-status --archivable           # listo para archivar sin riesgos
pm-status --needs-attention      # tiene trabajo sin salvaguardar
pm-status --stale                # sin tocar en N días
pm-status --client ACME          # filtrar por primer nivel de ruta

pm-archive Cliente/proyecto                        # simula (dry-run); no modifica nada
pm-archive Cliente/proyecto --execute --keep-hot   # archiva y conserva el original
pm-archive Cliente/proyecto --execute              # archiva y borra el original si verifica

pm-restore Cliente/proyecto                        # simula
pm-restore Cliente/proyecto --execute              # restaura el árbol completo
pm-restore Cliente/proyecto --execute --from-bundle  # solo la historia git
```

`pm-archive` y `pm-restore` **simulan por defecto**. Sin `--execute` no tocan nada.

## Qué se excluye del archivo

`config/exclude.txt` deja fuera lo regenerable: `node_modules`, `.venv`, `dist`, `build`, `target`,
cachés. Un proyecto restaurado no arranca solo: hay que reinstalar dependencias. A cambio los
archivos son un orden de magnitud más pequeños.

## Secretos

Al archivar viaja el working tree completo, incluidos los ficheros no trackeados por git. Eso
significa que claves y credenciales acabarían en claro en el disco de archivo. `pm-archive` los
detecta por nombre (patrones en `config/secrets.txt`), los lista y bloquea hasta que añadas
`--accept-secrets`. Quedan registrados en `secrets_in_archive` del manifiesto.

**Limitación:** la detección es por nombre de fichero. No ve una clave pegada dentro de un `.py`,
ni una ya commiteada en la historia git.

## Recuperación sin estas herramientas

```bash
zstd -dc proyecto.tar.zst | tar -tf - | less     # ver contenido
mkdir -p dest && zstd -dc proyecto.tar.zst | tar -xf - -C dest
git clone proyecto.bundle dest                   # reconstruir el repo
shasum -a 256 -c proyecto.tar.zst.sha256
```

## Estado

En uso real, pero con poco kilometraje: validado sobre un parque de ~180 proyectos y un puñado de
archivados verificados con restauración y comparación contra el original. Revisa siempre el
dry-run antes de usar `--execute`.
