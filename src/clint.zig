const std = @import("std");
const Allocator = std.mem.Allocator;

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

    pub fn load(self: *Self, comptime ResultType: type, addr: u64) ResultType {
        return switch (ResultType) {
            u64 => switch (addr) {
                mtimecmp_addr => self.mtimecmp,
                mtime_addr => self.mtime,
                else => 0,
            },
            else => unreachable,
        };
    }

    pub fn store(self: *Self, comptime ValueType: type, addr: u64, value: ValueType) void {
        switch (ValueType) {
            u64 => switch (addr) {
                mtimecmp_addr => self.mtimecmp = value,
                mtime_addr => self.mtime = value,
                else => {},
            },
            else => unreachable,
        }
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
    try expect(clint.load(u64, Clint.mtimecmp_addr) == 42);
    try expect(clint.load(u64, Clint.mtime_addr) == 24);
    // store
    clint.store(u64, Clint.mtime_addr, 88);
    try expect(clint.load(u64, Clint.mtime_addr) == 88);
    clint.store(u64, Clint.mtimecmp_addr, 99);
    try expect(clint.load(u64, Clint.mtimecmp_addr) == 99);
}
