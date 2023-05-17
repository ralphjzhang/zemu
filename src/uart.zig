const std = @import("std");
const Allocator = std.mem.Allocator;
const Exception = @import("./exception.zig").Exception;

const Uart = struct {
    const Self = @This();
    const uart_base = 0x10000000;
    const uart_size = 0x100;
    const rhr_addr = uart_base + 0;
    const thr_addr = uart_base + 0;
    const lcr_addr = uart_base + 3;
    const lsr_addr = uart_base + 5;
    const lsr_rx = 1;
    const lsr_tx = 1 << 5;

    data: [uart_size]u8,
    interrupting_: bool,

    thread: std.Thread,
    lock: std.Thread.Mutex,
    cond: std.Thread.Condition,

    pub fn create(allocator: Allocator) !*Self {
        var self = try allocator.create(Self);
        self.data[lsr_addr - uart_base] |= lsr_tx;
        self.thread = try std.Thread.spawn(.{}, worker, .{self});
        return self;
    }

    pub fn destroy(self: *Self, allocator: Allocator) void {
        allocator.destroy(self);
    }

    fn worker(self: *Self) !void {
        while (true) {
            var c = [_]u8{0};
            _ = try std.os.read(std.os.STDIN_FILENO, &c);
            self.lock.lock();
            while ((self.data[lsr_addr - uart_base] & lsr_rx) == 1) {
                self.cond.wait(&self.lock);
            }
            self.data[0] = c[0];
            self.interrupting_ = true;
            self.data[lsr_addr - uart_base] |= lsr_rx;
            defer self.lock.unlock();
        }
    }

    pub fn load(self: *Self, addr: u64, size: u64) union { result: u64, exception: Exception } {
        if (size == 8) {
            self.lock.lock();
            defer self.lock.unlock();
            switch (addr) {
                rhr_addr => {
                    self.cond.broadcast();
                    self.data[lsr_addr - uart_base] &= ~lsr_rx;
                    return .{ .result = 0 };
                },
                else => return .{ .result = self.data[addr - uart_base] },
            }
        } else return .{ .exception = Exception.load_access_fault };
    }

    pub fn store(self: *Self, addr: u64, size: u64, value: u8) Exception {
        if (size == 8) {
            self.lock.lock();
            defer self.lock.unlock();
            switch (addr) {
                rhr_addr => {
                    std.c.printf("%c", value & 0xFF);
                    std.c.fflush(std.c.stdio);
                },
                else => self.data[addr - uart_base] = value & 0xFF,
            }
            return Exception.ok;
        } else return .{ .exception = Exception.store_amo_access_fault };
    }

    pub fn interrupting(self: *Self) bool {
        self.lock.lock();
        defer self.lock.unlock();
        const intr = self.interrupting_;
        self.interrupting_ = false;
        return intr;
    }
};

test "uart" {
    const allocator = std.testing.allocator;
    const expect = std.testing.expect;
    _ = expect;

    var uart = try Uart.create(allocator);
    defer uart.destroy(allocator);
}
