#!/bin/zsh
# Plays a route on a simulator through Core Location's simulation (drives the real CLLocationManager path).
#   sim-route.sh <udid> <route-name|file> [speed m/s, default 16] 
#   sim-route.sh <udid> stop
set -euo pipefail
udid=$1; route=${2:-akagi}; speed=${3:-16}
if [[ $route == stop ]]; then xcrun simctl location "$udid" clear; exit 0; fi
file=$route
[[ -f $file ]] || file="${0:A:h}/routes/$route.txt"
xcrun simctl location "$udid" start --speed="$speed" --interval=1 - < "$file"
echo "Playing $file at $speed m/s on $udid (stop: scripts/xc.sh route stop)"
