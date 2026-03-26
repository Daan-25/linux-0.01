/*
 * Linker script for Linux 0.01 kernel
 * Ensures sections are packed contiguously as the boot loader expects.
 */
OUTPUT_FORMAT("elf32-i386")
ENTRY(startup_32)

SECTIONS
{
    . = 0x0000;

    .text : {
        *(.text)
        *(.text.*)
    }

    .rodata : {
        *(.rodata)
        *(.rodata.*)
    }

    .data : {
        *(.data)
        *(.data.*)
    }

    .bss : {
        *(.bss)
        *(COMMON)
    }
    _end = .;
    end = .;

    /DISCARD/ : {
        *(.eh_frame)
        *(.eh_frame_hdr)
        *(.note.*)
        *(.comment)
        *(.note.GNU-stack)
    }
}
