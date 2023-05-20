const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Plic = struct {
    const Self = @This();
    pub const plic_base = 0xc000000;
    pub const plic_size = 0x4000000;
    const pending_addr = plic_base + 0x1000;
    const senable_addr = plic_base + 0x2000;
    const spriority_addr = plic_base + 0x201000;
    const sclaim_addr = plic_base + 0x201004;

    pending: u64,
    senable: u64,
    spriority: u64,
    sclaim: u64,

    pub fn create(allocator: Allocator) !*Self {
        return try allocator.create(Self);
    }
    pub fn destroy(self: *Self, allocator: Allocator) void {
        allocator.destroy(self);
    }

    pub fn load(self: *Self, comptime ResultType: type, addr: u64) ResultType {
        return switch (ResultType) {
            u32 => @truncate(u32, switch (addr) {
                pending_addr => self.pending,
                senable_addr => self.senable,
                spriority_addr => self.spriority,
                sclaim_addr => self.sclaim,
                else => 0,
            }),
            else => unreachable,
        };
    }

    pub fn store(self: *Self, comptime ValueType: type, addr: u64, value: ValueType) void {
        switch (ValueType) {
            u32 => switch (addr) {
                pending_addr => self.pending = value,
                senable_addr => self.senable = value,
                spriority_addr => self.spriority = value,
                sclaim_addr => self.sclaim = value,
                else => {},
            },
            else => unreachable,
        }
    }
};

test "plic load & store" {
    const allocator = std.testing.allocator;
    const expect = std.testing.expect;

    var plic = try Plic.create(allocator);
    defer plic.destroy(allocator);
    plic.pending = 11;
    plic.senable = 22;
    plic.spriority = 33;
    plic.sclaim = 44;
    // load
    try expect(plic.load(u32, Plic.pending_addr) == 11);
    try expect(plic.load(u32, Plic.senable_addr) == 22);
    try expect(plic.load(u32, Plic.spriority_addr) == 33);
    try expect(plic.load(u32, Plic.sclaim_addr) == 44);
    // store
    plic.store(u32, Plic.pending_addr, 1111);
    try expect(plic.load(u32, Plic.pending_addr) == 1111);
    plic.store(u32, Plic.senable_addr, 2222);
    try expect(plic.load(u32, Plic.senable_addr) == 2222);
    plic.store(u32, Plic.spriority_addr, 3333);
    try expect(plic.load(u32, Plic.spriority_addr) == 3333);
    plic.store(u32, Plic.sclaim_addr, 4444);
    try expect(plic.load(u32, Plic.sclaim_addr) == 4444);
}
