#!/bin/bash
# Copyright (c) 2015 SUSE LLC
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
# 
#======================================
# Functions...
#--------------------------------------
test -f /.kconfig && . /.kconfig
test -f /.profile && . /.profile

set -euxo pipefail

mkdir /var/lib/misc/reconfig_system

#======================================
# Greeting...
#--------------------------------------
echo "Configure image: [$kiwi_iname]-[$kiwi_profiles]..."

#======================================
# add missing fonts
#--------------------------------------
CONSOLE_FONT="eurlatgr.psfu"

#======================================
# prepare for setting root pw, timezone
#--------------------------------------
echo "** reset machine settings"
rm -f /etc/machine-id \
      /var/lib/zypp/AnonymousUniqueId \
      /var/lib/systemd/random-seed

echo "** Running ldconfig..."
/sbin/ldconfig

#======================================
# Setup baseproduct link
#--------------------------------------
suseSetupProduct

#======================================
# Specify default runlevel
#--------------------------------------
baseSetRunlevel 3

#======================================
# Add missing gpg keys to rpm
#--------------------------------------
suseImportBuildKey

#======================================
# Enable sshd
#--------------------------------------
chkconfig sshd on
chkconfig salt-minion off

if [ -e /etc/cloud/cloud.cfg ]; then
    systemctl enable cloud-init-local
    systemctl enable cloud-init
    systemctl enable cloud-config
    systemctl enable cloud-final
fi

# Enable jeos-firstboot
mkdir -p /var/lib/YaST2
touch /var/lib/YaST2/reconfig_system

systemctl mask systemd-firstboot.service
systemctl enable jeos-firstboot.service

# Enable firewalld if installed except on VMware
if [ -x /usr/sbin/firewalld ] && [ "$kiwi_profiles" != "VMware" ]; then
    echo 'Enabling firewall...'
    chkconfig firewalld on
fi

# Set GRUB2 to boot graphically (bsc#1097428)
sed -Ei"" "s/#?GRUB_TERMINAL=.+$/GRUB_TERMINAL=gfxterm/g" /etc/default/grub
sed -Ei"" "s/#?GRUB_GFXMODE=.+$/GRUB_GFXMODE=auto/g" /etc/default/grub

# Systemd controls the console font now
echo FONT="$CONSOLE_FONT" >> /etc/vconsole.conf

#======================================
# SSL Certificates Configuration
#--------------------------------------
echo '** Rehashing SSL Certificates...'
update-ca-certificates

if [ ! -s /var/log/zypper.log ]; then
	> /var/log/zypper.log
fi

#======================================
# Import trusted rpm keys
#--------------------------------------
for i in /usr/lib/rpm/gnupg/keys/gpg-pubkey*asc; do
    # importing can fail if it already exists
    rpm --import $i || true
done

# only for debugging
#systemctl enable debug-shell.service

#=====================================
# Configure snapper
#-------------------------------------
if [ "${kiwi_btrfs_root_is_snapshot-false}" = 'true' ]; then
        echo "creating initial snapper config ..."
        # we can't call snapper here as the .snapshots subvolume
        # already exists and snapper create-config doens't like
        # that.
        cp /etc/snapper/config-templates/default /etc/snapper/configs/root
        # Change configuration to match SLES12-SP1 values
        sed -i -e '/^TIMELINE_CREATE=/s/yes/no/' /etc/snapper/configs/root
        sed -i -e '/^NUMBER_LIMIT=/s/50/10/'     /etc/snapper/configs/root

        baseUpdateSysConfig /etc/sysconfig/snapper SNAPPER_CONFIGS root
fi

#=====================================
# Enable chrony if installed
#-------------------------------------
if [ -f /etc/chrony.conf ]; then
	suseInsertService chronyd
fi

#======================================
# Disable recommends on virtual images (keep hardware supplements, see bsc#1089498)
#--------------------------------------
sed -i 's/.*solver.onlyRequires.*/solver.onlyRequires = true/g' /etc/zypp/zypp.conf

#======================================
# Disable installing documentation
#--------------------------------------
sed -i 's/.*rpm.install.excludedocs.*/rpm.install.excludedocs = yes/g' /etc/zypp/zypp.conf

#======================================
# Configure Raspberry Pi specifics
#--------------------------------------
if [[ "$kiwi_profiles" == *"RaspberryPi"* ]]; then
	# Also show WLAN interfaces in /etc/issue
	baseUpdateSysConfig /etc/sysconfig/issue-generator NETWORK_INTERFACE_REGEX '^[bew]'

	# Add necessary kernel modules to initrd (will disappear with bsc#1084272)
	echo 'add_drivers+=" bcm2835_dma dwc2 "' > /etc/dracut.conf.d/raspberrypi_modules.conf

	# Work around network issues
  	cat > /etc/modprobe.d/50-rpi3.conf <<-EOF
		# Prevent too many page allocations (bsc#1012449)
		options smsc95xx turbo_mode=N
	EOF

	cat > /usr/lib/sysctl.d/50-rpi3.conf <<-EOF
		# Avoid running out of DMA pages for smsc95xx (bsc#1012449)
		vm.min_free_kbytes = 2048
	EOF
fi

exit 0
