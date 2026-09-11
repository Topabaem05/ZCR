@AGENTS.md

## Claude Code 세션 메모

- 이 저장소는 현재 설계 패키지 v1.0 기준선이다. runtime source는 아직 없다.
- 작업 시작 순서는 AGENTS.md를 따른다: README → docs/01 → docs/02 → docs/06 → docs/13 → 현재 tasks/Txx.md.
- Toolchain은 Zig 0.16.0으로 고정한다. 공식 tarball(SHA256 `b23d70de…401489`)을 `~/.local/share/zig/0.16.0/zig`에 설치했다. PATH의 `zig`는 다른 버전일 수 있으므로 절대 경로를 쓰고, `zig version`이 0.16.0이 아니면 빌드·시험 결과를 증거로 쓰지 않는다.
- task 작업은 이 checkout이 아니라 `../ZCR-worktrees/task-tNN`(branch `task-tNN`)에서 한다. `ZIG_GLOBAL_CACHE_DIR`·`ZIG_LOCAL_CACHE_DIR`·`TMPDIR`·raw log는 `../ZCR-state/tasks/TNN/` 아래에 task별로 분리한다.
- 설계 패키지 파일을 편집하면 `MANIFEST.sha256`과 `verification/report.json`을 다시 생성해야 한다.
