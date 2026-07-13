#!/usr/bin/env bash
set -euo pipefail

find_python() {
  local candidates=(".venv/Scripts/python.exe" ".venv/bin/python" "python3" "python" "python.exe")
  local candidate resolved

  for candidate in "${candidates[@]}"; do
    if [[ "$candidate" == */* ]]; then
      [[ -x "$candidate" ]] || continue
      printf '%s\n' "$candidate"
      return 0
    else
      resolved="$(command -v "$candidate" 2>/dev/null || true)"
      [[ -n "$resolved" ]] || continue
      printf '%s\n' "$resolved"
      return 0
    fi
  done

  echo "python executable not found" >&2
  return 127
}

PYTHON="$(find_python)"

"${PYTHON}" -m pytest -q
