const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("./common.zig");
const Exception = common.Exception;
const Result = common.Result;

pub const Clint = struct {
    const Self = @This();
    pub const clint_base = 0x2000000;
    pub const clint_size = 0x10000;
    const mtimecmp_addr = clint_base + 0x4000;
    const mtime_addr = clint_base + 0xbff8;

    mtime: u64,
    mtimecmp: u64,

    pub fn create(allocator: Allocator) !*Self {
        return try allocator.create(Self);
    }

    pub fn destroy(self: *Self, allocator: Allocator) void {
        allocator.destroy(self);
    }

    pub fn load(self: *Self, addr: u64, comptime size: u8) Result {
        if (size == 64) {
            return switch (addr) {
                mtimecmp_addr => .{ .result = self.mtimecmp },
                mtime_addr => .{ .result = self.mtime },
                else => .{ .result = 0 },
            };
        } else return .{ .exception = Exception.load_access_fault };
    }

    pub fn store(self: *Self, addr: u64, comptime size: u8, value: u64) ?Exception {
        if (size == 64) {
            switch (addr) {
                mtimecmp_addr => self.mtimecmp = value,
                mtime_addr => self.mtime = value,
                else => {},
            }
            return null;
        } else return Exception.store_amo_access_fault;
    }
};

test "clint load & store" {
    const allocator = std.testing.allocator;
    const expect = std.testing.expect;

    var clint = try Clint.create(allocator);
    defer clint.destroy(allocator);
    clint.mtimecmp = 42;
    clint.mtime = 24;
    // load
    try expect(clint.load(Clint.mtime_addr, 63).exception == Exception.load_access_fault);
    try expect(clint.load(424242, 64).result == 0);
    try expect(clint.load(Clint.mtimecmp_addr, 64).result == 42);
    try expect(clint.load(Clint.mtime_addr, 64).result == 24);
    // store
    try expect(clint.store(Clint.mtime_addr, 63, 42) == Exception.store_amo_access_fault);
    try expect(clint.store(424242, 64, 42) == null);
    try expect(clint.store(Clint.mtime_addr, 64, 88) == null);
    try expect(clint.load(Clint.mtime_addr, 64).result == 88);
    try expect(clint.store(Clint.mtimecmp_addr, 64, 99) == null);
    try expect(clint.load(Clint.mtimecmp_addr, 64).result == 99);
}
