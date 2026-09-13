#!/bin/bash
# Live player probe. Tails the Apple TV's dev probe endpoint (:8123) so a
# scrub, a seek or a stalled cache can be watched as it happens instead of
# reconstructed from a log afterwards. DEBUG builds only.
#
#   scripts/probe.sh 192.168.1.42            # levels every 2s + events live
#   scripts/probe.sh 192.168.1.42 events     # events only, no level blocks
#   scripts/probe.sh 192.168.1.42 once       # one snapshot and exit
#   scripts/probe.sh 192.168.1.42 health     # just the counters
#   scripts/probe.sh 192.168.1.42 mark "froze here"   # anchor the live tail
#
# Set ORIVIO_TV to skip the argument:  export ORIVIO_TV=192.168.1.42
set -u

HOST="${1:-${ORIVIO_TV:-}}"
MODE="${2:-live}"

if [ -z "$HOST" ]; then
    echo "usage: $0 <apple-tv-ip> [live|events|once|health|trail|mark <note>]" >&2
    echo "  (or export ORIVIO_TV=<ip>)" >&2
    exit 64
fi

case "$MODE" in
    live)   PATH_="/live" ;;
    events) PATH_="/events" ;;
    once)   PATH_="/probe" ;;
    health) PATH_="/health" ;;
    trail)  PATH_="/" ;;
    # A mark is an anchor in the tail: what the viewer just reported, written
    # into the same clock as the events, so the two can be lined up later
    # instead of guessed at.
    mark)   PATH_="/mark?$(printf %s "${3:-mark}" | sed 's/ /+/g')" ;;
    *)      echo "unknown mode: $MODE" >&2; exit 64 ;;
esac

# --no-buffer is what makes a streaming route print as it arrives.
exec curl --no-buffer --silent --show-error --max-time 86400 \
     "http://${HOST}:8123${PATH_}"
