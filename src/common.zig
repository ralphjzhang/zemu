pub const Exception = enum(i8) {
    ok = -1,
    instruction_address_misaligned = 0,
    illegal_instruction,
    breakpoint,
    load_address_misaligned,
    load_access_fault,
    store_amo_address_misaligned,
    store_amo_access_fault,
    ecall_from_umode,
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

pub const Result = union {
    result: u64,
    exception: Exception,
};
