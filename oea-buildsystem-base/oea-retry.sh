#!/bin/bash
# oea-retry -- queue MACHINE(s) for priority build in the running loop.
#
# The main entrypoint drains the priority queue before each natural
# round-robin iteration. The currently-running MACHINE build is NOT
# interrupted -- your requested MACHINE(s) start as soon as the
# current one finishes.
#
# Usage:
#   oea-retry dm900               # single
#   oea-retry dm900 dm920 dm7080  # multiple, processed in order
#   oea-retry --list              # show current queue
#   oea-retry --clear             # empty the queue
#
# Meant to be run from an exec'd shell or over SSH into a running
# oea-buildsystem container.
set -euo pipefail

QUEUE=/temp/.oea-priority

case "${1:-}" in
    ""|-h|--help)
        cat <<'EOF'
usage:
  oea-retry <MACHINE> [MACHINE ...]   queue MACHINE(s) for priority build
  oea-retry --list                    show current priority queue
  oea-retry --clear                   empty the queue
EOF
        exit 2
        ;;
    --list)
        if [ -s "$QUEUE" ]; then
            echo "priority queue ($(wc -l < "$QUEUE") entries):"
            cat -n "$QUEUE"
        else
            echo "priority queue is empty"
        fi
        exit 0
        ;;
    --clear)
        : > "$QUEUE"
        echo "priority queue cleared"
        exit 0
        ;;
esac

mkdir -p "$(dirname "$QUEUE")"
for M in "$@"; do
    echo "$M" >> "$QUEUE"
    echo "queued: $M (position #$(wc -l < "$QUEUE") in priority queue)"
done
