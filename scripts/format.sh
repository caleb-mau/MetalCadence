#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" != "" && "${1:-}" != "--check" ]]; then
    echo "Usage: $0 [--check]" >&2
    exit 2
fi
if ! xcrun --find clang-format >/dev/null 2>&1; then
    echo "clang-format is required. Install Xcode command line tools." >&2
    exit 1
fi
count=0
while IFS= read -r -d '' path; do
    if [[ "${1:-}" == "--check" ]]; then
        if ! xcrun clang-format --dry-run --Werror "$path"; then
            echo "Unformatted Objective-C/C file: $path" >&2
            exit 1
        fi
    else
        xcrun clang-format -i "$path"
    fi
    count=$((count+1))
done < <(find Audit Demo Sources Tests Tools -type f \( -name '*.m' -o -name '*.h' \) -print0)
echo "clang-format ${1:---write} passed for $count files"
