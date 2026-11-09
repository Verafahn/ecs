const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("ecs", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_mod = b.addTest(.{ .root_module = mod });
    const run_test = b.addRunArtifact(test_mod);
    const test_step = b.step("test", "Test this module.");
    test_step.dependOn(&run_test.step);

    if (b.isRoot()) {
        {
            const exe = b.addExecutable(.{
                .name = "map",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("examples/map.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "ecs", .module = mod },
                    },
                }),
            });
            const run = b.addRunArtifact(exe);
            run.addPassthruArgs();
            const step = b.step("run-map", "Run example 'map.zig'");
            step.dependOn(&run.step);
        }
        {
            const exe = b.addExecutable(.{
                .name = "sparse_set",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("examples/sparse_set.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "ecs", .module = mod },
                    },
                }),
            });
            const run = b.addRunArtifact(exe);
            run.addPassthruArgs();
            const step = b.step("run-sparse_set", "Run example 'sparse_set.zig'");
            step.dependOn(&run.step);
        }
        {
            const exe = b.addExecutable(.{
                .name = "archetype",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("examples/archetype.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "ecs", .module = mod },
                    },
                }),
            });
            const run = b.addRunArtifact(exe);
            run.addPassthruArgs();
            const step = b.step("run-archetype", "Run example 'archetype.zig'");
            step.dependOn(&run.step);
        }
    }
}
