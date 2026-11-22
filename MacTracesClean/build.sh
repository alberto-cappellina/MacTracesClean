#!/bin/bash
# Genera, compila e avvia MacTracesClean.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "XcodeGen non trovato. Installa con: brew install xcodegen" >&2
    exit 1
fi

echo "▸ Genero il progetto Xcode…"
xcodegen generate

echo "▸ Compilo (Release)…"
xcodebuild -project MacTracesClean.xcodeproj -scheme MacTracesClean -configuration Release \
    -derivedDataPath build CODE_SIGNING_ALLOWED=NO build

APP="build/Build/Products/Release/MacTracesClean.app"
if [ -d "$APP" ]; then
    echo "▸ Avvio $APP"
    open "$APP"
else
    echo "Build non trovata in $APP" >&2
    exit 1
fi
