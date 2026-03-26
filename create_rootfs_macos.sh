#!/bin/bash
#
# Create a MINIX v1 root filesystem image for Linux 0.01 booting in QEMU.
# macOS-compatible version: uses Python for partition table and MINIX fs creation.
# No sfdisk, mkfs.minix, losetup, or mount required.
#
# Usage: ./create_rootfs_macos.sh
# Requires: i686-elf-as, i686-elf-ld, i686-elf-objcopy, python3

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOTFS="${SCRIPT_DIR}/rootfs.img"

# Detect cross-toolchain prefix
if command -v i686-elf-as &>/dev/null; then
    AS="i686-elf-as --32"
    LD="i686-elf-ld -m elf_i386"
    OBJCOPY="i686-elf-objcopy"
elif command -v as &>/dev/null && as --version 2>&1 | grep -q GNU; then
    AS="as --32"
    LD="ld -m elf_i386"
    OBJCOPY="objcopy"
else
    echo "Error: need i686-elf-binutils (brew install i686-elf-binutils)"
    exit 1
fi

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Create minimal userspace binaries
# /bin/update: loop doing sync() + pause()
cat > "$TMPDIR/update.s" << 'ASM'
.text
.globl _start
_start:
    movl $36, %eax
    int $0x80
    movl $29, %eax
    int $0x80
    jmp _start
ASM

# /bin/sh: write a message then loop with pause()
cat > "$TMPDIR/sh.s" << 'ASM'
.text
.globl _start
_start:
    movl $4, %eax
    movl $1, %ebx
    leal msg, %ecx
    movl $msglen, %edx
    int $0x80
loop:
    movl $29, %eax
    int $0x80
    jmp loop
msg:
    .ascii "Linux 0.01 booted successfully!\n"
    msglen = . - msg
ASM

$AS -o "$TMPDIR/update.o" "$TMPDIR/update.s"
$LD -Ttext 0 -e _start -o "$TMPDIR/update.elf" "$TMPDIR/update.o"
$OBJCOPY -O binary "$TMPDIR/update.elf" "$TMPDIR/update.bin"

$AS -o "$TMPDIR/sh.o" "$TMPDIR/sh.s"
$LD -Ttext 0 -e _start -o "$TMPDIR/sh.elf" "$TMPDIR/sh.o"
$OBJCOPY -O binary "$TMPDIR/sh.elf" "$TMPDIR/sh.bin"

echo "Userspace binaries created."

# Do everything else in Python: create disk image, partition table, MINIX fs
python3 - "$ROOTFS" "$TMPDIR/update.bin" "$TMPDIR/sh.bin" << 'PYEOF'
import struct
import sys
import time

ROOTFS = sys.argv[1]
UPDATE_BIN = sys.argv[2]
SH_BIN = sys.argv[3]

# Disk geometry matching HD_TYPE in config.h
HEADS = 4
SECTORS = 17
CYLINDERS = 100
SECTOR_SIZE = 512
TOTAL_SECTORS = HEADS * SECTORS * CYLINDERS
BLOCK_SIZE = 1024

# Partition starts at sector 17 (track 1)
PART_START = SECTORS  # 17
PART_SIZE = TOTAL_SECTORS - PART_START

print(f"Creating disk image: {TOTAL_SECTORS * SECTOR_SIZE} bytes ({TOTAL_SECTORS} sectors)")

# Create blank disk image
disk = bytearray(TOTAL_SECTORS * SECTOR_SIZE)

# --- Write MBR partition table ---
# Partition entry at offset 0x1BE (446)
# CHS start: head=1, sector=1, cylinder=0
# CHS end: head=3, sector=17, cylinder=99
# Type: 0x81 (MINIX)
part_entry = struct.pack('<BBBB BBBB II',
    0x80,  # bootable
    1,     # start head
    1,     # start sector (bits 0-5) | cylinder high (bits 6-7)
    0,     # start cylinder low
    0x81,  # type: MINIX
    HEADS - 1,                    # end head
    SECTORS | (((CYLINDERS-1) >> 2) & 0xC0),  # end sector + cyl high
    (CYLINDERS - 1) & 0xFF,      # end cylinder low
    PART_START,                   # LBA start
    PART_SIZE                     # LBA size
)
disk[0x1BE:0x1BE + 16] = part_entry
disk[0x1FE] = 0x55  # MBR signature
disk[0x1FF] = 0xAA

print("MBR partition table written.")

# --- Create MINIX v1 filesystem in partition area ---
part_offset = PART_START * SECTOR_SIZE
part_bytes = PART_SIZE * SECTOR_SIZE
part_blocks = part_bytes // BLOCK_SIZE

# MINIX v1 parameters
MINIX_MAGIC = 0x137F
INODE_SIZE = 32
DIR_ENTRY_SIZE = 16  # 2 byte inode + 14 byte name
INODES_PER_BLOCK = BLOCK_SIZE // INODE_SIZE  # 32

# Calculate filesystem layout
s_ninodes = 128  # enough for our small fs
s_imap_blocks = 1
s_zmap_blocks = 1
inode_table_blocks = (s_ninodes + INODES_PER_BLOCK - 1) // INODES_PER_BLOCK  # 4
s_firstdatazone = 2 + s_imap_blocks + s_zmap_blocks + inode_table_blocks  # 2+1+1+4 = 8
s_nzones = min(part_blocks, 65535)
s_log_zone_size = 0
s_max_size = 7 * 1024 + 512 * 1024 + 512 * 512 * 1024  # approx

def poff(block):
    """Convert partition-relative block number to byte offset in disk."""
    return part_offset + block * BLOCK_SIZE

# Write superblock at block 1
sb = struct.pack('<HHHHHHI HH',
    s_ninodes, s_nzones, s_imap_blocks, s_zmap_blocks,
    s_firstdatazone, s_log_zone_size, s_max_size,
    MINIX_MAGIC, 0)
sb = sb + b'\x00' * (BLOCK_SIZE - len(sb))
disk[poff(1):poff(1) + BLOCK_SIZE] = sb

# Initialize inode bitmap (block 2)
# Bit 0 is reserved (always set), bit 1 = root inode (allocated)
imap = bytearray(BLOCK_SIZE)
imap[0] = 0x03  # bits 0 and 1 set (reserved + root inode)
disk[poff(2):poff(2) + BLOCK_SIZE] = imap

# Initialize zone bitmap (block 3)
# Bit 0 is reserved (always set)
zmap = bytearray(BLOCK_SIZE)
zmap[0] = 0x01  # bit 0 reserved
disk[poff(3):poff(3) + BLOCK_SIZE] = zmap

# State tracking
next_inode = 2  # next free inode (root=1 already allocated)
next_zone_bit = 1  # next free zone bitmap bit

def alloc_inode():
    global next_inode
    ino = next_inode
    next_inode += 1
    # Set bit in inode bitmap
    byte_idx = ino // 8
    bit_idx = ino % 8
    bm_off = poff(2) + byte_idx
    disk[bm_off] |= (1 << bit_idx)
    return ino

def alloc_zone():
    global next_zone_bit
    zbit = next_zone_bit
    next_zone_bit += 1
    # Set bit in zone bitmap
    byte_idx = zbit // 8
    bit_idx = zbit % 8
    bm_off = poff(3) + byte_idx
    disk[bm_off] |= (1 << bit_idx)
    return zbit

def zone_to_block(zone):
    return zone + s_firstdatazone - 1

def write_inode(ino, mode, uid, size, mtime, gid, nlinks, zones):
    idx = ino - 1
    block = 2 + s_imap_blocks + s_zmap_blocks + idx // INODES_PER_BLOCK
    offset = poff(block) + (idx % INODES_PER_BLOCK) * INODE_SIZE
    # Pad zones to 9 entries
    z = list(zones) + [0] * (9 - len(zones))
    data = struct.pack('<HHI I BB 9H',
        mode, uid, size, mtime, gid, nlinks, *z[:9])
    disk[offset:offset + INODE_SIZE] = data

def write_dir_entry(block_num, entry_idx, ino, name):
    offset = poff(block_num) + entry_idx * DIR_ENTRY_SIZE
    name_bytes = name.encode('ascii')[:14].ljust(14, b'\x00')
    data = struct.pack('<H14s', ino, name_bytes)
    disk[offset:offset + DIR_ENTRY_SIZE] = data

def create_aout(binpath):
    """Create a.out ZMAGIC binary from flat binary."""
    with open(binpath, 'rb') as bf:
        code = bf.read()
    textsize = len(code)
    aligned = (textsize + 4095) & ~4095
    header = struct.pack('<IIIIIIII',
        0x0000010b,  # ZMAGIC
        aligned, 0, 0, 0, 0, 0, 0)
    return header + b'\x00' * (1024 - 32) + code + b'\x00' * (aligned - textsize)

def write_file_blocks(data):
    """Write data to allocated zones, return list of zone numbers."""
    zones = []
    offset = 0
    while offset < len(data):
        chunk = data[offset:offset + BLOCK_SIZE]
        if len(chunk) < BLOCK_SIZE:
            chunk = chunk + b'\x00' * (BLOCK_SIZE - len(chunk))
        zone = alloc_zone()
        zones.append(zone)
        blk = zone_to_block(zone)
        disk[poff(blk):poff(blk) + BLOCK_SIZE] = chunk
        offset += BLOCK_SIZE
    return zones

now = int(time.time())

# --- Create root directory (inode 1) ---
root_zone = alloc_zone()
root_block = zone_to_block(root_zone)

# Will fill in entries as we go
root_entries = 0

def root_add_entry(ino, name):
    global root_entries
    write_dir_entry(root_block, root_entries, ino, name)
    root_entries += 1

# . and ..
root_add_entry(1, '.')
root_add_entry(1, '..')

# --- Create /dev directory ---
dev_ino = alloc_inode()
dev_zone = alloc_zone()
dev_block = zone_to_block(dev_zone)
dev_entries = 0

def dev_add_entry(ino, name):
    global dev_entries
    write_dir_entry(dev_block, dev_entries, ino, name)
    dev_entries += 1

dev_add_entry(dev_ino, '.')
dev_add_entry(1, '..')

# Device nodes in /dev
# /dev/tty0 - char 4,0
tty0_ino = alloc_inode()
write_inode(tty0_ino, 0o20666, 0, 0, now, 0, 1, [(4 << 8) | 0])
dev_add_entry(tty0_ino, 'tty0')

# /dev/tty1 - char 4,1
tty1_ino = alloc_inode()
write_inode(tty1_ino, 0o20666, 0, 0, now, 0, 1, [(4 << 8) | 1])
dev_add_entry(tty1_ino, 'tty1')

# /dev/hda - block 3,0
hda_ino = alloc_inode()
write_inode(hda_ino, 0o60600, 0, 0, now, 0, 1, [(3 << 8) | 0])
dev_add_entry(hda_ino, 'hda')

# /dev/hda1 - block 3,1
hda1_ino = alloc_inode()
write_inode(hda1_ino, 0o60600, 0, 0, now, 0, 1, [(3 << 8) | 1])
dev_add_entry(hda1_ino, 'hda1')

# Write /dev inode
write_inode(dev_ino, 0o40755, 0, dev_entries * DIR_ENTRY_SIZE, now, 0, 2, [dev_zone])

root_add_entry(dev_ino, 'dev')

# --- Create /bin directory ---
bin_ino = alloc_inode()
bin_zone = alloc_zone()
bin_block = zone_to_block(bin_zone)
bin_entries = 0

def bin_add_entry(ino, name):
    global bin_entries
    write_dir_entry(bin_block, bin_entries, ino, name)
    bin_entries += 1

bin_add_entry(bin_ino, '.')
bin_add_entry(1, '..')

# /bin/update
update_data = create_aout(UPDATE_BIN)
update_zones = write_file_blocks(update_data)
update_ino = alloc_inode()
write_inode(update_ino, 0o100755, 0, len(update_data), now, 0, 1, update_zones)
bin_add_entry(update_ino, 'update')
print(f"Created /bin/update ({len(update_data)} bytes)")

# /bin/sh
sh_data = create_aout(SH_BIN)
sh_zones = write_file_blocks(sh_data)
sh_ino = alloc_inode()
write_inode(sh_ino, 0o100755, 0, len(sh_data), now, 0, 1, sh_zones)
bin_add_entry(sh_ino, 'sh')
print(f"Created /bin/sh ({len(sh_data)} bytes)")

# Write /bin inode
write_inode(bin_ino, 0o40755, 0, bin_entries * DIR_ENTRY_SIZE, now, 0, 2, [bin_zone])

root_add_entry(bin_ino, 'bin')

# --- Create /etc directory ---
etc_ino = alloc_inode()
etc_zone = alloc_zone()
etc_block = zone_to_block(etc_zone)
write_dir_entry(etc_block, 0, etc_ino, '.')
write_dir_entry(etc_block, 1, 1, '..')
write_inode(etc_ino, 0o40755, 0, 2 * DIR_ENTRY_SIZE, now, 0, 2, [etc_zone])
root_add_entry(etc_ino, 'etc')

# --- Create /usr directory ---
usr_ino = alloc_inode()
usr_zone = alloc_zone()
usr_block = zone_to_block(usr_zone)
usr_entries = 0

def usr_add_entry(ino, name):
    global usr_entries
    write_dir_entry(usr_block, usr_entries, ino, name)
    usr_entries += 1

usr_add_entry(usr_ino, '.')
usr_add_entry(1, '..')

# /usr/root
usrroot_ino = alloc_inode()
usrroot_zone = alloc_zone()
usrroot_block = zone_to_block(usrroot_zone)
write_dir_entry(usrroot_block, 0, usrroot_ino, '.')
write_dir_entry(usrroot_block, 1, usr_ino, '..')
write_inode(usrroot_ino, 0o40755, 0, 2 * DIR_ENTRY_SIZE, now, 0, 2, [usrroot_zone])
usr_add_entry(usrroot_ino, 'root')

write_inode(usr_ino, 0o40755, 0, usr_entries * DIR_ENTRY_SIZE, now, 0, 3, [usr_zone])
root_add_entry(usr_ino, 'usr')

# --- Write root inode ---
# nlinks = 2 (self) + number of subdirectories (dev, bin, etc, usr = 4) = 6
write_inode(1, 0o40755, 0, root_entries * DIR_ENTRY_SIZE, now, 0, 2 + 4, [root_zone])

# --- Write disk image ---
with open(ROOTFS, 'wb') as f:
    f.write(disk)

print(f"\nRoot filesystem image created: {ROOTFS}")
print(f"Disk: {CYLINDERS} cyl, {HEADS} heads, {SECTORS} spt = {len(disk)} bytes")
PYEOF

echo ""
echo "Done! Now run: ./run.sh"
