#!/bin/echo not_sourced
# This is an example of how one could setup raid for instance.
#
# Be aware that the foreman discovery image with mdadm haven't been released yet.
# NOTE that i haven't tested this partition script yet because of that.

# find all disks.
DEVICES=$(lsblk -d -b -n -r -o TYPE,NAME | egrep ^disk | awk '{print "/dev/"$2}')
DEVCOUNT=$(echo ${DEVICES} | wc -w)
[[ ! ${DEVCOUNT} -gt 1 ]] && exit 1 # we need more than two disks for raid1 or raid10
[[ ! $((DEVCOUNT%2)) -eq 0 ]] && exit 1 # exit if we don't have an even disk count

# wipe devices
for i in ${DEVICES}; do
  dd if=/dev/zero of=${i} bs=512 count=2
done

# Create the array
if [[ ${DEVCOUNT} -eq 2 ]]; then
  mdadm --create /dev/md0 --run --level=1 --raid-devices=${DEVCOUNT} ${DEVICES}
elif [[ ${DEVCOUNT} -gt 4 ]]; then
  mdadm --create /dev/md0 --run --level=10 --raid-devices=${DEVCOUNT} ${DEVICES}
fi

# setting this variable will allow is to run mdadm in image.sh after rootfs is mounted
CUSTOM_LATE_CMD='mdadm --detail --scan | tee -a /target/etc/mdadm/mdadm.conf'

# set DISK variable
DISK=md0

# what is the disk size
DISK_SIZE=$(lsblk -d -b -n -r -o SIZE /dev/${DISK})

# enable swap based on disk size
[[ ${DISK_SIZE} -gt 10737418239 ]] && SWAP=true && SWAPSIZE=1 # if > 10GB disk, enable swap, swap 1GB
[[ ${DISK_SIZE} -gt 16106127359 ]] && SWAPSIZE=2 # if > 15GB disk, swap 2GB
[[ ${DISK_SIZE} -gt 32212254719 ]] && SWAPSIZE=4 # if > 30GB disk, swap 4GB
[[ ${DISK_SIZE} -gt 64424509439 ]] && SWAPSIZE=8 # if > 60GB disk, swap 8GB

# partition disk if boot parameters partition=true
parted="parted-3.2-static -a optimal -s -- /dev/${DISK}"
fstype=ext4
${parted} mklabel gpt
${parted} mkpart primary 0% 32MiB
${parted} name 1 grub
${parted} set 1 bios_grub on
if [[ ${SWAP} == 'true' ]]; then
  ${parted} mkpart primary linux-swap 32MiB ${SWAPSIZE}GiB
  ${parted} name 2 swap
  ${parted} mkpart primary ${fstype} ${SWAPSIZE}GiB -1
  ${parted} name 3 cloudimg-rootfs
  ${parted} set 3 boot on
  # set swap partition
  SWAP_PARTITION=/dev/${DISK}p2
  # set rootfs partition to third partition
  PARTITION=${DISK}p3
else
  ${parted} mkpart primary ${fstype} 32MiB -1
  ${parted} name 2 cloudimg-rootfs
  ${parted} set 2 boot on
  # set partition to second partition
  PARTITION=${DISK}p2
fi
