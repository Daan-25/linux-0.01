#!/bin/bash
#
# Boot Linux 0.01 in QEMU
#
# Prerequisites:
#   - Build the kernel: make
#   - Create root filesystem: sudo ./create_rootfs.sh
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

IMAGE="${SCRIPT_DIR}/Image"
ROOTFS="${SCRIPT_DIR}/rootfs.img"

if [ ! -f "${IMAGE}" ]; then
    echo "Error: ${IMAGE} not found. Run 'make' first."
    exit 1
fi

if [ ! -f "${ROOTFS}" ]; then
    echo "Error: ${ROOTFS} not found. Run 'sudo ./create_rootfs.sh' first."
    exit 1
fi

echo "Booting Linux 0.01..."
echo "Press Ctrl-A X to exit QEMU"
echo ""

qemu-system-i386 \
    -fda "${IMAGE}" \
    -hda "${ROOTFS}" \
    -m 8 \
    -boot a \
    -display curses \
    "$@"
