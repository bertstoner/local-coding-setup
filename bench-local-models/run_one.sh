#!/bin/bash
# Usage: run_one.sh <model-name> <result-file>
set -uo pipefail
MODEL="$1"
RESULT_FILE="$2"
export PATH="$PATH:/c/Users/berts/AppData/Roaming/Python/Python312/Scripts"
export OLLAMA_API_BASE="http://localhost:11434"

WORKDIR="/tmp/bench-$(echo "$MODEL" | tr ':/' '__')"
rm -rf "$WORKDIR" && mkdir -p "$WORKDIR"
cd "$WORKDIR"

START=$(date +%s)
aider --model "ollama/$MODEL" --yes-always --no-auto-commits \
  --message "$(cat /v/projects/bench-local-models/task_prompt.txt)" \
  > aider_output.log 2>&1
END=$(date +%s)
ELAPSED=$((END - START))

RUN_OUTPUT=""
RUN_STATUS="NO_FILE"
if [ -f lru_cache.py ]; then
    RUN_OUTPUT=$(python lru_cache.py 2>&1)
    if echo "$RUN_OUTPUT" | grep -q "ALL PASSED"; then
        RUN_STATUS="PASS"
    else
        RUN_STATUS="FAIL"
    fi
fi

{
  echo "=== MODEL: $MODEL ==="
  echo "ELAPSED_SECONDS: $ELAPSED"
  echo "RUN_STATUS: $RUN_STATUS"
  echo "--- lru_cache.py ---"
  cat lru_cache.py 2>&1
  echo "--- python run output ---"
  echo "$RUN_OUTPUT"
  echo "--- aider log (tail) ---"
  tail -15 aider_output.log
} > "$RESULT_FILE"

cat "$RESULT_FILE"
