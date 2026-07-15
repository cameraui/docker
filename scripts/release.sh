#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
  cat <<EOF
Usage: scripts/release.sh <patch|minor|major|revision|version> [--yes] [--skip-checks]

The version is the camera.ui launcher version the image ships (leading "v"
optional). The package.json version tracks the last released image.

"revision" re-releases the current launcher with docker-only changes
(2.0.1 -> 2.0.1-1 -> 2.0.1-2); the workflow still installs launcher 2.0.1
but tags the image 2.0.1-1.

Examples:
  scripts/release.sh patch        # 2.0.0 -> 2.0.1
  scripts/release.sh v2.0.1
  scripts/release.sh revision     # 2.0.1 -> 2.0.1-1 (docker-only change)

Pushes a tag v<version>; the build workflow then builds all flavors with the
pinned launcher and pushes them to GHCR (versioned tags + latest/flavor tags).

Options:
  --yes, -y       Push without the confirmation prompt.
  --skip-checks   Skip verifying that the launcher version exists on npm.
EOF
  exit 1
}

SPEC="${1:-}"
YES=false
SKIP_CHECKS=false
for arg in "${@:2}"; do
  case "$arg" in
    --yes | -y) YES=true ;;
    --skip-checks) SKIP_CHECKS=true ;;
    *) echo "Unknown option: $arg"; usage ;;
  esac
done

[ -z "$SPEC" ] && usage

cd "$ROOT"

if [ -n "$(git status --porcelain)" ]; then
  echo -e "${RED}Working tree not clean - commit or stash first.${NC}"
  exit 1
fi
branch="$(git rev-parse --abbrev-ref HEAD)"
if [ "$branch" != "main" ]; then
  echo -e "${RED}Not on main (on '$branch').${NC}"
  exit 1
fi
git fetch -q origin main || true
if [ -n "$(git rev-list HEAD..origin/main 2>/dev/null)" ]; then
  echo -e "${RED}Local main is behind origin/main - pull first.${NC}"
  exit 1
fi

cur="$(node -p "require('./package.json').version")"

NEW="$(node -e "
  const cur = '$cur';
  const spec = '$SPEC'.replace(/^v/, '');
  const m = cur.match(/^(\d+)\.(\d+)\.(\d+)(?:-(\d+))?\$/);
  if (!m) throw new Error('current version unparseable: ' + cur);
  const [, ma, mi, pa, rev] = m;
  switch (spec) {
    case 'patch': console.log(ma + '.' + mi + '.' + (+pa + 1)); break;
    case 'minor': console.log(ma + '.' + (+mi + 1) + '.0'); break;
    case 'major': console.log((+ma + 1) + '.0.0'); break;
    case 'revision': console.log(ma + '.' + mi + '.' + pa + '-' + (rev ? +rev + 1 : 1)); break;
    default: console.log(spec);
  }
")"

# X.Y.Z, or X.Y.Z-N for a docker-only revision of the same launcher
if ! echo "$NEW" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?$'; then
  echo -e "${RED}Invalid version '$NEW' (expected X.Y.Z or X.Y.Z-N).${NC}"
  exit 1
fi

LAUNCHER="$(echo "$NEW" | sed -E 's/-[0-9]+$//')"

TAG="v$NEW"
if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo -e "${RED}Tag $TAG already exists.${NC}"
  exit 1
fi

echo -e "${CYAN}Releasing image $cur -> $NEW (launcher camera.ui@$LAUNCHER, tag $TAG)${NC}"

if [ "$SKIP_CHECKS" = false ]; then
  echo -e "${YELLOW}Pre-flight: verifying camera.ui@$LAUNCHER exists on npm...${NC}"
  if ! npm view "camera.ui@$LAUNCHER" version >/dev/null 2>&1; then
    echo -e "${RED}camera.ui@$LAUNCHER not found on npm. Publish the launcher first, or use --skip-checks.${NC}"
    exit 1
  fi
  echo -e "${GREEN}Launcher found on npm.${NC}"
fi

node -e "
  const f = './package.json';
  const p = require(f);
  p.version = '$NEW';
  require('fs').writeFileSync(f, JSON.stringify(p, null, 2) + '\n');
"

git add package.json
git commit -q -m "release: v$NEW"
echo -e "${GREEN}Committed version bump.${NC}"

git tag "$TAG"
echo -e "${GREEN}Created tag $TAG.${NC}"

if [ "$YES" = false ]; then
  printf "Push main + %s and trigger the image build? [y/N] " "$TAG"
  read -r ans
  case "$ans" in
    y | Y | yes) ;;
    *)
      git tag -d "$TAG" >/dev/null
      git reset -q --hard HEAD~1
      echo "Aborted - tag and bump commit were undone locally."
      exit 0
      ;;
  esac
fi

git push -q origin main
git push -q origin "$TAG"
echo -e "${GREEN}Pushed. Watch the build workflow under the repo's Actions tab.${NC}"
