#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root/dev/ffi_compare"

flutter pub get
dart compile exe bin/benchmark_compare.dart -o build/benchmark_compare
build/benchmark_compare "$@"
