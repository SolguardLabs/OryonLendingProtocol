#!/usr/bin/env bash
set -euo pipefail

find_python_with_pip() {
  local candidates=(".venv/Scripts/python.exe" ".venv/bin/python" "python3" "python" "python.exe")
  local candidate resolved

  for candidate in "${candidates[@]}"; do
    if [[ "$candidate" == */* ]]; then
      [[ -x "$candidate" ]] || continue
      resolved="$candidate"
    else
      resolved="$(command -v "$candidate" 2>/dev/null || true)"
      [[ -n "$resolved" ]] || continue
    fi

    if "$resolved" -m pip --version >/dev/null 2>&1; then
      printf '%s\n' "$resolved"
      return 0
    fi
  done

  echo "python executable with pip not found" >&2
  return 127
}

PYTHON="$(find_python_with_pip)"

"${PYTHON}" -m pip install -e ".[dev]"
"${PYTHON}" -m compileall -q client scripts tests
"${PYTHON}" scripts/compile_contracts.py
"${PYTHON}" scripts/check_loc.py
"${PYTHON}" -m pytest -q
