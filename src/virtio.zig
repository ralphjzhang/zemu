const std = @import("std");
const Allocator = std.mem.Allocator;
const Exception = @import("./exception.zig").Exception;

const Virtio = struct {
    const Self = @This();
    const virtio_base = 0x10001000;
    const virtio_size = 0x1000;
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

    const vring_desc_size = 16;
    const desc_num = 8;

    const virtio_irq = 1;
    const uart_irq = 10;

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
        var self = try allocator.create(Self);
        self.disk = disk;
        self.queue_notify = 0xFFFF_FFFF;
        return self;
    }
    pub fn destroy(self: *Self, allocator: Allocator) void {
        allocator.destroy(self);
    }

    pub fn load(self: *Self, addr: u64, size: u64) union { result: u64, exception: Exception } {
        if (size == 32) {
            return switch (addr) {
                magic_addr => .{ .result = 0x74726976 },
                version_addr => .{ .result = 0x1 },
                device_id_addr => .{ .result = 0x2 },
                vendor_id_addr => .{ .result = 0x554d4551 },
                device_features_addr => .{ .result = 0 },
                driver_features_addr => .{ .result = self.driver_features },
                queue_num_max_addr => .{ .result = 8 },
                queue_pfn_addr => .{ .result = self.queue_pfn },
                status_addr => .{ .result = self.status },
                else => .{ .result = 0 },
            };
        } else return .{.Exception.load_access_fault};
    }

    pub fn store(self: *Self, addr: u64, size: u64, value: u64) Exception {
        if (size == 32) {
            switch (addr) {
                device_features_addr => self.driver_features = value,
                guest_page_size_addr => self.page_size = value,
                queue_sel_addr => self.queue_sel = value,
                queue_num_addr => self.queue_num = value,
                queue_pfn_addr => self.queue_pfn = value,
                queue_notify_addr => self.queue_notify = value,
                status_addr => self.status = value,
                else => {},
            }
            return Exception.ok;
        } else return Exception.store_amo_access_fault;
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

    pub fn diskRead(self: *Self, addr: u64) u64 {
        return self.disk[addr];
    }

    pub fn diskWrite(self: *Self, addr: u64, value: u64) void {
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
    _ = expect;

    var disk = [_]u8{0};

    var virtio = try Virtio.create(allocator, &disk);
    defer virtio.destroy(allocator);
}
