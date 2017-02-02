# image installer extension for foreman discovery image

This is some helper scripts to use foreman discover image to write "cloud images" (ready OS images) disk on instances we want to deploy.
It can be used both on virtual and bare metal nodes. It's main purpose was to mimic deployment used in cloud and virtual environments on bare metal.

Why not deploy bare metal as you would virtual or cloud?

Installation is a lot faster than Kickstart and Preseed, and a lot less complicated. Anyone that have been using Preseed and written complex partman recipes knows what I'm talking about.

## TODO
Stuff we can do to improve this project.
* improve README
* add Udpcast support
* add and test CentOS/RHEL/SuSE and more distros
* make templates/examples and scripts more dynamic
* set image.partition=auto or custom when baremetal and image.partition=no when virtual.

## Setup
To use this it's recommended to have [The Foreman](https://theforeman.org/).
To setup foreman read foreman documentation and setup foreman discover(at least download the image to your TFTP/HTTP/PXE store).
After that we bend the will of foreman discovery image to something it wasn't originally intended for.

### foreman
A working setup is in foreman exemplified here.

1. Create a OS template.
2. Create PXE, finish, provision templates and associate with OS.
3. Go back to OS, select the templates.
4. Run create_image_installer_zip.sh and image_installer.zip copy to your TFTP server.

Examples below:
#### PXELinux template
Create a PXELinux or ipxe template and associate with OS

adjustable parameters
* image.image - URL to the raw image containing the OS.
* image.cloudinit - URL to cloud-init configuration (foreman provision)
* image.finish - URL to the finish script, this will run before reboot in a chroot.
* image.partition - currently this can be 'auto', 'no' or 'custom'.
  * if you set image.partition to custom you must add a image.partition.custom with a URL to custom partitioning script.

```ruby
<%#
kind: PXELinux
name: discovery_image_pxelinux
-%>
<%# Used to boot discovery image and get it to install os image to disk. %>
default discovery
LABEL discovery
  MENU LABEL Foreman Discovery Image
  KERNEL <%= foreman_server_url %>/files/os/fdi-image/vmlinuz0
  APPEND initrd=<%= foreman_server_url %>/files/os/fdi-image/initrd0.img rootflags=loop root=live:/fdi.iso rootfstype=auto ro rd.live.image acpi=force rd.luks=0 rd.md=0 rd.dm=0 rd.lvm=0 rd.bootif=0 rd.neednet=0 rd.debug=0 nomodeset fdi.ssh=1 fdi.rootpw=debug fdi.countdown=99999 fdi.noregister=0 proxy.url=<%= foreman_server_url %> proxy.type=foreman fdi.zips=os/fdi-image/image_installer.zip image.image=<%= foreman_server_url %>/files/os/ubuntu/<%= @host.operatingsystem.release_name %>-server-cloudimg-amd64.img image.cloudinit=<%= foreman_url("provision")%> image.partition=auto image.finish=<%= foreman_url("finish") %>
  IPAPPEND 2
```

#### finish template
Create a finish template and associate with OS

```bash
<%#
kind: Finish
name: discovery_image_finish
-%>
#!/bin/bash -x

PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# setup our local apt mirrors
cat << EOF > /etc/apt/sources.list
<%= snippet('ubuntu local apt repos') %>
EOF

# update apt repos
apt-get update

# install some needed packages
DEBIAN_FRONTEND=noninteractive apt-get install -y grep grub-pc ntpdate biosdevname

# grub setup
rm -f /etc/default/grub.d/50-cloudimg-settings.cfg

cat <<EOF >/etc/default/grub
GRUB_DEFAULT=0
GRUB_HIDDEN_TIMEOUT=3
GRUB_HIDDEN_TIMEOUT_QUIET=true
GRUB_RECORDFAIL_TIMEOUT=0
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX=""
GRUB_DISABLE_LINUX_UUID=true
EOF

# install grub
for line in $(cat /tmp/disklist); do
  grub-install --force "${line}"
done
update-grub
# end grub setup

# excuse me, do you have the time?
ntpdate 0.se.pool.ntp.org

# cloud-init config
# remove some defaults from the image
rm -f /etc/cloud/cloud.cfg.d/91-dib-cloud-init-datasources.cfg
rm -f /etc/cloud/cloud.cfg.d/90_dpkg.cfg

# disable cloud-init network config since we do that via foreman
cat << EOF > /etc/cloud/cloud.cfg.d/98_disable_network_config.cfg
network: {config: disabled}
EOF

echo 'datasource_list: [ NoCloud ]' > /etc/cloud/cloud.cfg.d/97_datasources.cfg

curl -o /etc/cloud/cloud.cfg.d/99_config.cfg <%= foreman_url("provision")%>
# end cloud-init config

# setup networking
<%= snippet("discovery_network") %>

# update the initial RAM file system
update-initramfs -u

# debug stuff
# echo root:debug | chpasswd
# useradd -m -s /bin/bash -G sudo,admin ubuntu
# echo ubuntu:debug | chpasswd

# mkdir /root/.ssh
# echo 'ssh-rsa [KEY GOES HERE] keyname@something' > /root/.ssh/authorized_keys
# chmod 0600 /root/.ssh/authorized_keys

curl -k <%= foreman_url('built') %>
```

#### network snippet
Just wanted to include my discovery_network snippet in case anyone wonders how I setup networking.

```bash
#!/bin/sh

# echo 'SUBSYSTEM=="net", KERNEL!="lo", ACTION=="add", TAG+="systemd", ENV{SYSTEMD_WANTS}+="dhcp-interface@$name.service"' > /etc/udev/rules.d/99-dhcp-all-interfaces.rules
rm -f /etc/udev/rules.d/99-dhcp-all-interfaces.rules

# remove any residual network config
rm -f /etc/network/interfaces.d/*

# bring up all interfaces except for loopback.
for i in `ip -o -0 link| grep -v "LOOPBACK"| awk -F': ' '{print $2}'`; do
  ip link set dev ${i} up;
done

# all interfaces with link.
BONDIFS=`ip -o -0 link| egrep -v "LOOPBACK|NO-CARRIER" | awk -F': ' '{print $2}'`

COUNT=`echo $BONDIFS | wc -w`

if [ $COUNT -gt 1 ]; then
for i in $BONDIFS ; do
cat >> /etc/network/interfaces.d/bond0 <<EOF
auto ${i}
iface ${i} inet manual
  bond-master bond0

EOF
done

cat >> /etc/network/interfaces.d/bond0.cfg <<EOF
auto bond0
iface bond0 inet dhcp
  hwaddress <%= @host.mac %>
  bond-miimon 100
  bond-mode balance-xor
  bond-slaves none
  bond-xmit-hash-policy layer2+3

EOF

else
for i in $BONDIFS ; do

# check if virtio
[[ -e /sys/class/net/${i}/device ]] && ls -l /sys/class/net/${i}/device | grep -q virtio
# also if it is systemd, then disable predictable network interface names.
[[ $? -eq 0 ]] && [[ -d /etc/systemd/network ]] && ln -s /dev/null /etc/systemd/network/99-default.link
# did this cause I couldn't find a way to get the virtio interface to be named ens3 or similar in truty and precise. But in Xenial it defaults to that name. So this way with all virtio NIC's they will be called eth*.

cat >> /etc/network/interfaces.d/default.cfg <<EOF
auto ${i}
iface ${i} inet dhcp

EOF
done
fi
```



#### provision template
Create a provision template with your cloud-init configuration and associate with OS.

```yaml
<%#
kind: Provision
name: discovery_image_cloudinit
-%>
datasource:
  NoCloud:
    user-data: |
      #cloud-config
      hostname: '<%= @host.shortname %>'
      fqdn: '<%= @host.name %>'
      manage_etc_hosts: true
      apt_update: true
      apt_upgrade: true
      apt_reboot_if_required: true
      timezone: Europe/Stockholm
      packages:
       - nano
      users:
       - name: someuser
         lock_passwd: False
         plain_text_passwd: 'somepw'
         sudo: ALL=(ALL) NOPASSWD:ALL
      apt_sources:
       - source: 'deb https://packages.chef.io/repos/apt/stable <%= @host.operatingsystem.release_name %> main'
         key: |
           -----BEGIN PGP PUBLIC KEY BLOCK-----
           <SNIP...>
           -----END PGP PUBLIC KEY BLOCK-----
      chef:
        force_install: false
        server_url: 'https://chef.hostname/organizations/evilcorp'
        node_name: '<%= @host.shortname %>.se-ix.delta.prod'
        validation_name: evilcorp-validator
        validation_cert: |
          -----BEGIN RSA PRIVATE KEY-----
          <SNIP...>
          -----END RSA PRIVATE KEY-----
        run_list:
         - 'role[ServerBase]'
      runcmd:
       - /opt/chef/embedded/bin/gem install chef_handler_foreman
       - chef-client
       - timedatectl set-timezone Europe/Stockholm
       - rm /etc/apt/sources.list.d/cloud_config_sources.list
      output: {all: '| tee -a /var/log/cloud-init-output.log'}
    meta-data:
      instance-id: <%= @host.shortname %>
      local-hostname: <%= @host.name %>
```

### build OS images
Building raw OS images can easily be done with OpenStack [diskimage builder](http://docs.openstack.org/developer/diskimage-builder/).

With cron and a script like this you can automate your image building process.

```bash
#!/bin/bash

cd $(dirname $0)

# requirements:
# apt-get install qemu-utils python-yaml curl

curl -L -O https://github.com/openstack/dib-utils/archive/master.tar.gz
tar xvf master.tar.gz
curl -L -O https://github.com/openstack/diskimage-builder/archive/master.tar.gz
tar xvf master.tar.gz

PATH=$PATH:${PWD}/diskimage-builder-master/bin:${PWD}/dib-utils-master/bin

DIB_CLOUD_INIT_DATASOURCES=NoCloud
DIB_RELEASE=xenial disk-image-create -t raw ubuntu baremetal -o xenial-server-cloudimg-amd64
DIB_RELEASE=trusty disk-image-create -t raw ubuntu baremetal -o trusty-server-cloudimg-amd64
DIB_RELEASE=precise disk-image-create -t raw ubuntu baremetal -o precise-server-cloudimg-amd64
```

### contribute

* create issues
* create pull requests

### license
Apache License 2.0
