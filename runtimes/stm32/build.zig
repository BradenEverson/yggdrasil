const std = @import("std");

const Chip = enum { f446, u073 };

fn targetQuery(chip: Chip) std.Target.Query {
    return switch (chip) {
        .f446 => .{
            .cpu_arch = .thumb,
            .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m4 },
            .cpu_features_add = std.Target.arm.featureSet(&.{.vfp4d16sp}),
            .os_tag = .freestanding,
            .abi = .eabihf,
        },
        .u073 => .{
            .cpu_arch = .thumb,
            .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m0plus },
            .os_tag = .freestanding,
            .abi = .eabi,
        },
    };
}

fn linkerScript(chip: Chip) []const u8 {
    return switch (chip) {
        .f446 => "ld/f446.ld",
        .u073 => "ld/u073.ld",
    };
}

fn defaultQueueLength(chip: Chip) usize {
    return switch (chip) {
        .f446 => 8,
        .u073 => 4,
    };
}

pub fn build(b: *std.Build) void {
    const chip = b.option(Chip, "chip", "Target MCU") orelse .f446;
    const target = b.resolveTargetQuery(targetQuery(chip));
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });

    const obj = b.addObject(.{
        .name = "yggdrasil",
        .root_module = b.createModule(.{
            .optimize = optimize,
            .target = target,
            .root_source_file = b.path("src/main.zig"),
        }),
    });

    obj.bundle_compiler_rt = true;
    obj.link_function_sections = true;
    obj.link_data_sections = true;

    const yggdrasil = b.dependency("yggdrasil", .{
        .target = target,
        .optimize = optimize,
        .max_neighbors = b.option(usize, "max_neighbors", "Neighbor slots in the yggdrasil message queue") orelse 16,
        .max_queue_length = b.option(usize, "max_queue_length", "Queued packets per neighbor") orelse defaultQueueLength(chip),
    });

    obj.root_module.addImport("yggdrasil", yggdrasil.module("yggdrasil"));

    const node_config = b.addOptions();
    node_config.addOption(u8, "node_addr", b.option(u8, "node_addr", "Yggdrasil address of this node, 0-254") orelse 1);
    node_config.addOption(u32, "period_ms", b.option(u32, "period_ms", "Radio listen and send period in ms, multiple of 100") orelse 60_000);
    node_config.addOption(u32, "sample_ms", b.option(u32, "sample_ms", "Sensor sample interval in ms, multiple of 10000, readings are batched and sent once per period") orelse 60_000);
    node_config.addOption(u4, "sf", b.option(u4, "sf", "LoRa spreading factor 7-12, must match the whole network") orelse 7);
    node_config.addOption(u32, "bw", b.option(u32, "bw", "LoRa bandwidth in Hz, must match the whole network") orelse 125_000);
    node_config.addOption(u3, "cr", b.option(u3, "cr", "LoRa coding rate 1-4, must match the whole network") orelse 1);
    node_config.addOption(u8, "preamble", b.option(u8, "preamble", "LoRa programmed preamble 4-7") orelse 4);
    node_config.addOption(u4, "tx_power", b.option(u4, "tx_power", "RF output power in dBm 0-15") orelse 15);
    node_config.addOption(u8, "beacon_periods", b.option(u8, "beacon_periods", "Periods between root beacons from joined nodes, also sets the join scan length, must match the whole network") orelse 1);
    node_config.addOption(u32, "radio_wake_ms", b.option(u32, "radio_wake_ms", "Lead time to wake the radio before a window") orelse 200);
    node_config.addOption(bool, "log", b.option(bool, "log", "Print debug output on the board debug UART") orelse true);
    node_config.addOption(bool, "radio_sleep", b.option(bool, "radio_sleep", "Put the radio and MCU to sleep between windows") orelse true);
    node_config.addOption(bool, "trace", b.option(bool, "trace", "Log every frame sent and received") orelse false);
    node_config.addOption(bool, "swd", b.option(bool, "swd", "Keep the SWD pins active") orelse true);
    obj.root_module.addOptions("node_config", node_config);

    const target_config = b.addOptions();
    target_config.addOption(Chip, "chip", chip);
    obj.root_module.addOptions("target", target_config);

    const ld_cmd = b.addSystemCommand(&.{ "arm-none-eabi-ld", "--gc-sections", "-T" });
    ld_cmd.addFileArg(b.path(linkerScript(chip)));
    ld_cmd.addArg("-o");
    const elf_file = ld_cmd.addOutputFileArg("yggdrasil.elf");
    ld_cmd.addArtifactArg(obj);

    const objcopy_cmd = b.addSystemCommand(&.{ "arm-none-eabi-objcopy", "-O", "binary" });
    objcopy_cmd.addFileArg(elf_file);
    const bin_file = objcopy_cmd.addOutputFileArg("yggdrasil.bin");

    const install_bin = b.addInstallFile(bin_file, "yggdrasil.bin");
    b.getInstallStep().dependOn(&install_bin.step);

    const programmer: std.Build.LazyPath = if (b.option([]const u8, "programmer", "Path to STM32_Programmer_CLI")) |path|
        .{ .cwd_relative = path }
    else
        b.findProgramLazy(.{ .names = &.{
            "STM32_Programmer_CLI",
            b.pathJoin(&.{ b.graph.environ_map.get("HOME") orelse "/root", "STMicroelectronics/STM32Cube/STM32CubeProgrammer/bin/STM32_Programmer_CLI" }),
            "/opt/st/stm32cubeprogrammer/bin/STM32_Programmer_CLI",
        } });

    const flash_cmd = std.Build.Step.Run.create(b, "flash");
    flash_cmd.addFileArg(programmer);
    flash_cmd.addArgs(&.{ "-c", b.fmt("port={s}", .{b.option([]const u8, "port", "Programmer port, e.g. SWD or /dev/ttyACM0") orelse "SWD"}), "-w" });
    flash_cmd.addFileArg(bin_file);
    flash_cmd.addArgs(&.{ "0x08000000", "-v", "-rst" });
    flash_cmd.has_side_effects = true;
    flash_cmd.step.dependOn(&install_bin.step);

    const flash_step = b.step("flash", "Build and flash with STM32_Programmer_CLI");
    flash_step.dependOn(&flash_cmd.step);
}
