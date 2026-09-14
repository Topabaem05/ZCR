#!/bin/zsh
# Slice A (T12 HostWitness) quiet evidence runs at the committed source.
# Refuses to start unless the worktree is clean at the code commit and no other zig build is running.
# Each group run installs its test binaries, then zcr-dev-evidence records and verifies the T12 binary.
# Exit codes are recorded as observed; a failing run is recorded, not retried.
#
# usage: record_runs.sh <code commit>
C=$1
WT=/Users/guribbong/code/ZCR-worktrees/t12-host-witness
STATE=/Users/guribbong/code/ZCR-state/tasks/T12/host-witness-20260914
TOOLS=/Users/guribbong/code/ZCR-state/tasks/MC004/rec2-tools/bin
ZIG=$HOME/.local/share/zig/0.16.0/zig
[ -n "$C" ] || { echo "usage: record_runs.sh <code commit>"; exit 64; }
cd $WT || exit 1
[ "$(git rev-parse HEAD)" = "$(git rev-parse $C)" ] || { echo "HEAD is not $C"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "worktree not clean"; exit 1; }
[ "$($ZIG version)" = "0.16.0" ] || { echo "zig is not 0.16.0"; exit 1; }
# Match zig processes by name; a command-line match would also find shells that merely mention zig.
if pgrep -x zig >/dev/null; then echo "another zig build is running; not quiet"; exit 1; fi
# Other applications can load the host too; require the 1-minute load average below the CPU count.
NCPU=$(sysctl -n hw.ncpu); LOAD1=$(sysctl -n vm.loadavg | awk '{print $2}')
awk -v l=$LOAD1 -v n=$NCPU 'BEGIN{exit !(l < n)}' || { echo "load average $LOAD1 >= $NCPU CPUs; not quiet"; exit 1; }
mkdir -p $STATE/logs; echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) start $(uptime)" > $STATE/logs/record_runs.uptime
export ZIG_GLOBAL_CACHE_DIR=$STATE/zig-global-cache ZIG_LOCAL_CACHE_DIR=$STATE/zig-local-cache TMPDIR=$STATE/tmp
mkdir -p $STATE/logs $STATE/records $STATE/tmp

$TOOLS/zcr-dev-evidence preflight --worktree $WT > $STATE/logs/rec-preflight.log 2>&1 || { echo "preflight rejected"; exit 1; }
$ZIG build verify-contracts > $STATE/logs/rec-contracts.log 2>&1; echo "verify-contracts exit=$?"

run_group() {
  local label=$1 opt=$2
  local out=$STATE/out-$label
  local cmd="zig build test -Dtest-group=write -Doptimize=$opt -Dinstall-tests=true --prefix \$STATE/out-$label --summary all"
  $ZIG build test -Dtest-group=write -Doptimize=$opt -Dinstall-tests=true --prefix $out --summary all > $STATE/logs/$label.log 2>&1
  local rc=$?
  echo "$label exit=$rc $(grep 'Build Summary' $STATE/logs/$label.log | tail -1)"
  [ -x $out/bin/T12-test ] || { echo "$label: no installed T12-test"; return 1; }
  $TOOLS/zcr-dev-evidence record --worktree $WT --task T12 --label $label-t12 --command "$cmd" --exit $rc --binary $out/bin/T12-test --out $STATE/records/$label-t12.json || return 1
  $TOOLS/zcr-dev-evidence verify --worktree $WT --evidence $STATE/records/$label-t12.json > $STATE/logs/verify-$label-t12.log 2>&1
  local vrc=$?
  echo "$label-t12 verify exit=$vrc"
  # A rejected record must fail the run, not only print its status.
  return $vrc
}
run_group quiet-write-debug Debug || exit 1
run_group quiet-write-releasesafe ReleaseSafe || exit 1

# Quiet reruns, one at a time, of the mutants whose first runs shared the CPU with other builds.
# Each runs on a copy; the task worktree is never modified. SKIP_MUTANT_RERUNS=1 records only the
# group runs, for a rerun whose mutants already ran against the same source.
[ "${SKIP_MUTANT_RERUNS:-0}" = "1" ] && { echo "$C" > $STATE/code-commit; echo "mutant reruns skipped"; exit 0; }
for M in no_one_use leaf_original_only; do
  rm -rf $STATE/mutant-$M-quiet
  rsync -a --exclude .git --exclude .zig-cache --exclude zig-out $WT/ $STATE/mutant-$M-quiet/ || exit 1
  python3 $STATE/task/mutants.py $M $STATE/mutant-$M-quiet/src/storage/recovery.zig || exit 1
  (cd $STATE/mutant-$M-quiet && ZIG_LOCAL_CACHE_DIR=$STATE/cache-mutant-$M-quiet $ZIG build test -Dtest-group=write -Dtest-id=WR-008 -Doptimize=Debug --summary all > $STATE/logs/mutant-$M-quiet.log 2>&1)
  echo "mutant $M quiet exit=$? $(grep 'Build Summary' $STATE/logs/mutant-$M-quiet.log | tail -1)"
  grep "error: 't12_test" $STATE/logs/mutant-$M-quiet.log
done
echo "$C" > $STATE/code-commit
