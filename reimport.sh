#!/usr/bin/env bash
set -euo pipefail

PROJECT_PATH="$(realpath "${1:?Usage: $0 <project_path> [godot_executable]}")"

if [[ -n "${2:-}" ]]; then
    GODOT_BIN="$2"
elif command -v godot4 &>/dev/null; then
    GODOT_BIN="godot4"
elif command -v godot &>/dev/null; then
    GODOT_BIN="godot"
else
    echo "Error: Could not find a Godot executable in PATH." >&2
    exit 1
fi

if [[ ! -d "$PROJECT_PATH" ]]; then
    echo "Error: Project directory not found: $PROJECT_PATH" >&2
    exit 1
fi

if [[ ! -f "$PROJECT_PATH/project.godot" ]]; then
    echo "Error: No project.godot found in: $PROJECT_PATH" >&2
    exit 1
fi

rm -rf "$PROJECT_PATH/.godot"

"$GODOT_BIN" \
    --headless \
    --path "$PROJECT_PATH" \
    --import \
    --quit
