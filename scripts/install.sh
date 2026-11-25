#!/bin/zsh
# Builds SoundSystem and installs it to /Applications.
set -euo pipefail
cd "${0:A:h}/.."
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT

xcodebuild -project SoundSystem.xcodeproj -scheme SoundSystem -configuration Release \
    -derivedDataPath "$build" -quiet build

osascript -e 'if application id "local.SoundSystem" is running then tell application id "local.SoundSystem" to quit' >/dev/null 2>&1 || true
sleep 1
rm -rf /Applications/SoundSystem.app
ditto "$build/Build/Products/Release/SoundSystem.app" /Applications/SoundSystem.app
# macOS ties the audio permission to the exact build, so an older grant shows as on but no longer
# works. Clear it (for this app only) so macOS asks again the first time a volume is changed.
tccutil reset AudioCapture local.SoundSystem >/dev/null
open -g /Applications/SoundSystem.app
echo "Installed. Look for the sliders icon in the menu bar."
