#!/bin/bash
if [[ "${CAMERA_UI_WORKER:-}" != "true" ]]; then
    curl -fsSk https://localhost:3443/api/health >/dev/null
    exit
fi

# the worker rewrites this every 15 s in every state, also while it waits for its master
status="${CAMERA_UI_HOME_PATH}/volume/worker-status.json"
if [[ -f "$status" ]]; then
    age=$(( $(date +%s) - $(stat -c %Y "$status") ))
    (( age < 60 )) && exit 0
    # a stale file whose worker still runs means a hung worker; a container restart hands out the same pids,
    # so a worker that started after the last write is a new one, e.g. an older server after a rollback
    pid=$(sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "$status")
    if [[ -n "$pid" ]] && pgrep -f '^camera\.ui-worker' | grep -qx "$pid"; then
        running=$(ps -o etimes= -p "$pid" | tr -d ' ')
        [[ -n "$running" ]] && (( running > age )) && exit 1
    fi
fi

# servers before 2.4.0 write no status file
pgrep -f '^camera\.ui-worker' >/dev/null
