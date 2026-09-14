#!/bin/zsh
# Compare the T10 test binary built from the fix commit with one built from unmodified main.
# Runs the two binaries alternately: N rounds idle, then N rounds while LOAD `yes` busy loops
# run. Each run is a full T10-test (45 or 46 tests). Prints per-run exit, duration and failing
# test names, and a tally per binary and condition. Only the binaries differ between rows.
#
# usage: compare_t10_binaries.sh <fix T10-test> <baseline T10-test> <log dir> <rounds> <load>
set -u
FIX=$1; BASE=$2; L=$3; N=${4:-4}; LOAD=${5:-8}
mkdir -p $L
CWD=$(mktemp -d)
echo "fix      sha256 $(shasum -a 256 $FIX | cut -d' ' -f1)"
echo "baseline sha256 $(shasum -a 256 $BASE | cut -d' ' -f1)"
typeset -A pass fail
pids=()
stop_load() { [ ${#pids[@]} -gt 0 ] && kill ${pids[@]} 2>/dev/null; wait 2>/dev/null; pids=(); }
trap stop_load EXIT
trap 'stop_load; echo "compare INTERRUPTED"; exit 130' INT TERM
one() {
  cond=$1; name=$2; bin=$3; i=$4
  s=$(date +%s)
  (cd $CWD && $bin > $L/$cond-$name-$i.log 2>&1); c=$?
  key=$cond-$name
  if [ $c -eq 0 ]; then pass[$key]=$(( ${pass[$key]:-0} + 1 )); else fail[$key]=$(( ${fail[$key]:-0} + 1 )); fi
  echo "$cond $name run=$i exit=$c secs=$(( $(date +%s) - s )) $(grep -oE 'IS-[0-9]+ [^.]*\.\.\.FAIL' $L/$cond-$name-$i.log | tr '\n' ' ')"
}
for i in $(seq 1 $N); do one idle fix $FIX $i; one idle baseline $BASE $i; done
for c in $(seq 1 $LOAD); do yes > /dev/null & pids+=($!); done
echo "load: ${#pids[@]} busy loops"
for i in $(seq 1 $N); do one loaded fix $FIX $i; one loaded baseline $BASE $i; done
stop_load
for key in idle-fix idle-baseline loaded-fix loaded-baseline; do echo "tally $key pass=${pass[$key]:-0} fail=${fail[$key]:-0}"; done
