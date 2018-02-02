#!/bin/bash -xe

# kill some of the discovery image services so the node doesn't get re-registered in foreman
systemctl kill discovery-register.service &
systemctl disable discovery-register.service &
systemctl kill discovery-menu.service &
systemctl disable discovery-menu.service &

# fetch /proc/cmdline
source /usr/share/fdi/commonfunc.sh
exportKCL

# if not image.partition=custom (=auto or =no)
if ! [[ ${KCL_IMAGE_PARTITION} == 'custom' ]]; then
  # find out which is the smallest disk and that is what we will use as OS disk
  DISK=$(lsblk -d -b -n -r -o TYPE,NAME,SIZE | egrep ^disk | sort -k3n | awk NR==1'{print $2}')

  DEVICES=/dev/${DISK}

  # wipe disk
  dd if=/dev/zero of=/dev/${DISK} bs=512 count=2

  # set parititon to disk device
  PARTITION=${DISK}

  # what is the disk size
  DISK_SIZE=$(lsblk -d -b -n -r -o SIZE /dev/${DISK})

  # enable swap based on disk size
  [[ ${DISK_SIZE} -gt 10737418239 ]] && SWAP=true && SWAPSIZE=1 # if > 10GB disk, enable swap, swap 1GB
  [[ ${DISK_SIZE} -gt 16106127359 ]] && SWAPSIZE=2 # if > 15GB disk, swap 2GB
  [[ ${DISK_SIZE} -gt 32212254719 ]] && SWAPSIZE=4 # if > 30GB disk, swap 4GB
  [[ ${DISK_SIZE} -gt 64424509439 ]] && SWAPSIZE=8 # if > 60GB disk, swap 8GB
fi

# if image.partition=auto
if [[ ${KCL_IMAGE_PARTITION} == 'auto' ]]; then
  # partition disk if boot parameters partition=true
  parted="parted -a optimal -s -- /dev/${DISK}"
  fstype=ext4
  ${parted} mklabel gpt

  # temporary partition used to calculate optimal align size
  ${parted} mkpart primary 0% 1%
  # optimal byte sizes
  byte=$(${parted} unit B print | grep " 1 " |awk '{print $2}')
  byte=${byte::-1}
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

  if [[ ${SWAP} == 'true' ]]; then
    # time to align second partition
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
    ${parted} mkpart primary ${fstype} ${start}S -1
    ${parted} name 3 cloudimg-rootfs
    ${parted} set 3 boot on
    # set swap partition
    SWAP_PARTITION=/dev/${DISK}2
    # set rootfs partition to third partition
    PARTITION=${DISK}3

  else
    ${parted} mkpart primary ${fstype} ${start}S -1
    ${parted} name 2 cloudimg-rootfs
    ${parted} set 2 boot on
    # set rootfs partition to second partition
    PARTITION=${DISK}2
  fi
fi

if [[ ${KCL_IMAGE_PARTITION} == 'custom' ]]; then
  # download custom partition setup script
  # this script can be used to create a raid, lvm, zfs or something
  # remember that the script needs to set variables DEVICES and PARTITION
  # DEVICES should contain absolute path devices that need grub installed (ex. DEVICES=/dev/sda\n/dev/sdb or DEVICES=mapper/vg00-root)
  # PARTITION should contain device or partition that will be used as OS device relative to /dev/ (ex. PARTITION=md0p3 or PARTITION=mapper/vg00-root).
  # Optionally set SWAP_PARTITION and SWAP=true if you want to use a swap partition (ex. SWAP_PARTITION=/dev/md0p2).
  curl -o /tmp/partition.sh ${KCL_IMAGE_PARTITION_CUSTOM}
  source /tmp/partition.sh
fi

FETCH="curl ${KCL_IMAGE_IMAGE}"
WRITE="dd bs=2M of=/dev/${PARTITION}"
case ${KCL_IMAGE_IMAGE##*.} in
  gz ) WRITE="gzip -d - | ${WRITE}" ;;
  xz ) WRITE="xz -d - | ${WRITE}" ;;
  bz2 ) WRITE="bzip2 -d - | ${WRITE}"
  ;;
esac

# write OS image
eval "${FETCH} | ${WRITE}"

# run extra actions per filesystem type
case $(blkid | grep /dev/${PARTITION} | sed -e 's/.*TYPE="\(\S*\)".*/\1/') in
  ext*)
  # make sure filesystem matches partition size.
    e2fsck -p -f /dev/${PARTITION}
    resize2fs /dev/${PARTITION}
    ;;
esac

# mount OS partition
mkdir /target
mount /dev/${PARTITION} /target
mount -t proc proc /target/proc
mount --rbind /sys /target/sys
mount --rbind /dev /target/dev
mount --rbind /run /target/run

# add noatime to mounts in /target/etc/fstab
noatime.rb

# create a swapfile if partitioning is set to "no"
if [[ ${SWAP} == 'true' ]] && [[ ${KCL_IMAGE_PARTITION} == 'no' ]]; then
  fallocate -l ${SWAPSIZE}G /target/swapfile
  chmod 600 /target/swapfile
  SWAP_PARTITION=/target/swapfile
  echo /swapfile none swap sw 0 0 >> /target/etc/fstab
fi

# apparently when using systemd, it detects swap partitions automagically and mounts them
if [[ ! -f /target/bin/systemctl ]]; then
  [[ ${SWAP} == 'true' ]] && [[ ! ${KCL_IMAGE_PARTITION} == 'no' ]] && echo "LABEL=swap none swap sw 0 0" >> /target/etc/fstab
fi

# format swap partition
[[ ${SWAP} == 'true' ]] && mkswap ${SWAP_PARTITION}
# create a swap label
[[ ${SWAP} == 'true' ]] && [[ ! ${KCL_IMAGE_PARTITION} == 'no' ]] && swaplabel -L swap ${SWAP_PARTITION}

# setup resolv.conf as we need working networking within the chroot we are about to run
rm /target/etc/resolv.conf
cp /etc/resolv.conf /target/etc/resolv.conf

# prepare for grub
# finish script will use this file to install grub on correct disk
echo -e "${DEVICES}" > /target/tmp/disklist

# if custom partition script, we can run a command when rootfs is mounted to /target
eval  ${CUSTOM_LATE_CMD}

# download and execute foreman finish script
curl -o /target/tmp/finish.sh ${KCL_IMAGE_FINISH}
chmod +x /target/tmp/finish.sh
chroot /target /tmp/finish.sh

# finish
sync
sleep 1
reboot
