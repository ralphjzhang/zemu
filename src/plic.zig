const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("./common.zig");
const Exception = common.Exception;
const Result = common.Result;

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

    pub fn load(self: *Self, addr: u64, size: u64) Result {
        if (size == 32) {
            return switch (addr) {
                pending_addr => .{ .result = self.pending },
                senable_addr => .{ .result = self.senable },
                spriority_addr => .{ .result = self.spriority },
                sclaim_addr => .{ .result = self.sclaim },
                else => .{ .result = 0 },
            };
        } else return .{ .exception = Exception.load_access_fault };
    }

    pub fn store(self: *Self, addr: u64, size: u64, value: u64) Exception {
        if (size == 32) {
            switch (addr) {
                pending_addr => self.pending = value,
                senable_addr => self.senable = value,
                spriority_addr => self.spriority = value,
                sclaim_addr => self.sclaim = value,
                else => {},
            }
            return Exception.ok;
        } else return Exception.store_amo_access_fault;
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
    try expect(plic.load(Plic.pending_addr, 33).exception == Exception.load_access_fault);
    try expect(plic.load(424242, 32).result == 0);
    try expect(plic.load(Plic.pending_addr, 32).result == 11);
    try expect(plic.load(Plic.senable_addr, 32).result == 22);
    try expect(plic.load(Plic.spriority_addr, 32).result == 33);
    try expect(plic.load(Plic.sclaim_addr, 32).result == 44);
    // store
    try expect(plic.store(Plic.pending_addr, 33, 0) == Exception.store_amo_access_fault);
    try expect(plic.store(424242, 32, 0) == Exception.ok);
    try expect(plic.store(Plic.pending_addr, 32, 1111) == Exception.ok);
    try expect(plic.load(Plic.pending_addr, 32).result == 1111);
    try expect(plic.store(Plic.senable_addr, 32, 2222) == Exception.ok);
    try expect(plic.load(Plic.senable_addr, 32).result == 2222);
    try expect(plic.store(Plic.spriority_addr, 32, 3333) == Exception.ok);
    try expect(plic.load(Plic.spriority_addr, 32).result == 3333);
    try expect(plic.store(Plic.sclaim_addr, 32, 4444) == Exception.ok);
    try expect(plic.load(Plic.sclaim_addr, 32).result == 4444);
}
