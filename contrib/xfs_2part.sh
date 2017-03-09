#!/bin/echo not_sourced
# this is a partition script creates a swap + a small rootfs ext4 and create a xfs partition with the rest.

DISK=$(lsblk -d -b -n -r -o TYPE,NAME,SIZE | egrep ^disk | sort -k3n | awk NR==1'{print $2}')
# device to which grub will be installed on later
DEVICES=/dev/${DISK}
# wipe disk
dd if=/dev/zero of=${DEVICES} bs=512 count=2

# what is the disk size
DISK_SIZE=$(lsblk -d -b -n -r -o SIZE /dev/${DISK})
# disk size in GB
DISK_SIZE=$(awk -vsize=${DISK_SIZE} 'BEGIN{printf int(size/1000/1000/1000)}')

# set swapsize
SWAP=true
[[ ${DISK_SIZE} -gt 10 ]] && SWAPSIZE=1
[[ ${DISK_SIZE} -gt 16 ]] && SWAPSIZE=2
[[ ${DISK_SIZE} -gt 32 ]] && SWAPSIZE=4
[[ ${DISK_SIZE} -gt 64 ]] && SWAPSIZE=8

# set size of root partition
[[ ${DISK_SIZE} -lt 500 ]] && ROOT_SIZE=20
[[ ${DISK_SIZE} -ge 500 ]] && ROOT_SIZE=50

ROOT_SIZE=$(awk -vroot=${ROOT_SIZE} -vswap=${SWAPSIZE} 'BEGIN{printf int(root+swap)}')

# partition disk
parted="parted-3.2-static -a optimal -s -- /dev/${DISK}"
${parted} mklabel gpt
${parted} mkpart primary 0% 32MiB
${parted} name 1 grub
${parted} set 1 bios_grub on
${parted} mkpart primary linux-swap 32MiB ${SWAPSIZE}GiB
${parted} name 2 swap
# rootfs ext4
${parted} mkpart primary ext4 ${SWAPSIZE}GiB ${ROOT_SIZE}GiB
${parted} name 3 cloudimg-rootfs
${parted} set 3 boot on
# datafs xfs
${parted} mkpart primary xfs ${ROOT_SIZE}GiB -1
${parted} name 4 data

# set swap partition
# shellcheck disable=SC2034
[[ ${SWAP} == 'true' ]] && SWAP_PARTITION=/dev/${DISK}2
# set rootfs partition to third partition
# shellcheck disable=SC2034
PARTITION=${DISK}3

#CUSTOM_LATE_CMD="chroot /target /sbin/mkfs.xfs -f /dev/${DISK}4 && mkdir /target/var/data && echo 'LABEL=data /var/data xfs noatime 0 2' | tee -a /target/etc/fstab"
