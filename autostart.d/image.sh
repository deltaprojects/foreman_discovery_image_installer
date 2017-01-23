#!/bin/bash -xe

# stop some of the discovery image services so the node doesn't get re-registered in foreman.
systemctl stop discovery-register.service &
systemctl disable discovery-register.service &
systemctl stop discovery-menu.service &
systemctl disable discovery-menu.service &

SMALLEST_DISK=$(lsblk -d -b -n -r -o TYPE,NAME,SIZE | egrep ^disk | sort -k3n | awk NR==1'{print $2}')
DISK_SIZE=$(lsblk -d -b -n -r -o NAME,SIZE | egrep ^${SMALLEST_DISK} | awk '{print $2}')
#printf %s\\n 'unit b print listquit' quit | parted | grep Disk | sort -k3n | awk NR==1'{print $2}' | cut -f1 -d:

# fetch /proc/cmdline
source /usr/share/fdi/commonfunc.sh
exportKCL

# wipe disk
dd if=/dev/zero of=/dev/${SMALLEST_DISK} bs=512 count=2

# set parititon to disk device
PARTITION=${SMALLEST_DISK}

[[ ${DISK_SIZE} -gt 10737418239 ]] && SWAP=true && SWAPSIZE=1 # if > 10GB disk, swap enabled, swap 1GB
[[ ${DISK_SIZE} -gt 16106127359 ]] && SWAPSIZE=2 # if > 15GB disk, swap 2GB
[[ ${DISK_SIZE} -gt 32212254719 ]] && SWAPSIZE=4 # if > 30GB disk, swap 4GB
[[ ${DISK_SIZE} -gt 64424509439 ]] && SWAPSIZE=8 # if > 60GB disk, swap 8GB

# partition disk if boot parameters partition=true
if [[ ${KCL_IMAGE_PARTITION} == 'true' ]]; then
  parted="parted-3.2-static -a optimal -s -- /dev/${SMALLEST_DISK}"
  fstype=ext4
  ${parted} mklabel gpt
  ${parted} mkpart primary 0% 32MiB
  ${parted} name 1 grub
  ${parted} set 1 bios_grub on
  # since parted 1.8.1 doesn't have the align features we align at 16MB.
  if [[ ${SWAP} == 'true' ]]; then
    ${parted} mkpart primary linux-swap 32MiB ${SWAPSIZE}GiB
    ${parted} name 2 swap
    ${parted} mkpart primary ${fstype} ${SWAPSIZE}GiB -1
    ${parted} name 3 cloudimg-rootfs
    ${parted} set 3 boot on
    # set partition to third partition
    PARTITION=${SMALLEST_DISK}3
  else
    ${parted} mkpart primary ${fstype} 32MiB -1
    ${parted} name 2 cloudimg-rootfs
    ${parted} set 2 boot on
    # set partition to second partition
    PARTITION=${SMALLEST_DISK}2
  fi
fi

# write OS image
curl ${KCL_IMAGE_IMAGE} | dd bs=2M of=/dev/${PARTITION}

mkdir /target
mount /dev/${PARTITION} /target
mount -t proc proc /target/proc
mount --rbind /sys /target/sys
mount --rbind /dev /target/dev
mount --rbind /run /target/run

# add noatime to mounts in /target/etc/fstab
noatime.rb

# create a swapfile if partitioning is set to false
if [[ ${SWAP} == 'true' ]] && [[ ${KCL_IMAGE_PARTITION} == 'false' ]]; then
  fallocate -l ${SWAPSIZE}G /target/swapfile
  chmod 600 /target/swapfile
  mkswap /target/swapfile
  echo /swapfile none swap sw 0 0 >> /target/etc/fstab
fi

# apparently when using systemd, it detects swap partitions automagically and mounts them.
# TODO: build detection if it's a systemd or systemv image.
# [[ ${SWAP} == 'true' ]] && [[ ${KCL_IMAGE_PARTITION} == 'true' ]] && echo "LABEL=swap none swap sw 0 0" >> /target/etc/fstab

# setup resolv.conf
rm /target/etc/resolv.conf
cp /etc/resolv.conf /target/etc/resolv.conf

# prepare for grub
# finish script will use this file to install grub on correct disk
echo /dev/${SMALLEST_DISK} > /target/tmp/disklist

# download and execute foreman finish script
curl -o /target/tmp/finish.sh ${KCL_IMAGE_FINISH}
chmod +x /target/tmp/finish.sh
chroot /target /tmp/finish.sh

# finish
sync
sleep 1
reboot
