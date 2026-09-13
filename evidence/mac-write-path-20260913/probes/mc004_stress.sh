#!/bin/zsh
# Reproduce the CI-only T08 MC-004 Debug failure on this host.
# Builds the MC-004 tests once from a clean main checkout into a state prefix, then
# runs the installed test binary N times without load and N times while `yes` busy
# loops occupy every CPU. Prints one line per run and a pass/fail tally.
#
# usage: mc004_stress.sh <iterations>
set -u
N=${1:-20}
WT=/Users/guribbong/code/ZCR-worktrees/main-verify
ST=/Users/guribbong/code/ZCR-state/verify-main
Z=~/.local/share/zig/0.16.0/zig
OUT=$ST/out-mc004
LOG=$ST/logs/mc004-stress
mkdir -p $LOG $ST/tmp/mc004-cwd
export ZIG_GLOBAL_CACHE_DIR=$ST/zig-global-cache ZIG_LOCAL_CACHE_DIR=$ST/zig-local-cache TMPDIR=$ST/tmp

cd $WT || exit 1
echo "source $(git rev-parse HEAD) tree $(git rev-parse HEAD^{tree}) dirty=$(git status --porcelain | wc -l | tr -d ' ')"
rm -rf $OUT
$Z build test -Dtest-group=mcp -Dtest-id=MC-004 -Doptimize=Debug -Dinstall-tests=true --prefix $OUT --summary all > $LOG/build.log 2>&1
echo "build exit=$? $(grep -E '^Build Summary' $LOG/build.log)"
BIN=$OUT/bin/T08-test
[ -x $BIN ] || { echo "no test binary"; exit 1; }
echo "binary sha256 $(shasum -a 256 $BIN | cut -d' ' -f1)"

run_series() {
  label=$1
  pass=0; fail=0
  for i in $(seq 1 $N); do
    (cd $ST/tmp/mc004-cwd && $BIN > $LOG/$label-$i.log 2>&1)
    code=$?
    if [ $code -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); fi
    echo "$label run=$i exit=$code $(grep -oE "[0-9]+ passed; [0-9]+ skipped; [0-9]+ failed" $LOG/$label-$i.log | tail -1)"
  done
  echo "$label tally pass=$pass fail=$fail"
}

run_series idle

cpus=$(sysctl -n hw.ncpu)
pids=()
for c in $(seq 1 $cpus); do yes > /dev/null & pids+=($!); done
echo "load: $cpus busy loops"
run_series loaded
kill ${pids[@]} 2>/dev/null
wait 2>/dev/null
