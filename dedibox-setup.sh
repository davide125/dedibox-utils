#!/bin/sh

# automate setup of Debian 9 on a Dedibox XC SATA 2016 from online.net
# based on https://blog.tincho.org/posts/Setting_up_my_server:_re-installing_on_an_encripted_LVM/
#
# Copyright (C) 2017 Davide Cavalca <davide@cavalca.name>

set -eu

HOSTNAME="$(hostname -s)"
DOMAINNAME="$(hostname -d)"
IPADDR='127.0.1.1'
IFACE='enp0s20f0'
VG='vg0'
NTP='ntp.online.net'
MIRROR='https://mirrors.online.net/debian'
FALLBACK_DNS='62.210.16.6 62.210.16.7 2001:bc8:401::3 2001:bc8:1::16'

# linux-image is needed to ensure the crypto kernel modules are available
RESCUE_PACKAGES="linux-image-$(uname -r) cryptsetup lvm2 debian-archive-keyring debootstrap ntpdate"

PACKAGES=
PACKAGES="$PACKAGES dbus locales linux-image-amd64 grub-pc kbd console-setup"
PACKAGES="$PACKAGES makedev cryptsetup lvm2 dropbear busybox ssh initramfs-tools"
EXTRA_PACKAGES=
EXTRA_CMDLINE=
SSH_PUBKEY=

if [ "$(id -u)" -ne 0 ]; then
  echo 'you need to run this as root'
  exit 1
fi

if [ -r "$PWD/dedibox-setup.conf" ]; then
  echo "using config from $PWD/dedibox-setup.conf"
  . "$PWD/dedibox-setup.conf"
fi

if [ -z "$SSH_PUBKEY" ]; then
  echo 'SSH_PUBKEY is not defined'
  exit 1
fi

PACKAGES=$(echo "$PACKAGES $EXTRA_PACKAGES" | tr ' ' ',')

# online.net rescue image defaults to French...
export LANG=C.UTF-8
export XTERM=xterm-color

# install required tools
# ignore failures as the postinst will fail in the rescue environment
apt-get update
if ! DEBIAN_FRONTEND=noninteractive apt-get install -y $RESCUE_PACKAGES; then
  echo 'apt-get failed but we are probably fine, ignoring'
fi

# make sure the clock is correct and update adjtime
ntpdate $NTP
hwclock --systohc --utc --update-drift

# partition disk and setup encryption
sfdisk /dev/sda <<'EOF'
label: dos
label-id: 0x4d3e385b
device: /dev/sda
unit: sectors

/dev/sda1 : start=        2048, size=      405505, type=83, bootable
/dev/sda2 : start=      409600, size=  1953115568, type=83
EOF
# partprobe doesn't block, so sleep to ensure the kernel catches up
partprobe /dev/sda
sleep 5
mkfs.ext4 -L boot /dev/sda1
cryptsetup -s 512 -c aes-xts-plain64 luksFormat /dev/sda2
cryptsetup luksOpen /dev/sda2 sda2_crypt
pvcreate /dev/mapper/sda2_crypt
vgcreate "$VG" /dev/mapper/sda2_crypt
lvcreate -L 50G -n root "$VG"
lvcreate -L 800G -n srv "$VG"
lvcreate -L 1G -n swap "$VG"
mkfs.ext4 -L root "/dev/mapper/${VG}-root"
mkfs.ext4 -L srv "/dev/mapper/${VG}-srv"
mkswap -L swap "/dev/mapper/${VG}-swap"

# mount target filesystems
mkdir /target
mount /dev/mapper/${VG}-root /target
mkdir /target/boot /target/run /target/srv
mount /dev/sda1 /target/boot
mount -t tmpfs tmpfs /target/run
mount /dev/mapper/${VG}-srv /target/srv
swapon /dev/mapper/${VG}-swap

# bootstrap debian
debootstrap --arch amd64 --include="$PACKAGES" --exclude='ifupdown' stretch /target "$MIRROR"

# mount virtual filesystems
mount -o bind /dev /target/dev
mount -t proc proc /target/proc
mount -t sysfs sysfs /target/sys

# setup fstab
ln -sf /proc/mounts /target/etc/mtab
cat > /target/etc/fstab <<'EOF'
# /etc/fstab: static file system information.
#
# <file system> <mount point>   <type>  <options>         <dump>  <pass>
LABEL=root      /               ext4    errors=remount-ro 0     1
LABEL=boot      /boot           ext4    defaults          0     2
LABEL=srv       /srv            ext4    defaults          0     2
LABEL=swap      none            swap    sw                0     0
EOF

# setup the clock
cp /etc/adjtime /target/etc/adjtime
/bin/echo -e "[Time]\nNTP=${NTP}" > /target/etc/systemd/timesyncd.conf
chroot /target /bin/systemctl enable systemd-timesyncd

# setup network services
/bin/echo -e "[Match]\nName=${IFACE}\n\n[Network]\nDHCP=yes" > /target/etc/systemd/network/eth.network
chroot /target /bin/systemctl enable systemd-networkd
/bin/echo -e "[Resolve]\nFallbackDNS=${FALLBACK_DNS}\nDomains=${DOMAINNAME}\nLLMNR=false" > /target/etc/systemd/resolved.conf
ln -sf /run/systemd/resolve/resolv.conf /target/etc/resolv.conf
chroot /target /bin/systemctl enable systemd-resolved

# setup hostname
echo "$HOSTNAME" > /etc/hostname
echo "${HOSTNAME}.${DOMAINNAME}" > /etc/mailname
echo "$IPADDR ${HOSTNAME}.${DOMAINNAME} $HOSTNAME" >> /etc/hosts	

# configure packages
cat > /target/etc/apt/sources.list <<EOF
deb $MIRROR stretch main non-free contrib
deb http://security.debian.org/debian-security stretch/updates main contrib non-free
deb $MIRROR stretch-updates main contrib non-free
EOF
chroot /target /usr/sbin/dpkg-reconfigure locales tzdata

# rebuild the initramfs
mkdir -p /target/etc/dropbear-initramfs
echo "$SSH_PUBKEY" > /target/etc/dropbear-initramfs/authorized_keys
crypt_uuid=$(cryptsetup luksDump /dev/sda2 | grep UUID: | awk '{print $2}')
echo "sda2_crypt UUID=${crypt_uuid} none luks" > /target/etc/crypttab
chroot /target /usr/sbin/update-initramfs -u
if ! zcat /target/boot/initrd.img-* | cpio -i --to-stdout conf/conf.d/cryptroot | grep -q "$crypt_uuid"; then
  echo "$crypt_uuid not found in initramfs config, something went wrong!"
  exit 1
fi

# setup grub
cat >> /target/etc/default/grub <<EOF

GRUB_CMDLINE_LINUX="console=ttyS1,9600 ip=:::::${IFACE}:dhcp $EXTRA_CMDLINE"
GRUB_TERMINAL=serial
GRUB_SERIAL_COMMAND="serial --unit=1 --speed=9600 --word=8 --parity=no --stop=1"
EOF
cat > /target/etc/systemd/system/getty.target.wants/getty@ttyS1.service <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty 9600 --noclear ttyS1 vt102
EOF
chroot /target /usr/sbin/update-grub2
chroot /target /usr/sbin/grub-install /dev/sda

# reset password and setup ssh key
mkdir -m 0700 /target/root/.ssh
echo "$SSH_PUBKEY" > /target/root/.ssh/authorized_keys
chroot /target /usr/bin/passwd

# unmount and close shop down
umount /target/sys
umount /target/proc
umount /target/dev
umount /target/srv
umount /target/run
umount /target/boot
umount /target
swapoff /dev/mapper/$VG-swap
lvchange -an /dev/mapper/$VG-*
cryptsetup luksClose sda2_crypt

# just to be sure
sync
sync
sync

# declare victory
echo
echo 'All done, reboot now.'
