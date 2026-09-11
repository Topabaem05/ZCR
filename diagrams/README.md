# C4 / 동적 / 배포 도식

SVG는 Graphviz DOT에서 렌더링한 오프라인 열람본이다. DOT와 Mermaid 원본을 함께 제공한다. Markdown 설명문이 규범이고, 짧은 영문 diagram label은 구조를 요약한다. source files를 수정한 후 dot -Tsvg <name>.dot -o <name>.svg로 다시 렌더링할 수 있다.

C1 system context, C2 deployable containers, C3 runtime components, C4 code ownership을 분리했다. 추가로 deployment, search pipeline, edit commit/recovery, memory pressure, Apple core scheduling, worktree isolation, task dependency graph를 제공한다. 코어 배치 화살표는 QoS 힌트와 OS 선택을 나타내며 강제 affinity가 아니다.
