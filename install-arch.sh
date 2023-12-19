#!/bin/sh

# Author:       Action <dev@action-server.com>
# License:      GNU GPLv3
# Description:  Arch install script

locale='en_US.UTF-8'
locale_gen='en_US.UTF-8 UTF-8'
pacman_packages='base linux linux-firmware'

set -e
trap 'cleanup' EXIT INT QUIT TERM HUP

print_error(){
	message="${1}"
	printf '%s\n' "Error: ${message}" >&2
}

cleanup(){
	print_error 'Unexpected exit...'
	stty echo
	set e
}

ask_yes_no(){
	answer="${1}"
	question="${2}"

	while ! printf '%s' "${answer}" | grep -q '^\([Yy]\(es\)\?\|[Nn]\(o\)\?\)$'; do
		printf '%s' "${question} [Y]es/[N]o: "
		read -r answer
	done

	if printf '%s' "${answer}" | grep -q '^[Nn]\(o\)\?$'; then
		return 1
	fi
}

check_root(){
	if [ "$(id -u)" -ne '0' ]; then
		print_error 'This script needs root privileges.'
		return 1
	fi
}

get_bios_mode(){
	if ! [ -d /sys/firmware/efi/efivars ]; then
		bios_mode='legacy'
		return
	fi

	bios_mode='uefi'
}

get_cpu_architecture(){
	if ! grep --quiet '\slm\s' /proc/cpuinfo; then
		cpu_architecture='i386'
		return
	fi

	cpu_architecture='x86_64'
}

get_cpu_model(){
	if ! grep --quiet 'Intel' /proc/cpuinfo; then
		cpu_model='amd'
		return
	fi

	cpu_model='intel'
}

get_keyboard_layout(){
	while true; do
		printf 'Enter the desired keyboard layout (e.g., us): '
		read -r keyboard_layout

		if ! loadkeys --quiet --parse "${keyboard_layout}"; then
			print_error 'Keyboard layout not found'
			continue
		fi

		break
	done
}

get_timezone(){
	while true; do
		printf 'Enter the name of your timezone (e.g., Europe/Berlin): '
		read -r timezone

		if ! [ -f /usr/share/zoneinfo/"${timezone}" ]; then
			print_error 'The specified timezone was not found.'
			continue
		fi

		break
	done
}

get_hostname(){
	while true; do
		printf 'Enter hostname: '
		read -r hostname

		if [ -z "${hostname}" ]; then
			print_error 'Hostname can not be empty.'
			continue
		fi

		break
	done
}

get_pacman_packages(){
	while true; do
		printf 'Enter any additional packages to be installed (e.g., networkmanager vim): '
		read -r additional_pacman_packages

		if ! sh -c "pacman -Si ${additional_pacman_packages} > /dev/null"; then
			print_error 'Some packages were not found.'
			continue
		fi

		break
	done
}

get_disk_path(){
	while true; do
		lsblk --nodeps --output 'PATH,SIZE'
		printf 'Enter the path of the desired disk to be affected (e.g., /dev/sda): '
		read -r disk_path

		if ! [ -b "${disk_path}" ]; then
			print_error 'Disk not found.'
			continue
		fi

		break
	done
}

get_filesystem(){
	options=$(\
		cat <<-EOF
		ext4
		btrfs
		f2fs
		EOF
	)

	while true; do
		printf '%s\n' "${options}"
		printf '%s' 'Choose filesystems: '
		read -r filesystem

		if ! printf '%s' "${options}" | grep -q "^${filesystem}$"; then
			print_error 'Wrong filesystem.'
			continue
		fi

		break
	done
}

get_boot_loader(){
	options=$(\
		cat <<-EOF
		systemd-boot
		grub
		EOF
	)

	while true; do
		printf '%s\n' "${options}"
		printf '%s' 'Choose boot method: '
		read -r boot_loader

		if ! printf '%s' "${options}" | grep -q "^${boot_loader}$"; then
			print_error 'Wrong boot loader.'
			continue
		fi

		break
	done
}

ask_clean_disk(){
	if ! ask_yes_no "${clean_disk}" 'Do you want to clean the disk? This may take a long time.'; then
		clean_disk='false'
		return
	fi

	clean_disk='true'
}

ask_setup_lvm(){
	if ! ask_yes_no "${setup_lvm}" 'Do you want to setup lvm?'; then
		setup_lvm='false'
		return
	fi

	pacman_packages="${pacman_packages} lvm2"
	mkinitcpio_lvm_hook='lvm2 '
	setup_lvm='true'
}

ask_swap_file(){
	if ! ask_yes_no "${setup_swap_file}" 'Do you want a swap file?'; then
		setup_swap_file='false'
		return
	fi

	setup_swap_file='true'
}

ask_swap_file_size(){
	if ! "${setup_swap_file}"; then
		return
	fi

	while true; do
		printf 'Enter swap file size in gigabyte (e.g. 4): '
		read -r swap_file_size

		if ! printf '%s' "${swap_file_size}" | grep -q '^[0-9]\+$'; then
			print_error 'Swap file size is incorrect.'
			continue
		fi

		break
	done
}

ask_encrypt_disk(){
	if ! ask_yes_no "${encrypt_disk}" 'Do you want encryption?'; then
		encrypt_disk='false'
		return
	fi

	mkinitcpio_encryption_hook='encrypt '
	encrypt_disk='true'
}

get_root_password(){
	while true; do
		printf 'Enter root password: '
		stty -echo
		read -r root_password
		stty echo
		printf '\n'

		if [ -z "${root_password}" ]; then
			print_error 'Password can not be empty.'
			continue
		fi

		printf 'Confirm root password: '
		stty -echo
		read -r root_confirm_password
		stty echo
		printf '\n'

		if [ "${root_password}" != "${root_confirm_password}" ]; then
			print_error 'Password did not match.'
			continue
		fi

		break
	done
}

get_encryption_password(){
	if ! "${encrypt_disk}"; then
		return
	fi

	while true; do
		printf 'Enter encryption password: '
		stty -echo
		read -r encryption_password
		stty echo
		printf '\n'

		if [ -z "${encryption_password}" ]; then
			print_error 'Encryption password cannot be empty.'
			continue
		fi

		printf 'Confirm encryption password: '
		stty -echo
		read -r encryption_confirm_password
		stty echo
		printf '\n'

		if [ "${encryption_password}" != "${encryption_confirm_password}" ]; then
			print_error 'Encryption password did not match.'
			continue
		fi

		break
	done
}

set_keyboard_layout(){
	loadkeys "${keyboard_layout}"
}

update_system_clock(){
	timedatectl set-ntp true
}

unmount_disk(){
	swapoff /mnt/swapfile || true
	swapoff /mnt/swap/swapfile || true
	umount -R /mnt || true
	vgremove --yes vg1 || true
	cryptsetup close root || true
}

clean_disk(){
	if ! "${clean_disk}"; then
		return
	fi

	dd if=/dev/urandom > "${disk_path}" bs=4096 status=progress || true
}

partition_disk(){
	case "${bios_mode}" in
		'legacy')
			sfdisk --wipe-partitions always "${disk_path}" <<- EOF
				label: dos
				size=1G, type=linux, bootable
				type=linux
			EOF
			;;
		'uefi')
			sfdisk --wipe-partitions always "${disk_path}" <<- EOF
				label: gpt
				size=1G, type=uefi, bootable
				type=linux
			EOF
			;;
	esac

	boot_path="$(lsblk "${disk_path}"*1 --list --noheadings --nodeps --output 'PATH' | head -1)"
	root_path="$(lsblk "${disk_path}"*2 --list --noheadings --nodeps --output 'PATH' | head -1)"
}

encrypt_disk(){
	if ! "${encrypt_disk}"; then
		return
	fi

	printf '%s' "${encryption_password}" | cryptsetup --batch-mode luksFormat "${root_path}" -
	printf '%s' "${encryption_password}" | cryptsetup open "${root_path}" root -

	encryption_root_path="${root_path}"
	root_path='/dev/mapper/root'
}

setup_lvm(){
	if ! "${setup_lvm}"; then
		return
	fi

	pvcreate "${root_path}"
	vgcreate 'vg1' "${root_path}"
	lvcreate --extents '100%FREE' vg1 --name 'root'

	root_path='/dev/vg1/root'

	if [ "${filesystem}" != 'ext4' ]; then
		return
	fi

	lvreduce --size -256M 'vg1/root'
}

format_disk(){
	mkfs.fat -F32 "${boot_path}"

	case "${filesystem}" in
		'ext4')
			mkfs.ext4 "${root_path}"
			;;
		'btrfs')
			mkfs.btrfs "${root_path}"
			root_mount_options='compress-force=zstd:6'
			;;
		'f2fs')
			mkfs.f2fs "${root_path}"
			root_mount_options='compress_algorithm=zstd:6,compress_chksum,lazytime'
			;;
	esac
}

mount_disk(){
	mount --options "${root_mount_options}" "${root_path}" /mnt
	mkdir /mnt/boot
	mount "${boot_path}" /mnt/boot
}

configure_cpu_microcode(){
	case "${cpu_model}" in
		'intel')
			pacman_packages="${pacman_packages} intel-ucode"
			systemd_boot_microcode='/intel-ucode.img'
			;;
		'amd')
			pacman_packages="${pacman_packages} amd-ucode"
			systemd_boot_microcode='/amd-ucode.img'
			;;
	esac
}

configure_grub_install_target(){
	if [ "${boot_loader}" != 'grub' ]; then
		return
	fi

	case "${cpu_architecture}" in
		'i386')
			grub_architecture='i386'
			;;
		'x86_64')
			grub_architecture='x86_64'
			;;
	esac

	case "${bios_mode}" in
		'legacy')
			grub_install_target='i386-pc'
			pacman_packages="${pacman_packages} grub"
			;;
		'uefi')
			grub_install_target="${grub_architecture}-efi"
			grub_install_options='--efi-directory=/boot --bootloader-id=GRUB'
			pacman_packages="${pacman_packages} grub efibootmgr"
			;;
	esac
}

install_pacman_packages(){
	/bin/sh -c "pacstrap -K /mnt ${pacman_packages} ${additional_pacman_packages}"
}

get_uuid(){
	root_uuid="$(lsblk "${root_path}" --list --noheadings --nodeps --output 'UUID')"
	encryption_root_uuid="$(lsblk "${encryption_root_path}" --list --noheadings --nodeps --output 'UUID')"
}

setup_btrfs_swap_file(){
	btrfs subvolume create /mnt/swap
	btrfs filesystem mkswapfile --size "${swap_file_size}g" --uuid clear /mnt/swap/swapfile
	swapon /mnt/swap/swapfile
	swap_file_offset="$(btrfs inspect-internal map-swapfile -r /mnt/swap/swapfile)"
	swap_boot_options=" resume=UUID=${root_uuid} resume_offset=${swap_file_offset}"
}

setup_swap_file(){
	if ! "${setup_swap_file}"; then
		return
	fi

	if printf '%s' "${filesystem}" | grep 'btrfs'; then
		setup_btrfs_swap_file
		return
	fi

	dd if=/dev/zero of=/mnt/swapfile bs=1M count="${swap_file_size}k" status=progress || true
	chmod 0600 /mnt/swapfile
	mkswap --uuid clear /mnt/swapfile
	swapon /mnt/swapfile
	swap_file_offset="$(filefrag -v /mnt/swapfile | awk '$1=="0:" {print substr($4, 1, length($4)-2)}')"
	swap_boot_options=" resume=UUID=${root_uuid} resume_offset=${swap_file_offset}"
}

generate_fstab(){
	genfstab -U /mnt >> /mnt/etc/fstab

	cat <<- EOF >> /mnt/etc/fstab

		# /dev/hugepages
		hugetlbfs       /dev/hugepages  hugetlbfs       mode=01770,gid=kvm        0 0
	EOF
}

set_timezone(){
	arch-chroot /mnt /bin/sh -c "ln -sf /usr/share/zoneinfo/${timezone} /etc/localtime"
}

set_hardware_clock(){
	arch-chroot /mnt /bin/sh -c 'hwclock --systohc'
}

set_locale(){
	printf '%s' "${locale_gen}" > /mnt/etc/locale.gen
	arch-chroot /mnt /bin/sh -c 'locale-gen'
	printf '%s' "LANG=${locale}" > /mnt/etc/locale.conf
}

set_vconsole(){
	printf '%s' "KEYMAP=${keyboard_layout}" > /mnt/etc/vconsole.conf
}

configure_network(){
	printf '%s' "${hostname}" > /mnt/etc/hostname

	cat <<- EOF > /mnt/etc/hosts
		127.0.0.1	localhost
		::1	localhost
		127.0.1.1	${hostname}
	EOF
}

set_root_password(){
	arch-chroot /mnt /bin/sh -c "printf '%s' 'root:${root_password}' | chpasswd"
}

configure_boot_options(){
	if ! "${encrypt_disk}"; then
		return
	fi

	boot_options="cryptdevice=UUID=${encryption_root_uuid}:root:allow-discards,no-read-workqueue,no-write-workqueue "
}

run_initramfs(){
	cat <<- EOF > /mnt/etc/mkinitcpio.conf
		MODULES=()
		BINARIES=()
		FILES=()
		HOOKS=(base udev keyboard autodetect modconf kms keymap consolefont block ${mkinitcpio_encryption_hook}${mkinitcpio_lvm_hook}filesystems resume fsck)
	EOF

	arch-chroot /mnt /bin/sh -c 'mkinitcpio -P || true'
}

install_boot_loader(){
	case "${boot_loader}" in
		'systemd-boot')
			arch-chroot /mnt /bin/sh -c 'bootctl install'

			cat <<- EOF > /mnt/boot/loader/loader.conf
				default arch.conf
				timeout 0
				console-mode max
			EOF

			cat <<- EOF > /mnt/boot/loader/entries/arch.conf
				title	Arch Linux
				linux	/vmlinuz-linux
				initrd	${systemd_boot_microcode}
				initrd	/initramfs-linux.img
				options ${boot_options}root=UUID=${root_uuid} rw${swap_boot_options}
				options	quiet splash
				options	sysrq_always_enabled=1
			EOF
			;;
		'grub')
			cat <<- EOF > /mnt/etc/default/grub
				GRUB_DEFAULT=0
				GRUB_TIMEOUT=1
				GRUB_DISTRIBUTOR="Arch"
				GRUB_CMDLINE_LINUX_DEFAULT="quiet splash sysrq_always_enabled=1 ${boot_options}root=UUID=${root_uuid} rw${swap_boot_options}"
				GRUB_PRELOAD_MODULES="part_gpt part_msdos"
				GRUB_TIMEOUT_STYLE=menu
				GRUB_TERMINAL_INPUT=console
				GRUB_GFXMODE=auto
				GRUB_GFXPAYLOAD_LINUX=keep
				GRUB_DISABLE_RECOVERY=true
			EOF

			arch-chroot /mnt /bin/sh -c "grub-install --target=${grub_install_target} ${grub_install_options} ${disk_path}"
			arch-chroot /mnt /bin/sh -c "grub-mkconfig --output /boot/grub/grub.cfg"
			;;
	esac
}

unmount_swap(){
	if ! [ "${setup_swap_file}" ]; then
		return
	fi

	if printf '%s' "${filesystem}" | grep 'btrfs'; then
		swapoff /mnt/swap/swapfile
		return
	fi

	swapoff /mnt/swapfile
}

finish_and_reboot(){
	umount -R /mnt
	printf '%s' 'Rebooting system in 5 seconds...'
	sleep 5
	reboot
}

main(){
	check_root
	get_bios_mode
	get_cpu_architecture
	get_cpu_model
	get_keyboard_layout
	get_timezone
	get_hostname
	get_pacman_packages
	get_disk_path
	get_filesystem
	get_boot_loader
	ask_clean_disk
	ask_encrypt_disk
	ask_setup_lvm
	ask_swap_file
	ask_swap_file_size
	get_root_password
	get_encryption_password

	set_keyboard_layout
	update_system_clock
	unmount_disk
	clean_disk
	partition_disk
	encrypt_disk
	setup_lvm
	format_disk
	mount_disk
	configure_cpu_microcode
	configure_grub_install_target
	install_pacman_packages
	get_uuid
	setup_swap_file
	generate_fstab
	set_timezone
	set_hardware_clock
	set_locale
	set_vconsole
	configure_network
	set_root_password
	configure_boot_options
	run_initramfs
	install_boot_loader
	unmount_swap
	finish_and_reboot
}

main "$@"
