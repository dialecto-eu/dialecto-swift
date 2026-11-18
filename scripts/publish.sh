#!/usr/bin/env bash
# Publishes DialectoLive to the public repository dialecto-eu/dialecto-swift, asking before anything leaves
# this Mac. The repository is a mirror: this folder is the source, and each version is one new commit.
# Run from anywhere: bash sdk/swift-live/scripts/publish.sh <version> [--check]
#   --check   build, test and try it as a consumer in a temporary folder, then stop (changes nothing).
set -euo pipefail

version="${1:-}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: publish.sh <version, such as 0.1.0> [--check]" >&2; exit 2; }
check_only=false
[[ "${2:-}" == "--check" ]] && check_only=true

here="$(cd "$(dirname "$0")/.." && pwd)"
root="$(git -C "$here" rev-parse --show-toplevel)"
sub="${here#"$root"/}"
mirror="dialecto-eu/dialecto-swift"
url="git@github.com:$mirror.git"
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ask() { read -r -p "$1 [y/N] " answer; [[ "$answer" == [yY]* ]]; }

tmp="$(mktemp -d)"
trap 'rm -r "$tmp"' EXIT

step "1. Check the tree"
if [[ -n "$(git -C "$root" status --porcelain -- "$sub")" ]]; then
  echo "$sub has uncommitted changes. Commit them first: the mirror gets exactly what HEAD holds." >&2
  exit 1
fi
echo "Clean."
if git -C "$root" ls-remote --exit-code --tags "$url" "refs/tags/$version" >/dev/null 2>&1; then
  echo "Version $version is already tagged on $mirror. Pick a new version." >&2
  exit 1
fi
echo "Version $version is unused on the mirror."

step "2. Export what the mirror gets"
export_dir="$tmp/dialecto-swift"
mkdir -p "$export_dir"
git -C "$root" archive "HEAD:$sub" | tar -x -C "$export_dir"
(cd "$export_dir" && find . -type f -not -path './docs/*' | sort | sed 's/^/  /')
echo "  docs/ ($(find "$export_dir/docs" -type f | wc -l | tr -d ' ') screenshots)"

step "3. Build and test the export (a minute or two)"
(cd "$export_dir" && swift build 2>&1 | tail -2 && swift test 2>&1 | tail -3)

step "4. Try it as a consumer"
bash "$export_dir/scripts/consumer-check.sh" "$export_dir"

step "5. Private words"
if grep -rInE '/Users/|handoffs|\bddd\b|dlocal|spec-0' "$export_dir" --exclude-dir=.build --exclude-dir=.git --exclude='*.png' --exclude=publish.sh; then
  echo "The export names something private (above). Fix it, commit, and run this again." >&2
  exit 1
fi
echo "None."

if $check_only; then
  echo; echo "Check passed for $version. Nothing was created or pushed."
  exit 0
fi

step "6. Publish $version"
echo "This pushes $sub as one new commit (no history from this repository) to $mirror as main, and tags"
echo "$version. The repository is public; a pushed tag should never move. It is created if it does not exist."
ask "Publish now?" || { echo "Stopped."; exit 0; }
if ! gh repo view "$mirror" >/dev/null 2>&1; then
  gh repo create "$mirror" --public --description "Show translations merged in GitHub in a shipped Mac or iOS app, without a rebuild or a store review."
fi
parent=()
if previous="$(git -C "$root" ls-remote "$url" refs/heads/main | cut -f1)" && [[ -n "$previous" ]]; then
  git -C "$root" fetch -q "$url" main
  parent=(-p "$previous")
fi
tree="$(git -C "$root" rev-parse "HEAD:$sub")"
commit="$(git -C "$root" commit-tree "$tree" "${parent[@]}" -m "DialectoLive $version")"
git -C "$root" push "$url" "$commit:refs/heads/main" "$commit:refs/tags/$version"
echo "Done: https://github.com/$mirror (tag $version)"
