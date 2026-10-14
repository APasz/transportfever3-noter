#!/usr/bin/env bash
set -euo pipefail

mod_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -gt 1 ]]; then
	printf 'Usage: tools/validate.sh [TpF3-install-directory]\n' >&2
	exit 2
fi

if [[ $# -eq 1 ]]; then
	exec python3 -B "${mod_root}/tools/check.py" --game-dir "$1"
fi
exec python3 -B "${mod_root}/tools/check.py"
