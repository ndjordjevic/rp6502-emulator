const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "rp6502-emulator",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // vrEmu6502 C library (vendored); W65C02 model for RP6502
    exe.root_module.addIncludePath(b.path("vendor/vrEmu6502"));
    exe.root_module.addCSourceFile(.{
        .file = b.path("vendor/vrEmu6502/vrEmu6502.c"),
        .flags = &.{ "-DVR_EMU_6502_STATIC" },
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the RP6502 emulator");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run tests");
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addIncludePath(b.path("vendor/vrEmu6502"));
    tests.root_module.addCSourceFile(.{
        .file = b.path("vendor/vrEmu6502/vrEmu6502.c"),
        .flags = &.{ "-DVR_EMU_6502_STATIC" },
    });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
