ENTRY(_start)

PHDRS
{
    text PT_LOAD FLAGS(5);   /* read + execute */
    rodata PT_LOAD FLAGS(4); /* read only */
    data PT_LOAD FLAGS(6);   /* initialized read + write data */
    bss PT_LOAD FLAGS(6);    /* zero-filled memory, never stored in the ELF */
}

SECTIONS
{
    /* Load kernel segments below the high-memory region used by UEFI apps. */
    . = 0x02000000;
    .text : ALIGN(4K) { *(.text .text.*) } :text
    .rodata : ALIGN(4K) { *(.rodata .rodata.*) } :rodata

    .data : ALIGN(4K) { *(.data .data.*) } :data
    .bss (NOLOAD) : ALIGN(4K) { *(COMMON) *(.bss .bss.*) } :bss
    /DISCARD/ : { *(.eh_frame .note .comment) }
}
