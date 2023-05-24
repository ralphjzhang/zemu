const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Virtio = struct {
    const Self = @This();
    pub const virtio_base = 0x10001000;
    pub const virtio_size = 0x1000;
    const magic_addr = virtio_base + 0x000;
    const version_addr = virtio_base + 0x004;
    const device_id_addr = virtio_base + 0x008;
    const vendor_id_addr = virtio_base + 0x00c;
    const device_features_addr = virtio_base + 0x010;
    const driver_features_addr = virtio_base + 0x020;
    const guest_page_size_addr = virtio_base + 0x028;
    const queue_sel_addr = virtio_base + 0x030;
    const queue_num_max_addr = virtio_base + 0x034;
    const queue_num_addr = virtio_base + 0x038;
    const queue_pfn_addr = virtio_base + 0x040;
    const queue_notify_addr = virtio_base + 0x050;
    const status_addr = virtio_base + 0x070;

    pub const vring_desc_size = 16;
    pub const desc_num = 8;

    pub const virtio_irq = 1;

    id: u64,
    driver_features: u32,
    page_size: u32,
    queue_sel: u32,
    queue_num: u32,
    queue_pfn: u32,
    queue_notify: u32,
    status: u32,
    disk: []u8,

    pub fn create(allocator: Allocator, disk: []u8) !*Self {
        const self = try allocator.create(Self);
        self.* = std.mem.zeroes(Self);
        self.disk = disk;
        self.queue_notify = 0xFFFF_FFFF;
        return self;
    }
    pub fn destroy(self: *Self, allocator: Allocator) void {
        allocator.destroy(self);
    }

    pub fn load(self: *Self, comptime ResultType: type, addr: u64) ResultType {
        return switch (ResultType) {
            u32 => switch (addr) {
                magic_addr => 0x74726976,
                version_addr => 0x1,
                device_id_addr => 0x2,
                vendor_id_addr => 0x554d4551,
                device_features_addr => 0,
                driver_features_addr => self.driver_features,
                queue_num_max_addr => 8,
                queue_pfn_addr => self.queue_pfn,
                status_addr => self.status,
                else => 0,
            },
            else => unreachable,
            // else => @compileError("Invalid ResultType: " ++ @typeName(ResultType)),
        };
    }

    pub fn store(self: *Self, comptime ValueType: type, addr: u64, value: ValueType) void {
        switch (ValueType) {
            u32 => switch (addr) {
                device_features_addr => self.driver_features = value,
                guest_page_size_addr => self.page_size = value,
                queue_sel_addr => self.queue_sel = value,
                queue_num_addr => self.queue_num = value,
                queue_pfn_addr => self.queue_pfn = value,
                queue_notify_addr => self.queue_notify = value,
                status_addr => self.status = value,
                else => {},
            },
            else => unreachable,
        }
    }

    pub fn isInterrupting(self: *Self) bool {
        if (self.queue_notify != 0xFFFF_FFFF) {
            self.queue_notify = 0xFFFF_FFFF;
            return true;
        }
        return false;
    }

    pub fn descAddr(self: *Self) u64 {
        return @as(u64, self.queue_pfn) * self.page_size;
    }

    pub fn diskRead(self: *Self, addr: u64) u8 {
        return self.disk[addr];
    }

    pub fn diskWrite(self: *Self, addr: u64, value: u8) void {
        self.disk[addr] = value;
    }

    pub fn newId(self: *Self) u64 {
        self.id += 1;
        return self.id;
    }
};

test "virtio" {
    const allocator = std.testing.allocator;
    const expect = std.testing.expect;

    var disk = [_]u8{0};

    var virtio = try Virtio.create(allocator, &disk);
    defer virtio.destroy(allocator);
    // load
    try expect(virtio.load(u32, Virtio.magic_addr) == 0x74726976);
    try expect(virtio.load(u32, Virtio.version_addr) == 0x1);
    try expect(virtio.load(u32, Virtio.device_id_addr) == 0x2);
    try expect(virtio.load(u32, Virtio.vendor_id_addr) == 0x554d4551);
    try expect(virtio.load(u32, Virtio.device_features_addr) == 0);
    try expect(virtio.load(u32, Virtio.queue_num_max_addr) == 8);
    // store
    virtio.store(u32, Virtio.device_features_addr, 111);
    try expect(virtio.load(u32, Virtio.driver_features_addr) == 111);
    virtio.store(u32, Virtio.guest_page_size_addr, 222);
    try expect(virtio.load(u32, Virtio.guest_page_size_addr) == 0);
    try expect(virtio.page_size == 222);
    virtio.store(u32, Virtio.queue_sel_addr, 333);
    try expect(virtio.load(u32, Virtio.queue_sel_addr) == 0);
    try expect(virtio.queue_sel == 333);
    virtio.store(u32, Virtio.queue_pfn_addr, 444);
    try expect(virtio.load(u32, Virtio.queue_pfn_addr) == 444);
    virtio.store(u32, Virtio.queue_notify_addr, 555);
    try expect(virtio.load(u32, Virtio.queue_notify_addr) == 0);
    try expect(virtio.queue_notify == 555);
    virtio.store(u32, Virtio.status_addr, 666);
    try expect(virtio.load(u32, Virtio.status_addr) == 666);
    // isInterrupting
    virtio.store(u32, Virtio.queue_notify_addr, 555);
    try expect(virtio.isInterrupting() == true);
    try expect(virtio.queue_notify == 0xFFFF_FFFF);
    try expect(virtio.isInterrupting() == false);
    // descAddr
    virtio.store(u32, Virtio.queue_pfn_addr, 6);
    virtio.store(u32, Virtio.guest_page_size_addr, 7);
    try expect(virtio.descAddr() == 42); // 6 * 7
    // disk read/write
    try expect(virtio.diskRead(0) == 0);
    virtio.diskWrite(0, 42);
    try expect(virtio.diskRead(0) == 42);
    // newId
    virtio.id = 1;
    try expect(virtio.newId() == 2);
    try expect(virtio.id == 2);
}
