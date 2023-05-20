const std = @import("std");
const Allocator = std.mem.Allocator;
const Exception = @import("./exception.zig").Exception;
const Bus = @import("./bus.zig").Bus;
const Dram = @import("./dram.zig").Dram;
const Virtio = @import("./virtio.zig").Virtio;

pub const Cpu = struct {
    const Self = @This();
    const Mode = enum(u8) {
        user = 0x0,
        supervisor = 0x1,
        machine = 0x3,
    };
    const Csr = enum(u16) {
        // machine level CSRs
        mstatus = 0x300,
        medeleg = 0x302,
        mideleg = 0x303,
        mie = 0x304,
        mtvec = 0x305,
        mepc = 0x341,
        mcause = 0x342,
        mtval = 0x343,
        mip = 0x344,
        // supervisor level CSRs
        sstatus = 0x100,
        sie = 0x104,
        stvec = 0x105,
        sepc = 0x141,
        scause = 0x142,
        stval = 0x143,
        sip = 0x144,
        satp = 0x180,
    };
    const page_size = 4096;

    regs: [32]u64,
    pc: u64,
    csrs: [4096]u64,
    mode: Mode,
    bus: *Bus,
    enable_paging: bool,
    pagetable: u64,

    pub fn create(allocator: Allocator, code: []u8, disk: []u8) !*Self {
        var self = try allocator.create(Cpu);
        self.regs[2] = Dram.dram_base + Dram.dram_size;
        self.bus = try Bus.create(
            allocator,
            try Dram.create(allocator, code),
            try Virtio.create(allocator, disk),
        );
        self.pc = Dram.dram_base;
        self.mode = Mode.machine;
        return self;
    }

    pub fn destroy(self: *Self, allocator: Allocator) void {
        self.bus.destroy(allocator);
        allocator.destroy(self);
    }

    pub fn updatePaging(self: *Self, csr_addr: Csr) void {
        if (csr_addr != Csr.satp) return;
        self.pagetable = (self.loadCsr(Csr.satp) & ((@as(u64, 1) << 44) - 1)) * page_size;
        const mode = self.loadCsr(Csr.satp) >> 60;

        self.enable_paging = (mode == 8);
    }

    pub fn translate(self: *Self, addr: u64, e: Exception) union(enum) { address: u64, exception: Exception } {
        if (!self.enable_paging) return .{ .address = addr };

        var levels: u16 = 3;
        var vpn = [_]u64{
            (addr >> 12) & 0x1FF,
            (addr >> 21) & 0x1FF,
            (addr >> 30) & 0x1FF,
        };

        var a = self.pagetable;
        var i = levels - 1;
        var pte: u64 = 0;
        while (true) {
            pte = self.bus.load(u64, a + vpn[i] * 8);
            var v: bool = (pte & 1) == 1;
            var r: bool = ((pte >> 1) & 1) == 1;
            var w: bool = ((pte >> 2) & 1) == 1;
            var x: bool = ((pte >> 3) & 1) == 1;
            if (v == false or (r == false and w == true)) return .{ .exception = e };

            if (r == true or x == true) break;

            i -= 1;
            var ppn = (pte >> 10) & 0x0FFF_FFFF_FFFF;
            a = ppn * page_size;
            if (i < 0) return .{ .exception = e };
        }

        var ppn = [_]u64{
            (pte >> 10) & 0x1FF,
            (pte >> 19) & 0x1FF,
            (pte >> 28) & 0x03FF_FFFF,
        };

        var offset = addr & 0xFF;
        return switch (i) {
            0 => .{ .address = (((pte >> 10) & 0x0FFF_FFFF_FFFF) << 12) | offset },
            1 => .{ .address = (ppn[2] << 30) | (ppn[1] << 21) | (vpn[0] << 12) | offset },
            2 => .{ .address = (ppn[2] << 30) | (vpn[1] << 21) | (vpn[0] << 12) | offset },
            else => .{ .exception = e },
        };
    }

    pub fn fetch(self: *Self) union { instruction: u32, exception: Exception } {
        var ppc = switch (self.translate(self.pc, Exception.instruction_page_fault)) {
            .exception => |e| return .{ .exception = e },
            .address => |addr| addr,
        };
        return switch (self.bus.load(u32, ppc)) {
            .exception => Exception.instruction_access_fault,
            .instruction => |val| val,
        };
    }

    fn getCsr(self: *Self, addr: Csr) u64 {
        return self.csrs[@enumToInt(addr)];
    }
    pub fn loadCsr(self: *Self, addr: Csr) u64 {
        return if (addr == Csr.sie)
            self.getCsr(Csr.mie) & self.getCsr(Csr.mideleg)
        else
            self.getCsr(addr);
    }
    pub fn storeCsr(self: *Self, addr: Csr, value: u64) void {
        if (addr == Csr.sie) {
            self.csrs[@enumToInt(Csr.mie)] = (self.getCsr(Csr.mie) & ~self.getCsr(Csr.mideleg)) | (value & self.getCsr(Csr.mideleg));
        } else self.csrs[@enumToInt(addr)] = value;
    }

    pub fn load(self: *Self, comptime DataType: type, addr: u64) union(enum) { data: DataType, exception: Exception } {
        return switch (self.translate(addr, Exception.load_page_fault)) {
            .exception => |e| .{ .exception = e },
            .address => |pa| .{ .data = self.bus.load(DataType, pa) },
        };
    }

    pub fn store(self: *Self, comptime DataType: type, addr: u64, value: DataType) ?Exception {
        return switch (self.translate(addr, Exception.load_page_fault)) {
            .exception => |e| e,
            .address => |pa| {
                self.bus.store(DataType, pa, value);
                return null;
            },
        };
    }

    pub fn dumpCsrs(self: *Self) void {
        const print = std.debug.print;
        print("mstatus={} mtvec={} mepc={} mcause={}", .{
            self.loadCsr(Csr.mstatus),
            self.loadCsr(Csr.mtvec),
            self.loadCsr(Csr.mepc),
            self.loadCsr(Csr.mcause),
        });
        print("sstatus={} stvec={} sepc={} scause={}", .{
            self.loadCsr(Csr.sstatus),
            self.loadCsr(Csr.stvec),
            self.loadCsr(Csr.sepc),
            self.loadCsr(Csr.scause),
        });
    }

    pub fn execute(self: *Self, inst: u64) ?Exception {
        const opcode = @truncate(u7, inst);
        const rd = @truncate(u5, (inst >> 7));
        const rs1 = @truncate(u5, (inst >> 15));
        const rs2 = @truncate(u5, (inst >> 20));
        const funct3: u3 = @truncate(u3, (inst >> 12));
        const funct7: u7 = @truncate(u7, (inst >> 25));

        self.regs[0] = 0; // x0 register is always 0
        switch (opcode) {
            0x03 => {
                const imm = @truncate(u12, inst >> 20);
                const base = self.regs[rs1];
                const addr = @addWithOverflow(base, imm)[0];
                self.regs[rd] = switch (funct3) {
                    0x0 => switch (self.load(u8, addr)) { // lb
                        .exception => |e| return e,
                        .data => |data| @bitCast(u64, @as(i64, data)),
                    },
                    0x1 => switch (self.load(u16, addr)) { // lh
                        .exception => |e| return e,
                        .data => |data| @bitCast(u64, @as(i64, data)),
                    },
                    0x2 => switch (self.load(u32, addr)) { // lw
                        .exception => |e| return e,
                        .data => |data| @bitCast(u64, @as(i64, data)),
                    },
                    0x3 => switch (self.load(u64, addr)) { // ld
                        .exception => |e| return e,
                        .data => |data| data,
                    },
                    0x4 => switch (self.load(u8, addr)) { // lbu
                        .exception => |e| return e,
                        .data => |data| data,
                    },
                    0x5 => switch (self.load(u16, addr)) { // lhu
                        .exception => |e| return e,
                        .data => |data| data,
                    },
                    0x6 => switch (self.load(u32, addr)) { // lwu
                        .exception => |e| return e,
                        .data => |data| data,
                    },
                    else => return Exception.illegal_instruction,
                };
            },
            0x0F => {
                switch (funct3) {
                    0x0 => {}, // fence, do nothing
                    else => return Exception.illegal_instruction,
                }
            },
            0x13 => {
                const imm_u = @truncate(u12, inst >> 20);
                const imm_i = @bitCast(i12, imm_u);
                const shift_amt = @truncate(u6, imm_u);
                const rs1_u = self.regs[rs1];
                const rs1_i = @bitCast(i64, rs1_u);
                self.regs[rd] = switch (funct3) {
                    0x0 => rs1_u + imm_u, // addi
                    0x1 => rs1_u << shift_amt, // slli
                    0x2 => @boolToInt(rs1_i < imm_i), // slti
                    0x3 => @boolToInt(rs1_u < imm_u), // sltiu
                    0x4 => @bitCast(u64, rs1_i ^ imm_i), // xori
                    0x5 => switch (funct7 >> 1) {
                        0x00 => rs1_u >> shift_amt, // srli
                        0x10 => @bitCast(u64, rs1_i >> shift_amt), // srai
                        else => return Exception.illegal_instruction,
                    },
                    0x6 => rs1_u | imm_u, // ori
                    0x7 => rs1_u & imm_u, // andi
                };
            },
            0x17 => { // auipc
                const imm_u = @truncate(u20, inst >> 12);
                self.regs[rd] = @addWithOverflow(self.pc, imm_u)[0] - 4;
            },
            0x1B => {
                const imm_u = @truncate(u12, inst >> 20);
                const imm_i = @bitCast(i12, imm_u);
                const shift_amt = @truncate(u4, imm_u);
                const rs1_u = self.regs[rs1];
                const rs1_u32 = @truncate(u32, rs1_u);
                const rs1_i32 = @bitCast(i32, rs1_u32);
                self.regs[rd] = @bitCast(u64, switch (funct3) {
                    0x0 => @as(i64, @addWithOverflow(rs1_i32, imm_i)[0]), // addiw
                    0x1 => @as(i64, rs1_i32 << shift_amt), // slliw
                    0x5 => switch (funct7) {
                        0x00 => @as(i64, @bitCast(i32, rs1_u32 >> shift_amt)),
                        0x20 => @as(i64, rs1_i32 >> shift_amt),
                        else => return Exception.illegal_instruction,
                    },
                    else => return Exception.illegal_instruction,
                });
            },
            0x2F => {
                const funct5 = @truncate(u5, inst >> 27);
                const rs1_u = self.regs[rs1];
                const rs2_u = self.regs[rs2];
                if (funct3 == 0x2 and funct5 == 0x00) { // amoadd.w
                    const t = switch (self.load(u32, rs1_u)) {
                        .exception => |e| return e,
                        .data => |data| data,
                    };
                    if (self.store(u32, rs1_u, @truncate(u32, rs2_u + t))) |e| return e;
                    self.regs[rd] = t;
                } else if (funct3 == 0x3 and funct5 == 0x00) { // amoadd.d
                    const t = switch (self.load(u64, rs1_u)) {
                        .exception => |e| return e,
                        .data => |data| data,
                    };
                    if (self.store(u64, rs1_u, rs2_u + t)) |e| return e;
                    self.regs[rd] = t;
                } else if (funct3 == 0x2 and funct5 == 0x01) { // amoswap.w
                    const t = switch (self.load(u32, rs1_u)) {
                        .exception => |e| return e,
                        .data => |data| data,
                    };
                    if (self.store(u32, rs1_u, @truncate(u32, rs2_u))) |e| return e;
                    self.regs[rd] = t;
                } else if (funct3 == 0x3 and funct5 == 0x01) { // amoswap.d
                    const t = switch (self.load(u64, rs1_u)) {
                        .exception => |e| return e,
                        .data => |data| data,
                    };
                    if (self.store(u64, rs1_u, rs2_u)) |e| return e;
                    self.regs[rd] = t;
                } else return Exception.illegal_instruction;
            },
            else => return Exception.illegal_instruction,
        }
        return null;
    }
};

test "cpu" {
    const allocator = std.testing.allocator;
    const expect = std.testing.expect;
    _ = expect;

    var code = [_]u8{0};
    var disk = [_]u8{0};
    var cpu = try Cpu.create(allocator, &code, &disk);
    defer cpu.destroy(allocator);

    _ = cpu.loadCsr(Cpu.Csr.mie);
    cpu.storeCsr(Cpu.Csr.sie, 0);
    cpu.updatePaging(Cpu.Csr.mcause);
    // _ = cpu.translate(0, Exception.breakpoint);
    // _ = cpu.load(u64, 4242);
    // _ = cpu.store(u64, 4242, 10);
    _ = cpu.execute(0);

    var x: u64 = 0xFFFF_FFFF_FFFF_FFFF;
    const xx = @bitCast(i8, @truncate(u8, x));
    std.debug.print("0x{X}\n", .{xx});
}
