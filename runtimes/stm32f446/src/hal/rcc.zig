//! Clock enable registers (RCC base 0x40023800)

const base = 0x4002_3800;

pub const ahb1enr: *volatile u32 = @ptrFromInt(base + 0x30);
pub const apb1enr: *volatile u32 = @ptrFromInt(base + 0x40);
pub const apb2enr: *volatile u32 = @ptrFromInt(base + 0x44);
