#!/usr/bin/env bash
# Checks what can be checked without macOS: every Swift file parses, the design-token rules
# hold, and the pure-logic files (no AppKit) build and pass their tests with a Linux toolchain.
# The real build and full test suite still need Xcode on a Mac.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "· parsing every Swift file"
status=0
while IFS= read -r file; do
  swiftc -parse "$file" || status=1
done < <(find Sources Tests -name '*.swift')
[ "$status" -eq 0 ] || { echo "parse errors"; exit 1; }

echo "· design tokens"
scripts/lint-design.sh || [ "${ALLOW_DESIGN_DEBT:-}" = 1 ]

# Pure Foundation files and the tests that cover them.
LOGIC=(
  Sources/Tako/UI/LayoutTree.swift
  Sources/Tako/Status/Checkpoints.swift
  Sources/Tako/Status/ProjectActions.swift
  Sources/Tako/Status/AgentOptions.swift
)
TESTS=(
  Tests/TakoTests/LayoutTreeTests.swift
  Tests/TakoTests/CheckpointTests.swift
  Tests/TakoTests/ProjectActionTests.swift
  Tests/TakoTests/AgentOptionTests.swift
)

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/Logic" "$work/Tests/LogicTests"
for file in "${LOGIC[@]}"; do [ -f "$file" ] && cp "$file" "$work/Sources/Logic/"; done
cp Tests/LinuxSupport/*.swift "$work/Sources/Logic/" 2>/dev/null || true
for file in "${TESTS[@]}"; do
  [ -f "$file" ] && sed 's/@testable import Tako/@testable import Logic/' "$file" > "$work/Tests/LogicTests/$(basename "$file")"
done
cat > "$work/Package.swift" <<'EOF'
// swift-tools-version:5.9
import PackageDescription
let package = Package(
  name: "Logic",
  targets: [
    .target(name: "Logic", swiftSettings: [.unsafeFlags(["-swift-version", "5"])]),
    .testTarget(name: "LogicTests", dependencies: ["Logic"], swiftSettings: [.unsafeFlags(["-swift-version", "5"])]),
  ])
EOF
echo "· building and testing pure logic"
(cd "$work" && swift test 2>&1 | grep -E "error:|failed|Executed .* tests" | sort -u)
