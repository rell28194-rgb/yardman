#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
PYTHONPATH=Tools python3 -m jmworld --json compile synthetic --size 12
PYTHONPATH=Tools python3 -m jmworld --json validate Assets/StreamingAssets/Yardman/manifest.json
