#!/bin/echo not_sourced
# This is an example of how one could setup raid for instance.
#
# Be aware that the foreman discovery image with mdadm haven't been released yet.
# temporary install rpm's until next version of discovery image.
rpm -ivh http://mirror.nsc.liu.se/CentOS/7.3.1611/os/x86_64/Packages/libreport-filesystem-2.1.11-35.el7.centos.x86_64.rpm
rpm -ivh --nodeps http://mirror.nsc.liu.se/CentOS/7.3.1611/os/x86_64/Packages/mdadm-3.4-14.el7.x86_64.rpm

# find all disks.
DEVICES=$(lsblk -d -b -n -r -o TYPE,NAME | egrep ^disk | awk '{print "/dev/"$2}')
DEVCOUNT=$(echo ${DEVICES} | wc -w)
[[ ! ${DEVCOUNT} -gt 1 ]] && exit 1 # we need more than two disks for raid1 or raid10
[[ ! $((DEVCOUNT%2)) -eq 0 ]] && exit 1 # exit if we don't have an even disk count

# wipe devices
for i in ${DEVICES}; do
  dd if=/dev/zero of=${i} bs=512 count=98303
done

# create partition table for mdraid
RAIDDEVICES=""
for dev in ${DEVICES}; do
  parted="parted-3.2-static -a optimal -s -- ${dev}"
  ${parted} mklabel gpt
  ${parted} mkpart primary 0% 32MiB
  ${parted} name 1 grub
  ${parted} set 1 bios_grub on
  ${parted} mkpart primary 32MiB -1
  ${parted} name 2 raid
  #${parted} set 2 raid on
  export RAIDDEVICES="${dev}2 ${RAIDDEVICES}"
done

# Create the array
if [[ ${DEVCOUNT} -eq 2 ]]; then
  mdadm --create /dev/md0 --run --level=1 --raid-devices=${DEVCOUNT} ${RAIDDEVICES}
elif [[ ${DEVCOUNT} -gt 4 ]]; then
  mdadm --create /dev/md0 --run --level=10 --raid-devices=${DEVCOUNT} ${RAIDDEVICES}
fi

# setting this variable will allow is to run mdadm in image.sh after rootfs is mounted
# shellcheck disable=SC2034
CUSTOM_LATE_CMD="mdadm --detail --scan | tee -a /target/etc/mdadm/mdadm.conf && cp /tmp/dmraid2mdadm.cfg /target/etc/default/grub.d/dmraid2mdadm.cfg"

cat << EOF > /tmp/dmraid2mdadm.cfg
DMRAID2MDADM_TOAPPEND="nomdmonddf nomdmonisw"

case "\$GRUB_CMDLINE_LINUX_DEFAULT" in
    *\$DMRAID2MDADM_TOAPPEND*)
        ;;
    *)
        GRUB_CMDLINE_LINUX_DEFAULT="\$GRUB_CMDLINE_LINUX_DEFAULT \$DMRAID2MDADM_TOAPPEND"
        ;;
esac
EOF

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
if [[ ${SWAP} == 'true' ]]; then
  ${parted} mkpart primary linux-swap 0% ${SWAPSIZE}GiB
  ${parted} name 1 swap
  ${parted} mkpart primary ${fstype} ${SWAPSIZE}GiB -1
  ${parted} name 2 cloudimg-rootfs
  ${parted} set 2 boot on
  # set swap partition
  # shellcheck disable=SC2034
  SWAP_PARTITION=/dev/${DISK}p1
  # set rootfs partition to third partition
  PARTITION=${DISK}p2
else
  ${parted} mkpart primary ${fstype} 0% -1
  ${parted} name 1 cloudimg-rootfs
  ${parted} set 1 boot on
  # set partition to second partition
  # shellcheck disable=SC2034
  PARTITION=${DISK}p1
fi
