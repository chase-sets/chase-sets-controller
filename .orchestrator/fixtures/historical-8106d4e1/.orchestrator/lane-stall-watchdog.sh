#!/usr/bin/env bash
# Lane stall watchdog (orchestrator skill §6).
# Usage: lane-stall-watchdog.sh <label:file> [<label:file> ...]
# Polls every POLL_S seconds. No growth is handed to the exact process-identity
# watchdog; live-slow owners retain the two-cycle diagnosis path.
POLL_S=${POLL_S:-120}
STALL_POLLS=${STALL_POLLS:-3}
MAX_S=${MAX_S:-7200}
declare -A last size stale
start=$(date +%s)
for arg in "$@"; do
  label="${arg%%:*}"; file="${arg#*:}"
  last[$label]="$file"; size[$label]=-1; stale[$label]=0
done
while :; do
  now=$(date +%s)
  if (( now - start > MAX_S )); then echo "WATCHDOG-EXPIRED: no stalls in ${MAX_S}s window"; exit 0; fi
  sleep "$POLL_S"
  for label in "${!last[@]}"; do
    file="${last[$label]}"
    [ -f "$file" ] || continue
    s=$(stat -c %s "$file" 2>/dev/null || echo 0)
    if [ "$s" = "${size[$label]}" ]; then
      stale[$label]=$(( ${stale[$label]} + 1 ))
      if (( ${stale[$label]} >= STALL_POLLS )); then
        script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
        observed_at=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
        if command -v pwsh.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
          ps_script=$(wslpath -w "$script_dir/lane-stall-watchdog.ps1")
          runtime_root=$(wslpath -w "$script_dir")
          transcript=$(wslpath -w "$file")
          pwsh.exe -NoProfile -NonInteractive -File "$ps_script" -Label "$label" \
            -RuntimeRoot "$runtime_root" -TranscriptPath "$transcript" -ObservedAt "$observed_at"
        fi
        echo "STALL-DETECTED: lane '$label' output unchanged for $(( POLL_S * STALL_POLLS ))s (file: $file, size: $s bytes)"
        echo "Other lanes at detection:"
        for l2 in "${!last[@]}"; do echo "  $l2: ${size[$l2]} bytes, stale-polls=${stale[$l2]}"; done
        exit 0
      fi
    else
      stale[$label]=0
      size[$label]=$s
    fi
  done
done
