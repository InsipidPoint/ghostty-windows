#!/bin/bash
# Build and package Ghostty for Windows as a portable ZIP.
#
# Usage:
#   ./dist/windows/package.sh              # ReleaseFast, x86_64
#   ./dist/windows/package.sh Debug        # Debug build (Console subsystem)
#
# Output: dist/windows/ghostty-windows-x64.zip

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
OPTIMIZE="${1:-ReleaseFast}"

cd "$REPO_DIR"

echo "Building ghostty (optimize=$OPTIMIZE)..."
zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize="$OPTIMIZE"

if [ ! -f zig-out/bin/ghostty.exe ]; then
    echo "ERROR: Build failed — ghostty.exe not found"
    exit 1
fi

# Get version string
VERSION="$(powershell.exe -Command "& '.\\zig-out\\bin\\ghostty.exe' --version" 2>/dev/null | head -1 | tr -d '\r' | awk '{print $2}')" || true
if [ -z "$VERSION" ]; then
    VERSION="$(git describe --tags --always 2>/dev/null || echo 'dev')"
fi
echo "Version: $VERSION"

# Create staging directory
STAGE_DIR="$REPO_DIR/dist/windows/_stage/ghostty"
rm -rf "$REPO_DIR/dist/windows/_stage"
mkdir -p "$STAGE_DIR"

# Copy exe
cp zig-out/bin/ghostty.exe "$STAGE_DIR/"
echo "  ghostty.exe"

# Copy share resources (themes, shell-integration)
if [ -d zig-out/share/ghostty ]; then
    mkdir -p "$STAGE_DIR/share/ghostty"
    cp -r zig-out/share/ghostty/themes "$STAGE_DIR/share/ghostty/"
    cp -r zig-out/share/ghostty/shell-integration "$STAGE_DIR/share/ghostty/"
    THEME_COUNT=$(ls "$STAGE_DIR/share/ghostty/themes/" 2>/dev/null | wc -l)
    echo "  share/ghostty/themes/ ($THEME_COUNT themes)"
    echo "  share/ghostty/shell-integration/"
fi

# Copy the terminfo source file. resourcesDir() (src/os/resourcesdir.zig)
# uses share/terminfo/ghostty.terminfo as the Windows sentinel; without it,
# theme loading silently fails on fresh extracts. The compiled terminfo
# tree contains symlinks Windows ZIP tools can't handle, so we ship only
# the plain-text source — native Windows apps don't read terminfo anyway,
# and WSL/SSH users get terminfo from the Linux side.
if [ -f zig-out/share/terminfo/ghostty.terminfo ]; then
    mkdir -p "$STAGE_DIR/share/terminfo"
    cp zig-out/share/terminfo/ghostty.terminfo "$STAGE_DIR/share/terminfo/"
    echo "  share/terminfo/ghostty.terminfo (resource sentinel)"
fi

# Create a minimal README
cat > "$STAGE_DIR/README.txt" << READMEEOF
Ghostty for Windows — $VERSION
https://github.com/InsipidPoint/ghostty-windows

QUICK START
  1. Run ghostty.exe
  2. Config file: %LOCALAPPDATA%\\ghostty\\config

KEYBOARD SHORTCUTS
  Ctrl+Shift+T        New tab
  Ctrl+Shift+W        Close tab/pane
  Ctrl+Shift+N        New window
  Ctrl+Shift+P        Command palette
  Ctrl+Shift+O        Split right
  Ctrl+Shift+E        Split down
  Ctrl+Shift+[ / ]    Navigate splits
  Ctrl+Shift+C / V    Copy / Paste
  Ctrl+Shift+F        Find
  Ctrl+Enter          Toggle fullscreen
  Ctrl+= / - / 0      Zoom in / out / reset
  Ctrl+,              Open config file

SHELL INTEGRATION (PowerShell)
  Add to your PowerShell profile:
    . "\$env:LOCALAPPDATA\\ghostty\\share\\ghostty\\shell-integration\\powershell\\ghostty-shell-integration.ps1"

For full documentation: https://ghostty.org/docs
READMEEOF
echo "  README.txt"

# Create ZIP
ZIP_NAME="ghostty-windows-x64-${VERSION}.zip"
ZIP_PATH="$REPO_DIR/dist/windows/$ZIP_NAME"
rm -f "$ZIP_PATH"
cd "$REPO_DIR/dist/windows/_stage"
if command -v zip &>/dev/null; then
    zip -qr "$ZIP_PATH" ghostty/
else
    # PowerShell can't zip from WSL UNC paths. Copy to Windows temp first.
    WIN_TEMP="$(cmd.exe /c "echo %TEMP%" 2>/dev/null | tr -d '\r')"
    WIN_TEMP_WSL="$(wslpath "$WIN_TEMP")"
    rm -rf "$WIN_TEMP_WSL/ghostty-zip-stage"
    mkdir -p "$WIN_TEMP_WSL/ghostty-zip-stage"
    cp -r "$REPO_DIR/dist/windows/_stage/ghostty" "$WIN_TEMP_WSL/ghostty-zip-stage/ghostty"
    powershell.exe -Command "Compress-Archive -Path '${WIN_TEMP}\\ghostty-zip-stage\\ghostty' -DestinationPath '${WIN_TEMP}\\${ZIP_NAME}' -Force" 2>&1 | tr -d '\r'
    cp "$WIN_TEMP_WSL/$ZIP_NAME" "$ZIP_PATH" 2>/dev/null
    rm -rf "$WIN_TEMP_WSL/ghostty-zip-stage" "$WIN_TEMP_WSL/$ZIP_NAME"
fi

# Clean up staging
rm -rf "$REPO_DIR/dist/windows/_stage"

if [ -f "$ZIP_PATH" ]; then
    SIZE=$(du -h "$ZIP_PATH" | cut -f1)
    echo ""
    echo "Package created: dist/windows/$ZIP_NAME ($SIZE)"

    # Also copy to Desktop
    USERPROFILE="$(cmd.exe /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r')"
    if [ -n "$USERPROFILE" ]; then
        DESKTOP="$(wslpath "$USERPROFILE")/Desktop"
        cp "$ZIP_PATH" "$DESKTOP/" 2>/dev/null && echo "Copied to Desktop/$ZIP_NAME"
        cp zig-out/bin/ghostty.exe "$DESKTOP/ghostty.exe" 2>/dev/null && echo "Copied ghostty.exe to Desktop"
    fi
else
    echo "ERROR: Failed to create ZIP"
    exit 1
fi
