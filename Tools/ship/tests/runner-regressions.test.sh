#!/usr/bin/env bash
# Synthetic runner scheduling/lifecycle checks; never runs Unity or writes an index.
set -euo pipefail
python3 "$(dirname "$0")/helpers/runner-regressions.py"
