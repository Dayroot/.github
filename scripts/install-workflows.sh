#!/usr/bin/env bash
#
# Distribuye los stubs de templates/ a otros repos de la cuenta usando la API
# de GitHub (sin clonar nada).
#
#   ./scripts/install-workflows.sh --list               # ver repos candidatos
#   ./scripts/install-workflows.sh --dry-run repo-a     # simular, no escribe
#   ./scripts/install-workflows.sh repo-a repo-b        # commit directo a main
#   ./scripts/install-workflows.sh --pr repo-a          # via PR en vez de commit
#   ./scripts/install-workflows.sh --all                # todos los candidatos
#   ./scripts/install-workflows.sh --secrets-only --all # solo crear el secret
#
# Con CLAUDE_CODE_OAUTH_TOKEN exportado, tambien crea el secret en cada repo:
#   export CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-..."
#
# Requiere: gh autenticado con scope `workflow` (gh auth refresh -s workflow).
# Es idempotente: si el archivo ya esta igual, no lo toca.

set -euo pipefail

OWNER="${OWNER:-Dayroot}"
DRY_RUN=false
VIA_PR=false
SECRETS_ONLY=false
REPOS=()

# stub local  ->  ruta destino en el repo consumidor
declare -A FILES=(
  ["templates/claude-code-review.yml"]=".github/workflows/claude-code-review.yml"
  ["templates/claude-mention.yml"]=".github/workflows/claude.yml"
)

cd "$(dirname "$0")/.."

log()  { printf '%s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }

list_candidates() {
  # Excluye forks y archivados: en los forks Actions viene deshabilitado y los
  # archivados son de solo lectura.
  gh repo list "$OWNER" --limit 500 --no-archived --source \
    --json name,defaultBranchRef \
    --jq '.[] | select(.name != ".github") | select(.defaultBranchRef != null) | .name'
}

# Sube un archivo si cambio. Devuelve 0 si escribio, 1 si ya estaba igual.
put_file() {
  local repo="$1" path="$2" src="$3" branch="$4"
  local new_b64 cur_b64 sha url="repos/$OWNER/$repo/contents/$path?ref=$branch"

  new_b64=$(base64 -w0 < "$src")

  # OJO: ante un 404, `gh api` imprime el JSON del error en STDOUT y sale con
  # codigo != 0. Un `|| true` DENTRO del $() se traga el fallo pero deja ese
  # JSON dentro de la variable, y el script cree que el archivo ya existe.
  # Por eso el `|| var=""` va FUERA del $(): limpia la variable si fallo.
  cur_b64=$(gh api "$url" --jq '.content' 2>/dev/null | tr -d '\n') || cur_b64=""
  sha=$(gh api "$url" --jq '.sha' 2>/dev/null) || sha=""

  if [ -n "$cur_b64" ] && [ "$cur_b64" = "$new_b64" ]; then
    log "  = $path (sin cambios)"
    return 1
  fi

  if $DRY_RUN; then
    if [ -n "$sha" ]; then log "  ~ $path (se ACTUALIZARIA)"; else log "  + $path (se CREARIA)"; fi
    return 0
  fi

  local args=(-X PUT "repos/$OWNER/$repo/contents/$path"
              -f message="ci: add Claude Code workflow from $OWNER/.github"
              -f content="$new_b64"
              -f branch="$branch")
  [ -n "$sha" ] && args+=(-f sha="$sha")

  gh api "${args[@]}" --jq '"  > " + .commit.html_url'
}

set_secret() {
  local repo="$1"
  [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && return 0
  if $DRY_RUN; then
    log "  + secret CLAUDE_CODE_OAUTH_TOKEN (se CREARIA)"
  else
    printf '%s' "$CLAUDE_CODE_OAUTH_TOKEN" \
      | gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo "$OWNER/$repo" --body -
    log "  > secret CLAUDE_CODE_OAUTH_TOKEN listo"
  fi
}

install_repo() {
  local repo="$1" base branch wrote=false src

  base=$(gh api "repos/$OWNER/$repo" --jq '.default_branch' 2>/dev/null) || {
    warn "$repo: no accesible, se omite"; return 0; }

  log ""
  log "== $OWNER/$repo (rama base: $base)"

  branch="$base"
  if $VIA_PR && ! $DRY_RUN; then
    branch="chore/claude-workflows"
    local base_sha
    base_sha=$(gh api "repos/$OWNER/$repo/git/ref/heads/$base" --jq '.object.sha')
    gh api -X POST "repos/$OWNER/$repo/git/refs" \
      -f ref="refs/heads/$branch" -f sha="$base_sha" >/dev/null 2>&1 \
      || log "  (la rama $branch ya existia)"
  fi

  if ! $SECRETS_ONLY; then
    for src in "${!FILES[@]}"; do
      if put_file "$repo" "${FILES[$src]}" "$src" "$branch"; then wrote=true; fi
    done
  fi

  set_secret "$repo"

  if $VIA_PR && ! $DRY_RUN && $wrote; then
    gh pr create --repo "$OWNER/$repo" --base "$base" --head "$branch" \
      --title "ci: agregar workflows de Claude Code" \
      --body "Stubs que apuntan a \`$OWNER/.github@v1\`.

Ojo: \`claude.yml\` solo responde a \`@claude\` una vez mergeado a \`$base\`.
Los eventos \`issue_comment\` e \`issues\` unicamente ejecutan workflows que
esten en la rama por defecto." 2>/dev/null || log "  (el PR ya existia)"
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)      DRY_RUN=true ;;
    --secrets-only) SECRETS_ONLY=true ;;
    --pr)      VIA_PR=true ;;
    --list)    list_candidates; exit 0 ;;
    --all)     mapfile -t REPOS < <(list_candidates) ;;
    -*)        echo "opcion desconocida: $1" >&2; exit 1 ;;
    *)         REPOS+=("$1") ;;
  esac
  shift
done

if [ ${#REPOS[@]} -eq 0 ]; then
  echo "uso: $0 [--dry-run] [--pr] <repo>... | --all | --list" >&2
  exit 1
fi

$DRY_RUN && log "*** DRY RUN: no se escribe nada ***"
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  if $SECRETS_ONLY; then
    echo "error: --secrets-only necesita CLAUDE_CODE_OAUTH_TOKEN exportado." >&2
    echo "       read -rsp 'Token: ' CLAUDE_CODE_OAUTH_TOKEN; export CLAUDE_CODE_OAUTH_TOKEN" >&2
    exit 1
  fi
  warn "CLAUDE_CODE_OAUTH_TOKEN no esta exportado: se omite la creacion del secret"
fi

for repo in "${REPOS[@]}"; do install_repo "$repo"; done

log ""
log "Listo. ${#REPOS[@]} repo(s) procesado(s)."
