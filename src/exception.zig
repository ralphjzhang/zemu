pub const Exception = enum(u4) {
    instruction_address_misaligned = 0,
    instruction_access_fault,
    illegal_instruction,
    breakpoint,
    load_address_misaligned,
    load_access_fault,
    store_amo_address_misaligned,
    store_amo_access_fault,
    ecall_from_umode,
    ecall_from_smode,
    ecall_from_mmode = 11,
    instruction_page_fault,
    load_page_fault,
    store_amo_page_fault = 15,

    pub fn isFatal(self: Exception) bool {
        return switch (self) {
            .instruction_address_misaligned, .instruction_access_fault, .load_access_fault, .store_amo_address_misaligned, .store_amo_access_fault => true,
            else => false,
        };
    }
};

pub const Interrupt = enum(u4) {
    user_software_interrupt = 0,
    supervisor_software_interrupt = 1,
    machine_software_interrupt = 3,
    user_timer_interrupt = 4,
    supervisor_timer_interrupt = 5,
    machine_timer_interrupt = 7,
    user_external_interrupt = 8,
    supervisor_external_interrupt = 9,
    machine_external_interrupt = 11,
};
