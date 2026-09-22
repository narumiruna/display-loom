set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

developer_dir := env_var_or_default("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
derived_data := ".derivedData"
app_path := derived_data / "Build/Products/Debug/Display Loom.app"

# List available recipes.
default:
    @just --list

# Regenerate the Xcode project from project.yml.
generate:
    xcodegen generate

# Build the Debug app without requiring a signing identity.
build:
    DEVELOPER_DIR="{{developer_dir}}" xcodebuild \
      -project DisplayLoom.xcodeproj \
      -scheme DisplayLoom \
      -configuration Debug \
      -derivedDataPath "{{derived_data}}" \
      CODE_SIGNING_ALLOWED=NO \
      build

# Build and launch the menu bar app.
run: build
    open "{{app_path}}"

# Run unit tests without creating a real virtual display.
test:
    DEVELOPER_DIR="{{developer_dir}}" xcodebuild \
      -project DisplayLoom.xcodeproj \
      -scheme DisplayLoom \
      -derivedDataPath "{{derived_data}}" \
      CODE_SIGNING_ALLOWED=NO \
      test

# Run the opt-in test that creates and switches a real virtual display.
test-live:
    DEVELOPER_DIR="{{developer_dir}}" xcodebuild \
      -project DisplayLoom.xcodeproj \
      -scheme DisplayLoom \
      -derivedDataPath "{{derived_data}}" \
      CODE_SIGNING_ALLOWED=NO \
      RUN_VIRTUAL_DISPLAY_TESTS=1 \
      -only-testing:DisplayLoomTests/LiveVirtualDisplayTests/testCreatesAndSwitchesARealVirtualDisplayWhenExplicitlyEnabled \
      test

# Build a universal Release app without requiring a signing identity.
build-release:
    DEVELOPER_DIR="{{developer_dir}}" xcodebuild \
      -project DisplayLoom.xcodeproj \
      -scheme DisplayLoom \
      -configuration Release \
      -derivedDataPath "{{derived_data}}" \
      CODE_SIGNING_ALLOWED=NO \
      build

# Build, sign, notarize, verify, and package a release.
package-release version:
    DEVELOPER_DIR="{{developer_dir}}" ./scripts/package-release.sh "{{version}}"

# Publish a packaged release to GitHub after explicit confirmation.
publish-release version:
    ./scripts/publish-release.sh "{{version}}"

# Remove local Xcode build products and release artifacts.
clean:
    rm -rf "{{derived_data}}" .release
