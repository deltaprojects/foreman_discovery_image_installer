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
parted="parted -a optimal -s -- /dev/${DISK}"
${parted} mklabel gpt

# temporary partition used to calculate optimal align size
${parted} mkpart primary 0% 1%
# optimal align byte size
byte=$(${parted} unit B print | grep " 1 " |awk '{print $2}')
byte=${byte::-1}
# optimal align sector size
sector=$(${parted} unit S print | grep " 1 " |awk '{print $2}')
sector=${sector::-1}
${parted} rm 1

# give grub mbr partition a optimal align size partition.
end=$((${sector}+${sector}))
${parted} mkpart primary ${sector}S ${end}S
${parted} name 1 grub
${parted} set 1 bios_grub on

# this is used to align next partition
start=$(${parted} unit S print | grep " 1 " |awk '{print $3}')
start=${start::-1}
start=$((${start}+${sector}))

# time to align swap partition
end=$((${SWAPSIZE}*1024*1024*1024))
round=$((${end}/${byte}))
end=$((${byte}*${round}))
${parted} mkpart primary linux-swap ${start}S ${end}B
${parted} name 2 swap

# time to align third partition
# this is used to align next partition
start=$(${parted} unit S print | grep " 2 " |awk '{print $3}')
start=${start::-1}
start=$((${start}+${sector}))

# rootfs ext4
# time to align rootfs partition
end=$((${ROOT_SIZE}*1024*1024*1024))
round=$((${end}/${byte}))
end=$((${byte}*${round}))
${parted} mkpart primary ext4 ${start}S ${end}B
${parted} name 3 cloudimg-rootfs
${parted} set 3 boot on

# this is used to align next partition
start=$(${parted} unit S print | grep " 3 " |awk '{print $3}')
start=${start::-1}
start=$((${start}+${sector}))

# datafs xfs
${parted} mkpart primary xfs ${start}S -1
${parted} name 4 data
mkfs.xfs -f /dev/${DISK}4 -L data

# set swap partition
# shellcheck disable=SC2034
[[ ${SWAP} == 'true' ]] && SWAP_PARTITION=/dev/${DISK}2
# set rootfs partition to third partition
# shellcheck disable=SC2034
PARTITION=${DISK}3

# shellcheck disable=SC2034
CUSTOM_LATE_CMD="mkdir /target/var/data && echo 'LABEL=data /var/data xfs noatime 0 2' | tee -a /target/etc/fstab"
