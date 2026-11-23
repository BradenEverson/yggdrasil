OUTPUT_FORMAT("elf32-littlearm")
OUTPUT_ARCH(arm)

MEMORY
{
    FLASH (rx)  : ORIGIN = 0x08000000, LENGTH = 128K
    RAM   (rwx) : ORIGIN = 0x20000000, LENGTH = 40K
}

ENTRY(run)

_estack = ORIGIN(RAM) + LENGTH(RAM);
_min_stack = 4K;

PROVIDE(NMI_Handler         = Default_Handler);
PROVIDE(HardFault_Handler   = Default_Handler);
PROVIDE(SVC_Handler         = Default_Handler);
PROVIDE(PendSV_Handler      = Default_Handler);
PROVIDE(SysTick_Handler     = Default_Handler);
PROVIDE(USART1_IRQHandler   = Default_Handler);
PROVIDE(RTC_TAMP_IRQHandler = Default_Handler);

SECTIONS {
    .vectors :
    {
        LONG(_estack)
        LONG(run + 1)
        LONG(NMI_Handler + 1)
        LONG(HardFault_Handler + 1)
        LONG(0) LONG(0) LONG(0) LONG(0) LONG(0) LONG(0) LONG(0)
        LONG(SVC_Handler + 1)
        LONG(0) LONG(0)
        LONG(PendSV_Handler + 1)
        LONG(SysTick_Handler + 1)
        LONG(Default_Handler + 1)
        LONG(Default_Handler + 1)
        LONG(RTC_TAMP_IRQHandler + 1)
        LONG(Default_Handler + 1)
        LONG(Default_Handler + 1)
        LONG(Default_Handler + 1)
        LONG(Default_Handler + 1)
        LONG(Default_Handler + 1)
        LONG(Default_Handler + 1)
        LONG(Default_Handler + 1)
        LONG(Default_Handler + 1)
        LONG(Default_Handler + 1)
        LONG(Default_Handler + 1)
        LONG(Default_Handler + 1)
        LONG(Default_Handler + 1)
        LONG(Default_Handler + 1)
        LONG(Default_Handler + 1)
        LONG(Default_Handler + 1)
        LONG(Default_Handler + 1)
        LONG(Default_Handler + 1)
        LONG(Default_Handler + 1)
        LONG(Default_Handler + 1)
        LONG(Default_Handler + 1)
        LONG(Default_Handler + 1)
        LONG(Default_Handler + 1)
        LONG(Default_Handler + 1)
        LONG(Default_Handler + 1)
        LONG(USART1_IRQHandler + 1)
        LONG(Default_Handler + 1)
        LONG(Default_Handler + 1)
        LONG(Default_Handler + 1)
        LONG(Default_Handler + 1)
    } > FLASH

    .rodata :
    {
        . = ALIGN(4);
        *(.rodata*)
    } > FLASH

    .text :
    {
        . = ALIGN(4);
        KEEP(*(.text*Handler))
        *(.text*)
    } > FLASH

    .ARM.exidx :
    {
        *(.ARM.exidx*)
        *(.ARM.extab*)
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

    ASSERT(_estack - _ebss >= _min_stack, "not enough RAM left for the stack, lower -Dmax_neighbors or -Dmax_queue_length")
}
