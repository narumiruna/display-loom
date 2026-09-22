#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: CONFIRM_PUBLISH=v<version> $0 <version>" >&2
  exit 2
}

fail() {
  echo "error: $*" >&2
  exit 1
}

[[ $# -eq 1 ]] || usage

version="$1"
tag="v$version"
root="$(cd "$(dirname "$0")/.." && pwd)"
release_dir="$root/.release"
artifact_name="Display-Loom-${version}.zip"
artifact_path="$release_dir/$artifact_name"
checksum_path="$artifact_path.sha256"
notes_path="$root/docs/releases/$tag.md"

cd "$root"

for command in git gh shasum; do
  command -v "$command" >/dev/null || fail "required command not found: $command"
done

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must use MAJOR.MINOR.PATCH format"
[[ "${CONFIRM_PUBLISH:-}" == "$tag" ]] || fail "set CONFIRM_PUBLISH=$tag to confirm public publication"
[[ "$(git branch --show-current)" == "main" ]] || fail "release must be published from main"
[[ -z "$(git status --porcelain)" ]] || fail "working tree must be clean"

project_version="$(awk -F'"' '/MARKETING_VERSION:/ { print $2; exit }' project.yml)"
[[ "$project_version" == "$version" ]] || fail "project version is $project_version, expected $version"
[[ -f "$artifact_path" ]] || fail "release artifact not found: $artifact_path"
[[ -f "$checksum_path" ]] || fail "checksum not found: $checksum_path"
[[ -f "$notes_path" ]] || fail "release notes not found: $notes_path"

(
  cd "$release_dir"
  shasum -a 256 -c "$artifact_name.sha256"
)

git fetch --quiet origin main --tags
head_commit="$(git rev-parse HEAD)"
[[ "$head_commit" == "$(git rev-parse refs/remotes/origin/main)" ]] || fail "main must match origin/main"

if git rev-parse --quiet --verify "refs/tags/$tag" >/dev/null; then
  fail "local tag already exists: $tag"
fi
if git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
  fail "remote tag already exists: $tag"
fi
if gh release view "$tag" >/dev/null 2>&1; then
  fail "GitHub Release already exists: $tag"
fi

gh release create "$tag" \
  "$artifact_path" \
  "$checksum_path" \
  --draft \
  --target "$head_commit" \
  --title "Display Loom $version" \
  --notes-file "$notes_path"

git fetch --quiet origin "refs/tags/$tag:refs/tags/$tag"
[[ "$(git rev-list -n 1 "$tag")" == "$head_commit" ]] || fail "$tag does not point to the expected commit"

asset_count="$(gh release view "$tag" --json assets --jq '.assets | length')"
[[ "$asset_count" == "2" ]] || fail "draft release has $asset_count assets, expected 2"

gh release edit "$tag" --draft=false --latest

gh release view "$tag" --json url --jq '.url'
