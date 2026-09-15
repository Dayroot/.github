# Workflows compartidos de Claude Code

Repo central (`Dayroot/.github`) con los workflows de GitHub Actions que reuso
en mis demas repositorios.

## Estructura

| Ruta | Que es |
|---|---|
| `.github/workflows/claude-code-review.yml` | Workflow **reutilizable** (`workflow_call`). Review automatico de PRs. |
| `.github/workflows/claude-mention.yml` | Workflow **reutilizable** (`workflow_call`). Responde a `@claude`. |
| `templates/*.yml` | Stubs de 6 lineas para copiar en cada repo. Estos si se ejecutan. |

La logica vive aca una sola vez. Cada repo solo copia el stub correspondiente.
Para actualizar los 20 repos a la vez, edito el workflow reutilizable y muevo
el tag `v1`.

## Instalar en un repo

1. Copiar el stub de `templates/` a `.github/workflows/` del repo destino.
   Copiarlo **completo, incluido el bloque `permissions:`** (ver abajo).
2. Agregar el secret `CLAUDE_CODE_OAUTH_TOKEN`
   (Settings -> Secrets and variables -> Actions -> New repository secret).
   El token se genera con `claude setup-token`.
3. Instalar la [GitHub App de Claude](https://github.com/apps/claude) en el repo.
4. **Mergear a `main`.** `claude.yml` no funciona desde una rama de feature.

> No hay secrets a nivel de cuenta personal en GitHub Actions: el secret hay que
> agregarlo repo por repo. `secrets: inherit` esta documentado para repos de la
> misma organizacion, por eso los stubs pasan el secret de forma explicita.

## Versionado

Los stubs apuntan a `@v1`. Para publicar cambios:

```bash
git tag -fa v1 -m "v1" && git push -f origin v1
```

Si algo se rompe, los repos consumidores siguen con el `v1` anterior hasta que
muevas el tag. Nunca apuntes los stubs a `@main`.

## Los dos workflows: en que se diferencian

Son complementarios, no alternativos. Conviene tener los dos.

| | `claude-code-review` | `claude-mention` |
|---|---|---|
| Evento | `pull_request` | `issue_comment`, `issues`, `pull_request_review*` |
| Se dispara | Solo, en cada PR | Cuando escribes `@claude` |
| Modo del action | Agent mode (`prompt` fijo) | Tag mode (obedece tu comentario) |
| Alcance | Solo PRs | Issues y PRs |

**GitHub no "detecta" menciones a `@claude`.** No existe tal mecanismo: `@claude`
es texto plano, no un usuario de GitHub. Lo que pasa es que el workflow se
dispara con **cada** comentario que se crea en el repo, y el `if:` del job es
quien revisa si el cuerpo contiene `@claude`. Si no lo contiene, el job se salta
y no consume minutos.

Detalle util: `contains()` en expresiones de GitHub **no distingue
mayusculas**, asi que `@Claude`, `@CLAUDE` y `@claude` funcionan igual.

## Cambios respecto a los workflows originales de Anthropic

**Ambos:**
- Convertidos a `workflow_call` + stubs, para no copiar YAML en cada repo.
- `concurrency` con `cancel-in-progress`: un push nuevo cancela la corrida
  anterior en vez de dejar dos Claudes corriendo sobre el mismo PR.
- `timeout-minutes`: corta corridas colgadas antes de que se coman la cuota.
- `pull-requests: write` / `issues: write` en vez de `read`. Con la GitHub App
  de Claude instalada el `read` alcanza porque el action cambia el token OIDC
  por uno de la app, pero con `write` funciona en los dos escenarios.
- `fetch-depth: 0` por defecto: con `1` no hay historial y cualquier
  `git diff base...HEAD` falla. Configurable por si el repo es enorme.
- Inputs para modelo, args extra y timeouts.

**`claude-code-review`:**
- Salta PRs en borrador y PRs de bots (dependabot/renovate) por defecto.
- Escape hatch: `[skip-review]` en el titulo del PR.
- `track_progress` opcional.

**`claude-mention`:**
- Filtro por `author_association`: por defecto solo `OWNER`, `MEMBER` y
  `COLLABORATOR` pueden invocar a Claude. Sin esto, en un repo publico
  cualquier persona gasta tu cuota comentando `@claude`. El action ademas exige
  permiso de escritura por su cuenta, esto es una segunda barrera mas barata
  (frena antes de levantar el runner).
- `sender.type != 'Bot'`: evita el bucle si Claude se cita a si mismo.
- `contents: write` para que Claude pueda crear ramas y commitear los cambios
  que le pidas.
- `trigger_phrase` configurable.

## Por que los `permissions:` van en el stub

Es la trampa principal de los workflows reutilizables:

> "The `GITHUB_TOKEN` permissions passed from the caller workflow can be only
> downgraded (not elevated) by the called workflow."
> — [docs de GitHub](https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations)

El `permissions:` del workflow reutilizable **no puede ampliar** lo que el stub
le pasa. Si el stub no declara nada, hereda el default del repo — que en la
mayoria de repos es solo lectura — y los `write` del reutilizable se pierden en
silencio: el job corre, Claude analiza, y al intentar comentar falla con 403.

Por eso el bloque esta duplicado a proposito en los dos lados. Al copiar el
stub, no lo borres.

## Nota sobre este repo

Un repo `.github` de **cuenta personal** sirve para archivos de comunidad por
defecto (`CONTRIBUTING.md`, plantillas de issue/PR). Los
[workflow templates](https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations)
que aparecen en la pestaña Actions -> New workflow son **solo para
organizaciones**. Por eso el approach aca es workflows reutilizables + stubs,
que si funcionan entre repos de una cuenta personal siempre que este repo sea
publico.
