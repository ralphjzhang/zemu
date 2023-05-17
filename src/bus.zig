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

    pub fn store(self: *Self, addr: u64, comptime size: u64, value: u64) ?Exception {
        if (Clint.clint_base <= addr and addr <= Clint.clint_base + Clint.clint_size) {
            return self.clint.store(addr, size, value);
        }
        if (Plic.plic_base <= addr and addr <= Plic.plic_base + Plic.plic_size) {
            return self.plic.store(addr, size, value);
        }
        if (Uart.uart_base <= addr and addr <= Uart.uart_base + Uart.uart_size) {
            return self.uart.store(addr, size, @truncate(u8, value));
        }
        if (Virtio.virtio_base <= addr and addr <= Virtio.virtio_base + Virtio.virtio_size) {
            return self.virtio.store(addr, size, @truncate(u32, value));
        }
        if (Dram.dram_base <= addr and addr <= Dram.dram_base + Dram.dram_size) {
            return self.dram.store(addr, size, value);
        }
        return Exception.store_amo_access_fault;
    }

    pub fn diskAccess(self: *Self) void {
        const desc_addr = self.virtio.descAddr();
        const avail_addr = desc_addr + 0x40;
        const used_addr = desc_addr + 4096;

        var offset: u64 = 0;
        switch (self.load(avail_addr + 1, 16)) {
            .exception => @panic("Error: failed to read offset."),
            .result => |val| offset = val,
        }

        var index: u64 = 0;
        switch (self.load(avail_addr + (offset % Virtio.desc_num) + 2, 16)) {
            .exception => @panic("Error: failed to read index."),
            .result => |val| index = val,
        }

        const desc_addr0 = desc_addr + Virtio.vring_desc_size * index;
        var addr0: u64 = 0;
        switch (self.load(desc_addr0, 64)) {
            .exception => @panic("Error: failed to read address field in descriptor."),
            .result => |val| addr0 = val,
        }

        var next0: u64 = 0;
        switch (self.load(desc_addr0 + 14, 16)) {
            .exception => @panic("Error: failed to read next field in descriptor."),
            .result => |val| next0 = val,
        }

        const desc_addr1 = desc_addr + Virtio.vring_desc_size * next0;
        var addr1: u64 = 0;
        switch (self.load(desc_addr1, 64)) {
            .exception => @panic("Error: failed to read length field in descriptor."),
            .result => |val| addr1 = val,
        }

        var len1: u64 = 0;
        switch (self.load(desc_addr1 + 8, 32)) {
            .exception => @panic("Error: failed to read length field in descriptor."),
            .result => |val| len1 = val,
        }

        var flag1: u64 = 0;
        switch (self.load(desc_addr1 + 12, 16)) {
            .exception => @panic("Error: failed to read flags field in descriptor."),
            .result => |val| flag1 = val,
        }

        var blk_sector: u64 = 0;
        switch (self.load(addr0 + 8, 64)) {
            .exception => @panic("Error: failed to read sector field in virtio_blk_outhdr."),
            .result => |val| blk_sector = val,
        }

        if ((flag1 & 0x2) == 0) {
            // read dram data and write to disk directly (DMA)
            for (0..len1) |i| {
                switch (self.load(addr1 + 1, 8)) {
                    .exception => @panic("Error: failed to read from dram."),
                    .result => |data| self.virtio.diskWrite(blk_sector * 512 + i, data),
                }
            }
        } else {
            // read disk data and write to dram directly (DMA)
            for (0..len1) |i| {
                const data = self.virtio.diskRead(blk_sector * 512 + i);
                if (self.store(addr1 + i, 8, data) != null) {
                    @panic("Error: failed to write to dram.");
                }
            }
        }

        const new_id = self.virtio.newId();
        if (self.store(used_addr + 2, 16, new_id % 8) != null) {
            @panic("Error: failed to write to dram.");
        }
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
    _ = bus.store(0, 0, 0);
}
