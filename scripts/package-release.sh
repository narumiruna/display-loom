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
team_id="${DEVELOPMENT_TEAM:-A4YQL6FFTK}"
notary_profile="${NOTARY_PROFILE:-display-loom-notary}"
root="$(cd "$(dirname "$0")/.." && pwd)"
release_dir="$root/.release"
archive_path="$release_dir/DisplayLoom.xcarchive"
export_path="$release_dir/export"
app_path="$export_path/Display Loom.app"
artifact_name="Display-Loom-${version}.zip"
artifact_path="$release_dir/$artifact_name"
submission_path="$release_dir/notarization-submission.zip"
export_options="$release_dir/ExportOptions.plist"
notary_result="$release_dir/notarization.json"
executable_path="$app_path/Contents/MacOS/Display Loom"

cd "$root"

for command in git security xcodebuild xcrun codesign spctl ditto lipo shasum plutil; do
  command -v "$command" >/dev/null || fail "required command not found: $command"
done

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must use MAJOR.MINOR.PATCH format"
[[ "$(git branch --show-current)" == "main" ]] || fail "release artifacts must be built from main"
[[ -z "$(git status --porcelain)" ]] || fail "working tree must be clean"
[[ "$(git rev-parse HEAD)" == "$(git rev-parse refs/remotes/origin/main)" ]] || fail "main must match origin/main"

project_version="$(awk -F'"' '/MARKETING_VERSION:/ { print $2; exit }' project.yml)"
build_version="$(awk -F'"' '/CURRENT_PROJECT_VERSION:/ { print $2; exit }' project.yml)"
[[ "$project_version" == "$version" ]] || fail "project version is $project_version, expected $version"
[[ -n "$build_version" ]] || fail "CURRENT_PROJECT_VERSION is missing from project.yml"

security find-identity -v -p codesigning \
  | grep -F 'Developer ID Application:' >/dev/null \
  || fail "Developer ID Application certificate is not installed"

xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null \
  || fail "notary profile '$notary_profile' is unavailable or invalid"

rm -rf "$release_dir"
mkdir -p "$release_dir"

xcodebuild \
  -project DisplayLoom.xcodeproj \
  -scheme DisplayLoom \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive_path" \
  DEVELOPMENT_TEAM="$team_id" \
  archive

cat >"$export_options" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>export</string>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>$team_id</string>
</dict>
</plist>
EOF

xcodebuild \
  -exportArchive \
  -archivePath "$archive_path" \
  -exportPath "$export_path" \
  -exportOptionsPlist "$export_options"

[[ -d "$app_path" ]] || fail "exported app not found at $app_path"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")" == "$version" ]] \
  || fail "exported app has an unexpected version"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Contents/Info.plist")" == "$build_version" ]] \
  || fail "exported app has an unexpected build number"

architectures="$(lipo -archs "$executable_path")"
[[ " $architectures " == *" arm64 "* && " $architectures " == *" x86_64 "* ]] \
  || fail "exported executable is not universal: $architectures"

codesign --verify --deep --strict --verbose=2 "$app_path"
signature_details="$(codesign --display --verbose=4 "$app_path" 2>&1)"
grep -F 'Authority=Developer ID Application:' <<<"$signature_details" >/dev/null \
  || fail "app is not signed with Developer ID Application"
grep -F "TeamIdentifier=$team_id" <<<"$signature_details" >/dev/null \
  || fail "app signature uses an unexpected team"

ditto -c -k --sequesterRsrc --keepParent "$app_path" "$submission_path"
xcrun notarytool submit "$submission_path" \
  --keychain-profile "$notary_profile" \
  --wait \
  --output-format json \
  >"$notary_result"

notary_status="$(plutil -extract status raw "$notary_result")"
[[ "$notary_status" == "Accepted" ]] || fail "notarization status is $notary_status; see $notary_result"

xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
spctl --assess --type execute --verbose=2 "$app_path"

rm -f "$submission_path" "$artifact_path" "$artifact_path.sha256"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$artifact_path"
(
  cd "$release_dir"
  shasum -a 256 "$artifact_name" >"$artifact_name.sha256"
)

printf 'Created:\n  %s\n  %s\n' "$artifact_path" "$artifact_path.sha256"
