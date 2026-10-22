#!/usr/bin/env bash
set -euo pipefail

task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export GOTOOLCHAIN=local
export GOCACHE="${GOCACHE:-$task_root/.local-state/go-cache}"
mkdir -p "$GOCACHE"
cd "$task_root/harness"

unformatted="$(gofmt -l .)"
if [[ -n "$unformatted" ]]; then
  printf 'gofmtが必要です:\n%s\n' "$unformatted" >&2
  exit 1
fi
go vet ./...
go test -race ./...
