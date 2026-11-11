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
artifact_name="Display-Loom-${version}.dmg"
artifact_path="$release_dir/$artifact_name"
checksum_path="$artifact_path.sha256"
provenance_path="$artifact_path.commit"

cd "$root"

for command in git gh jq shasum cmp mktemp rm awk; do
  command -v "$command" >/dev/null || fail "required command not found: $command"
done

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must use MAJOR.MINOR.PATCH format"
[[ "${CONFIRM_PUBLISH:-}" == "$tag" ]] || fail "set CONFIRM_PUBLISH=$tag to confirm public publication"
current_branch="$(git branch --show-current)"
[[ -z "$current_branch" || "$current_branch" == "main" ]] || fail "release must be published from main"
[[ -z "$(git status --porcelain)" ]] || fail "working tree must be clean"

project_version="$(awk '$1 == "MARKETING_VERSION" && $2 == "=" { print $3; exit }' Configuration/Version.xcconfig)"
[[ "$project_version" == "$version" ]] || fail "project version is $project_version, expected $version"
[[ -f "$artifact_path" ]] || fail "release artifact not found: $artifact_path"
[[ -f "$checksum_path" ]] || fail "checksum not found: $checksum_path"
[[ -f "$provenance_path" ]] || fail "commit provenance not found: $provenance_path; rebuild the release"

head_commit="$(git rev-parse HEAD)"
[[ "$(<"$provenance_path")" == "$head_commit" ]] \
  || fail "release artifact was not packaged from HEAD; rebuild the release"
(
  cd "$release_dir"
  expected_checksum="$(shasum -a 256 "$artifact_name")"
  [[ "$(<"$artifact_name.sha256")" == "$expected_checksum" ]] \
    || fail "checksum verification failed for $artifact_name; restore the original packaged files"
)

git fetch --quiet origin main
[[ "$(git rev-parse HEAD)" == "$head_commit" ]] || fail "HEAD changed during publication; retry from the packaging commit"
[[ -z "$(git status --porcelain)" ]] || fail "working tree changed during publication"
git merge-base --is-ancestor "$head_commit" refs/remotes/origin/main \
  || fail "HEAD must be an ancestor of origin/main"

origin_url="$(git remote get-url origin)" || fail "could not read origin URL"
remote_tag="$(git ls-remote --tags "$origin_url" "refs/tags/$tag" "refs/tags/$tag^{}")" \
  || fail "could not check remote tag: $tag; retry publication"
tag_commit=""
peeled_commit=""
while read -r commit ref; do
  case "$ref" in
    "refs/tags/$tag") tag_commit="$commit" ;;
    "refs/tags/$tag^{}") peeled_commit="$commit" ;;
  esac
done <<<"$remote_tag"
[[ "${peeled_commit:-$tag_commit}" == "$head_commit" ]] \
  || fail "remote tag $tag does not point to HEAD; publish the release for the selected commit first"

repository="$(gh repo view "$origin_url" --json url --jq .url)" \
  || fail "could not identify the GitHub repository for origin"
[[ -n "$repository" ]] || fail "could not identify the GitHub repository for origin"

release_json="$(gh release view "$tag" --repo "$repository" --json isDraft,assets,url)" \
  || fail "could not read GitHub Release $tag; check access and publish the release before retrying"
jq -e '.isDraft == false' <<<"$release_json" >/dev/null \
  || fail "GitHub Release $tag must exist and must not be a draft"

validate_assets() {
  jq -e --arg artifact "$artifact_name" --arg checksum "$artifact_name.sha256" '
    (.assets | type == "array") and
    all(.assets[]; .name == $artifact or .name == $checksum) and
    (([.assets[].name] | unique | length) == (.assets | length))
  ' <<<"$1" >/dev/null \
    || fail "GitHub Release $tag has unexpected or duplicate assets; expected only $artifact_name and $artifact_name.sha256"
}
validate_assets "$release_json"

comparison_dir="$(mktemp -d "$release_dir/publish.XXXXXX")"
trap 'rm -rf "$comparison_dir"' EXIT
missing_assets=()
for asset_path in "$artifact_path" "$checksum_path"; do
  asset_name="${asset_path##*/}"
  if jq -e --arg name "$asset_name" 'any(.assets[]; .name == $name)' <<<"$release_json" >/dev/null; then
    gh release download "$tag" --repo "$repository" --pattern "$asset_name" --dir "$comparison_dir" \
      || fail "could not download existing asset $asset_name; retry publication without replacing assets"
    cmp -s "$asset_path" "$comparison_dir/$asset_name" \
      || fail "existing asset $asset_name differs; retry with the original packaged files, not a rebuild. Published assets must not be replaced"
  else
    missing_assets+=("$asset_path")
  fi
done

[[ "$(git rev-parse HEAD)" == "$head_commit" ]] || fail "HEAD changed during publication; retry from the packaging commit"
[[ -z "$(git status --porcelain)" ]] || fail "working tree changed during publication"
if [[ ${#missing_assets[@]} -gt 0 ]]; then
  gh release upload "$tag" --repo "$repository" "${missing_assets[@]}"
fi

release_json="$(gh release view "$tag" --repo "$repository" --json isDraft,assets,url)" \
  || fail "could not verify GitHub Release $tag; retry publication with the same packaged files"
validate_assets "$release_json"
jq -e '.isDraft == false and (.assets | length == 2)' <<<"$release_json" >/dev/null \
  || fail "GitHub Release $tag must be non-draft with exactly two assets; retry publication with the same packaged files"
jq -r '.url' <<<"$release_json"
