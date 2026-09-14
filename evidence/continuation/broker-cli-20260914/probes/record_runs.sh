#!/bin/zsh
# Slice C (T01 broker CLI wiring) quiet evidence runs at the committed source.
# Refuses to start unless the worktree is clean at the code commit, no other zig build is running,
# no other quiet evidence run holds the marker, and the 1-minute load average is below the CPU count.
# The Zig local cache uses a short task-local root: the broker socket lives under the test temp
# directory, which must keep the path within macOS sun_path (104 bytes).
# Exit codes are recorded as observed; a failing run is recorded, not retried.
#
# usage: record_runs.sh <code commit>
C=$1
WT=/Users/guribbong/code/ZCR-worktrees/t01-broker-cli
STATE=/Users/guribbong/code/ZCR-state/tasks/T01/broker-cli-20260914
SHORT=/Users/guribbong/code/ZCR-state/tasks/T01/bc
MARK=/Users/guribbong/code/ZCR-state/tasks/quiet-evidence.running
TOOLS=/Users/guribbong/code/ZCR-state/tasks/MC004/rec2-tools/bin
ZIG=$HOME/.local/share/zig/0.16.0/zig
[ -n "$C" ] || { echo "usage: record_runs.sh <code commit>"; exit 64; }
cd $WT || exit 1
[ "$(git rev-parse HEAD)" = "$(git rev-parse $C)" ] || { echo "HEAD is not $C"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "worktree not clean"; exit 1; }
[ "$($ZIG version)" = "0.16.0" ] || { echo "zig is not 0.16.0"; exit 1; }
[ -e $MARK ] && { echo "another quiet evidence run holds $MARK"; exit 1; }
# Match zig processes by name; a command-line match would also find shells that merely mention zig.
if pgrep -x zig >/dev/null; then echo "another zig build is running; not quiet"; exit 1; fi
NCPU=$(sysctl -n hw.ncpu); LOAD1=$(sysctl -n vm.loadavg | awk '{print $2}')
awk -v l=$LOAD1 -v n=$NCPU 'BEGIN{exit !(l < n)}' || { echo "load average $LOAD1 >= $NCPU CPUs; not quiet"; exit 1; }
export ZIG_GLOBAL_CACHE_DIR=$SHORT/zgc ZIG_LOCAL_CACHE_DIR=$SHORT/zlc TMPDIR=$SHORT/tmp
mkdir -p $STATE/logs $STATE/records $SHORT/zgc $SHORT/zlc $SHORT/tmp
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) start $(uptime)" > $STATE/logs/record_runs.uptime

$TOOLS/zcr-dev-evidence preflight --worktree $WT > $STATE/logs/rec-preflight.log 2>&1 || { echo "preflight rejected"; exit 1; }
$ZIG build verify-contracts > $STATE/logs/rec-contracts.log 2>&1; echo "verify-contracts exit=$?"

# group, optimize, label, installed binary to record
run_group() {
  local group=$1 opt=$2 label=$3 bin=$4
  local out=$STATE/out-$label
  local cmd="zig build test -Dtest-group=$group -Doptimize=$opt -Dinstall-tests=true --prefix \$STATE/out-$label --summary all (ZIG_LOCAL_CACHE_DIR=$SHORT/zlc)"
  $ZIG build test -Dtest-group=$group -Doptimize=$opt -Dinstall-tests=true --prefix $out --summary all > $STATE/logs/$label.log 2>&1
  local rc=$?
  echo "$label exit=$rc $(grep 'Build Summary' $STATE/logs/$label.log | tail -1)"
  grep "error: '" $STATE/logs/$label.log
  [ -x $out/bin/$bin ] || { echo "$label: no installed $bin"; return 1; }
  $TOOLS/zcr-dev-evidence record --worktree $WT --task T01 --label $label --command "$cmd" --exit $rc --binary $out/bin/$bin --out $STATE/records/$label.json || return 1
  $TOOLS/zcr-dev-evidence verify --worktree $WT --evidence $STATE/records/$label.json > $STATE/logs/verify-$label.log 2>&1
  echo "$label verify exit=$?"
}
run_group broker Debug quiet-broker-debug T01-broker-cli-test || exit 1
run_group broker ReleaseSafe quiet-broker-releasesafe T01-broker-cli-test || exit 1
run_group dev Debug quiet-dev-debug T01-test || exit 1
run_group mcp Debug quiet-mcp-debug T08-launch-test || exit 1
echo "$C" > $STATE/code-commit
