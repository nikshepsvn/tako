#!/usr/bin/env bash
# Every size, radius and color in the UI comes from UI/Design.swift. Raw values elsewhere are how
# an interface drifts into 22 font sizes, so they fail the check.
set -euo pipefail
cd "$(dirname "$0")/.."
pattern='\.system\(size: *[0-9]|cornerRadius: *[0-9]|Color\(red:|srgbRed:|\.font\(\.(caption2?|callout|footnote|body|headline|subheadline|title[23]?)\b'
hits=$(grep -rnE "$pattern" Sources/Tako --include='*.swift' \
  | grep -v '^Sources/Tako/UI/Design.swift:' \
  | grep -v '^Sources/Tako/Ghostty/' \
  | grep -v '// design-exempt' || true)
if [ -n "$hits" ]; then
  echo "Raw design values outside UI/Design.swift (use the tokens):"
  echo "$hits"
  exit 1
fi
echo "design tokens: ok"
