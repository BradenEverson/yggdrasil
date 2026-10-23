OUTPUT_FORMAT("elf32-littlearm")
OUTPUT_ARCH(arm)

MEMORY
{
    FLASH (rx)  : ORIGIN = 0x08000000, LENGTH = 512K
    RAM   (rwx) : ORIGIN = 0x20000000, LENGTH = 128K
}

_estack = ORIGIN(RAM) + LENGTH(RAM);

PROVIDE(NMI_Handler        = Default_Handler);
PROVIDE(HardFault_Handler  = Default_Handler);
PROVIDE(MemManage_Handler  = Default_Handler);
PROVIDE(BusFault_Handler   = Default_Handler);
PROVIDE(UsageFault_Handler = Default_Handler);
PROVIDE(SVC_Handler        = Default_Handler);
PROVIDE(DebugMon_Handler   = Default_Handler);
PROVIDE(PendSV_Handler     = Default_Handler);
PROVIDE(SysTick_Handler    = Default_Handler);

SECTIONS {
    .vectors :
    {
        LONG(_estack)
        LONG(run + 1)
        LONG(NMI_Handler + 1)
        LONG(HardFault_Handler + 1)
        LONG(MemManage_Handler + 1)
        LONG(BusFault_Handler + 1)
        LONG(UsageFault_Handler + 1)
        LONG(0) LONG(0) LONG(0) LONG(0)
        LONG(SVC_Handler + 1)
        LONG(DebugMon_Handler + 1)
        LONG(0)
        LONG(PendSV_Handler + 1)
        LONG(SysTick_Handler + 1)
    } > FLASH

    .rodata :
    {
        . = ALIGN(4);
        *(.rodata*)
    } > FLASH

    .text :
    {
        . = ALIGN(4);
        *(.text*)
    } > FLASH

    .ARM.exidx :
    {
        *(.ARM.exidx*)
    } > FLASH

    _sidata = LOADADDR(.data);
    .data :
    {
        . = ALIGN(4);
        _sdata = .;
        *(.data*)
        . = ALIGN(4);
        _edata = .;
    } > RAM AT > FLASH

    .bss (NOLOAD) :
    {
        . = ALIGN(4);
        _sbss = .;
        *(.bss*)
        *(COMMON)
        . = ALIGN(4);
        _ebss = .;
    } > RAM
}

