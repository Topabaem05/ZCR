# 메인 통합 검증 증거

- 로컬 runtime source: `169be181ecdb717399cdff26208fe7b602cb949d`.
- 원격 동등 source: `88546e8069a69d92f86cb9b4b9af0f6902055727`.
- 두 source의 동일 tree: `54dba2efb586303f5b60e80bf3834c28519a223e`.
- [tested-source.bundle](tested-source.bundle)은 로컬 source commit을 보존한다. prerequisite는 저장소 이력에 있는 `a911bf87752ede4aa5ddfc966af50dbd2df5fa59`이며 `git bundle verify`로 확인했다.
- [bootstrap-red.log](bootstrap-red.log): plain Python launch가 소스에 bytecode를 생성하는 수정 전 실패.
- [bootstrap-green.log](bootstrap-green.log): 수정 후 회귀 및 storage capture 검사 5개 통과.
- [local-native-report.json](local-native-report.json): 전체 native runner 결과, 명령, exit code, binary·source·입력 digest. 전체 상태는 FAIL이다.
- [local-native-evidence.tar.gz](local-native-evidence.tar.gz): 보고서, source 전후 파일 digest, 원본 command 로그, CLI transcript, capability 자료, T12 raw fixture capture. 큰 binary archive는 포함하지 않았으며 실행한 바이너리의 digest는 보고서에 있다. 외부 빈 폴더에 풀어 검사한다.

Debug/ReleaseSafe 각각 등록 시험 346 PASS, 1 native GCD SKIP, 9 broker socket FAIL. AF_UNIX가 이 컨테이너에서 EPERM으로 거부됨을 별도로 확인했다. Build/contracts, codec 10개, CLI subprocess 19개, capability probe 및 source 전후 무변경 검사는 두 모드 모두 통과했다.

실제 Codex/Claude, 모델 공존, macOS 11, kernel fault/전원 손실 게이트는 이 실행으로 검증하지 않았다. 문서 변경 commit을 런타임 실행 source와 혼동하지 않는다.

## GitHub Apple Silicon 증거

[실행 34705666351](https://github.com/Topabaem05/ZCR/actions/runs/34705666351), artifact ID `10301399942`의 ZIP SHA-256은 `9d1f845c4d4ecf29c944ed133fa9780adc7771eff472a1aaef52f0c4492be475`이며 다운로드 후 일치를 확인했다. [mac-native-report.json](mac-native-report.json)과 [mac-registered-logs.tar.gz](mac-registered-logs.tar.gz)는 그 artifact에서 추출한 보고서와 등록 시험 stderr 원문이다.

Debug 320 PASS / 12 SKIP / 24 FAIL; ReleaseSafe 321 PASS / 12 SKIP / 23 FAIL. T12 Linux 전용 guard로 인한 23개 실패, Debug fixture 초기화 오류의 168 allocation leak, Debug MC-004 retirement assertion 실패가 남아 있다. Linux job은 SUCCESS이며 Intel Mac의 최종 상태는 원본 workflow에서 확인한다.
