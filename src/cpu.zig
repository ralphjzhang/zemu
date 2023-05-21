const std = @import("std");
const Allocator = std.mem.Allocator;
const Exception = @import("./exception.zig").Exception;
const Interrupt = @import("./exception.zig").Interrupt;
const Bus = @import("./bus.zig").Bus;
const Dram = @import("./dram.zig").Dram;
const Virtio = @import("./virtio.zig").Virtio;
const Uart = @import("./uart.zig").Uart;
const Plic = @import("./plic.zig").Plic;

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
    const mip_ssip = @as(u64, 1) << 1;
    const mip_msip = @as(u64, 1) << 3;
    const mip_stip = @as(u64, 1) << 5;
    const mip_mtip = @as(u64, 1) << 7;
    const mip_seip = @as(u64, 1) << 9;
    const mip_meip = @as(u64, 1) << 11;

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

    pub fn execute(self: *Self, inst: u32) ?Exception {
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
            0x0f => {
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
            0x1b => {
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
            0x2f => {
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
            0x33 => {
                const rs1_u = self.regs[rs1];
                const rs2_u = self.regs[rs2];
                const shift_amt = @truncate(u6, rs2_u);
                if (funct3 == 0x0 and funct7 == 0x00) { // add
                    self.regs[rd] = @addWithOverflow(rs1_u, rs2_u)[0];
                } else if (funct3 == 0x0 and funct7 == 0x01) { // mul
                    self.regs[rd] = @mulWithOverflow(rs1_u, rs2_u)[0];
                } else if (funct3 == 0x0 and funct7 == 0x20) { // sub
                    self.regs[rd] = @subWithOverflow(rs1_u, rs2_u)[0];
                } else if (funct3 == 0x1 and funct7 == 0x00) { // sll
                    self.regs[rd] = rs1_u << shift_amt;
                } else if (funct3 == 0x2 and funct7 == 0x00) { // slt
                    self.regs[rd] = @boolToInt(@bitCast(i64, rs1_u) < @bitCast(i64, rs2_u));
                } else if (funct3 == 0x3 and funct7 == 0x00) { // sltu
                    self.regs[rd] = @boolToInt(rs1_u < rs2_u);
                } else if (funct3 == 0x4 and funct7 == 0x00) { // xor
                    self.regs[rd] = rs1_u ^ rs2_u;
                } else if (funct3 == 0x5 and funct7 == 0x00) { // srl
                    self.regs[rd] = rs1_u >> shift_amt;
                } else if (funct3 == 0x5 and funct7 == 0x20) { // sra
                    self.regs[rd] = @bitCast(u64, @bitCast(i64, rs1_u) >> shift_amt);
                } else if (funct3 == 0x6 and funct7 == 0x00) { // or
                    self.regs[rd] = rs1_u | rs2_u;
                } else if (funct3 == 0x7 and funct7 == 0x00) { // and
                    self.regs[rd] = rs1_u & rs2_u;
                } else return Exception.illegal_instruction;
            },
            0x37 => { // lui
                const imm = @bitCast(i20, @truncate(u20, inst >> 12));
                self.regs[rd] = @bitCast(u64, @as(i64, imm));
            },
            0x3b => {
                const rs1_u = self.regs[rs1];
                const rs1_u32 = @truncate(u32, rs1_u);
                const rs1_i32 = @bitCast(i32, rs1_u32);
                const rs2_u = self.regs[rs2];
                const rs2_u32 = @truncate(u32, rs2_u);
                const shift_amt = @truncate(u5, rs2_u);
                if (funct3 == 0x0 and funct7 == 0x00) { // addw
                    const res = @bitCast(i32, @truncate(u32, @addWithOverflow(rs1_u, rs2_u)[0]));
                    self.regs[rd] = @bitCast(u64, @as(i64, res));
                } else if (funct3 == 0x0 and funct7 == 0x20) { // subw
                    const res = @bitCast(i32, @truncate(u32, @subWithOverflow(rs1_u, rs2_u)[0]));
                    self.regs[rd] = @bitCast(u64, @as(i64, res));
                } else if (funct3 == 0x1 and funct7 == 0x00) { // sllw
                    const res = @bitCast(i32, rs1_u32 << shift_amt);
                    self.regs[rd] = @bitCast(u64, @as(i64, res));
                } else if (funct3 == 0x5 and funct7 == 0x00) { // srlw
                    const res = @bitCast(i32, rs1_u32 >> shift_amt);
                    self.regs[rd] = @bitCast(u64, @as(i64, res));
                } else if (funct3 == 0x5 and funct7 == 0x01) { // divu
                    self.regs[rd] = if (rs2_u == 0) 0xFFFF_FFFF_FFFF_FFFF else rs1_u / rs2_u;
                } else if (funct3 == 0x5 and funct7 == 0x20) { // sraw
                    const res = rs1_i32 >> shift_amt;
                    self.regs[rd] = @bitCast(u64, @as(i64, res));
                } else if (funct3 == 0x7 and funct7 == 0x01) { // remuw
                    if (rs2_u == 0) {
                        self.regs[rd] = rs1_u;
                    } else {
                        const res = @bitCast(i32, rs1_u32 % rs2_u32);
                        self.regs[rd] = @bitCast(u64, @as(i64, res));
                    }
                } else return Exception.illegal_instruction;
            },
            0x63 => {
                const rs1_u = self.regs[rs1];
                const rs1_i = @bitCast(i64, rs1_u);
                const rs2_u = self.regs[rs2];
                const rs2_i = @bitCast(i64, rs2_u);
                const imm12 = @truncate(u12, (inst & 0x8000_0000) >> 20);
                const imm11 = @truncate(u12, (inst & 0x80) << 3);
                const imm4_1 = @truncate(u12, (inst >> 8) & 0xF);
                const imm10_5 = @truncate(u12, (inst >> 25) & 0x3F);
                const imm = @as(u13, imm12 | imm11 | imm10_5 | imm4_1) << 1;

                switch (funct3) {
                    0x0 => { // beq
                        if (rs1_u == rs2_u) self.pc += imm - 4;
                    },
                    0x1 => { // bne
                        if (rs1_u != rs2_u) self.pc += imm - 4;
                    },
                    0x4 => { // blt
                        if (rs1_i < rs2_i) self.pc += imm - 4;
                    },
                    0x5 => { // bge
                        if (rs1_i >= rs2_i) self.pc += imm - 4;
                    },
                    0x6 => { // bltu
                        if (rs1_u < rs2_u) self.pc += imm - 4;
                    },
                    0x7 => { // bgeu
                        if (rs1_u >= rs2_u) self.pc += imm - 4;
                    },
                    else => return Exception.illegal_instruction,
                }
            },
            0x67 => { // jalr
                const t = self.pc;
                const imm = @bitCast(u32, @bitCast(i32, inst & 0xFFF0_0000) >> 20);
                self.pc = @addWithOverflow(self.regs[rs1], imm)[0] & 0xFFFF_FFFF_FFFF_FFFE;
                self.regs[rd] = t;
            },
            0x6f => { // jal
                self.regs[rd] = self.pc;
                const imm20 = @truncate(u20, (inst >> 12) & 0x80000);
                const imm19_12 = @truncate(u20, (inst >> 1) & 0x7f800);
                const imm11 = @truncate(u20, (inst >> 10) & 0x400);
                const imm10_1 = @truncate(u20, (inst >> 21) & 0x3ff);
                const imm = @as(u21, imm20 | imm19_12 | imm11 | imm10_1) << 1;
                self.pc += imm - 4;
            },
            0x73 => {
                const addr = @truncate(u16, (inst & 0xfff0_0000) >> 20);
                const csr = @intToEnum(Cpu.Csr, addr);
                const rs1_u = self.regs[rs1];
                switch (funct3) {
                    0x0 => {
                        if (rs2 == 0x0 and funct7 == 0x0) { // ecall
                            return switch (self.mode) {
                                .user => Exception.ecall_from_umode,
                                .supervisor => Exception.ecall_from_smode,
                                .machine => Exception.ecall_from_mmode,
                            };
                        } else if (rs2 == 0x1 and funct7 == 0x0) { // ebreak
                            return Exception.breakpoint;
                        } else if (rs2 == 0x2 and funct7 == 0x8) { // sret
                            self.pc = self.loadCsr(Csr.sepc);
                            const sstatus = self.loadCsr(Csr.sstatus);
                            const spp = (sstatus >> 8) & 1;
                            self.mode = if (spp == 1) .supervisor else .user;
                            const spie = (sstatus >> 5) & 1;
                            const _1: u64 = 1;
                            var new_sstatus = if (spie == 1) sstatus | (_1 << 1) else sstatus & ~(_1 << 1);
                            new_sstatus = new_sstatus | (_1 << 5); // spie
                            new_sstatus = new_sstatus & ~(_1 << 8); // spp
                            self.storeCsr(Csr.sstatus, new_sstatus);
                        } else if (rs2 == 0x2 and funct7 == 0x18) { // mret
                            self.pc = self.loadCsr(Csr.sepc);
                            const mstatus = self.loadCsr(Csr.mstatus);
                            const mpp = (mstatus >> 11) & 3;
                            self.mode = switch (mpp) {
                                2 => .machine,
                                1 => .supervisor,
                                else => .user,
                            };
                            const mpie = (mstatus >> 7) & 1;
                            const _1: u64 = 1;
                            const _3: u64 = 3;
                            var new_mstatus = if (mpie == 1) mstatus | (_1 << 3) else mstatus & ~(_1 << 3);
                            new_mstatus = new_mstatus | (_1 << 7); // mpie
                            new_mstatus = new_mstatus & ~(_3 << 11); // mpp
                            self.storeCsr(Csr.mstatus, new_mstatus);
                        } else if (funct7 == 0x9) { // sfence.vma
                            // fence, do nothing
                        } else return Exception.illegal_instruction;
                    },
                    0x1 => { // csrrw
                        const t = self.loadCsr(csr);
                        self.storeCsr(csr, rs1_u);
                        self.regs[rd] = t;
                        self.updatePaging(csr);
                    },
                    0x2 => { // csrrs
                        const t = self.loadCsr(csr);
                        self.storeCsr(csr, t | rs1_u);
                        self.regs[rd] = t;
                        self.updatePaging(csr);
                    },
                    0x3 => { // csrrc
                        const t = self.loadCsr(csr);
                        self.storeCsr(csr, t & ~rs1_u);
                        self.regs[rd] = t;
                        self.updatePaging(csr);
                    },
                    0x5 => { // csrrwi
                        self.regs[rd] = self.loadCsr(csr);
                        self.storeCsr(csr, rs1);
                        self.updatePaging(csr);
                    },
                    0x6 => { // csrrsi
                        const t = self.loadCsr(csr);
                        self.storeCsr(csr, t | rs1);
                        self.regs[rd] = t;
                        self.updatePaging(csr);
                    },
                    0x7 => { // csrrci
                        const t = self.loadCsr(csr);
                        self.storeCsr(csr, t & ~rs1);
                        self.regs[rd] = t;
                        self.updatePaging(csr);
                    },
                    else => return Exception.illegal_instruction,
                }
            },
            else => return Exception.illegal_instruction,
        }
        return null;
    }

    pub fn dumpRegisters(self: *Self) void {
        const abi = [32][]u8{
            "zero", " ra ", " sp ", " gp ", " tp ", " t0 ", " t1 ", " t2 ", " s0 ", " s1 ", " a0 ",
            " a1 ", " a2 ", " a3 ", " a4 ", " a5 ", " a6 ", " a7 ", " s2 ", " s3 ", " s4 ", " s5 ",
            " s6 ", " s7 ", " s8 ", " s9 ", " s10", " s11", " t3 ", " t4 ", " t5 ", " t6 ",
        };
        var i = 0;
        const print = std.debug.print;
        while (i < 32) : (i += 4) {
            print("{}-{s}=0x{x}", .{ i + 0, abi[i + 0], self.regs[i + 0] });
            print("{}-{s}=0x{x}", .{ i + 1, abi[i + 1], self.regs[i + 1] });
            print("{}-{s}=0x{x}", .{ i + 2, abi[i + 2], self.regs[i + 2] });
            print("{}-{s}=0x{x}", .{ i + 3, abi[i + 3], self.regs[i + 3] });
        }
    }

    pub fn takeTrap(self: *Self, exception: Exception, interrupt: Interrupt) void {
        _ = interrupt;
        _ = exception;
        _ = self;
    }

    pub fn checkPendingInterrupt(self: *Self) Interrupt {
        switch (self.mode) {
            .machine => if (((self.loadCsr(Csr.mstatus) >> 3) & 1) == 0) return .none,
            .supervisor => if (((self.loadCsr(Csr.sstatus) >> 1) & 1) == 0) return .none,
            .user => {},
        }

        var irq: u32 = 0;
        if (self.bus.uart.interrupting()) {
            irq = Uart.uart_irq;
        } else if (self.bus.virtio.isInterrupting()) {
            self.bus.diskAccess();
            irq = Virtio.virtio_irq;
        }

        if (irq != 0) {
            self.bus.store(u32, Plic.sclaim_addr, irq);
            self.storeCsr(Csr.mip, self.loadCsr(Csr.mip) | mip_seip);
        }

        var pending: u64 = self.loadCsr(Csr.mie) & self.loadCsr(Csr.mip);
        if (pending & mip_meip != 0) {
            self.storeCsr(Csr.mip, self.loadCsr(Csr.mip) & ~mip_meip);
            return .machine_external_interrupt;
        }
        if (pending & mip_msip != 0) {
            self.storeCsr(Csr.mip, self.loadCsr(Csr.mip) & ~mip_msip);
            return .machine_software_interrupt;
        }
        if (pending & mip_mtip != 0) {
            self.storeCsr(Csr.mip, self.loadCsr(Csr.mip) & ~mip_mtip);
            return .machine_timer_interrupt;
        }
        if (pending & mip_seip != 0) {
            self.storeCsr(Csr.mip, self.loadCsr(Csr.mip) & ~mip_seip);
            return .supervisor_external_interrupt;
        }
        if (pending & mip_ssip != 0) {
            self.storeCsr(Csr.mip, self.loadCsr(Csr.mip) & ~mip_ssip);
            return .supervisor_software_interrupt;
        }
        if (pending & mip_stip != 0) {
            self.storeCsr(Csr.mip, self.loadCsr(Csr.mip) & ~mip_stip);
            return .supervisor_timer_interrupt;
        }
        return .none;
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
    _ = cpu.checkPendingInterrupt();

    var x: u64 = 0xFFFF_FFFF_FFFF_FFFF;
    const xx = @bitCast(i8, @truncate(u8, x));
    std.debug.print("0x{X}\n", .{xx});
}
