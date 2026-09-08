#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
FILEFORM_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
test "$#" -eq 1 || { echo 'Usage: Tools/generate-fixtures.sh <empty-output-directory>' >&2; exit 2; }
FILEFORM_COMPILER_WORK="$(mktemp -d /tmp/fileform-fixture-tool.XXXXXX)"
trap 'rm -rf "$FILEFORM_COMPILER_WORK"' EXIT
# AOT compilation avoids a CoreGraphics overlay symbol-resolution failure in
# Swift's interpreter on macOS 14. The generated content is unchanged.
swiftc -O -target "$(uname -m)-apple-macosx14.0" "$FILEFORM_ROOT/Tools/generate-fixtures.swift" -o "$FILEFORM_COMPILER_WORK/generate-fixtures"
"$FILEFORM_COMPILER_WORK/generate-fixtures" "$1"
