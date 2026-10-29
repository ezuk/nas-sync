#!/bin/bash
# Blocks commits that contain personal strings.
# Patterns are read from .private-patterns (one extended regex per line, gitignored).
# Install: ln -s ../../scripts/check-private.sh .git/hooks/pre-commit

set -euo pipefail

root="$(git rev-parse --show-toplevel)"
patterns="$root/.private-patterns"

if [[ ! -f "$patterns" ]]; then
  exit 0
fi

files=$(git diff --cached --name-only --diff-filter=ACMR)
if [[ -z "$files" ]]; then
  exit 0
fi

found=0
while IFS= read -r pattern; do
  [[ -z "$pattern" || "$pattern" == \#* ]] && continue
  while IFS= read -r file; do
    if git show ":$file" 2>/dev/null | grep -Eiq -- "$pattern"; then
      echo "check-private: '$file' matches a private pattern" >&2
      found=1
    fi
  done <<< "$files"
done < "$patterns"

if [[ $found -ne 0 ]]; then
  echo "check-private: commit blocked. Remove the personal details or edit .private-patterns." >&2
  exit 1
fi
