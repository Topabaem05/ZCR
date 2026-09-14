#!/bin/zsh
# Slice B (T15 BR-005 reconnect) quiet evidence runs at the committed source.
# Refuses to start unless the worktree is clean at the code commit and no other zig build is running.
# The Zig local cache uses a short task-local root: test temp directories live under it, and the broker
# socket path must fit macOS sun_path (104 bytes). The long state path produced a 110-byte path.
# Exit codes are recorded as observed; a failing run is recorded, not retried.
#
# usage: record_runs.sh <code commit>
C=$1
WT=/Users/guribbong/code/ZCR-worktrees/t15-reconnect
STATE=/Users/guribbong/code/ZCR-state/tasks/T15/reconnect-20260914
SHORT=/Users/guribbong/code/ZCR-state/tasks/T15/r
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
export ZIG_GLOBAL_CACHE_DIR=$SHORT/zgc ZIG_LOCAL_CACHE_DIR=$SHORT/zlc TMPDIR=$SHORT/tmp
mkdir -p $STATE/logs $STATE/records $SHORT/zgc $SHORT/zlc $SHORT/tmp

$TOOLS/zcr-dev-evidence preflight --worktree $WT > $STATE/logs/rec-preflight.log 2>&1 || { echo "preflight rejected"; exit 1; }
$ZIG build verify-contracts > $STATE/logs/rec-contracts.log 2>&1; echo "verify-contracts exit=$?"

run_group() {
  local label=$1 opt=$2
  local out=$STATE/out-$label
  local cmd="zig build test -Dtest-group=broker -Doptimize=$opt -Dinstall-tests=true --prefix \$STATE/out-$label --summary all (ZIG_LOCAL_CACHE_DIR=$SHORT/zlc)"
  $ZIG build test -Dtest-group=broker -Doptimize=$opt -Dinstall-tests=true --prefix $out --summary all > $STATE/logs/$label.log 2>&1
  local rc=$?
  echo "$label exit=$rc $(grep 'Build Summary' $STATE/logs/$label.log | tail -1)"
  grep "error: 't15_test" $STATE/logs/$label.log
  [ -x $out/bin/T15-test ] || { echo "$label: no installed T15-test"; return 1; }
  $TOOLS/zcr-dev-evidence record --worktree $WT --task T15 --label $label-t15 --command "$cmd" --exit $rc --binary $out/bin/T15-test --out $STATE/records/$label-t15.json || return 1
  $TOOLS/zcr-dev-evidence verify --worktree $WT --evidence $STATE/records/$label-t15.json > $STATE/logs/verify-$label-t15.log 2>&1
  local vrc=$?
  echo "$label-t15 verify exit=$vrc"
  # A rejected record must fail the run, not only print its status.
  return $vrc
}
run_group quiet-broker-debug Debug || exit 1
run_group quiet-broker-releasesafe ReleaseSafe || exit 1
echo "$C" > $STATE/code-commit
