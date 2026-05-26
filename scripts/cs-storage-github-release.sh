#!/bin/sh
set -eu

OWNER=${OWNER:-Loongel}
REPO=${REPO:-cloud-shared-storage}
VISIBILITY=${VISIBILITY:-public}
VERSION=${VERSION:-0.1.10}
DEB=${DEB:-dist/cs-storage_${VERSION}_amd64.deb}
DEB_SET=${DEB_SET:-0}
REMOTE=${REMOTE:-origin}
BRANCH=${BRANCH:-main}

usage() {
  cat <<'EOF'
Usage: scripts/cs-storage-github-release.sh [options]

Create/push the GitHub repository and publish the release .deb.

Options:
  --owner OWNER           GitHub owner/org, default Loongel.
  --repo NAME             Repository name, default cloud-shared-storage.
  --visibility private|public, default public.
  --version VERSION       Release version, default 0.1.10.
  --deb PATH              Release asset path.
  --branch NAME           Branch to push, default main.

Prerequisites:
  gh auth login -h github.com
  git commit created locally

The script does not print or read project secrets.
EOF
}

while test "$#" -gt 0; do
  case "$1" in
    --owner) shift; OWNER=$1 ;;
    --repo) shift; REPO=$1 ;;
    --visibility) shift; VISIBILITY=$1 ;;
    --version) shift; VERSION=$1 ;;
    --deb) shift; DEB=$1; DEB_SET=1 ;;
    --branch) shift; BRANCH=$1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

case "$VISIBILITY" in
  private|public) ;;
  *) echo "invalid visibility: $VISIBILITY" >&2; exit 1 ;;
esac

if test "$DEB_SET" != "1"; then
  DEB="dist/cs-storage_${VERSION}_amd64.deb"
fi

command -v gh >/dev/null 2>&1 || { echo "missing gh" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "missing git" >&2; exit 1; }
test -s "$DEB" || { echo "missing release asset: $DEB" >&2; exit 1; }

gh auth status -h github.com >/dev/null

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "not inside a git repository; run git init and commit first" >&2
  exit 1
fi

if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
  if gh repo view "$OWNER/$REPO" >/dev/null 2>&1; then
    git remote add "$REMOTE" "git@github.com:$OWNER/$REPO.git"
  else
    gh repo create "$OWNER/$REPO" "--$VISIBILITY" --source . --remote "$REMOTE"
  fi
fi

git branch -M "$BRANCH"
git push -u "$REMOTE" "$BRANCH"

tag="v$VERSION"
if ! git rev-parse "$tag" >/dev/null 2>&1; then
  git tag "$tag"
fi
git push "$REMOTE" "$tag"

if gh release view "$tag" --repo "$OWNER/$REPO" >/dev/null 2>&1; then
  gh release upload "$tag" "$DEB" --repo "$OWNER/$REPO" --clobber
else
  gh release create "$tag" "$DEB" \
    --repo "$OWNER/$REPO" \
    --title "CS-Storage $tag" \
    --notes "Host systemd CS-Storage release package. Install with scripts/cs-storage-systemd-node-install.sh --deb-url <asset-url>."
fi

echo "CS_STORAGE_GITHUB_RELEASE_OK repo=$OWNER/$REPO tag=$tag asset=$DEB"
