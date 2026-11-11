#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <version>" >&2
  exit 2
}

fail() {
  echo "error: $*" >&2
  exit 1
}

[[ $# -eq 1 ]] || usage

version="$1"
root="$(cd "$(dirname "$0")/.." && pwd)"
release_dir="$root/.release"
build_dir="$release_dir/build"
app_path="$build_dir/Build/Products/Release/Display Loom.app"
staging_dir="$release_dir/dmg-root"
artifact_name="Display-Loom-${version}.dmg"
artifact_path="$release_dir/$artifact_name"
provenance_path="$artifact_path.commit"
executable_path="$app_path/Contents/MacOS/Display Loom"

cd "$root"

for command in git xcodebuild codesign ditto hdiutil lipo shasum plutil ln; do
  command -v "$command" >/dev/null || fail "required command not found: $command"
done

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must use MAJOR.MINOR.PATCH format"
current_branch="$(git branch --show-current)"
[[ -z "$current_branch" || "$current_branch" == "main" ]] || fail "release artifacts must be built from main or a detached release commit"
source_commit="$(git rev-parse HEAD)"
[[ -z "$(git status --porcelain)" ]] || fail "working tree must be clean"
git merge-base --is-ancestor "$source_commit" refs/remotes/origin/main \
  || fail "release commit must be on origin/main"

project_version="$(awk '$1 == "MARKETING_VERSION" && $2 == "=" { print $3; exit }' Configuration/Version.xcconfig)"
build_version="$(awk -F'"' '/CURRENT_PROJECT_VERSION:/ { print $2; exit }' project.yml)"
[[ "$project_version" == "$version" ]] || fail "project version is $project_version, expected $version"
[[ -n "$build_version" ]] || fail "CURRENT_PROJECT_VERSION is missing from project.yml"

rm -rf "$release_dir"
mkdir -p "$release_dir"

xcodebuild \
  -project DisplayLoom.xcodeproj \
  -scheme DisplayLoom \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$build_dir" \
  'ARCHS=arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

[[ -d "$app_path" ]] || fail "built app not found: $app_path"
[[ "$(plutil -extract CFBundleShortVersionString raw "$app_path/Contents/Info.plist")" == "$version" ]] \
  || fail "built app has an unexpected version"
[[ "$(plutil -extract CFBundleVersion raw "$app_path/Contents/Info.plist")" == "$build_version" ]] \
  || fail "built app has an unexpected build number"

architectures="$(lipo -archs "$executable_path")"
[[ " $architectures " == *" arm64 "* && " $architectures " == *" x86_64 "* ]] \
  || fail "built executable is not universal: $architectures"

# Ad-hoc signing preserves sandbox entitlements, not Developer ID trust or notarization.
codesign --force --sign - --timestamp=none --options runtime \
  --entitlements "$root/DisplayLoom/Resources/DisplayLoom.entitlements" \
  "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"

mkdir -p "$staging_dir"
ditto "$app_path" "$staging_dir/Display Loom.app"
ln -s /Applications "$staging_dir/Applications"
hdiutil create -quiet -volname 'Display Loom' -srcfolder "$staging_dir" \
  -ov -format UDZO "$artifact_path" </dev/null
hdiutil verify "$artifact_path" </dev/null
rm -rf "$staging_dir"
(
  cd "$release_dir"
  shasum -a 256 "$artifact_name" >"$artifact_name.sha256"
)

[[ "$(git rev-parse HEAD)" == "$source_commit" ]] || fail "HEAD changed during packaging; rebuild the release"
[[ -z "$(git status --porcelain)" ]] || fail "working tree changed during packaging; rebuild the release"
printf '%s\n' "$source_commit" >"$provenance_path"

printf 'Created:\n  %s\n  %s\n  %s\n' "$artifact_path" "$artifact_path.sha256" "$provenance_path"
