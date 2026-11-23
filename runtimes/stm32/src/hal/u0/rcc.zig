const base = 0x4002_1000;

pub const cr: *volatile u32 = @ptrFromInt(base + 0x00);
pub const cfgr: *volatile u32 = @ptrFromInt(base + 0x08);
pub const iopenr: *volatile u32 = @ptrFromInt(base + 0x4C);
pub const apbenr1: *volatile u32 = @ptrFromInt(base + 0x58);
pub const apbenr2: *volatile u32 = @ptrFromInt(base + 0x60);
pub const bdcr: *volatile u32 = @ptrFromInt(base + 0x90);
pub const csr: *volatile u32 = @ptrFromInt(base + 0x94);
