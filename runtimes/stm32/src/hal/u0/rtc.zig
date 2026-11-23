const rcc = @import("rcc.zig");

const PWR_CR1: *volatile u32 = @ptrFromInt(0x4000_7000);
const PWR_DBP: u32 = 1 << 8;
const APBENR1_RTCAPBEN: u32 = 1 << 10;
const APBENR1_PWREN: u32 = 1 << 28;

const BDCR_LSEON: u32 = 1 << 0;
const BDCR_LSERDY: u32 = 1 << 1;
const BDCR_RTCSEL_MASK: u32 = 0b11 << 8;
const BDCR_RTCEN: u32 = 1 << 15;
const BDCR_BDRST: u32 = 1 << 16;

const CSR_LSION: u32 = 1 << 0;
const CSR_LSIRDY: u32 = 1 << 1;

const base = 0x4000_2800;
const TR: *volatile u32 = @ptrFromInt(base + 0x00);
const DR: *volatile u32 = @ptrFromInt(base + 0x04);
const SSR: *volatile u32 = @ptrFromInt(base + 0x08);
const ICSR: *volatile u32 = @ptrFromInt(base + 0x0C);
const PRER: *volatile u32 = @ptrFromInt(base + 0x10);
const WUTR: *volatile u32 = @ptrFromInt(base + 0x14);
const CR: *volatile u32 = @ptrFromInt(base + 0x18);
const WPR: *volatile u32 = @ptrFromInt(base + 0x24);
const SCR: *volatile u32 = @ptrFromInt(base + 0x5C);

const CR_WUCKSEL_MASK: u32 = 0b111;
const CR_BYPSHAD: u32 = 1 << 5;
const CR_WUTE: u32 = 1 << 10;
const CR_WUTIE: u32 = 1 << 14;

const ICSR_WUTWF: u32 = 1 << 2;
const ICSR_INITF: u32 = 1 << 6;
const ICSR_INIT: u32 = 1 << 7;

const SCR_CWUTF: u32 = 1 << 2;

const EXTI_IMR1: *volatile u32 = @ptrFromInt(0x4002_1800 + 0x80);
const EXTI_RTC_WAKEUP: u32 = 1 << 28;

const NVIC_ISER0: *volatile u32 = @ptrFromInt(0xE000_E100);
const RTC_TAMP_IRQ: u5 = 2;

const ASYNC_DIV: u32 = 8;
const MS_PER_DAY: u32 = 86_400_000;
const LSE_TIMEOUT_LOOPS: u32 = 8_000_000;

pub const MAX_WAKEUP_MS: u32 = 30_000;

pub const Source = enum { lse, lsi };

var source_hz: u32 = 32_768;
var sync_div: u32 = 4095;
var day_base: u32 = 0;
var last_tod: u32 = 0;
pub var ready: bool = false;

fn unlock() void {
    WPR.* = 0xCA;
    WPR.* = 0x53;
}

fn lock() void {
    WPR.* = 0xFF;
}

fn startLse() bool {
    rcc.bdcr.* |= BDCR_LSEON;
    var n: u32 = 0;
    while (rcc.bdcr.* & BDCR_LSERDY == 0) : (n += 1) {
        if (n >= LSE_TIMEOUT_LOOPS) {
            rcc.bdcr.* &= ~BDCR_LSEON;
            return false;
        }
    }
    return true;
}

fn startLsi() void {
    rcc.csr.* |= CSR_LSION;
    while (rcc.csr.* & CSR_LSIRDY == 0) {}
}

fn resetBackupDomain() void {
    rcc.bdcr.* |= BDCR_BDRST;
    rcc.bdcr.* &= ~BDCR_BDRST;
}

pub fn init() Source {
    rcc.apbenr1.* |= APBENR1_PWREN | APBENR1_RTCAPBEN;
    PWR_CR1.* |= PWR_DBP;
    while (PWR_CR1.* & PWR_DBP == 0) {}

    const wanted_sel: u32 = 0b01 << 8;
    const current_sel = rcc.bdcr.* & BDCR_RTCSEL_MASK;
    if (current_sel != 0 and current_sel != wanted_sel) resetBackupDomain();

    const src: Source = if (startLse()) .lse else blk: {
        if (rcc.bdcr.* & BDCR_RTCSEL_MASK != 0) resetBackupDomain();
        startLsi();
        break :blk .lsi;
    };

    source_hz = if (src == .lse) 32_768 else 32_000;
    sync_div = source_hz / ASYNC_DIV - 1;

    const sel: u32 = if (src == .lse) 0b01 else 0b10;
    rcc.bdcr.* = (rcc.bdcr.* & ~BDCR_RTCSEL_MASK) | (sel << 8) | BDCR_RTCEN;

    unlock();
    ICSR.* |= ICSR_INIT;
    while (ICSR.* & ICSR_INITF == 0) {}
    PRER.* = sync_div;
    PRER.* = sync_div | ((ASYNC_DIV - 1) << 16);
    TR.* = 0;
    DR.* = 0x0000_2101;
    CR.* = CR_BYPSHAD;
    ICSR.* &= ~ICSR_INIT;
    lock();

    EXTI_IMR1.* |= EXTI_RTC_WAKEUP;
    NVIC_ISER0.* = @as(u32, 1) << RTC_TAMP_IRQ;

    day_base = 0;
    last_tod = 0;
    ready = true;
    return src;
}

fn bcd(v: u32) u32 {
    return (v >> 4) * 10 + (v & 0xF);
}

pub fn millis() u32 {
    var ssr: u32 = undefined;
    var tr: u32 = undefined;
    while (true) {
        ssr = SSR.*;
        tr = TR.*;
        if (SSR.* == ssr and TR.* == tr) break;
    }

    const hours = bcd((tr >> 16) & 0x3F);
    const minutes = bcd((tr >> 8) & 0x7F);
    const seconds = bcd(tr & 0x7F);
    const sub = (sync_div -| ssr) * 1000 / (sync_div + 1);
    const tod = ((hours * 60 + minutes) * 60 + seconds) * 1000 + sub;

    if (tod < last_tod)
        day_base +%= MS_PER_DAY;
    last_tod = tod;
    return day_base +% tod;
}

pub fn armWakeup(ms: u32) void {
    const tick_hz = source_hz / 16;
    const ticks = @max(@as(u64, @min(ms, MAX_WAKEUP_MS)) * tick_hz / 1000, 1);

    unlock();
    CR.* &= ~(CR_WUTE | CR_WUTIE);
    while (ICSR.* & ICSR_WUTWF == 0) {}
    WUTR.* = @intCast(ticks - 1);
    SCR.* = SCR_CWUTF;
    CR.* = (CR.* & ~CR_WUCKSEL_MASK) | CR_WUTIE | CR_WUTE;
    lock();
}

pub fn disarmWakeup() void {
    unlock();
    CR.* &= ~(CR_WUTE | CR_WUTIE);
    SCR.* = SCR_CWUTF;
    lock();
}

export fn RTC_TAMP_IRQHandler() void {
    SCR.* = SCR_CWUTF;
}
