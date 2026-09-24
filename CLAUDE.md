# CLAUDE.md — Contrato de uso de pm-archive para agentes

Este fichero define cómo debe comportarse un agente (Claude Code u otro) que use esta herramienta.
Léelo entero antes de ejecutar nada.

## Rol y límites

**Qué puedes hacer sin preguntar:**

- `pm-scan`, `pm-status` — solo lectura, nunca modifican un proyecto.
- `pm-archive` / `pm-restore` **sin `--execute`** — son simulaciones (dry-run).

**Qué NO debes hacer por iniciativa propia:**

- Ejecutar `--execute` sobre proyectos del usuario sin que lo haya pedido para ese proyecto.
- Usar `--accept-single-copy`, `--accept-no-git` o `--accept-secrets`. Esos flags reconocen riesgos
  que solo el dueño de los datos puede asumir: presentar el riesgo y esperar decisión.
- Hacer `git commit`, `git push` o `git gc` en los proyectos del usuario para "desbloquear" un
  archivado. Propón los comandos; que los ejecute quien corresponda.
- Borrar originales del disco de trabajo al margen de la herramienta.

## Antes de archivar cualquier cosa

1. `pm-scan` si el índice tiene más de unos días: el estado git envejece.
2. `git -C <proyecto> fetch` — el estado se calcula contra refs locales, que pueden estar viejas.
   La herramienta **no hace fetch** por sí sola.
3. `pm-archive <ruta>` en dry-run y **leer todos los bloqueos**.
4. Preferir `--execute --keep-hot` y verificar el resultado antes de liberar el original.

## Cómo interpretar los estados

| Estado | Significado | Acción del agente |
|---|---|---|
| `clean_synced` | Sincronizado con el remoto | Archivable; puedes proponerlo |
| `dirty_uncommitted` | Cambios sin commitear | Propón commit+push; **no lo hagas tú** |
| `dirty_unpushed` | Commits locales sin publicar | Propón `git push` |
| `diverged` | Local y remoto han divergido | Requiere decisión humana |
| `unpushed_no_upstream` | Rama no publicada en ningún remoto | Propón `git push -u` |
| `clean_local_only` | Limpio pero **sin remoto** | El archivo sería la única copia: avisa |
| `not_git` | No es repositorio | Sin historia ni red de seguridad: avisa |
| `worktree_orphan` | Worktree con el enlace roto | Requiere consolidación manual |

## Worktrees: unidad atómica

Un worktree guarda una ruta **absoluta** al repo padre. Archivar el padre rompe los hijos; archivar
un hijo suelto produce un directorio inservible. La herramienta bloquea ambos casos. Para
consolidar: `git worktree remove <ruta>` si la rama ya está publicada, o `git clone <padre> <destino>`
para convertirlo en repo independiente.

## Secretos

Al archivar viaja el working tree completo, incluidos ficheros no trackeados. La herramienta
detecta secretos **por nombre de fichero** y bloquea hasta reconocerlo. Esa detección es
incompleta por diseño: no ve claves embebidas en código ni commiteadas en la historia git. Si
detectas secretos, **exponlos al usuario y deja que decida**; no añadas `--accept-secrets` tú.

## Verificación antes de borrar

`pm-archive --execute` solo borra el original si pasan cuatro comprobaciones: `zstd -t`, listado
del tar no vacío, checksum SHA-256 y `git bundle verify`. Si alguna falla, escribe
`verified: false` en el manifiesto, sale con código 3 y **no toca el original**. Nunca fuerces un
borrado manual saltándote esto.

## Códigos de salida

| Código | Significado |
|---|---|
| 0 | Correcto (o dry-run completado) |
| 2 | Bloqueado: hay riesgos sin resolver o sin reconocer |
| 3 | Verificación fallida tras empaquetar; el original sigue intacto |

## Instancia

La configuración y los datos viven en `$PM_HOME` (por defecto `~/.config/pm-archive`), no en este
repo. Si modificas rutas o políticas, hazlo en `$PM_HOME/config/pm.conf`.
