//! ZCR build runner (T01, integrator-owned).
//!
//!   zig build                                   build `zcr` and `zcr-dev-evidence`
//!   zig build test [-Dtest-group=G] [-Dtest-id=ID] [-Dfault-injection=true] [-Dinstall-tests=true]
//!   zig build verify-contracts                  core declarations vs contracts/ and config/
//!   zig build bench -Dcorpus=C -Dvariant=V      reserved for T21; fails until implemented
//!
//! Tasks do not add their own runner flags. New test files are registered in
//! `test_files` by the integrator.

const std = @import("std");
const builtin = @import("builtin");
const manifest = @import("build.zig.zon");

comptime {
    const v = builtin.zig_version;
    if (v.major != 0 or v.minor != 16 or v.patch != 0 or v.pre != null) {
        @compileError("ZCR is pinned to Zig 0.16.0 (ADR-001); this is Zig " ++ builtin.zig_version_string);
    }
}

pub const TestGroup = enum { io, fs, search, batch, write, mcp, isolation, broker, watch, observe, ast, scheduler, memory, perf, dev, security };

const Import = enum { core, evidence, caps, build_options, policy, guard, memory, admission, fs_read, fs_traverse, search, batch, projection, mcp, executor, workspace, queue, darwin, launch, edit, cache, watch, broker, storage };

const TestFile = struct {
    task: []const u8,
    path: []const u8,
    group: TestGroup,
    imports: []const Import,
};

/// Integrator-owned registry. One row per task test file; group follows tasks/tasks.json.
const test_files = [_]TestFile{
    .{ .task = "T00", .path = "tests/t00_test.zig", .group = .perf, .imports = &.{.caps} },
    .{ .task = "T01", .path = "tests/t01_test.zig", .group = .dev, .imports = &.{ .core, .evidence, .build_options } },
    .{ .task = "T02", .path = "tests/t02_test.zig", .group = .isolation, .imports = &.{ .core, .policy, .guard, .evidence, .build_options } },
    .{ .task = "T03", .path = "tests/t03_test.zig", .group = .memory, .imports = &.{ .core, .memory, .admission } },
    .{ .task = "T04", .path = "tests/t04_test.zig", .group = .io, .imports = &.{ .core, .policy, .memory, .admission, .fs_read } },
    .{ .task = "T04-deadline", .path = "tests/timing_test.zig", .group = .io, .imports = &.{.core} },
    .{ .task = "T05", .path = "tests/t05_test.zig", .group = .fs, .imports = &.{ .core, .policy, .memory, .fs_traverse, .evidence } },
    .{ .task = "T06", .path = "tests/t06_test.zig", .group = .search, .imports = &.{ .core, .policy, .memory, .fs_read, .fs_traverse, .search } },
    .{ .task = "T07", .path = "tests/t07_test.zig", .group = .batch, .imports = &.{ .core, .policy, .memory, .admission, .fs_read, .batch, .projection } },
    .{ .task = "T08", .path = "tests/t08_test.zig", .group = .mcp, .imports = &.{ .core, .policy, .memory, .admission, .fs_read, .fs_traverse, .search, .batch, .projection, .mcp, .workspace, .cache, .build_options } },
    .{ .task = "T09", .path = "tests/t09_test.zig", .group = .scheduler, .imports = &.{ .core, .memory, .admission, .executor, .queue, .darwin } },
    .{ .task = "T08-launch", .path = "tests/launch_test.zig", .group = .mcp, .imports = &.{.launch} },
    .{ .task = "T10", .path = "tests/t10_test.zig", .group = .isolation, .imports = &.{ .core, .policy, .workspace } },
    .{ .task = "T11", .path = "tests/t11_test.zig", .group = .write, .imports = &.{ .core, .policy, .memory, .fs_read, .workspace, .edit } },
    .{ .task = "T12", .path = "tests/t12_test.zig", .group = .write, .imports = &.{ .core, .policy, .memory, .fs_read, .workspace, .edit, .storage, .build_options } },
    .{ .task = "T13", .path = "tests/t13_test.zig", .group = .memory, .imports = &.{ .core, .policy, .memory, .workspace, .cache } },
    .{ .task = "T14", .path = "tests/t14_test.zig", .group = .watch, .imports = &.{ .core, .policy, .memory, .workspace, .cache, .fs_traverse, .watch } },
    .{ .task = "T15", .path = "tests/t15_test.zig", .group = .broker, .imports = &.{ .core, .policy, .memory, .workspace, .cache, .executor, .mcp, .broker, .build_options } },
};

/// Exit code for CLI roles that exist in the contract but are not built yet (EX_UNAVAILABLE).
pub const exit_unavailable = 69;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_group = b.option(TestGroup, "test-group", "Run only test files registered for this group");
    const test_id = b.option([]const u8, "test-id", "Run only tests whose name contains this ID, e.g. WR-005");
    const fault_injection = b.option(bool, "fault-injection", "Compile fault-injection hooks into the build") orelse false;
    const install_tests = b.option(bool, "install-tests", "Also install test binaries to <prefix>/bin so evidence can record their digest") orelse false;
    const bench_corpus = b.option([]const u8, "corpus", "Benchmark corpus id for the bench step (T21)");
    const bench_variant = b.option([]const u8, "variant", "Benchmark variant for the bench step (T21)");

    const options = b.addOptions();
    options.addOption([]const u8, "version", manifest.version);
    options.addOption([]const u8, "zig_version", builtin.zig_version_string);
    options.addOption(bool, "fault_injection", fault_injection);
    options.addOption([]const u8, "tools_json", @embedFile("contracts/tools.json"));
    const contract_digest = contractDigest();
    options.addOption([]const u8, "contract_digest", &contract_digest);
    options.addOption([]const u8, "repo_root", b.build_root.path orelse ".");
    const options_module = options.createModule();

    const core = b.addModule("zcr_core", .{
        .root_source_file = b.path("src/core/types.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zcr = b.addExecutable(.{
        .name = "zcr",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zcr_core", .module = core },
                .{ .name = "build_options", .module = options_module },
            },
        }),
    });
    b.installArtifact(zcr);

    const run_zcr = b.addRunArtifact(zcr);
    if (b.args) |args| run_zcr.addArgs(args);
    b.step("run", "Run zcr with arguments after --").dependOn(&run_zcr.step);

    const evidence_module = b.createModule(.{
        .root_source_file = b.path("tools/dev/evidence.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zcr_core", .module = core }},
    });
    const evidence_tool = b.addExecutable(.{ .name = "zcr-dev-evidence", .root_module = evidence_module });
    b.installArtifact(evidence_tool);

    // T02: capability, path and task-scope checks (I01).
    const policy_module = b.createModule(.{
        .root_source_file = b.path("src/policy/capability.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zcr_core", .module = core }},
    });
    // T02: development scope and ownership guard.
    const guard_module = b.createModule(.{
        .root_source_file = b.path("tools/dev/guard.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zcr_core", .module = core },
            .{ .name = "evidence", .module = evidence_module },
        },
    });
    // T03: budgets, reservation-bound allocation, request arenas, accounting.
    const memory_module = b.createModule(.{
        .root_source_file = b.path("src/memory/budget.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = target.result.os.tag.isDarwin(),
        .imports = &.{.{ .name = "zcr_core", .module = core }},
    });
    // T03: admission control in front of the in-flight budget (I02).
    const admission_module = b.createModule(.{
        .root_source_file = b.path("src/scheduler/admission.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zcr_core", .module = core },
            .{ .name = "zcr_memory", .module = memory_module },
        },
    });
    // T04: bounded, handle-relative range reads (I03).
    const fs_read_module = b.createModule(.{
        .root_source_file = b.path("src/fs/read.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zcr_core", .module = core },
            .{ .name = "zcr_policy", .module = policy_module },
            .{ .name = "zcr_memory", .module = memory_module },
        },
    });
    // T05: Git-aware streaming traversal with ignore rules (I04).
    const fs_traverse_module = b.createModule(.{
        .root_source_file = b.path("src/fs/traverse.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zcr_core", .module = core },
            .{ .name = "zcr_policy", .module = policy_module },
        },
    });
    // T06: scalar literal search with context projection (I05).
    const search_module = b.createModule(.{
        .root_source_file = b.path("src/search/literal.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zcr_core", .module = core },
            .{ .name = "zcr_policy", .module = policy_module },
            .{ .name = "zcr_fs_read", .module = fs_read_module },
            .{ .name = "zcr_fs_traverse", .module = fs_traverse_module },
        },
    });
    // T07: batch read (I06) and the common compact output projection.
    const batch_module = b.createModule(.{
        .root_source_file = b.path("src/batch/read.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zcr_core", .module = core },
            .{ .name = "zcr_policy", .module = policy_module },
            .{ .name = "zcr_memory", .module = memory_module },
            .{ .name = "zcr_admission", .module = admission_module },
            .{ .name = "zcr_fs_read", .module = fs_read_module },
        },
    });
    const projection_module = b.createModule(.{
        .root_source_file = b.path("src/protocol/projection.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zcr_core", .module = core },
        },
    });
    const mcp_module = b.createModule(.{
        .root_source_file = b.path("src/protocol/mcp.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zcr_core", .module = core },
            .{ .name = "zcr_policy", .module = policy_module },
            .{ .name = "zcr_memory", .module = memory_module },
            .{ .name = "zcr_admission", .module = admission_module },
            .{ .name = "zcr_fs_read", .module = fs_read_module },
            .{ .name = "zcr_fs_traverse", .module = fs_traverse_module },
            .{ .name = "zcr_search", .module = search_module },
            .{ .name = "zcr_batch_read", .module = batch_module },
            .{ .name = "zcr_projection", .module = projection_module },
        },
    });
    const queue_module = b.createModule(.{
        .root_source_file = b.path("src/scheduler/queue.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zcr_core", .module = core }},
    });
    const darwin_module = b.createModule(.{
        .root_source_file = b.path("src/platform/darwin.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "zcr_core", .module = core }},
    });
    const executor_module = b.createModule(.{
        .root_source_file = b.path("src/scheduler/executor.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zcr_core", .module = core },
            .{ .name = "zcr_memory", .module = memory_module },
            .{ .name = "zcr_admission", .module = admission_module },
            .{ .name = "zcr_queue", .module = queue_module },
            .{ .name = "zcr_darwin", .module = darwin_module },
        },
    });
    if (target.result.os.tag == .macos and sourceExists(b, "c/darwin_shim.c")) {
        darwin_module.addCSourceFile(.{ .file = b.path("c/darwin_shim.c") });
        darwin_module.addIncludePath(b.path("c"));
    }
    const workspace_module = b.createModule(.{
        .root_source_file = b.path("src/workspace/registry.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zcr_core", .module = core },
            .{ .name = "zcr_policy", .module = policy_module },
        },
    });
    const edit_module = b.createModule(.{
        .root_source_file = b.path("src/fs/edit.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zcr_core", .module = core },
            .{ .name = "zcr_policy", .module = policy_module },
            .{ .name = "zcr_memory", .module = memory_module },
            .{ .name = "zcr_fs_read", .module = fs_read_module },
            .{ .name = "zcr_workspace", .module = workspace_module },
        },
    });
    const storage_module = b.createModule(.{
        .root_source_file = b.path("src/storage/journal.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zcr_core", .module = core },
            .{ .name = "zcr_policy", .module = policy_module },
            .{ .name = "zcr_memory", .module = memory_module },
            .{ .name = "zcr_workspace", .module = workspace_module },
            .{ .name = "zcr_fs_read", .module = fs_read_module },
        },
    });
    const cache_module = b.createModule(.{
        .root_source_file = b.path("src/cache/content.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zcr_core", .module = core },
            .{ .name = "zcr_policy", .module = policy_module },
            .{ .name = "zcr_memory", .module = memory_module },
            .{ .name = "zcr_workspace", .module = workspace_module },
        },
    });
    mcp_module.addImport("zcr_cache", cache_module);
    fs_read_module.addImport("zcr_cache", cache_module);
    const watch_module = b.createModule(.{
        .root_source_file = b.path("src/watch/core.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zcr_core", .module = core },
            .{ .name = "zcr_policy", .module = policy_module },
            .{ .name = "zcr_memory", .module = memory_module },
            .{ .name = "zcr_workspace", .module = workspace_module },
            .{ .name = "zcr_cache", .module = cache_module },
            .{ .name = "zcr_fs_traverse", .module = fs_traverse_module },
        },
    });
    if (target.result.os.tag == .macos) {
        watch_module.linkFramework("CoreServices", .{});
        watch_module.linkFramework("CoreFoundation", .{});
    }
    const broker_module = b.createModule(.{
        .root_source_file = b.path("src/broker/server.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zcr_core", .module = core },
            .{ .name = "zcr_policy", .module = policy_module },
            .{ .name = "zcr_memory", .module = memory_module },
            .{ .name = "zcr_workspace", .module = workspace_module },
            .{ .name = "zcr_cache", .module = cache_module },
            .{ .name = "zcr_executor", .module = executor_module },
            .{ .name = "zcr_mcp", .module = mcp_module },
        },
    });
    const launch_module = b.createModule(.{
        .root_source_file = b.path("src/launch.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zcr_core", .module = core },
            .{ .name = "zcr_policy", .module = policy_module },
            .{ .name = "zcr_memory", .module = memory_module },
            .{ .name = "zcr_workspace", .module = workspace_module },
            .{ .name = "zcr_mcp", .module = mcp_module },
            .{ .name = "zcr_fs_read", .module = fs_read_module },
            .{ .name = "build_options", .module = options_module },
        },
    });
    launch_module.addImport("zcr_cache", cache_module);
    zcr.root_module.addImport("zcr_launch", launch_module);
    // A tool is installed once its owning task has delivered the source file.
    if (sourceExists(b, "tools/dev/guard.zig")) {
        b.installArtifact(b.addExecutable(.{ .name = "zcr-dev-guard", .root_module = guard_module }));
    }

    const verify_contracts = b.addRunArtifact(evidence_tool);
    verify_contracts.addArgs(&.{ "verify-contracts", "--root" });
    verify_contracts.addDirectoryArg(b.path("."));
    verify_contracts.has_side_effects = true;
    verify_contracts.expectExitCode(0);
    b.step("verify-contracts", "Check core declarations against contracts/ and config/").dependOn(&verify_contracts.step);

    const bench_step = b.step("bench", "Run benchmarks (-Dcorpus, -Dvariant); harness is owned by T21");
    bench_step.dependOn(&b.addFail(b.fmt(
        "bench harness is not implemented yet (T21); corpus={s} variant={s}",
        .{ bench_corpus orelse "-", bench_variant orelse "-" },
    )).step);

    const test_step = b.step("test", "Run registered tests (-Dtest-group, -Dtest-id, -Dfault-injection)");
    var caps_module: ?*std.Build.Module = null;
    var selected: usize = 0;

    for (test_files) |file| {
        if (test_group) |group| if (group != file.group) continue;
        if (!sourceExists(b, file.path)) {
            test_step.dependOn(&b.addFail(b.fmt("registered test file {s} is missing ({s} not delivered yet)", .{ file.path, file.task })).step);
            selected += 1;
            continue;
        }
        if (test_id) |id| if (!declaresTest(b, file.path, id)) continue;
        selected += 1;

        const module = b.createModule(.{
            .root_source_file = b.path(file.path),
            .target = target,
            .optimize = optimize,
            // POSIX fixtures call mkfifo/open/chmod on Linux as well as Darwin.
            .link_libc = target.result.os.tag != .windows,
        });
        for (file.imports) |import| switch (import) {
            .core => module.addImport("zcr_core", core),
            .evidence => module.addImport("evidence", evidence_module),
            .build_options => module.addImport("build_options", options_module),
            .policy => module.addImport("zcr_policy", policy_module),
            .guard => module.addImport("dev_guard", guard_module),
            .memory => module.addImport("zcr_memory", memory_module),
            .admission => module.addImport("zcr_admission", admission_module),
            .fs_read => module.addImport("zcr_fs_read", fs_read_module),
            .fs_traverse => module.addImport("zcr_fs_traverse", fs_traverse_module),
            .search => module.addImport("zcr_search", search_module),
            .batch => module.addImport("zcr_batch", batch_module),
            .projection => module.addImport("zcr_projection", projection_module),
            .mcp => module.addImport("zcr_mcp", mcp_module),
            .executor => module.addImport("zcr_executor", executor_module),
            .workspace => module.addImport("zcr_workspace", workspace_module),
            .queue => module.addImport("zcr_queue", queue_module),
            .darwin => module.addImport("zcr_darwin", darwin_module),
            .launch => module.addImport("zcr_launch", launch_module),
            .watch => module.addImport("zcr_watch", watch_module),
            .broker => module.addImport("zcr_broker", broker_module),
            .edit => module.addImport("zcr_fs_edit", edit_module),
            .cache => module.addImport("zcr_cache", cache_module),
            .storage => module.addImport("zcr_storage", storage_module),
            .caps => module.addImport("caps", caps_module orelse blk: {
                caps_module = capsModule(b, target, optimize);
                break :blk caps_module.?;
            }),
        };

        if (std.mem.eql(u8, file.task, "T12")) {
            // Separate real exec image: builtin.is_test preserves the production
            // write gate, and child declarations never run in the parent suite.
            const child_module = b.createModule(.{
                .root_source_file = b.path("tests/t12_child.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "zcr_core", .module = core },
                    .{ .name = "zcr_policy", .module = policy_module },
                    .{ .name = "zcr_memory", .module = memory_module },
                    .{ .name = "zcr_workspace", .module = workspace_module },
                    .{ .name = "zcr_fs_read", .module = fs_read_module },
                    .{ .name = "zcr_fs_edit", .module = edit_module },
                    .{ .name = "zcr_storage", .module = storage_module },
                    .{ .name = "build_options", .module = options_module },
                },
            });
            const child = b.addTest(.{ .name = "T12-child", .root_module = child_module });
            const child_options = b.addOptions();
            child_options.addOptionPath("child_exe", child.getEmittedBin());
            module.addOptions("t12_options", child_options);
            if (install_tests) test_step.dependOn(&b.addInstallArtifact(child, .{}).step);
        }

        const test_artifact = b.addTest(.{
            .name = b.fmt("{s}-test", .{file.task}),
            .root_module = module,
            .filters = if (test_id) |id| b.dupeStrings(&.{id}) else &.{},
        });
        if (install_tests) test_step.dependOn(&b.addInstallArtifact(test_artifact, .{}).step);
        const run_tests = b.addRunArtifact(test_artifact);
        // std.testing.tmpDir writes under the cwd; keep fixtures out of the source tree.
        run_tests.setCwd(.{ .cwd_relative = b.cache_root.path orelse ".zig-cache" });
        run_tests.has_side_effects = true;
        test_step.dependOn(&run_tests.step);
    }

    // CLI contract checks for the dev group.
    if (test_id == null and (test_group == null or test_group.? == .dev)) {
        const version = b.addRunArtifact(zcr);
        version.addArg("--version");
        version.expectStdOutEqual(b.fmt("zcr {s} schema=zcr/1 zig={s}\n", .{ manifest.version, builtin.zig_version_string }));
        version.has_side_effects = true;
        test_step.dependOn(&version.step);

        const unavailable = b.addRunArtifact(zcr);
        unavailable.addArg("mcp");
        unavailable.expectExitCode(64);
        unavailable.expectStdErrEqual("zcr: mcp requires --standalone --policy /absolute/approved-policy.json\n");
        unavailable.has_side_effects = true;
        test_step.dependOn(&unavailable.step);
        selected += 1;
    }

    if (selected == 0) {
        test_step.dependOn(&b.addFail(b.fmt(
            "no registered tests match test-group={s} test-id={s}; an empty selection is not a pass",
            .{ if (test_group) |g| @tagName(g) else "-", test_id orelse "-" },
        )).step);
    }
}

fn sourceExists(b: *std.Build, path: []const u8) bool {
    b.build_root.handle.access(b.graph.io, path, .{}) catch return false;
    return true;
}

/// True when the test file declares a test whose name contains `id`.
fn declaresTest(b: *std.Build, path: []const u8, id: []const u8) bool {
    const source = b.build_root.handle.readFileAlloc(b.graph.io, path, b.allocator, .limited(16 * 1024 * 1024)) catch |err| {
        std.debug.panic("cannot read registered test file {s}: {t}", .{ path, err });
    };
    var rest = source;
    while (std.mem.indexOf(u8, rest, "test \"")) |start| {
        const name_start = start + "test \"".len;
        const name_end = std.mem.indexOfScalarPos(u8, rest, name_start, '"') orelse return false;
        if (std.mem.indexOf(u8, rest[name_start..name_end], id) != null) return true;
        rest = rest[name_end..];
    }
    return false;
}

/// T00 platform probe module; the Darwin C ABI probes are linked only for macOS targets.
fn capsModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("bench/spikes/caps.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (target.result.os.tag == .macos) {
        module.addCSourceFile(.{ .file = b.path("bench/spikes/darwin_abi.c") });
        module.linkFramework("Foundation", .{});
        module.linkFramework("IOKit", .{});
        module.linkFramework("CoreFoundation", .{});
    }
    return module;
}

/// Same sorted sha256sum-of-sha256sum contract fingerprint used by zcr-dev-evidence.
fn contractDigest() [64]u8 {
    var total = std.crypto.hash.sha2.Sha256.init(.{});
    inline for (.{
        "contracts/README.md",
        "contracts/data.schema.json",
        "contracts/inputs/zcr_batch_read.schema.json",
        "contracts/inputs/zcr_create.schema.json",
        "contracts/inputs/zcr_files.schema.json",
        "contracts/inputs/zcr_health.schema.json",
        "contracts/inputs/zcr_patch.schema.json",
        "contracts/inputs/zcr_read.schema.json",
        "contracts/inputs/zcr_search.schema.json",
        "contracts/inputs/zcr_status.schema.json",
        "contracts/response.schema.json",
        "contracts/task-manifest.schema.json",
        "contracts/tools.json",
    }) |path| {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(@embedFile(path), &digest, .{});
        total.update(&std.fmt.bytesToHex(digest, .lower));
        total.update("  ");
        total.update(path);
        total.update("\n");
    }
    return std.fmt.bytesToHex(total.finalResult(), .lower);
}
