const std = @import("std");
const Allocator = std.mem.Allocator;
const Cpu = @import("./cpu.zig").Cpu;
const Csr = @import("./cpu.zig").Csr;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 2 and args.len != 3) {
        std.debug.print("Usage: zemu <filename> [<image>]\n", .{});
        std.os.exit(1);
    }

    var binary = try readFile(allocator, args[1]);
    defer allocator.free(binary);
    var image: []u8 = if (args.len == 3) try readFile(allocator, args[2]) else "";
    defer if (image.len > 0) allocator.free(image);

    try runBinary(allocator, binary, image);
}

fn runBinary(allocator: Allocator, binary: []u8, disk: []u8) !void {
    var cpu = try Cpu.create(allocator, binary, disk);
    defer cpu.destroy(allocator);

    while (true) {
        switch (cpu.fetch()) {
            .exception => |exception| {
                cpu.takeTrap(exception, null);
                if (exception.isFatal()) break;
            },
            .instruction => |inst| {
                debugCpu(cpu, inst);
                cpu.pc += 4;
                if (cpu.execute(inst)) |exception| {
                    cpu.takeTrap(exception, null);
                    if (exception.isFatal()) break;
                }
                if (cpu.checkPendingInterrupt()) |interrupt| {
                    cpu.takeTrap(null, interrupt);
                }
            },
        }
    }

    cpu.dumpRegisters();
    std.debug.print("------------------------------------------------------------------------------\n", .{});
    cpu.dumpCsrs();
}

fn debugCpu(cpu: *Cpu, inst: u32) void {
    // std.debug.print("pc=0x{x}, ra=0x{x}, sp=0x{x}, mode={}\n", .{
    if (inst == 0x6f) return; // so that j loop won't flush screen
    std.debug.print("pc=0x{x}, inst=0x{x}, ra=0x{x}, sp=0x{x}, a0=0x{x}, s0=0x{x}, s1=0x{x}\n", .{
        cpu.pc,
        inst,
        cpu.regs[1],
        cpu.regs[2],
        cpu.regs[10],
        cpu.regs[8],
        cpu.regs[9],
        // cpu.mode,
    });
}

fn readFile(allocator: Allocator, filename: []u8) ![]u8 {
    var file = try std.fs.cwd().openFile(filename, .{});
    const file_size = try file.getEndPos();
    var buf = try allocator.alloc(u8, file_size);
    _ = try file.read(buf);
    return buf;
}
