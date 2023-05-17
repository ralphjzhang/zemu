const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("./common.zig");
const Exception = common.Exception;
const Result = common.Result;
const Dram = @import("./dram.zig").Dram;
const Clint = @import("./clint.zig").Clint;
const Plic = @import("./plic.zig").Plic;
const Uart = @import("./uart.zig").Uart;
const Virtio = @import("./virtio.zig").Virtio;

const Bus = struct {
    const Self = @This();

    dram: *Dram,
    clint: *Clint,
    plic: *Plic,
    uart: *Uart,
    virtio: *Virtio,

    pub fn create(allocator: Allocator, dram: *Dram, virtio: *Virtio) !*Self {
        var self = try allocator.create(Self);
        self.dram = dram;
        self.virtio = virtio;
        self.clint = try Clint.create(allocator);
        self.plic = try Plic.create(allocator);
        self.uart = try Uart.create(allocator);
        return self;
    }

    pub fn destroy(self: *Self, allocator: Allocator) void {
        self.dram.destroy(allocator);
        self.virtio.destroy(allocator);
        self.clint.destroy(allocator);
        self.plic.destroy(allocator);
        self.uart.destroy(allocator);
        allocator.destroy(self);
    }

    pub fn load(self: *Self, addr: u64, comptime size: u64) Result {
        if (Clint.clint_base <= addr and addr <= Clint.clint_base + Clint.clint_size) {
            return self.clint.load(addr, size);
        }
        if (Plic.plic_base <= addr and addr <= Plic.plic_base + Plic.plic_size) {
            return self.plic.load(addr, size);
        }
        if (Uart.uart_base <= addr and addr <= Uart.uart_base + Uart.uart_size) {
            return self.uart.load(addr, size);
        }
        if (Virtio.virtio_base <= addr and addr <= Virtio.virtio_base + Virtio.virtio_size) {
            return self.virtio.load(addr, size);
        }
        if (Dram.dram_base <= addr and addr <= Dram.dram_base + Dram.dram_size) {
            return self.dram.load(addr, size);
        }
        return .{ .exception = Exception.load_access_fault };
    }

    pub fn store(self: *Self, addr: u64, size: u64, comptime value: u64) Exception {
        if (Clint.clint_base <= addr and addr <= Clint.clint_base + Clint.clint_size) {
            return self.clint.store(addr, size, value);
        }
        if (Plic.plic_base <= addr and addr <= Plic.plic_base + Plic.plic_size) {
            return self.plic.store(addr, size, value);
        }
        if (Uart.uart_base <= addr and addr <= Uart.uart_base + Uart.uart_size) {
            return self.uart.store(addr, size, value);
        }
        if (Virtio.virtio_base <= addr and addr <= Virtio.virtio_base + Virtio.virtio_size) {
            return self.virtio.store(addr, size, value);
        }
        if (Dram.dram_base <= addr and addr <= Dram.dram_base + Dram.dram_size) {
            return self.dram.store(addr, size, value);
        }
        return Exception.store_amo_access_fault;
    }
};

test "bus" {
    const allocator = std.testing.allocator;
    const expect = std.testing.expect;
    _ = expect;

    var code = [_]u8{0};
    var disk = [_]u8{0};
    var dram = try Dram.create(allocator, &code);
    var virtio = try Virtio.create(allocator, &disk);
    var bus = try Bus.create(allocator, dram, virtio);
    defer bus.destroy(allocator);

    _ = bus.load(0, 0);
}
