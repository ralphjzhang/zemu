const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Uart = struct {
    const Self = @This();
    pub const uart_base = 0x10000000;
    pub const uart_size = 0x100;
    const rhr_addr = uart_base + 0;
    const thr_addr = uart_base + 0;
    const lcr_addr = uart_base + 3;
    const lsr_addr = uart_base + 5;
    const lsr_rx = 1;
    const lsr_tx = 1 << 5;

    pub const uart_irq = 10;

    data: [uart_size]u8,
    interrupting_: bool,

    thread: std.Thread,
    lock: std.Thread.Mutex,
    cond: std.Thread.Condition,

    pub fn create(allocator: Allocator) !*Self {
        const self = try allocator.create(Self);
        self.data = std.mem.zeroes(@TypeOf(self.data));
        self.data[lsr_addr - uart_base] |= lsr_tx;
        self.interrupting_ = false;
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

    pub fn load(self: *Self, comptime ResultType: type, addr: u64) ResultType {
        switch (ResultType) {
            u8 => {
                self.lock.lock();
                defer self.lock.unlock();
                switch (addr) {
                    rhr_addr => {
                        self.cond.broadcast();
                        self.data[lsr_addr - uart_base] &= ~@as(u8, lsr_rx);
                        return 0;
                    },
                    else => return self.data[addr - uart_base],
                }
            },
            // else => @compileError("Invalid ResultType: " ++ @typeName(ResultType)),
            else => unreachable,
        }
    }

    pub fn store(self: *Self, comptime ValueType: type, addr: u64, value: ValueType) void {
        switch (ValueType) {
            u8 => {
                self.lock.lock();
                defer self.lock.unlock();
                switch (addr) {
                    rhr_addr => _ = std.os.write(std.os.STDOUT_FILENO, &[_]u8{value & 0xFF}) catch unreachable, // TODO good?
                    else => self.data[addr - uart_base] = value & 0xFF,
                }
            },
            // else => @compileError("Invalid ValueType: " ++ @typeName(ValueType)),
            else => unreachable,
        }
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
