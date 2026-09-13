#!/bin/zsh
# Run an installed MC-004 test binary N times idle and M times while `yes` busy loops
# occupy every CPU. The same loop ran the instrumented original test (loaded 20) and the
# new test (idle 10, loaded 30); per-run logs are in ../logs/*.tar.gz.
#
# Exit status: 0 only if every run exited 0; 1 if any run failed.
#
# usage: mc004_stress.sh <T08-test binary> <log dir> <idle runs> <loaded runs>
set -u
BIN=$1; L=$2; IDLE=${3:-10}; LOADED=${4:-30}
NCPU=$(sysctl -n hw.ncpu)
mkdir -p $L
CWD=$(mktemp -d)
echo "binary sha256 $(shasum -a 256 $BIN | cut -d' ' -f1)"
failed=0
pids=()
stop_load() { [ ${#pids[@]} -gt 0 ] && kill ${pids[@]} 2>/dev/null; wait 2>/dev/null; pids=(); }
# EXIT only cleans up. An interrupted run is never a PASS, and no iteration may run
# after the load is gone under the `loaded` label, so INT and TERM exit nonzero.
trap stop_load EXIT
trap 'stop_load; echo "stress INTERRUPTED signal=INT"; exit 130' INT
trap 'stop_load; echo "stress INTERRUPTED signal=TERM"; exit 143' TERM
# Loaded runs count only while every load worker is alive before and after the run.
load_alive() {
  [ ${#pids[@]} -eq $NCPU ] || return 1
  for pid in ${pids[@]}; do kill -0 $pid 2>/dev/null || return 1; done
}
series() {
  p=0; f=0
  for i in $(seq 1 $2); do
    if [ $1 = loaded ] && ! load_alive; then echo "stress FAIL load workers missing before loaded run $i"; exit 2; fi
    (cd $CWD && $BIN > $L/$1-$i.log 2>&1); c=$?
    if [ $1 = loaded ] && ! load_alive; then echo "stress FAIL load workers missing after loaded run $i"; exit 2; fi
    if [ $c -eq 0 ]; then p=$((p+1)); else f=$((f+1)); echo "$1 run=$i exit=$c $(grep -m1 FAIL $L/$1-$i.log)"; fi
    grep -h MC004DIAG $L/$1-$i.log
  done
  echo "$1 tally pass=$p fail=$f"
  failed=$((failed+f))
}
[ $IDLE -gt 0 ] && series idle $IDLE
for c in $(seq 1 $NCPU); do yes > /dev/null & pids+=($!); done
sleep 1
if ! load_alive; then echo "stress FAIL load workers did not start"; exit 2; fi
echo "load: $NCPU busy loops"
series loaded $LOADED
stop_load
if [ $failed -gt 0 ]; then echo "stress FAIL failed_runs=$failed"; exit 1; fi
echo "stress PASS"
exit 0
