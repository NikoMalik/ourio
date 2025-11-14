const std = @import("std");
const linux = std.os.linux;

const Module = std.Build.Module;
const Target = std.Build.ResolvedTarget;
const OptimizeMode = std.builtin.OptimizeMode;

fn supportedFlags() u32 {
    // clamp is supported by all kernels that have io_uring
    var flags: u32 = linux.IORING_SETUP_CLAMP;

    var utsname: linux.utsname = undefined;
    switch (linux.E.init(linux.uname(&utsname))) {
        .SUCCESS => {},
        else => return flags,
    }

    const release = if (std.mem.indexOfScalar(u8, &utsname.release, '-')) |idx|
        utsname.release[0..idx]
    else
        &utsname.release;
    const version = std.SemanticVersion.parse(release) catch return flags;
    switch (version.order(.{ .major = 5, .minor = 18, .patch = 0 })) {
        .lt => return flags,
        else => flags |= linux.IORING_SETUP_SUBMIT_ALL,
    }

    switch (version.order(.{ .major = 5, .minor = 19, .patch = 0 })) {
        .lt => return flags,
        else => flags |= linux.IORING_SETUP_COOP_TASKRUN,
    }

    switch (version.order(.{ .major = 6, .minor = 0, .patch = 0 })) {
        .lt => return flags,
        else => flags |= linux.IORING_SETUP_SINGLE_ISSUER,
    }

    switch (version.order(.{ .major = 6, .minor = 1, .patch = 0 })) {
        .lt => return flags,
        else => flags |= linux.IORING_SETUP_DEFER_TASKRUN,
    }

    return flags;
}

fn generateConfig(
    b: *std.Build,
    opt: std.builtin.OptimizeMode,
    target: std.Build.ResolvedTarget,
) *std.Build.Module {
    _ = opt;
    _ = target;

    const supported_io_uring_flags: u32 =
        supportedFlags();

    const config_content = std.fmt.allocPrint(
        b.allocator,
        \\const std = @import("std");
        \\pub const Config = struct {{
        \\    pub const supported_io_uring_flags: u32 = {};
        \\}};
    ,
        .{
            supported_io_uring_flags,
        },
    ) catch |err| {
        std.log.err("Failed to generate config.zig: {}", .{err});
        @panic("cannot create config file,try to restart");
    };

    const config_module = b.createModule(.{
        .root_source_file = b.addWriteFiles().add("config.zig", config_content),
    });
    return config_module;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const conf = generateConfig(b, optimize, target);
    const ourio_mod = b.addModule("ourio", .{
        .root_source_file = b.path("src/ourio.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "config", .module = conf },
        },
    });

    strip(ourio_mod);

    const stda_mod = setupStdaMod(b, target, optimize, ourio_mod);
    strip(stda_mod);

    const ourio_tests = b.addTest(.{ .root_module = ourio_mod });
    const stda_tests = b.addTest(.{ .root_module = stda_mod });

    const run_ourio_tests = b.addRunArtifact(ourio_tests);
    const run_stda_tests = b.addRunArtifact(stda_tests);
    run_ourio_tests.skip_foreign_checks = true;
    b.installArtifact(ourio_tests);

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_ourio_tests.step);
    test_step.dependOn(&run_stda_tests.step);

    const test_ourio_step = b.step("test-ourio", "Run ourio unit tests");
    test_ourio_step.dependOn(&run_ourio_tests.step);

    const install_step = b.getInstallStep();
    install_step.dependOn(test_step);
}

pub fn setupStdaMod(b: *std.Build, target: Target, optimize: OptimizeMode, ourio: *Module) *Module {
    const stda_mod = b.addModule("stda", .{
        .root_source_file = b.path("src/stda.zig"),
        .target = target,
        .optimize = optimize,
    });
    stda_mod.addImport("ourio", ourio);

    const tls_dep = b.dependency("tls", .{ .target = target, .optimize = optimize });
    stda_mod.addImport("tls", tls_dep.module("tls"));

    return stda_mod;
}

fn strip(root_module: *std.Build.Module) void {
    if (root_module.optimize != .Debug and root_module.optimize != .ReleaseSafe) {
        root_module.strip = true;
        root_module.omit_frame_pointer = true;
        root_module.unwind_tables = .none;
        root_module.sanitize_c = .off;
    } else {
        root_module.strip = false;
        root_module.omit_frame_pointer = false;
        root_module.unwind_tables = .sync;
        root_module.sanitize_c = .full;
    }
}

fn strip_step(step: *std.Build.Step.Compile) void {
    if (step.root_module.optimize != .Debug and step.root_module.optimize != .ReleaseSafe) {
        step.use_llvm = true;
        step.lto = .full;
        step.bundle_compiler_rt = true;
        step.pie = false;
        step.bundle_ubsan_rt = false;
        step.link_gc_sections = true;
        step.link_function_sections = true;
        step.link_data_sections = true;
        step.discard_local_symbols = true;

        step.compress_debug_sections = .none;
    } else {
        step.use_llvm = true;
    }
}
