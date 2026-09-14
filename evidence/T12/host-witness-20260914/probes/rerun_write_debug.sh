#!/bin/zsh
# Slice A: one more write group Debug run at the code commit, recorded under a new label.
# The earlier quiet-write-debug record (68/70; a T11 git discovery timeout and a WR-005 recovery child
# that closed its pipe before its hello) is kept as observed. Same gates as record_runs.sh.
#
# usage: rerun_write_debug.sh <code commit> <label>
C=$1; LABEL=$2
WT=/Users/guribbong/code/ZCR-worktrees/t12-host-witness
STATE=/Users/guribbong/code/ZCR-state/tasks/T12/host-witness-20260914
TOOLS=/Users/guribbong/code/ZCR-state/tasks/MC004/rec2-tools/bin
ZIG=$HOME/.local/share/zig/0.16.0/zig
[ -n "$C" ] && [ -n "$LABEL" ] || { echo "usage: rerun_write_debug.sh <code commit> <label>"; exit 64; }
[ -e $STATE/records/$LABEL-t12.json ] && { echo "record $LABEL-t12 already exists; not overwriting"; exit 64; }
cd $WT || exit 1
[ "$(git rev-parse HEAD)" = "$(git rev-parse $C)" ] || { echo "HEAD is not $C"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "worktree not clean"; exit 1; }
if pgrep -x zig >/dev/null; then echo "another zig build is running; not quiet"; exit 1; fi
NCPU=$(sysctl -n hw.ncpu); LOAD1=$(sysctl -n vm.loadavg | awk '{print $2}')
awk -v l=$LOAD1 -v n=$NCPU 'BEGIN{exit !(l < n)}' || { echo "load average $LOAD1 >= $NCPU CPUs; not quiet"; exit 1; }
export ZIG_GLOBAL_CACHE_DIR=$STATE/zig-global-cache ZIG_LOCAL_CACHE_DIR=$STATE/zig-local-cache TMPDIR=$STATE/tmp
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) start $(uptime)" > $STATE/logs/$LABEL.uptime
out=$STATE/out-$LABEL
cmd="zig build test -Dtest-group=write -Doptimize=Debug -Dinstall-tests=true --prefix \$STATE/out-$LABEL --summary all"
$ZIG build test -Dtest-group=write -Doptimize=Debug -Dinstall-tests=true --prefix $out --summary all > $STATE/logs/$LABEL.log 2>&1
rc=$?
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) end $(uptime)" >> $STATE/logs/$LABEL.uptime
echo "$LABEL exit=$rc $(grep 'Build Summary' $STATE/logs/$LABEL.log | tail -1)"
grep "error: '" $STATE/logs/$LABEL.log
[ -x $out/bin/T12-test ] || { echo "no installed T12-test"; exit 1; }
$TOOLS/zcr-dev-evidence record --worktree $WT --task T12 --label $LABEL-t12 --command "$cmd" --exit $rc --binary $out/bin/T12-test --out $STATE/records/$LABEL-t12.json || exit 1
$TOOLS/zcr-dev-evidence verify --worktree $WT --evidence $STATE/records/$LABEL-t12.json > $STATE/logs/verify-$LABEL-t12.log 2>&1
echo "$LABEL-t12 verify exit=$?"
