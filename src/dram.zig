const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Dram = struct {
    pub const dram_size = 1024 * 1024 * 128;
    pub const dram_base = 0x80000000;
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

    pub fn load(self: *Self, comptime ResultType: type, addr: u64) ResultType {
        const index = addr - dram_base;
        return switch (ResultType) {
            u8, u16, u32, u64 => load_impl(ResultType, self.data, index),
            else => unreachable,
        };
    }

    pub fn store(self: *Self, comptime ValueType: type, addr: u64, value: ValueType) void {
        const index = addr - dram_base;
        return switch (ValueType) {
            u8, u16, u32, u64 => store_impl(ValueType, self.data, index, value),
            else => unreachable,
        };
    }
};

inline fn load_impl(comptime ResultType: type, data: []u8, index: u64) ResultType {
    var ret: u64 = 0;
    const size = @sizeOf(ResultType);
    inline for (0..size) |i| {
        ret |= @as(u64, data[index + i]) << i * 8;
    }
    return @truncate(ResultType, ret);
}

inline fn store_impl(comptime ValueType: type, data: []u8, index: u64, value: ValueType) void {
    const size = @sizeOf(ValueType);
    inline for (0..size) |i| {
        data[index + i] = @intCast(u8, (value >> i * 8) & 0xFF);
    }
}

test "dram load & store" {
    const expect = std.testing.expect;

    var data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    // load_impl
    try expect(load_impl(u8, &data, 0) == 1);
    try expect(load_impl(u8, &data, 4) == 5);
    try expect(load_impl(u8, &data, 7) == 8);
    try expect(load_impl(u16, &data, 0) == 0x201);
    try expect(load_impl(u16, &data, 4) == 0x605);
    try expect(load_impl(u16, &data, 6) == 0x807);
    try expect(load_impl(u32, &data, 0) == 0x4030201);
    try expect(load_impl(u32, &data, 4) == 0x8070605);
    try expect(load_impl(u64, &data, 0) == 0x807060504030201);
    // store_impl
    store_impl(u8, &data, 0, 9);
    try expect(load_impl(u8, &data, 0) == 9);
    try expect(load_impl(u16, &data, 0) == 0x209);
    try expect(load_impl(u32, &data, 0) == 0x4030209);
    try expect(load_impl(u64, &data, 0) == 0x807060504030209);
    store_impl(u16, &data, 0, 0xA0B);
    try expect(load_impl(u16, &data, 0) == 0xA0B);
    try expect(load_impl(u64, &data, 0) == 0x807060504030A0B);
    store_impl(u32, &data, 0, 0xA0B0C0D);
    try expect(load_impl(u16, &data, 2) == 0xA0B);
    try expect(load_impl(u64, &data, 0) == 0x80706050A0B0C0D);
    store_impl(u64, &data, 0, 0x8090A0B0C0D0E0F);
    try expect(load_impl(u8, &data, 0) == 0xF);
    try expect(load_impl(u64, &data, 0) == 0x8090A0B0C0D0E0F);

    data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var code = [_]u8{0};
    const allocator = std.testing.allocator;
    var dram = try Dram.create(allocator, &code);
    defer dram.destroy(allocator);
    std.mem.copy(u8, dram.data, &data);
    try expect(dram.load(u8, Dram.dram_base) == 1);
    try expect(dram.load(u16, Dram.dram_base) == 0x201);
    try expect(dram.load(u32, Dram.dram_base) == 0x4030201);
    try expect(dram.load(u64, Dram.dram_base) == 0x807060504030201);
    const addr = Dram.dram_base + 0x1000;
    dram.store(u8, addr, 0x42);
    try expect(dram.load(u8, addr) == 0x42);
    dram.store(u16, addr, 0x1234);
    try expect(dram.load(u16, addr) == 0x1234);
    dram.store(u32, addr, 0x12345678);
    try expect(dram.load(u32, addr) == 0x12345678);
    dram.store(u64, addr, 0x12345678ABCDEF0);
    try expect(dram.load(u64, addr) == 0x12345678ABCDEF0);
}
