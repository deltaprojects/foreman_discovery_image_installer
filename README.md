# image installer for foreman discovery image

# TODO
fix readme.

## stuff

pxe:

```
<%#
kind: PXELinux
name: pxelinux_discovery_image
-%>
<%# Used to boot discovery image and get it to install os image to disk. %>
default discovery
LABEL discovery
  MENU LABEL Foreman Discovery Image
  KERNEL <%= foreman_server_url %>/files/os/fdi-image/vmlinuz0
  APPEND initrd=<%= foreman_server_url %>/files/os/fdi-image/initrd0.img rootflags=loop root=live:/fdi.iso rootfstype=auto ro rd.live.image acpi=force rd.luks=0 rd.md=0 rd.dm=0 rd.lvm=0 rd.bootif=0 rd.neednet=0 rd.debug=0 nomodeset fdi.ssh=1 fdi.rootpw=debug fdi.countdown=99999 proxy.url=<%= foreman_server_url %> proxy.type=foreman fdi.zips=os/fdi-image/image_installer.zip image.image=<%= foreman_server_url %>/files/os/ubuntu/<%= @host.operatingsystem.release_name %>-server-cloudimg-amd64.img image.cloudinit=<%= foreman_url("provision")%> image.partition=true image.finish=<%= foreman_url("finish") %>
  IPAPPEND 2
```

finish:
```
#!/bin/bash -x

PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# excuse me, do you have the time?
ntpdate 0.se.pool.ntp.org

# blacklist modues we don't use or cause problems, can't remeber why i blacklisted these in the first place.
echo "blacklist sb_edac" > /etc/modprobe.d/blacklist-sb_edac.conf
echo "blacklist mei" >> /etc/modprobe.d/blacklist-sb_edac.conf
echo "blacklist acpi_pad" >> /etc/modprobe.d/blacklist-sb_edac.conf
echo "blacklist i7core_edac" >> /etc/modprobe.d/blacklist-sb_edac.conf

# grub setup
rm -f /etc/default/grub.d/50-cloudimg-settings.cfg

cat <<EOF >/etc/default/grub
GRUB_DEFAULT=0
GRUB_HIDDEN_TIMEOUT=0
GRUB_HIDDEN_TIMEOUT_QUIET=true
GRUB_RECORDFAIL_TIMEOUT=0
GRUB_TIMEOUT=3
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX=""
GRUB_DISABLE_LINUX_UUID=true
EOF

DEBIAN_FRONTEND=noninteractive apt-get install -y grep grub-pc

for line in $(cat /tmp/disklist); do
  grub-install --force "${line}"
done
update-grub
# end grub setup

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
<%= snippet("network-cloudimg") %>

# debug stuff
# echo root:debug | chpasswd
# useradd -m -s /bin/bash -G sudo,admin ubuntu
# echo ubuntu:debug | chpasswd

# mkdir /root/.ssh
# echo 'ssh-rsa [KEY GOES HERE] keyname@something' > /root/.ssh/authorized_keys
# chmod 0600 /root/.ssh/authorized_keys

curl -k <%= foreman_url('built') %>
```

cloud-init/provision:

```
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

### parted
parted v3.2 is built with following
edit parted/Makefile.am and find parted_LDFLAGS = $(PARTEDLDFLAGS)
add ' -all-static' to the line.
and patch http://www.linuxfromscratch.org/patches/blfs/7.6/parted-3.2-devmapper-1.patch
(http://www.linuxfromscratch.org/blfs/view/7.6/postlfs/parted.html)

./configure --disable-shared --disable-dynamic-loading --enable-static --enable-static=parted --enable-device-mapper=no
