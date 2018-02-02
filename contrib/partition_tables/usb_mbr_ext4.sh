#!/bin/echo not_sourced
# this is a partition script for usb/flash devices that a create a 50% size rootfs ext4 and leave the rest unused.

# find out which is the smallest disk and that is what we will use as OS disk
DISK=$(lsblk -d -b -n -r -o TYPE,NAME,SIZE | egrep ^disk | sort -k3n | awk NR==1'{print $2}')
# device to which grub will be installed on later
# shellcheck disable=SC2034
DEVICES=/dev/${DISK}

# set parititon to disk device
PARTITION=${DISK}

# disable swap
# shellcheck disable=SC2034
SWAP=false

# partition disk if boot parameters partition=true
parted="parted -a optimal -s -- /dev/${DISK}"
fstype=ext4
${parted} mklabel msdos
${parted} mkpart primary ${fstype} 0% 50%
${parted} set 1 boot on
# create a partition to stop other installation stages to expanding the partition to the rest of the disk.
${parted} mkpart primary ${fstype} 50% 51%
# set rootfs partition to first partition
# shellcheck disable=SC2034
PARTITION=${DISK}1
