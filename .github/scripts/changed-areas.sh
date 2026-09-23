#!/usr/bin/env bash
# changed-areas.sh
#
# Decides which of this repo's two apps a push to main changed, so each deploy
# runs only for its own app:
#
#   next=true   when a file the Next image is built from changed. That list is
#               exactly what Dockerfile.next COPYs — package.json,
#               pnpm-lock.yaml, prisma/, tsconfig.json, src/ — plus the files
#               that define how it is built and deployed. Keep it in step with
#               Dockerfile.next.
#
#   rails=true  unless EVERY changed file is Next-only or documentation. A
#               denylist rather than an allowlist on purpose: a path nobody
#               thought to list deploys Rails, which is what every merge did
#               before this existed. The failure to avoid is a Rails change
#               that silently never reaches production.
#
# package.json and pnpm-lock.yaml count for BOTH: the Rails image installs them
# for the Vite frontend its assets:precompile builds.
#
# If the range cannot be diffed (first push, force-push, missing base) both are
# reported changed. An extra deploy of code CI just passed costs a build; a
# missed one ships nothing and says nothing.
#
# Env: BASE_SHA (github.event.before), HEAD_SHA (github.sha). Writes rails= and
# next= to $GITHUB_OUTPUT when it is set, and always prints them.

set -euo pipefail

base="${BASE_SHA:-}"
head="${HEAD_SHA:-HEAD}"

emit() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    { echo "rails=$1"; echo "next=$2"; } >> "$GITHUB_OUTPUT"
  fi
  echo "rails=$1 next=$2"
}

if [[ -z "$base" || "$base" =~ ^0+$ ]] || ! git cat-file -e "${base}^{commit}" 2>/dev/null; then
  echo "Cannot diff against '${base:-<none>}'; treating both apps as changed."
  emit true true
  exit 0
fi

rails=false
next=false

while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  echo "  changed: $file"

  case "$file" in
    src/* | prisma/* | package.json | pnpm-lock.yaml | tsconfig.json | \
    Dockerfile.next | cloudbuild-next.yml | .github/workflows/deploy-next.yml)
      next=true ;;
  esac

  case "$file" in
    src/* | prisma/* | scripts/* | docs/* | *.md | .env.example | \
    tsconfig.json | vitest.config.ts | Dockerfile.next | cloudbuild-next.yml | \
    .github/workflows/ci-next.yml | .github/workflows/deploy-next.yml | .github/scripts/*)
      ;;
    *)
      rails=true ;;
  esac
done < <(git diff --name-only "$base" "$head")

emit "$rails" "$next"
