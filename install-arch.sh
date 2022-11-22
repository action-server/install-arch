#!/bin/bash

# Author:       Action <dev@action-server.com>
# License:      GNU GPLv3
# Description:  Arch install script

# ENV
set -e
NAME="$(basename "$0")"

keyboard_layout=
want_clean_drive=
want_encryption=
drive_name=
package_list='base linux linux-firmware vim networkmanager intel-ucode grub'
timezone_region=
timezone_city=
hostname=

print_error(){
	message="$1"
	echo "${NAME} - Error: ${message}" >&2
}

ask_yes_no(){
	answer="$1"
	question="$2"
	while ! printf "$answer" | grep -q '^\([Yy]\(es\)\?\|[Nn]\(o\)\?\)$'
	do
		printf "${question} [Y]es/[N]o: "
		read answer
	done

	if printf "$answer" | grep -q '^[Nn]\(o\)\?$'; then
		return 1
	fi
}

check_root(){
	if [ "$(id -u)" -ne '0' ]; then
		print_error 'This script needs root privileges.'
		exit 1
	fi
}

set_keyboard_layout(){
	printf 'Enter the keyboard layout name, or press enter for the default layout (us): '
	read keyboard_layout

	if [ -z "$keyboard_layout" ]; then
		keyboard_layout='us'
	fi

	if ls /usr/share/kbd/keymaps/**/*"$keyboard_layout"*.map.gz >/dev/null 2>&1; then
		loadkeys "$keyboard_layout"
	else
		print_error "Keyboard layout not found"
		keyboard_layout=''
		set_keyboard_layout
	fi
}

verify_boot_mode(){
	if [ -d /sys/firmware/efi/efivars ]; then
		boot_mode='uefi'
	else
		boot_mode='bios'
	fi
}

update_system_clock(){
	timedatectl set-ntp true >/dev/null 2>&1
}

clean_dirve(){
	return
}

encrypt_drive(){
	return
}

get_drive_name(){
	lsblk
	printf "Enter the name of the desired drive to be affected (e.g., sda): "
	read drive_name
}

partion_disk(){
	while [ -z "$drive_name" ]; do
		get_drive_name
		while ! [ -b /dev/"$drive_name" ]; do
			print_error "Drive \"${drive_name}\" not found."
			get_drive_name
		done
	done

	if ask_yes_no "$want_encryption" 'Do you want to encryption?'; then
		if	ask_yes_no "$want_clean_drive" 'Do you want to clean the drive? This may take a long time.'; then
			clean_dirve
		fi
		encrypt_drive
	fi

	if [ "$boot_mode" = 'uefi' ]; then
		sfdisk -W always /dev/"$drive_name" <<- EOF
			label: gpt
			size=512MiB, type=uefi, bootable
			size=4GiB, type=swap
			type=linux
		EOF
	else
		sfdisk -W always /dev/"$drive_name" <<- EOF
			label: dos
			size=512MiB, type=linux, bootable
			size=4GiB, type=swap
			type=linux
		EOF
	fi
}

get_partition_path(){
	boot_path="$(blkid | grep "/dev/${drive_name}.*1" | sed -n 's/^\(\/dev\/'"$drive_name"'.*1\):\s\+.*$/\1/p')"
	swap_path="$(blkid | grep "/dev/${drive_name}.*2" | sed -n 's/^\(\/dev\/'"$drive_name"'.*2\):\s\+.*$/\1/p')"
	root_path="$(blkid | grep "/dev/${drive_name}.*3" | sed -n 's/^\(\/dev\/'"$drive_name"'.*3\):\s\+.*$/\1/p')"
}

format_partition(){
	if [ "$boot_mode" = 'uefi' ]; then
		mkfs.fat -F32 "$boot_path"
		mkswap "$swap_path"
		mkfs.ext4 "$root_path"
	else
		mkfs.ext4 "$boot_path"
		mkswap "$swap_path"
		mkfs.ext4 "$root_path"
	fi
}

mount_file_system(){
	mount "$root_path" /mnt
	mkdir /mnt/boot
	mount "$boot_path" /mnt/boot
	swapon "$swap_path"
}

install_essential_packages(){
	pacstrap /mnt $package_list
}

generate_fstab(){
	genfstab -U /mnt >> /mnt/etc/fstab
}

copy_script_to_chroot(){
	cp "$0" /mnt/root
	cat <<-EOF > /mnt/root/env.sh
	export keyboard_layout=${keyboard_layout}
	export boot_mode=${boot_mode}
	drive_name=${drive_name}
	EOF
}

run_arch_chroot(){
	arch-chroot /mnt /bin/bash -c 'bash /root/env.sh; bash /root/${0} part2'
}

finish_and_reboot(){
	umount -R /mnt
	echo 'Rebooting in 5Sec'
	sleep 5
	reboot
}

run_part1(){
	check_root
	set_keyboard_layout
	verify_boot_mode
	update_system_clock
	partion_disk
	get_partition_path
	format_partition
	mount_file_system
	install_essential_packages
	generate_fstab
	copy_script_to_chroot
	run_arch_chroot
	finish_and_reboot
}

set_time_zone(){
	printf 'Enter the name of your Region (e.g., Europe): '
	read timezone_region
	printf 'Enter the timezone name of your city (e.g., Berlin): '
	read timezone_city

	if ls /usr/share/zoneinfo/"$timezone_region"/"$timezone_city" >/dev/null 2>&1; then
		ln -sf /usr/share/zoneinfo/"$timezone_region"/"$timezone_city" /etc/localtime
	else
		print_error "The specified Region, and/or city were not found."
		set_time_zone
	fi
}

set_hardware_clock(){
	hwclock --systohc
}

set_locale(){
	locale='en_US.UTF-8'
	sed -i '0,/^\s*#\+\s*\('"$locale"'.*\)$/ s/^\s*#\+\s*\('"$locale"'.*\)$/\1/' /etc/locale.gen
	locale-gen
	echo "LANG=${locale}" > /etc/locale.conf
}

set_vconsole(){
	echo "KEYMAP=${keyboard_layout}" > /etc/vconsole.conf
}

configure_network(){
	while [ -z "$hostname" ]; do
		printf 'Enter hostname: '
		read hostname
	done

	echo "$hostname" > /etc/hostname

	cat <<- EOF > /etc/hosts
	127.0.0.1	localhost
	::1		localhost
	127.0.1.1	"${hostname}".localdomain	"${hostname}"
	EOF
}

run_initramfs(){
	mkinitcpio -P
}

change_root_password(){
	passwd
}

install_boot_loader(){
	if [ "$boot_mode" = 'uefi' ]; then
		grub-install --target=x86_64-efi --efi-directory=/boot/EFI --bootloader-id=GRUB
	else
		grub-install --target=i386-pc /dev/"$drive_name"
	fi

	grub-mkconfig -o /boot/grub/grub.cfg
}

run_part2(){
	set_time_zone
	set_hardware_clock
	set_locale
	set_vconsole
	configure_network
	run_initramfs
	change_root_password
	install_boot_loader
	exit
}

main(){
	if [ "$1" = 'part2' ];then
		run_part2 "$@"
	else
		run_part1 "$@"
	fi
}

main "$@"
