#!/bin/bash
#
# Create a MINIX v1 root filesystem image for Linux 0.01 booting in QEMU.
#
# HD_TYPE in config.h: { 4, 17, 100, 0, 100, 0 }
#   4 heads, 17 sectors/track, 100 cylinders
#   Total: 4 * 17 * 100 = 6800 sectors = 3,481,600 bytes
#
# ROOT_DEV = 0x301 = /dev/hda1 (first partition on first HD)
#

set -e

ROOTFS=rootfs.img
HEADS=4
SECTORS=17
CYLINDERS=100
TOTAL_SECTORS=$((HEADS * SECTORS * CYLINDERS))

echo "Creating disk image: $((TOTAL_SECTORS * 512)) bytes (${TOTAL_SECTORS} sectors)"

# Create blank disk image
dd if=/dev/zero of=${ROOTFS} bs=512 count=${TOTAL_SECTORS} 2>/dev/null

# Create partition table with one partition starting at sector 17 (head 1, cyl 0)
PART_START=${SECTORS}
PART_SIZE=$((TOTAL_SECTORS - PART_START))

echo "${PART_START},${PART_SIZE},0x81,-" | sfdisk --no-reread ${ROOTFS} 2>/dev/null || true

echo "Partition table created."

# Create minimal userspace binaries (flat binary, will be wrapped in a.out)
# /bin/update: loop doing sync() + pause()
cat > /tmp/update.s << 'ASM'
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
cat > /tmp/sh.s << 'ASM'
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

as --32 -o /tmp/update.o /tmp/update.s
ld -m elf_i386 -Ttext 0 -e _start -o /tmp/update.elf /tmp/update.o
objcopy -O binary /tmp/update.elf /tmp/update.bin

as --32 -o /tmp/sh.o /tmp/sh.s
ld -m elf_i386 -Ttext 0 -e _start -o /tmp/sh.elf /tmp/sh.o
objcopy -O binary /tmp/sh.elf /tmp/sh.bin

echo "Userspace binaries created."

# Extract partition, format as MINIX v1, then populate using Python
dd if=${ROOTFS} of=part.img bs=512 skip=${PART_START} count=${PART_SIZE} 2>/dev/null

mkfs.minix -1 -n 14 part.img 2>/dev/null

echo "MINIX v1 filesystem created. Populating..."

# Use Python to directly write files into the MINIX v1 filesystem
python3 << 'PYEOF'
import struct
import os
import stat
import time

BLOCK_SIZE = 1024
PART_IMG = "part.img"

def read_block(f, block):
    f.seek(block * BLOCK_SIZE)
    return f.read(BLOCK_SIZE)

def write_block(f, block, data):
    f.seek(block * BLOCK_SIZE)
    f.write(data)

def create_aout(binpath):
    """Create a.out ZMAGIC binary from flat binary."""
    with open(binpath, 'rb') as bf:
        code = bf.read()
    textsize = len(code)
    aligned = (textsize + 4095) & ~4095
    # a.out header
    header = struct.pack('<IIIIIIII',
        0x0000010b,  # ZMAGIC
        aligned,     # a_text
        0, 0, 0,     # a_data, a_bss, a_syms
        0, 0, 0)     # a_entry, a_trsize, a_drsize
    result = header + b'\x00' * (1024 - 32) + code + b'\x00' * (aligned - textsize)
    return result

# MINIX v1 superblock format (at block 1, offset 1024)
# uint16 s_ninodes
# uint16 s_nzones
# uint16 s_imap_blocks
# uint16 s_zmap_blocks
# uint16 s_firstdatazone
# uint16 s_log_zone_size
# uint32 s_max_size
# uint16 s_magic
# uint16 s_state

MINIX_SUPER_MAGIC = 0x137F
MINIX_INODE_SIZE = 32  # MINIX v1 inode: 32 bytes
MINIX_DIR_ENTRY_SIZE = 16  # 2 bytes inode + 14 bytes name
INODES_PER_BLOCK = BLOCK_SIZE // MINIX_INODE_SIZE  # 32

with open(PART_IMG, 'r+b') as f:
    # Read superblock
    sb_data = read_block(f, 1)
    (s_ninodes, s_nzones, s_imap_blocks, s_zmap_blocks,
     s_firstdatazone, s_log_zone_size, s_max_size,
     s_magic, s_state) = struct.unpack_from('<HHHHHHI HH', sb_data, 0)

    assert s_magic == MINIX_SUPER_MAGIC, f"Bad magic: {s_magic:#x}"
    print(f"Superblock: {s_ninodes} inodes, {s_nzones} zones, "
          f"firstdata={s_firstdatazone}, imap={s_imap_blocks}, zmap={s_zmap_blocks}")

    # Block layout:
    # 0: boot block
    # 1: superblock
    # 2 .. 2+imap_blocks-1: inode bitmap
    # 2+imap_blocks .. 2+imap_blocks+zmap_blocks-1: zone bitmap
    # 2+imap_blocks+zmap_blocks .. firstdatazone-1: inode table
    imap_start = 2
    zmap_start = imap_start + s_imap_blocks
    inode_start = zmap_start + s_zmap_blocks

    def read_inode(ino):
        """Read inode number ino (1-based)."""
        idx = ino - 1
        block = inode_start + idx // INODES_PER_BLOCK
        offset = (idx % INODES_PER_BLOCK) * MINIX_INODE_SIZE
        data = read_block(f, block)
        # MINIX v1 inode: mode(2), uid(2), size(4), mtime(4), gid(1), nlinks(1), zone[9](18)
        fields = struct.unpack_from('<HHI I BB 9H', data, offset)
        return {
            'mode': fields[0], 'uid': fields[1], 'size': fields[2],
            'mtime': fields[3], 'gid': fields[4], 'nlinks': fields[5],
            'zones': list(fields[6:15])
        }

    def write_inode(ino, inode):
        """Write inode number ino (1-based)."""
        idx = ino - 1
        block = inode_start + idx // INODES_PER_BLOCK
        offset = (idx % INODES_PER_BLOCK) * MINIX_INODE_SIZE
        data = bytearray(read_block(f, block))
        struct.pack_into('<HHI I BB 9H', data, offset,
            inode['mode'], inode['uid'], inode['size'],
            inode['mtime'], inode['gid'], inode['nlinks'],
            *inode['zones'])
        write_block(f, block, bytes(data))

    def alloc_inode():
        """Allocate a free inode from the inode bitmap."""
        for bk in range(s_imap_blocks):
            data = bytearray(read_block(f, imap_start + bk))
            for byte_idx in range(BLOCK_SIZE):
                if data[byte_idx] != 0xFF:
                    for bit in range(8):
                        if not (data[byte_idx] & (1 << bit)):
                            ino = bk * BLOCK_SIZE * 8 + byte_idx * 8 + bit
                            if ino == 0:
                                continue  # inode 0 is reserved
                            if ino > s_ninodes:
                                raise RuntimeError("No free inodes")
                            data[byte_idx] |= (1 << bit)
                            write_block(f, imap_start + bk, bytes(data))
                            return ino
        raise RuntimeError("No free inodes")

    def alloc_zone():
        """Allocate a free zone from the zone bitmap."""
        for bk in range(s_zmap_blocks):
            data = bytearray(read_block(f, zmap_start + bk))
            for byte_idx in range(BLOCK_SIZE):
                if data[byte_idx] != 0xFF:
                    for bit in range(8):
                        if not (data[byte_idx] & (1 << bit)):
                            zone = bk * BLOCK_SIZE * 8 + byte_idx * 8 + bit
                            if zone == 0:
                                continue
                            abs_block = zone + s_firstdatazone - 1
                            if zone >= s_nzones:
                                raise RuntimeError("No free zones")
                            data[byte_idx] |= (1 << bit)
                            write_block(f, zmap_start + bk, bytes(data))
                            return zone
        raise RuntimeError("No free zones")

    def zone_to_block(zone):
        return zone + s_firstdatazone - 1

    def write_file_data(inode, file_data):
        """Write file data to zones referenced by inode."""
        offset = 0
        zone_idx = 0
        while offset < len(file_data):
            chunk = file_data[offset:offset + BLOCK_SIZE]
            if len(chunk) < BLOCK_SIZE:
                chunk = chunk + b'\x00' * (BLOCK_SIZE - len(chunk))
            zone = alloc_zone()
            if zone_idx < 7:
                inode['zones'][zone_idx] = zone
            else:
                raise RuntimeError("File too large for direct zones")
            write_block(f, zone_to_block(zone), chunk)
            offset += BLOCK_SIZE
            zone_idx += 1
        inode['size'] = len(file_data)

    def add_dir_entry(parent_inode_num, parent_inode, name, child_ino):
        """Add a directory entry to parent."""
        # Read existing directory data
        dir_size = parent_inode['size']
        # Find the zone with space or allocate new
        entries_per_block = BLOCK_SIZE // MINIX_DIR_ENTRY_SIZE
        entry_offset = dir_size
        zone_idx = entry_offset // BLOCK_SIZE
        block_offset = entry_offset % BLOCK_SIZE

        if zone_idx < 7:
            if parent_inode['zones'][zone_idx] == 0:
                zone = alloc_zone()
                parent_inode['zones'][zone_idx] = zone
                write_block(f, zone_to_block(zone), b'\x00' * BLOCK_SIZE)
            zone = parent_inode['zones'][zone_idx]
        else:
            raise RuntimeError("Directory too large")

        block_num = zone_to_block(zone)
        data = bytearray(read_block(f, block_num))
        # Pack directory entry: uint16 inode + 14 byte name
        name_bytes = name.encode('ascii')[:14].ljust(14, b'\x00')
        struct.pack_into('<H14s', data, block_offset, child_ino, name_bytes)
        write_block(f, block_num, bytes(data))

        parent_inode['size'] = dir_size + MINIX_DIR_ENTRY_SIZE
        write_inode(parent_inode_num, parent_inode)

    def create_dir(parent_ino, parent_inode, name, mode=0o40755):
        """Create a subdirectory."""
        ino = alloc_inode()
        now = int(time.time())
        inode = {
            'mode': mode, 'uid': 0, 'size': 0,
            'mtime': now, 'gid': 0, 'nlinks': 2,
            'zones': [0]*9
        }
        # Create . and .. entries
        zone = alloc_zone()
        inode['zones'][0] = zone
        dir_data = bytearray(BLOCK_SIZE)
        # . entry
        name_dot = b'.\x00' + b'\x00' * 12
        struct.pack_into('<H14s', dir_data, 0, ino, name_dot)
        # .. entry
        name_dotdot = b'..\x00' + b'\x00' * 11
        struct.pack_into('<H14s', dir_data, 16, parent_ino, name_dotdot)
        inode['size'] = 2 * MINIX_DIR_ENTRY_SIZE
        write_block(f, zone_to_block(zone), bytes(dir_data))
        write_inode(ino, inode)

        # Add entry in parent
        add_dir_entry(parent_ino, parent_inode, name, ino)

        # Update parent nlinks
        parent_inode['nlinks'] += 1
        write_inode(parent_ino, parent_inode)

        return ino, inode

    def create_file(parent_ino, parent_inode, name, data, mode=0o100755):
        """Create a regular file."""
        ino = alloc_inode()
        now = int(time.time())
        inode = {
            'mode': mode, 'uid': 0, 'size': 0,
            'mtime': now, 'gid': 0, 'nlinks': 1,
            'zones': [0]*9
        }
        write_file_data(inode, data)
        write_inode(ino, inode)
        add_dir_entry(parent_ino, parent_inode, name, ino)
        return ino, inode

    def create_device(parent_ino, parent_inode, name, major, minor, mode):
        """Create a device node."""
        ino = alloc_inode()
        now = int(time.time())
        dev = (major << 8) | minor
        inode = {
            'mode': mode, 'uid': 0, 'size': 0,
            'mtime': now, 'gid': 0, 'nlinks': 1,
            'zones': [dev, 0, 0, 0, 0, 0, 0, 0, 0]
        }
        write_inode(ino, inode)
        add_dir_entry(parent_ino, parent_inode, name, ino)
        return ino, inode

    # Root inode is inode 1
    root_ino = 1
    root_inode = read_inode(root_ino)
    print(f"Root inode: mode={root_inode['mode']:#o}, size={root_inode['size']}, "
          f"nlinks={root_inode['nlinks']}")

    # Create /bin directory
    bin_ino, bin_inode = create_dir(root_ino, root_inode, 'bin')
    root_inode = read_inode(root_ino)  # re-read after modification
    print(f"Created /bin (inode {bin_ino})")

    # Create /dev directory
    dev_ino, dev_inode = create_dir(root_ino, root_inode, 'dev')
    root_inode = read_inode(root_ino)
    print(f"Created /dev (inode {dev_ino})")

    # Create /etc directory
    etc_ino, etc_inode = create_dir(root_ino, root_inode, 'etc')
    root_inode = read_inode(root_ino)
    print(f"Created /etc (inode {etc_ino})")

    # Create /usr directory
    usr_ino, usr_inode = create_dir(root_ino, root_inode, 'usr')
    root_inode = read_inode(root_ino)
    print(f"Created /usr (inode {usr_ino})")

    # Create /usr/root directory
    usrroot_ino, usrroot_inode = create_dir(usr_ino, usr_inode, 'root')
    print(f"Created /usr/root (inode {usrroot_ino})")

    # Create device nodes
    # /dev/tty0 - char device 4,0
    create_device(dev_ino, dev_inode, 'tty0', 4, 0, 0o20666)
    dev_inode = read_inode(dev_ino)
    print("Created /dev/tty0")

    # /dev/tty1 - char device 4,1
    create_device(dev_ino, dev_inode, 'tty1', 4, 1, 0o20666)
    dev_inode = read_inode(dev_ino)
    print("Created /dev/tty1")

    # /dev/hda - block device 3,0
    create_device(dev_ino, dev_inode, 'hda', 3, 0, 0o60600)
    dev_inode = read_inode(dev_ino)
    print("Created /dev/hda")

    # /dev/hda1 - block device 3,1
    create_device(dev_ino, dev_inode, 'hda1', 3, 1, 0o60600)
    dev_inode = read_inode(dev_ino)
    print("Created /dev/hda1")

    # Create /bin/update
    update_data = create_aout('/tmp/update.bin')
    bin_inode = read_inode(bin_ino)
    create_file(bin_ino, bin_inode, 'update', update_data)
    print("Created /bin/update")

    # Create /bin/sh
    sh_data = create_aout('/tmp/sh.bin')
    bin_inode = read_inode(bin_ino)
    create_file(bin_ino, bin_inode, 'sh', sh_data)
    print("Created /bin/sh")

print("Filesystem populated successfully!")
PYEOF

# Write formatted+populated partition back to disk image
dd if=part.img of=${ROOTFS} bs=512 seek=${PART_START} conv=notrunc 2>/dev/null
rm -f part.img

echo ""
echo "Root filesystem image created: ${ROOTFS}"
echo "Disk geometry: ${CYLINDERS} cyl, ${HEADS} heads, ${SECTORS} spt"
ls -la ${ROOTFS}
echo ""
echo "To boot: ./run.sh"
