#!/bin/zsh
# Run an installed MC-004 test binary N times idle and M times while `yes` busy loops
# occupy every CPU. The same loop ran the instrumented original test (loaded 20) and the
# new test (idle 10, loaded 30); per-run logs are in ../logs/*.tar.gz.
#
# usage: mc004_stress.sh <T08-test binary> <log dir> <idle runs> <loaded runs>
set -u
BIN=$1; L=$2; IDLE=${3:-10}; LOADED=${4:-30}
mkdir -p $L
CWD=$(mktemp -d)
echo "binary sha256 $(shasum -a 256 $BIN | cut -d' ' -f1)"
series() {
  p=0; f=0
  for i in $(seq 1 $2); do
    (cd $CWD && $BIN > $L/$1-$i.log 2>&1); c=$?
    if [ $c -eq 0 ]; then p=$((p+1)); else f=$((f+1)); echo "$1 run=$i exit=$c $(grep -m1 FAIL $L/$1-$i.log)"; fi
    grep -h MC004DIAG $L/$1-$i.log
  done
  echo "$1 tally pass=$p fail=$f"
}
[ $IDLE -gt 0 ] && series idle $IDLE
pids=()
for c in $(seq 1 $(sysctl -n hw.ncpu)); do yes > /dev/null & pids+=($!); done
echo "load: $(sysctl -n hw.ncpu) busy loops"
series loaded $LOADED
kill ${pids[@]} 2>/dev/null
wait 2>/dev/null
