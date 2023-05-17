const std = @import("std");
const Allocator = std.mem.Allocator;
const Exception = @import("./exception.zig").Exception;

const Dram = struct {
    const dram_size = 1024 * 1024 * 128;
    const dram_base = 0x80000000;
    const Self = @This();

    data: []u8,

    pub fn create(allocator: Allocator, code: []u8) !*Self {
        var dram = try allocator.create(Dram);
        dram.data = try allocator.alloc(u8, dram_size);
        std.mem.copy(u8, dram.data, code);
        return dram;
    }

    pub fn destroy(self: *Self, allocator: Allocator) void {
        allocator.free(self.data);
        allocator.destroy(self);
    }

    pub fn load(self: *Self, addr: u64, comptime size: u8) union { result: u64, exception: Exception } {
        const index = addr - dram_base;
        return switch (size) {
            8 => .{ .result = load_impl(1, self.data, index) },
            16 => .{ .result = load_impl(2, self.data, index) },
            32 => .{ .result = load_impl(4, self.data, index) },
            64 => .{ .result = load_impl(8, self.data, index) },
            else => .{ .exception = Exception.load_access_fault },
        };
    }

    pub fn store(self: *Self, addr: u64, comptime size: u8, value: u64) Exception {
        const index = addr - dram_base;
        return switch (size) {
            8 => store_impl(1, self.data, index, value),
            16 => store_impl(2, self.data, index, value),
            32 => store_impl(4, self.data, index, value),
            64 => store_impl(8, self.data, index, value),
            else => Exception.store_amo_access_fault,
        };
    }
};

inline fn load_impl(comptime bytes: u8, data: []u8, index: u64) u64 {
    var ret: u64 = 0;
    inline for (0..bytes) |i| {
        ret |= @as(u64, data[index + i]) << i * 8;
    }
    return ret;
}

inline fn store_impl(comptime bytes: u8, data: []u8, index: u64, value: u64) Exception {
    inline for (0..bytes) |i| {
        data[index + i] = @intCast(u8, (value >> i * 8) & 0xFF);
    }
    return Exception.ok;
}

test "dram load & store" {
    const expect = std.testing.expect;

    var data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    // load_impl
    try expect(load_impl(1, &data, 0) == 1);
    try expect(load_impl(1, &data, 4) == 5);
    try expect(load_impl(1, &data, 7) == 8);
    try expect(load_impl(2, &data, 0) == 0x201);
    try expect(load_impl(2, &data, 4) == 0x605);
    try expect(load_impl(2, &data, 6) == 0x807);
    try expect(load_impl(4, &data, 0) == 0x4030201);
    try expect(load_impl(4, &data, 4) == 0x8070605);
    try expect(load_impl(8, &data, 0) == 0x807060504030201);
    // store_impl
    try expect(store_impl(1, &data, 0, 9) == Exception.ok);
    try expect(load_impl(1, &data, 0) == 9);
    try expect(load_impl(2, &data, 0) == 0x209);
    try expect(load_impl(4, &data, 0) == 0x4030209);
    try expect(load_impl(8, &data, 0) == 0x807060504030209);
    try expect(store_impl(2, &data, 0, 0xA0B) == Exception.ok);
    try expect(load_impl(2, &data, 0) == 0xA0B);
    try expect(load_impl(8, &data, 0) == 0x807060504030A0B);
    try expect(store_impl(4, &data, 0, 0xA0B0C0D) == Exception.ok);
    try expect(load_impl(2, &data, 2) == 0xA0B);
    try expect(load_impl(8, &data, 0) == 0x80706050A0B0C0D);
    try expect(store_impl(8, &data, 0, 0x8090A0B0C0D0E0F) == Exception.ok);
    try expect(load_impl(1, &data, 0) == 0xF);
    try expect(load_impl(8, &data, 0) == 0x8090A0B0C0D0E0F);

    data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var code = [_]u8{0};
    const allocator = std.testing.allocator;
    var dram = try Dram.create(allocator, &code);
    defer dram.destroy(allocator);
    std.mem.copy(u8, dram.data, &data);
    try expect(dram.load(Dram.dram_base, 8).result == 1);
    try expect(dram.load(Dram.dram_base, 16).result == 0x201);
    try expect(dram.load(Dram.dram_base, 32).result == 0x4030201);
    try expect(dram.load(Dram.dram_base, 64).result == 0x807060504030201);
    try expect(dram.load(Dram.dram_base, 9).exception == Exception.load_access_fault);
    const addr = Dram.dram_base + 0x1000;
    try expect(dram.store(addr, 8, 0x42) == Exception.ok);
    try expect(dram.load(addr, 8).result == 0x42);
    try expect(dram.store(addr, 16, 0x1234) == Exception.ok);
    try expect(dram.load(addr, 16).result == 0x1234);
    try expect(dram.store(addr, 32, 0x12345678) == Exception.ok);
    try expect(dram.load(addr, 32).result == 0x12345678);
    try expect(dram.store(addr, 64, 0x12345678ABCDEF0) == Exception.ok);
    try expect(dram.load(addr, 64).result == 0x12345678ABCDEF0);
}
