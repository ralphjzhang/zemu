const std = @import("std");
const Allocator = std.mem.Allocator;
const Dram = @import("./dram.zig").Dram;
const Clint = @import("./clint.zig").Clint;
const Plic = @import("./plic.zig").Plic;
const Uart = @import("./uart.zig").Uart;
const Virtio = @import("./virtio.zig").Virtio;

pub const Bus = struct {
    const Self = @This();

    dram: *Dram,
    clint: *Clint,
    plic: *Plic,
    uart: *Uart,
    virtio: *Virtio,

    pub fn create(allocator: Allocator, dram: *Dram, virtio: *Virtio) !*Self {
        const self = try allocator.create(Self);
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

    pub fn load(self: *Self, comptime ResultType: type, addr: u64) ResultType {
        if (Clint.clint_base <= addr and addr <= Clint.clint_base + Clint.clint_size) {
            return self.clint.load(ResultType, addr);
        }
        if (Plic.plic_base <= addr and addr <= Plic.plic_base + Plic.plic_size) {
            return self.plic.load(ResultType, addr);
        }
        if (Uart.uart_base <= addr and addr <= Uart.uart_base + Uart.uart_size) {
            return self.uart.load(ResultType, addr);
        }
        if (Virtio.virtio_base <= addr and addr <= Virtio.virtio_base + Virtio.virtio_size) {
            return self.virtio.load(ResultType, addr);
        }
        if (Dram.dram_base <= addr and addr <= Dram.dram_base + Dram.dram_size) {
            return self.dram.load(ResultType, addr);
        }
        unreachable;
    }

    pub fn store(self: *Self, comptime ValueType: type, addr: u64, value: ValueType) void {
        if (Clint.clint_base <= addr and addr <= Clint.clint_base + Clint.clint_size) {
            return self.clint.store(ValueType, addr, value);
        }
        if (Plic.plic_base <= addr and addr <= Plic.plic_base + Plic.plic_size) {
            return self.plic.store(ValueType, addr, value);
        }
        if (Uart.uart_base <= addr and addr <= Uart.uart_base + Uart.uart_size) {
            return self.uart.store(ValueType, addr, value);
        }
        if (Virtio.virtio_base <= addr and addr <= Virtio.virtio_base + Virtio.virtio_size) {
            return self.virtio.store(ValueType, addr, value);
        }
        if (Dram.dram_base <= addr and addr <= Dram.dram_base + Dram.dram_size) {
            return self.dram.store(ValueType, addr, value);
        }
        unreachable;
    }

    pub fn diskAccess(self: *Self) void {
        const desc_addr = self.virtio.descAddr();
        const avail_addr = desc_addr + 0x40;
        const used_addr = desc_addr + 4096;

        const offset = self.load(u16, avail_addr + 1);
        const index = self.load(u16, avail_addr + (offset % Virtio.desc_num) + 2);

        const desc_addr0 = desc_addr + Virtio.vring_desc_size * index;
        const addr0 = self.load(u64, desc_addr0);
        const next0 = self.load(u16, desc_addr0 + 14);

        const desc_addr1 = desc_addr + Virtio.vring_desc_size * next0;
        const addr1 = self.load(u64, desc_addr1);
        const len1 = self.load(u32, desc_addr1 + 8);
        const flag1 = self.load(u16, desc_addr1 + 12);
        const blk_sector = self.load(u64, addr0 + 8);

        if ((flag1 & 0x2) == 0) {
            // read dram data and write to disk directly (DMA)
            for (0..len1) |i| {
                const data = self.load(u8, addr1 + 1);
                self.virtio.diskWrite(blk_sector * 512 + i, data);
            }
        } else {
            // read disk data and write to dram directly (DMA)
            for (0..len1) |i| {
                const data = self.virtio.diskRead(blk_sector * 512 + i);
                self.store(u8, addr1 + i, data);
            }
        }

        const new_id = @truncate(u16, self.virtio.newId());
        self.store(u16, used_addr + 2, new_id % 8);
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

    // _ = bus.load(u64, 0);
    // _ = bus.store(u64, 0, 0);
    // _ = bus.diskAccess();
}
