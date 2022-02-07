#!/bin/bash

MY_HOST_NAME="focal"

TARGET_UBUNTU_VERSION="focal"
TARGET_UBUNTU_MIRROR="http://jp.archive.ubuntu.com/ubuntu/"

# OPTION: for new user creation. Uncomment "adduser" in chroot.

# TARGET_USER_NAME="ubuntu"
# TARGET_USER_PASSWORD="custom"

TIMEZONE="Asia/Tokyo"
ZONEINFO_FILE="/usr/share/zoneinfo/Asia/Tokyo"

log() {
  echo "$(date -Iseconds) [info ] $*"
}

log_error() {
  echo "$(date -Iseconds) [error] $*" >&2
}

# only root can run
if [[ "$(id -u)" != "0" ]]; then
  log_error "This script must be run as root"
  exit 1
fi

# install packages

apt update
apt install -y binutils debootstrap squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin mtools

# remove directories

log "Removing previously created directories ..."
rm -rf root/
log "Done."

# install base

log "Execute debootstrap..."
mkdir root
debootstrap --arch=amd64 --variant=minbase focal root
log "Done."

# prepare chroot

log "Prepare chroot..."

# mkdir -p root/etc/apt # already exist

cat <<EOF > root/etc/apt/sources.list
deb $TARGET_UBUNTU_MIRROR $TARGET_UBUNTU_VERSION main restricted universe multiverse
deb-src $TARGET_UBUNTU_MIRROR $TARGET_UBUNTU_VERSION main restricted universe multiverse

deb $TARGET_UBUNTU_MIRROR $TARGET_UBUNTU_VERSION-security main restricted universe multiverse
deb-src $TARGET_UBUNTU_MIRROR $TARGET_UBUNTU_VERSION-security main restricted universe multiverse

deb $TARGET_UBUNTU_MIRROR $TARGET_UBUNTU_VERSION-updates main restricted universe multiverse
deb-src $TARGET_UBUNTU_MIRROR $TARGET_UBUNTU_VERSION-updates main restricted universe multiverse
EOF


echo $MY_HOST_NAME > root/etc/hostname

mount --bind /dev root/dev
mount --bind /run root/run

chroot root mount none -t proc /proc
chroot root mount none -t sysfs /sys
chroot root mount none -t devpts /dev/pts

chroot root mkdir -p /boot/efi
chroot root mount ${TARGET_DISK}1 /boot/efi
chroot root rm -rf /boot/efi/*

log "Done."

# chroot and customize
log "Start chroot..."

chroot root <<EOT

# export HOME=/root # already set
export LC_ALL=C

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y systemd-sysv
# apt-get install -y libterm-readline-gnu-perl systemd-sysv

dbus-uuidgen > /etc/machine-id
ln -fs /etc/machine-id /var/lib/dbus/machine-id

dpkg-divert --local --rename --add /sbin/initctl
ln -s /bin/true /sbin/initctl

apt-get upgrade

# live package

apt-get install -y \
sudo \
ubuntu-standard \
casper \
lupin-casper \
discover \
laptop-detect \
os-prober \
network-manager \
resolvconf \
net-tools \
wireless-tools \
grub-common \
grub-gfxpayload-lists \
grub-pc \
grub-pc-bin \
grub2-common \

#

apt-get install -y ubuntu-minimal
apt-get install -y ubuntu-desktop-minimal

apt-get install -y --no-install-recommends linux-generic 

# graphic installer - ubiquity
apt-get install -y \
ubiquity \
ubiquity-casper \
ubiquity-frontend-gtk \
ubiquity-slideshow-ubuntu \
ubiquity-ubuntu-artwork

cat <<EOF > /etc/NetworkManager/NetworkManager.conf
[main]
rc-manager=resolvconf
plugins=ifupdown,keyfile
dns=dnsmasq

[ifupdown]
managed=false
EOF

dpkg-reconfigure network-manager

# setup Japanese

echo "Setup Japanese..."

wget -q https://www.ubuntulinux.jp/ubuntu-ja-archive-keyring.gpg -O- | apt-key add -
wget -q https://www.ubuntulinux.jp/ubuntu-jp-ppa-keyring.gpg -O- | apt-key add -
wget https://www.ubuntulinux.jp/sources.list.d/focal.list -O /etc/apt/sources.list.d/ubuntu-ja.list
apt-get update
apt-get install -y ubuntu-defaults-ja

rm -f /etc/localtime
ln -s "$ZONEINFO_FILE" /etc/localtime
echo "$TIMEZONE" > /etc/timezone

update-locale LANG=ja_JP.UTF-8
sed -i 's/# ja_JP.UTF-8 UTF-8/ja_JP.UTF-8 UTF-8/' /etc/locale.gen
locale-gen --keep-existing

# install my essential package

sh -c 'echo "deb [arch=amd64] http://dl.google.com/linux/chrome/deb/ stable main" >> /etc/apt/sources.list.d/google.list'
wget -q -O - https://dl-ssl.google.com/linux/linux_signing_key.pub | apt-key add -
apt-get update
apt-get install -y google-chrome-stable
apt-get install -y bcmwl-kernel-source
apt-get install -y emacs vim bat

apt-add-repository ppa:fish-shell/release-3
apt-get update
apt-get install fish

#

truncate -s 0 /etc/machine-id

rm /sbin/initctl
dpkg-divert --rename --remove /sbin/initctl

umount /proc
umount /sys
umount /dev/pts

rm -rf /tmp/* ~/.bash_history

EOT

#####

log "Finished chroot."

umount root/dev
umount root/run

# /etc/hosts

log "edit /etc/hosts..."

cat <<EOF >>root/etc/hosts
127.0.1.1 $MY_HOST_NAME
EOF

# keyboard to jp

log "keyboard to jp..."

cat <<EOF >keyboard
XKBMODEL=pc105
XKBLAYOUT=jp
BACKSPACE=guess
EOF

mv keyboard root/etc/default

log "Start building ISO..."

rm -rf image
mkdir -p image/{casper,isolinux,install}

    # copy kernel files
cp root/boot/vmlinuz-**-**-generic image/casper/vmlinuz
cp root/boot/initrd.img-**-**-generic image/casper/initrd

    # grub
touch image/ubuntu
cat <<EOF > image/isolinux/grub.cfg

search --set=root --file /ubuntu

insmod all_video

set default="0"
set timeout=10

menuentry "${MY_HOST_NAME}" {
   linux /casper/vmlinuz boot=casper nopersistent toram quiet splash ---
   initrd /casper/initrd
}

EOF

# Packages to be removed from the target system after installation completes succesfully
TARGET_PACKAGE_REMOVE="
    ubiquity \
    casper \
    discover \
    laptop-detect \
    os-prober \
"

# generate manifest
chroot root dpkg-query -W --showformat='${Package} ${Version}\n' | tee image/casper/filesystem.manifest
cp -v image/casper/filesystem.manifest image/casper/filesystem.manifest-desktop
for pkg in $TARGET_PACKAGE_REMOVE; do
    sed -i "/$pkg/d" image/casper/filesystem.manifest-desktop
done

    # compress rootfs
mksquashfs root image/casper/filesystem.squashfs \
        -noappend -no-duplicates -no-recovery \
        -wildcards \
        -e "var/cache/apt/archives/*" \
        -e "root/*" \
        -e "root/.*" \
        -e "tmp/*" \
        -e "tmp/.*" \
        -e "swapfile"
printf $(du -sx --block-size=1 root | cut -f1) > image/casper/filesystem.size

    # create diskdefines
cat <<EOF > image/README.diskdefines
#define DISKNAME  ${MY_HOST_NAME}
#define TYPE  binary
#define TYPEbinary  1
#define ARCH  amd64
#define ARCHamd64  1
#define DISKNUM  1
#define DISKNUM1  1
#define TOTALNUM  0
#define TOTALNUM0  1
EOF

    # create iso image
pushd image
    grub-mkstandalone \
        --format=x86_64-efi \
        --output=isolinux/bootx64.efi \
        --locales="" \
        --fonts="" \
        "boot/grub/grub.cfg=isolinux/grub.cfg"
    
    (
        cd isolinux && \
        dd if=/dev/zero of=efiboot.img bs=1M count=10 && \
        mkfs.vfat efiboot.img && \
        LC_CTYPE=C mmd -i efiboot.img efi efi/boot && \
        LC_CTYPE=C mcopy -i efiboot.img ./bootx64.efi ::efi/boot/
    )

    grub-mkstandalone \
        --format=i386-pc \
        --output=isolinux/core.img \
        --install-modules="linux16 linux normal iso9660 biosdisk memdisk search tar ls" \
        --modules="linux16 linux normal iso9660 biosdisk search" \
        --locales="" \
        --fonts="" \
        "boot/grub/grub.cfg=isolinux/grub.cfg"

    cat /usr/lib/grub/i386-pc/cdboot.img isolinux/core.img > isolinux/bios.img

    /bin/bash -c "(find . -type f -print0 | xargs -0 md5sum | grep -v -e 'md5sum.txt' -e 'bios.img' -e 'efiboot.img' > md5sum.txt)"

    xorriso \
        -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "$MY_HOST_NAME" \
        -eltorito-boot boot/grub/bios.img \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        --eltorito-catalog boot/grub/boot.cat \
        --grub2-boot-info \
        --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img \
        -eltorito-alt-boot \
        -e EFI/efiboot.img \
        -no-emul-boot \
        -append_partition 2 0xef isolinux/efiboot.img \
	-appended_part_as_gpt  \
	--mbr-force-bootable  \
        -output "../$MY_HOST_NAME.iso" \
        -m "isolinux/efiboot.img" \
        -m "isolinux/bios.img" \
        -graft-points \
           "/EFI/efiboot.img=isolinux/efiboot.img" \
           "/boot/grub/bios.img=isolinux/bios.img" \
           "."

    popd

log "Finished script."
