REQUIRE_IMAGE_METADATA=1
RAMFS_COPY_BIN='fitblk fit_check_sign sha256sum'

asus_initial_setup()
{
	# initialize UBI if it's running on initramfs
	[ "$(rootfs_type)" = "tmpfs" ] || return 0

	ubirmvol /dev/ubi0 -N rootfs
	ubirmvol /dev/ubi0 -N rootfs_data
	ubirmvol /dev/ubi0 -N jffs2
	ubimkvol /dev/ubi0 -N jffs2 -s 0x3e000
}

buffalo_initial_setup()
{
	local mtdnum="$( find_mtd_index ubi )"
	if [ ! "$mtdnum" ]; then
		echo "unable to find mtd partition ubi"
		return 1
	fi

	ubidetach -m "$mtdnum"
	ubiformat /dev/mtd$mtdnum -y
}

jiorouter_initial_setup()
{
	[ "$(rootfs_type)" = "tmpfs" ] || return 0

	local mtdnum="$( find_mtd_index ubi )"
	if [ ! "$mtdnum" ]; then
		echo "unable to find mtd partition ubi"
		return 1
	fi

	ubidetach -m "$mtdnum" 2>/dev/null
	ubiformat /dev/mtd$mtdnum -y
	ubiattach -m "$mtdnum"
	ubimkvol /dev/ubi0 -n 0 -N u-boot-env -s 0x80000

	# Set boot arguments in freshly created U-Boot environment
	fw_setenv bootcmd 'ubi read 46000000 kernel;fdt addr $(fdtcontroladdr);fdt rm /signature;bootm 0x46000000'
	fw_setenv bootdelay 0
	fw_setenv ipaddr ''
}

# C2000MAX boots this image from a GPT-partitioned TF card.  Its factory
# firmware lives in SPI-NOR and must never be considered an upgrade target.
# Bind stage2 to the exact SD card backing the currently mounted /rom before
# pivoting to ramfs, then revalidate its device numbers and CID immediately
# before any write.  There is deliberately no global MMC scan and no MTD path.
c2000max_block_info()
{
	block info 2>/dev/null
}

c2000max_is_block_device()
{
	[ -b "$1" ]
}

c2000max_prepare_tf_targets()
{
	local sys_class="${C2000MAX_SYS_CLASS_BLOCK:-/sys/class/block}"
	local root_candidates root_dev root_node disk_node candidate node
	local kernel_dev kernel_count=0 type cid disk_dev kernel_devno root_devno

	# `mount` reports /dev/root for squashfs on this board.  `block info`
	# resolves that alias back to the block device actually mounted at /rom.
	root_candidates="$(c2000max_block_info |
		sed -n 's#^\(/dev/mmcblk[0-9][0-9]*p[0-9][0-9]*\):.*MOUNT="/rom".*#\1#p')"
	set -- $root_candidates
	[ "$#" -eq 1 ] || {
		echo 'C2000MAX upgrade: cannot uniquely resolve the active TF rootfs.' >&2
		return 1
	}
	root_dev="$1"
	root_node="${root_dev##*/}"
	printf '%s\n' "$root_node" | grep -Eq '^mmcblk[0-9]+p[0-9]+$' || return 1
	disk_node="$(printf '%s\n' "$root_node" | sed 's/p[0-9][0-9]*$//')"
	c2000max_is_block_device "$root_dev" || return 1
	[ -r "$sys_class/$root_node/uevent" ] &&
		grep -qx 'PARTNAME=rootfs' "$sys_class/$root_node/uevent" || return 1

	type="$(cat "$sys_class/$disk_node/device/type" 2>/dev/null)"
	[ "$type" = SD ] || {
		echo 'C2000MAX upgrade: the active rootfs is not on an SD/TF card.' >&2
		return 1
	}
	cid="$(cat "$sys_class/$disk_node/device/cid" 2>/dev/null)"
	[ "${#cid}" -eq 32 ] || return 1
	case "$cid" in *[!0-9a-fA-F]*) return 1 ;; esac

	for candidate in "$sys_class"/"${disk_node}"p*; do
		[ -r "$candidate/uevent" ] || continue
		grep -qx 'PARTNAME=kernel' "$candidate/uevent" || continue
		node="${candidate##*/}"
		printf '%s\n' "$node" |
			grep -Eq "^${disk_node}p[0-9]+$" || continue
		kernel_dev="/dev/$node"
		kernel_count=$((kernel_count + 1))
	done
	[ "$kernel_count" -eq 1 ] &&
		c2000max_is_block_device "$kernel_dev" || {
		echo 'C2000MAX upgrade: cannot uniquely resolve the TF kernel partition.' >&2
		return 1
	}

	disk_dev="$(cat "$sys_class/$disk_node/dev" 2>/dev/null)"
	kernel_devno="$(cat "$sys_class/${kernel_dev##*/}/dev" 2>/dev/null)"
	root_devno="$(cat "$sys_class/$root_node/dev" 2>/dev/null)"
	printf '%s\n%s\n%s\n' "$disk_dev" "$kernel_devno" "$root_devno" |
		grep -Eqv '^[0-9]+:[0-9]+$' && return 1

	export C2000MAX_TF_BOUND=1
	export C2000MAX_TF_DISK="/dev/$disk_node"
	export C2000MAX_TF_KERNEL="$kernel_dev"
	export C2000MAX_TF_ROOTFS="$root_dev"
	export C2000MAX_TF_DISK_DEVNO="$disk_dev"
	export C2000MAX_TF_KERNEL_DEVNO="$kernel_devno"
	export C2000MAX_TF_ROOTFS_DEVNO="$root_devno"
	export C2000MAX_TF_CID="$cid"
}

c2000max_validate_tf_targets()
{
	local sys_class="${C2000MAX_SYS_CLASS_BLOCK:-/sys/class/block}"
	local disk_node kernel_node root_node type cid

	[ "$C2000MAX_TF_BOUND" = 1 ] || return 1
	disk_node="${C2000MAX_TF_DISK##*/}"
	kernel_node="${C2000MAX_TF_KERNEL##*/}"
	root_node="${C2000MAX_TF_ROOTFS##*/}"
	printf '%s\n' "$disk_node" | grep -Eq '^mmcblk[0-9]+$' || return 1
	printf '%s\n' "$kernel_node" | grep -Eq "^${disk_node}p[0-9]+$" || return 1
	printf '%s\n' "$root_node" | grep -Eq "^${disk_node}p[0-9]+$" || return 1
	[ "$kernel_node" != "$root_node" ] || return 1
	c2000max_is_block_device "$C2000MAX_TF_DISK" &&
		c2000max_is_block_device "$C2000MAX_TF_KERNEL" &&
		c2000max_is_block_device "$C2000MAX_TF_ROOTFS" || return 1

	type="$(cat "$sys_class/$disk_node/device/type" 2>/dev/null)"
	cid="$(cat "$sys_class/$disk_node/device/cid" 2>/dev/null)"
	[ "$type" = SD ] && [ "$cid" = "$C2000MAX_TF_CID" ] || return 1
	[ "$(cat "$sys_class/$disk_node/dev" 2>/dev/null)" = "$C2000MAX_TF_DISK_DEVNO" ] &&
		[ "$(cat "$sys_class/$kernel_node/dev" 2>/dev/null)" = "$C2000MAX_TF_KERNEL_DEVNO" ] &&
		[ "$(cat "$sys_class/$root_node/dev" 2>/dev/null)" = "$C2000MAX_TF_ROOTFS_DEVNO" ] || return 1
	grep -qx 'PARTNAME=kernel' "$sys_class/$kernel_node/uevent" &&
		grep -qx 'PARTNAME=rootfs' "$sys_class/$root_node/uevent"
}

c2000max_tf_sectors()
{
	local node="${1##*/}"
	cat "${C2000MAX_SYS_CLASS_BLOCK:-/sys/class/block}/$node/size" 2>/dev/null
}

c2000max_tar_member_bytes()
{
	tar x${C2000MAX_UPGRADE_GZ}f "$1" "$2" -O | wc -c | awk '{print $1}'
}

c2000max_tar_member_padded_hash()
{
	local tar_file="$1" member="$2" bytes="$3" blocks="$4" padding
	padding=$((blocks * 512 - bytes))
	(
		tar x${C2000MAX_UPGRADE_GZ}f "$tar_file" "$member" -O
		[ "$padding" -eq 0 ] ||
			dd if=/dev/zero bs=1 count="$padding" 2>/dev/null
	) | sha256sum | awk '{print $1}'
}

c2000max_tf_padded_hash()
{
	local dev="$1" blocks="$2" large tail
	large=$((blocks / 128))
	tail=$((blocks % 128))
	(
		[ "$large" -eq 0 ] ||
			dd if="$dev" bs=65536 count="$large" 2>/dev/null
		[ "$tail" -eq 0 ] ||
			dd if="$dev" bs=512 skip=$((large * 128)) count="$tail" 2>/dev/null
	) |
		sha256sum | awk '{print $1}'
}

c2000max_tf_write_member()
{
	local tar_file="$1" member="$2" dev="$3" bytes="$4" blocks="$5"
	local expected actual

	expected="$(c2000max_tar_member_padded_hash \
		"$tar_file" "$member" "$bytes" "$blocks")"
	[ "${#expected}" -eq 64 ] || return 1

	tar x${C2000MAX_UPGRADE_GZ}f "$tar_file" "$member" -O |
		dd of="$dev" bs=65536 conv=notrunc || return 1
	sync

	actual="$(c2000max_tf_padded_hash "$dev" "$blocks")"
	[ "$actual" = "$expected" ]
}

c2000max_tf_upgrade_tar()
{
	local tar_file="$1" board_dir kernel_member root_member
	local kernel_bytes root_bytes kernel_blocks root_blocks root_aligned
	local kernel_sectors root_sectors root_wipe_blocks

	C2000MAX_UPGRADE_GZ=
	[ "$(identify_magic_long "$(get_magic_long "$tar_file" cat)")" = gzip ] &&
		C2000MAX_UPGRADE_GZ=z
	board_dir="$(tar t${C2000MAX_UPGRADE_GZ}f "$tar_file" |
		sed -n '/^sysupgrade-[^/]*\/$/{s#/$##;p;q;}')"
	[ -n "$board_dir" ] || {
		echo 'C2000MAX upgrade: sysupgrade directory is missing.' >&2
		return 1
	}

	kernel_member="$board_dir/kernel"
	root_member="$board_dir/root"
	tar t${C2000MAX_UPGRADE_GZ}f "$tar_file" "$kernel_member" >/dev/null 2>&1 &&
		tar t${C2000MAX_UPGRADE_GZ}f "$tar_file" "$root_member" >/dev/null 2>&1 || {
		echo 'C2000MAX upgrade: kernel or root image is missing.' >&2
		return 1
	}

	c2000max_validate_tf_targets || {
		echo 'C2000MAX upgrade: active TF identity changed; refusing all writes.' >&2
		return 1
	}
	EMMC_KERN_DEV="$C2000MAX_TF_KERNEL"
	EMMC_ROOT_DEV="$C2000MAX_TF_ROOTFS"
	export EMMC_KERN_DEV EMMC_ROOT_DEV

	kernel_bytes="$(c2000max_tar_member_bytes "$tar_file" "$kernel_member")"
	root_bytes="$(c2000max_tar_member_bytes "$tar_file" "$root_member")"
	case "$kernel_bytes:$root_bytes" in
	*[!0-9:]*|0:*|*:0|'')
		echo 'C2000MAX upgrade: image size validation failed.' >&2
		return 1
		;;
	esac
	kernel_blocks=$(((kernel_bytes + 511) / 512))
	root_blocks=$(((root_bytes + 511) / 512))
	root_aligned=$(((root_blocks + 127) & ~127))
	kernel_sectors="$(c2000max_tf_sectors "$EMMC_KERN_DEV")"
	root_sectors="$(c2000max_tf_sectors "$EMMC_ROOT_DEV")"
	case "$kernel_sectors:$root_sectors" in
	*[!0-9:]*|0:*|*:0|'') return 1 ;;
	esac
	[ "$kernel_blocks" -le "$kernel_sectors" ] &&
		[ "$root_aligned" -lt "$root_sectors" ] || {
		echo 'C2000MAX upgrade: image exceeds its GPT partition.' >&2
		return 1
	}

	echo "Writing C2000MAX rootfs to $EMMC_ROOT_DEV ..."
	c2000max_tf_write_member "$tar_file" "$root_member" \
		"$EMMC_ROOT_DEV" "$root_bytes" "$root_blocks" || {
		echo 'C2000MAX upgrade: rootfs readback verification failed.' >&2
		return 1
	}
	export EMMC_ROOTFS_BLOCKS="$root_aligned"

	# Invalidate the old kernel only after the new rootfs has passed readback.
	dd if=/dev/zero of="$EMMC_KERN_DEV" bs=512 count=8 conv=notrunc || return 1
	sync
	echo "Writing C2000MAX kernel to $EMMC_KERN_DEV ..."
	c2000max_tf_write_member "$tar_file" "$kernel_member" \
		"$EMMC_KERN_DEV" "$kernel_bytes" "$kernel_blocks" || {
		echo 'C2000MAX upgrade: kernel readback verification failed.' >&2
		return 1
	}
	export EMMC_KERNEL_BLOCKS="$kernel_blocks"

	# With -n, destroy a full MiB at the aligned overlay start.  This clears
	# both F2FS superblock copies, so stale settings cannot reappear even when
	# the new squashfs happens to have the same length as the old one.
	if [ -z "$UPGRADE_BACKUP" ]; then
		root_wipe_blocks=$((root_sectors - root_aligned))
		[ "$root_wipe_blocks" -gt 2048 ] && root_wipe_blocks=2048
		[ "$root_wipe_blocks" -ge 8 ] || return 1
		dd if=/dev/zero of="$EMMC_ROOT_DEV" bs=512 \
			seek="$root_aligned" count="$root_wipe_blocks" conv=notrunc || return 1
		sync
	fi

	export C2000MAX_TF_UPGRADE_OK=1
	return 0
}

c2000max_tf_do_upgrade()
{
	# Keep the proven v36.01 sysupgrade data path.  The only board-specific
	# change is that the native eMMC helper receives the exact kernel/rootfs
	# devices of the SD card backing /rom, so the native helper performs no
	# device discovery and the factory SPI-NOR is never an upgrade target.
	c2000max_validate_tf_targets || {
		echo 'C2000MAX upgrade: active TF identity changed; refusing all writes.' >&2
		return 1
	}
	CI_KERNPART='kernel'
	CI_ROOTPART='rootfs'
	EMMC_KERN_DEV="$C2000MAX_TF_KERNEL"
	EMMC_ROOT_DEV="$C2000MAX_TF_ROOTFS"
	export CI_KERNPART CI_ROOTPART EMMC_KERN_DEV EMMC_ROOT_DEV
	emmc_do_upgrade "$1"
}

xiaomi_initial_setup()
{
	# initialize UBI and setup uboot-env if it's running on initramfs
	[ "$(rootfs_type)" = "tmpfs" ] || return 0

	local mtdnum="$( find_mtd_index ubi )"
	if [ ! "$mtdnum" ]; then
		echo "unable to find mtd partition ubi"
		return 1
	fi

	local kern_mtdnum="$( find_mtd_index ubi_kernel )"
	if [ ! "$kern_mtdnum" ]; then
		echo "unable to find mtd partition ubi_kernel"
		return 1
	fi

	ubidetach -m "$mtdnum"
	ubiformat /dev/mtd$mtdnum -y

	ubidetach -m "$kern_mtdnum"
	ubiformat /dev/mtd$kern_mtdnum -y

	if ! fw_printenv -n flag_try_sys2_failed &>/dev/null; then
		echo "failed to access u-boot-env. skip env setup."
		return 0
	fi

	fw_setenv -s - <<-EOF
		boot_wait on
		uart_en 1
		flag_boot_rootfs 0
		flag_last_success 1
		flag_boot_success 1
		flag_try_sys1_failed 8
		flag_try_sys2_failed 8
	EOF

	local board=$(board_name)
	case "$board" in
	xiaomi,mi-router-ax3000t|\
	xiaomi,mi-router-wr30u-stock)
		fw_setenv mtdparts "nmbm0:1024k(bl2),256k(Nvram),256k(Bdata),2048k(factory),2048k(fip),256k(crash),256k(crash_log),34816k(ubi),34816k(ubi1),32768k(overlay),12288k(data),256k(KF)"
		;;
	xiaomi,redmi-router-ax6000-stock)
		fw_setenv mtdparts "nmbm0:1024k(bl2),256k(Nvram),256k(Bdata),2048k(factory),2048k(fip),256k(crash),256k(crash_log),30720k(ubi),30720k(ubi1),51200k(overlay)"
		;;
	esac
}

platform_do_upgrade() {
	local board=$(board_name)

	case "$board" in
	abt,asr3000|\
	acer,predator-w6x-ubootmod|\
	asus,zenwifi-bt8-ubootmod|\
	bananapi,bpi-r3|\
	bananapi,bpi-r3-mini|\
	bananapi,bpi-r4|\
	bananapi,bpi-r4-2g5|\
	bananapi,bpi-r4-poe|\
	bananapi,bpi-r4-lite|\
	bazis,ax3000wm|\
	cetron,ct3003-ubootmod|\
	cmcc,a10-ubootmod|\
	cmcc,rax3000m|\
	cmcc,rax3000me|\
	comfast,cf-wr632ax-ubootmod|\
	creatlentem,clt-r30b1-ubi|\
	cudy,tr3000-v1-ubootmod|\
	cudy,wbr3000uax-v1-ubootmod|\
	cudy,wr3000e-v1-ubootmod|\
	cudy,wr3000s-v1-ubootmod|\
	cudy,wr3000h-v1-ubootmod|\
	cudy,wr3000p-v1-ubootmod|\
	gatonetworks,gdsp|\
	h3c,magic-nx30-pro|\
	imou,hx21|\
	jcg,q30-pro|\
	jdcloud,re-cp-03|\
	konka,komi-a31|\
	livinet,zr-3020-ubootmod|\
	mediatek,mt7981-rfb|\
	mediatek,mt7988a-rfb|\
	mercusys,mr90x-v1-ubi|\
	netis,eap930-v1|\
	netis,nx30v2|\
	netis,nx31|\
	netis,nx32u|\
	nokia,ea0326gmp|\
	openwrt,one|\
	netcore,n60|\
	netcore,n60-pro|\
	qihoo,360t7|\
	qihoo,360t7-ubi|\
	routerich,ax3000-ubootmod|\
	routerich,be7200|\
	ruijie,rg-x60-new-ubi|\
	snr,snr-cpe-ax2|\
	tplink,tl-7dr7230-v1|\
	tplink,tl-7dr7230-v2|\
	tplink,tl-7dr7250-v1|\
	tplink,tl-xdr4288|\
	tplink,tl-xdr6086|\
	tplink,tl-xdr6088|\
	tplink,tl-xtr8488|\
	viettel,32x6|\
	viettel,nr3053|\
	wirelesstag,zx7981pd-ubootmod|\
	xiaomi,mi-router-ax3000t-ubootmod|\
	xiaomi,redmi-router-ax6000-ubootmod|\
	xiaomi,mi-router-wr30u-ubootmod|\
	zyxel,ex5601-t0-ubootmod|\
	zyxel,wx5600-t0-ubootmod)
		fit_do_upgrade "$1"
		;;
	acer,predator-w6|\
	acer,predator-w6d|\
	acer,vero-w6m|\
	airpi,ap3000m|\
	arcadyan,mozart|\
	clx,s20p|\
	glinet,gl-mt2500|\
	glinet,gl-mt2500-airoha|\
	glinet,gl-mt6000|\
	glinet,gl-x3000|\
	glinet,gl-xe3000|\
	huasifei,wh3000-emmc|\
	huasifei,wh3000-pro-emmc|\
	sl,3000-emmc|\
	smartrg,sdg-8612|\
	smartrg,sdg-8614|\
	smartrg,sdg-8622|\
	smartrg,sdg-8632|\
	smartrg,sdg-8733|\
	smartrg,sdg-8733a|\
	smartrg,sdg-8734)
		CI_KERNPART="kernel"
		CI_ROOTPART="rootfs"
		emmc_do_upgrade "$1"
		;;
	nradio,c2000-max)
		CI_KERNPART="kernel"
		CI_ROOTPART="rootfs"
		c2000max_tf_do_upgrade "$1" || {
			echo 'C2000MAX system upgrade stopped; the device will not reboot.' >&2
			exit 1
		}
		;;
	asus,rt-ax52|\
	asus,rt-ax57m|\
	asus,rt-ax59u|\
	asus,tuf-ax4200|\
	asus,tuf-ax4200q|\
	asus,tuf-ax6000|\
	asus,zenwifi-bt8)
		CI_UBIPART="UBI_DEV"
		CI_KERNPART="linux"
		nand_do_upgrade "$1"
		;;
	buffalo,wsr-6000ax8|\
	cudy,wr3000h-v1|\
	cudy,wr3000p-v1|\
	huasifei,wh3000-pro-nand|\
	huasifei,wh3000r-nand|\
	jiorouter,ax6000-jidu6101|\
	ruijie,rg-x30e-pro|\
	zhao,7981r128)
		CI_UBIPART="ubi"
		nand_do_upgrade "$1"
		;;
	cudy,re3000-v1|\
	cudy,wr3000-v1|\
	kebidumei,ax3000-u22|\
	totolink,x6000r|\
	wavlink,wl-wn573hx3|\
	widelantech,wap430x|\
	yuncore,ax835)
		default_do_upgrade "$1"
		;;
	dlink,aquila-pro-ai-e30-a1|\
	dlink,aquila-pro-ai-m30-a1|\
	dlink,aquila-pro-ai-m60-a1)
		fw_setenv sw_tryactive 0
		nand_do_upgrade "$1"
		;;
	elecom,wrc-x3000gs3)
		local bootnum="$(mstc_rw_bootnum)"
		case "$bootnum" in
		1|2)
			CI_UBIPART="ubi$bootnum"
			[ -z "$(find_mtd_index $CI_UBIPART)" ] &&
				CI_UBIPART="ubi"
			;;
		*)
			v "invalid bootnum found ($bootnum), rebooting..."
			nand_do_upgrade_failed
			;;
		esac
		nand_do_upgrade "$1"
		;;
	mercusys,mr80x-v3|\
	mercusys,mr85x|\
	mercusys,mr90x-v1|\
	tplink,archer-ax80-v1|\
	tplink,archer-ax80-v1-eu|\
	tplink,be450|\
	tplink,re6000xd)
		CI_UBIPART="ubi0"
		nand_do_upgrade "$1"
		;;
	netgear,eax17)
		echo "UPGRADING SECOND SLOT"
		CI_KERNPART="kernel2"
		CI_ROOTPART="rootfs2"
		nand_do_flash_file "$1" || nand_do_upgrade_failed
		echo "UPGRADING PRIMARY SLOT"
		CI_KERNPART="kernel"
		CI_ROOTPART="rootfs"
		nand_do_flash_file "$1" || nand_do_upgrade_failed
		nand_do_upgrade_success
		;;
	tplink,fr365-v1)
		CI_UBIPART="ubi"
		CI_KERNPART="kernel"
		CI_ROOTPART="rootfs"
		nand_do_upgrade "$1"
		;;
	teltonika,rutc50)
		CI_UBIPART="$(cmdline_get_var ubi.mtd)"
		nand_do_upgrade "$1"
		;;
	nradio,c8-668gl)
		CI_DATAPART="rootfs_data"
		CI_KERNPART="kernel_2nd"
		CI_ROOTPART="rootfs_2nd"
		emmc_do_upgrade "$1"
		;;
	ubnt,unifi-6-plus)
		CI_KERNPART="kernel0"
		EMMC_ROOT_DEV="$(cmdline_get_var root)"
		emmc_do_upgrade "$1"
		;;
	unielec,u7981-01*)
		local rootdev="$(cmdline_get_var root)"
		rootdev="${rootdev##*/}"
		rootdev="${rootdev%p[0-9]*}"
		case "$rootdev" in
		mmc*)
			CI_ROOTDEV="$rootdev"
			CI_KERNPART="kernel"
			CI_ROOTPART="rootfs"
			emmc_do_upgrade "$1"
			;;
		*)
			CI_KERNPART="fit"
			nand_do_upgrade "$1"
			;;
		esac
		;;
	xiaomi,mi-router-ax3000t|\
	xiaomi,mi-router-wr30u-stock|\
	xiaomi,redmi-router-ax6000-stock)
		CI_KERN_UBIPART=ubi_kernel
		CI_ROOT_UBIPART=ubi
		nand_do_upgrade "$1"
		;;
	*)
		nand_do_upgrade "$1"
		;;
	esac
}

PART_NAME=firmware

platform_check_image() {
	local board=$(board_name)

	[ "$#" -gt 1 ] && return 1

	case "$board" in
	abt,asr3000|\
	acer,predator-w6x-ubootmod|\
	asus,zenwifi-bt8-ubootmod|\
	bananapi,bpi-r3|\
	bananapi,bpi-r3-mini|\
	bananapi,bpi-r4|\
	bananapi,bpi-r4-2g5|\
	bananapi,bpi-r4-poe|\
	bananapi,bpi-r4-lite|\
	bazis,ax3000wm|\
	cetron,ct3003-ubootmod|\
	cmcc,a10-ubootmod|\
	cmcc,rax3000m|\
	cmcc,rax3000me|\
	comfast,cf-wr632ax-ubootmod|\
	creatlentem,clt-r30b1-ubi|\
	cudy,tr3000-v1-ubootmod|\
	cudy,wbr3000uax-v1-ubootmod|\
	cudy,wr3000e-v1-ubootmod|\
	cudy,wr3000s-v1-ubootmod|\
	cudy,wr3000h-v1-ubootmod|\
	cudy,wr3000p-v1-ubootmod|\
	gatonetworks,gdsp|\
	h3c,magic-nx30-pro|\
	imou,lc-hx3001|\
	jcg,q30-pro|\
	jdcloud,re-cp-03|\
	konka,komi-a31|\
	livinet,zr-3020-ubootmod|\
	mediatek,mt7981-rfb|\
	mediatek,mt7988a-rfb|\
	mercusys,mr90x-v1-ubi|\
	nokia,ea0326gmp|\
	netis,eap930-v1|\
	netis,nx32u|\
	openwrt,one|\
	netcore,n60|\
	netcore,n60-pro|\
	qihoo,360t7|\
	qihoo,360t7-ubi|\
	routerich,ax3000-ubootmod|\
	ruijie,rg-x60-new-ubi|\
	tplink,tl-7dr7230-v1|\
	tplink,tl-7dr7230-v2|\
	tplink,tl-7dr7250-v1|\
	tplink,tl-xdr4288|\
	tplink,tl-xdr6086|\
	tplink,tl-xdr6088|\
	tplink,tl-xtr8488|\
	viettel,32x6|\
	viettel,nr3053|\
	xiaomi,mi-router-ax3000t-ubootmod|\
	xiaomi,redmi-router-ax6000-ubootmod|\
	xiaomi,mi-router-wr30u-ubootmod|\
	wirelesstag,zx7981pd-ubootmod|\
	zyxel,ex5601-t0-ubootmod)
		fit_check_image "$1"
		return $?
		;;
	creatlentem,clt-r30b1|\
	creatlentem,clt-r30b1-112m|\
	nradio,c2000-max|\
	nradio,c8-668gl|\
	zhao,7981r128)
		# tar magic `ustar`
		magic="$(dd if="$1" bs=1 skip=257 count=5 2>/dev/null)"

		[ "$magic" != "ustar" ] && {
			echo "Invalid image type."
			return 1
		}

		return 0
		;;
	*)
		nand_do_platform_check "$board" "$1"
		return $?
		;;
	esac

	return 0
}

platform_copy_config() {
	case "$(board_name)" in
	acer,predator-w6|\
	acer,predator-w6d|\
	acer,vero-w6m|\
	airpi,ap3000m|\
	arcadyan,mozart|\
	clx,s20p|\
	glinet,gl-mt2500|\
	glinet,gl-mt2500-airoha|\
	glinet,gl-mt6000|\
	glinet,gl-x3000|\
	glinet,gl-xe3000|\
	huasifei,wh3000-emmc|\
	huasifei,wh3000-pro-emmc|\
	jdcloud,re-cp-03|\
	nradio,c2000-max|\
	sl,3000-emmc|\
	nradio,c8-668gl|\
	smartrg,sdg-8612|\
	smartrg,sdg-8614|\
	smartrg,sdg-8622|\
	smartrg,sdg-8632|\
	smartrg,sdg-8733|\
	smartrg,sdg-8733a|\
	smartrg,sdg-8734|\
	ubnt,unifi-6-plus)
		emmc_copy_config
		;;
	bananapi,bpi-r3|\
	bananapi,bpi-r3-mini|\
	bananapi,bpi-r4|\
	bananapi,bpi-r4-2g5|\
	bananapi,bpi-r4-poe|\
	bananapi,bpi-r4-lite|\
	cmcc,rax3000m|\
	cmcc,rax3000me|\
	gatonetworks,gdsp|\
	mediatek,mt7988a-rfb)
		if [ "$CI_METHOD" = "emmc" ]; then
			emmc_copy_config
		fi
		;;
	esac
}

platform_pre_upgrade() {
	local board=$(board_name)

	case "$board" in
	nradio,c2000-max)
		# Resolve /rom while the full userspace is still available, and export
		# an immutable SD CID + dev-number guard into the stage2 ramfs shell.
		# If this cannot prove the running system is on one TF card, stop before
		# touching any block device.  SPI-NOR (/dev/mtd*) is never accepted.
		c2000max_prepare_tf_targets || {
			echo "Unable to bind the active C2000MAX TF card; upgrade aborted." >&2
			exit 1
		}
		echo "C2000MAX upgrade target locked to $C2000MAX_TF_DISK (TF CID $C2000MAX_TF_CID)."
		# sysupgrade -n discards the overlay, so persist the verified physical
		# selection in the dedicated GPT U-Boot environment before stage2.
		# Abort rather than silently boot the new image's external2 default.
		/usr/sbin/c2000max-sim persist || {
			echo "Unable to preserve the C2000MAX SIM slot; upgrade aborted." >&2
			exit 1
		}
		;;
	asus,rt-ax52|\
	asus,rt-ax57m|\
	asus,rt-ax59u|\
	asus,tuf-ax4200|\
	asus,tuf-ax4200q|\
	asus,tuf-ax6000|\
	asus,zenwifi-bt8)
		asus_initial_setup
		;;
	buffalo,wsr-6000ax8)
		buffalo_initial_setup
		;;
	jiorouter,ax6000-jidu6101)
		jiorouter_initial_setup
		;;
	xiaomi,mi-router-ax3000t|\
	xiaomi,mi-router-wr30u-stock|\
	xiaomi,redmi-router-ax6000-stock)
		xiaomi_initial_setup
		;;
	esac
}
