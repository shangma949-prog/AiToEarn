#!/usr/bin/env bash
# 兼容旧入口。实际命令见 aitoearnctl.sh。
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${1:-}" == "--web" ]]; then
  shift
fi
exec "$DIR/aitoearnctl.sh" start "$@"
