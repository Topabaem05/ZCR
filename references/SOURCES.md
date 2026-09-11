# 출처 및 검증 범위

기준일: **2026-09-11**. 아래는 외부 사실의 primary source다. scheduler 수치·메모리 cap·성능 목표·task 구조는 본 설계의 제안이며 외부 자료가 보증한 성능이 아니다.

<a id="R01"></a>
## R01 · Zig downloads / stable release

[Zig downloads / stable release](https://ziglang.org/download/)  
분류: official release index · 확인일: 2026-09-11  
사용 범위: Zig 0.16.0 stable, release date 2026-04-13

<a id="R02"></a>
## R02 · Zig 0.16.0 Release Notes

[Zig 0.16.0 Release Notes](https://ziglang.org/download/0.16.0/release-notes.html)  
분류: official release notes · 확인일: 2026-09-11  
사용 범위: std.Io migration, Threaded, experimental Evented/Uring/Kqueue/Dispatch

<a id="R03"></a>
## R03 · Zig 0.16.0 Language Reference

[Zig 0.16.0 Language Reference](https://ziglang.org/documentation/0.16.0/)  
분류: official documentation · 확인일: 2026-09-11  
사용 범위: explicit allocator and developer-owned lifetime

<a id="R04"></a>
## R04 · Apple debuts M5 Pro and M5 Max

[Apple debuts M5 Pro and M5 Max](https://www.apple.com/newsroom/2026/03/apple-debuts-m5-pro-and-m5-max-to-supercharge-the-most-demanding-pro-workflows/)  
분류: official announcement · 확인일: 2026-09-11  
사용 범위: 18-core example: six super cores and twelve performance cores

<a id="R05"></a>
## R05 · Explore the new system architecture of Apple silicon Macs

[Explore the new system architecture of Apple silicon Macs](https://developer.apple.com/videos/play/wwdc2020/10686/)  
분류: official developer presentation · 확인일: 2026-09-11  
사용 범위: heterogeneous scheduling, QoS/GCD

<a id="R06"></a>
## R06 · Tune CPU job scheduling for Apple silicon games

[Tune CPU job scheduling for Apple silicon games](https://developer.apple.com/videos/play/tech-talks/110147/)  
분류: official developer presentation · 확인일: 2026-09-11  
사용 범위: perflevel sysctl, scheduler cooperation, task granularity

<a id="R07"></a>
## R07 · Prioritize Work at the Task Level

[Prioritize Work at the Task Level](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/PrioritizeWorkWithQoS.html)  
분류: official archived guide · 확인일: 2026-09-11  
사용 범위: QoS semantics and GCD queue intent; no iOS-only behavior assumed on Mac

<a id="R08"></a>
## R08 · Using the File System Events API

[Using the File System Events API](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html)  
분류: official archived guide · 확인일: 2026-09-11  
사용 범위: watch before scan, coalescing, drop/rescan, root changes

<a id="R09"></a>
## R09 · DispatchSourceMemoryPressure

[DispatchSourceMemoryPressure](https://developer.apple.com/documentation/dispatch/dispatchsourcememorypressure)  
분류: official API reference; dynamic page · 확인일: 2026-09-11  
사용 범위: API existence; exact SDK availability remains gate G03

<a id="R10"></a>
## R10 · ProcessInfo thermalState

[ProcessInfo thermalState](https://developer.apple.com/documentation/foundation/processinfo/thermalstate)  
분류: official API reference; dynamic page · 확인일: 2026-09-11  
사용 범위: API existence; exact SDK availability remains gate G03

<a id="R11"></a>
## R11 · ProcessInfo isLowPowerModeEnabled

[ProcessInfo isLowPowerModeEnabled](https://developer.apple.com/documentation/foundation/processinfo/islowpowermodeenabled)  
분류: official API reference; dynamic page · 확인일: 2026-09-11  
사용 범위: API existence; exact SDK availability remains gate G03

<a id="R12"></a>
## R12 · Codex MCP documentation

[Codex MCP documentation](https://developers.openai.com/codex/mcp/)  
분류: official OpenAI documentation · 확인일: 2026-09-11  
사용 범위: stdio server registration and configuration; redirected official documentation

<a id="R13"></a>
## R13 · Claude Code MCP documentation

[Claude Code MCP documentation](https://code.claude.com/docs/en/mcp)  
분류: official Anthropic documentation · 확인일: 2026-09-11  
사용 범위: stdio configuration, client roots, host integration

<a id="R14"></a>
## R14 · MCP 2025-11-25 Transports

[MCP 2025-11-25 Transports](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)  
분류: official pinned specification · 확인일: 2026-09-11  
사용 범위: newline-delimited JSON-RPC, stdout/stderr

<a id="R15"></a>
## R15 · MCP 2025-11-25 Tools

[MCP 2025-11-25 Tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)  
분류: official pinned specification · 확인일: 2026-09-11  
사용 범위: schema, structured content compatibility, tool annotations

<a id="R16"></a>
## R16 · git-worktree

[git-worktree](https://git-scm.com/docs/git-worktree)  
분류: official Git documentation · 확인일: 2026-09-11  
사용 범위: shared and per-worktree state, worktree list/identity

<a id="R17"></a>
## R17 · gitignore

[gitignore](https://git-scm.com/docs/gitignore)  
분류: official Git documentation · 확인일: 2026-09-11  
사용 범위: ignore pattern precedence/negation/parent exclusion

<a id="R18"></a>
## R18 · Linux Pressure Stall Information

[Linux Pressure Stall Information](https://docs.kernel.org/accounting/psi.html)  
분류: official kernel documentation · 확인일: 2026-09-11  
사용 범위: pressure signals

<a id="R19"></a>
## R19 · Linux Control Group v2

[Linux Control Group v2](https://docs.kernel.org/admin-guide/cgroup-v2.html)  
분류: official kernel documentation · 확인일: 2026-09-11  
사용 범위: effective memory and CPU restrictions

<a id="R20"></a>
## R20 · openat2(2)

[openat2(2)](https://man7.org/linux/man-pages/man2/openat2.2.html)  
분류: Linux man-pages project · 확인일: 2026-09-11  
사용 범위: descriptor-relative path resolution flags and errors

<a id="R21"></a>
## R21 · Windows Quality of Service

[Windows Quality of Service](https://learn.microsoft.com/en-us/windows/win32/procthread/quality-of-service)  
분류: official Microsoft documentation · 확인일: 2026-09-11  
사용 범위: EcoQoS and scheduling hints

<a id="R22"></a>
## R22 · C4 model diagrams

[C4 model diagrams](https://c4model.com/diagrams)  
분류: C4 model primary source · 확인일: 2026-09-11  
사용 범위: Context/Container/Component/Code model

<a id="R23"></a>
## R23 · Tree-sitter: Using parsers

[Tree-sitter: Using parsers](https://tree-sitter.github.io/tree-sitter/using-parsers/)  
분류: official project documentation · 확인일: 2026-09-11  
사용 범위: parser C API and syntax representation

<a id="R24"></a>
## R24 · ripgrep

[ripgrep](https://github.com/BurntSushi/ripgrep)  
분류: official project repository · 확인일: 2026-09-11  
사용 범위: native baseline, filtering and behavior

<a id="R25"></a>
## R25 · fsync(2), Apple archived man page

[fsync(2), Apple archived man page](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fsync.2.html)  
분류: official archived man page · 확인일: 2026-09-11  
사용 범위: fsync vs F_FULLFSYNC; platform validation required

<a id="R26"></a>
## R26 · mmap(2)

[mmap(2)](https://man7.org/linux/man-pages/man2/mmap.2.html)  
분류: Linux man-pages project · 확인일: 2026-09-11  
사용 범위: mapping lifetime/truncation faults and memory semantics
