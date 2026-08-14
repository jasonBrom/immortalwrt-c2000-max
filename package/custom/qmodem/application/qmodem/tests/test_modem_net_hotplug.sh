#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
HOTPLUG="$ROOT/files/etc/hotplug.d/net/20-modem-net"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/sys/class/net" \
	"$WORK/sys/bus/pci/devices/0000:01:00.0" \
	"$WORK/sys/bus/usb/devices/2-1/2-1:2.0"

cat > "$WORK/bin/uci" <<'EOF'
#!/bin/sh
case "$*" in
	*block_auto_probe*) echo 0 ;;
	*hotplug_add_delay*) echo 0 ;;
esac
EOF
cat > "$WORK/bin/logger" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$WORK/bin/scan" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$WORK/calls"
EOF
chmod +x "$WORK/bin/uci" "$WORK/bin/logger" "$WORK/bin/scan"

run_event() {
	INTERFACE="$1" DEVPATH="$2" ACTION=add \
	QMODEM_SYS_ROOT="$WORK/sys" QMODEM_SCAN_SCRIPT="$WORK/bin/scan" \
	PATH="$WORK/bin:$PATH" sh "$HOTPLUG"
	# The production helper is intentionally asynchronous.
	sleep 0.1
}

mkdir -p "$WORK/sys/devices/platform/pcie/0000:01:00.0/net/ra0" \
	"$WORK/sys/class/net/ra0"
ln -s "$WORK/sys/devices/platform/pcie/0000:01:00.0" \
	"$WORK/sys/class/net/ra0/device"
run_event ra0 class/net/ra0
[ ! -e "$WORK/calls" ] || {
	echo "FAIL: Wi-Fi PCI interface triggered modem scan" >&2
	exit 1
}

mkdir -p "$WORK/sys/devices/platform/pcie/0000:01:00.0/net/wwan0" \
	"$WORK/sys/class/net/wwan0"
ln -s "$WORK/sys/devices/platform/pcie/0000:01:00.0" \
	"$WORK/sys/class/net/wwan0/device"
run_event wwan0 class/net/wwan0
grep -qx 'add 0000:01:00.0 pcie 0' "$WORK/calls"

mkdir -p "$WORK/sys/devices/platform/usb/2-1/2-1:2.0/net/eth2" \
	"$WORK/sys/class/net/eth2"
ln -s "$WORK/sys/devices/platform/usb/2-1/2-1:2.0" \
	"$WORK/sys/class/net/eth2/device"
run_event eth2 class/net/eth2
grep -qx 'add 2-1 usb 0' "$WORK/calls"

echo "PASS: modem net hotplug accepts only real USB/PCI modem interfaces"
