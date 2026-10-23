const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .thumb,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m4 },
        .cpu_features_add = std.Target.arm.featureSet(&.{.vfp4d16sp}),
        .os_tag = .freestanding,
        .abi = .eabihf,
    });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });

    const obj = b.addObject(.{
        .name = "ztm32",
        .root_module = b.createModule(.{
            .optimize = optimize,
            .target = target,
            .root_source_file = b.path("src/main.zig"),
        }),
    });

    const ld_cmd = b.addSystemCommand(&.{ "arm-none-eabi-ld", "-T", "flash.ld", "-o" });
    const elf_file = ld_cmd.addOutputFileArg("ztm32.elf");
    ld_cmd.addArtifactArg(obj);

    const objcopy_cmd = b.addSystemCommand(&.{ "arm-none-eabi-objcopy", "-O", "binary" });
    objcopy_cmd.addFileArg(elf_file);
    const bin_file = objcopy_cmd.addOutputFileArg("ztm32.bin");

    const install_bin = b.addInstallFile(bin_file, "ztm32.bin");
    b.getInstallStep().dependOn(&install_bin.step);
}
