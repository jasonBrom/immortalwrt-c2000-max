#!/bin/bash

set -euo pipefail

ROOT="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
TOP="$(CDPATH= cd "$ROOT/../../.." && pwd)"
CONFIG="$TOP/configs/c2000max.config"
DEFCONFIG="$TOP/defconfig/low-mem-512m/c2000max-mt7993-be3600-wifi.config"
DEFAULTS="$ROOT/files/etc/uci-defaults/99-c2000max-defaults"
SYSCTL="$ROOT/files/etc/sysctl.d/99-c2000max-low-memory.conf"
DAED_CLEANUP="$ROOT/files/usr/sbin/c2000max-daed-cleanup"
DAED_PATCH="$TOP/scripts/c2000max/packages-daed-generated-assets.patch"
APP_BRIDGE="$TOP/package/custom/c2000max-app/files/usr/sbin/c2000max-app-bridge"

fail() { echo "FAIL: $*" >&2; exit 1; }

for script in "$DEFAULTS" "$DAED_CLEANUP"; do
	sh -n "$script" || fail "shell syntax failed: $script"
done

grep -Fq 'PKG_VERSION:=2.36.10' "$ROOT/Makefile" ||
	fail 'board package version is not V36.10'
if grep -Eq '^CONFIG_(DEFAULT_)?(PACKAGE_)?(netbird|luci-app-netbird|luci-i18n-netbird-zh-cn)=y$' "$CONFIG" "$DEFCONFIG"; then
	fail 'NetBird is still selected in a C2000MAX image configuration'
fi
if grep -Eq '\+netbird|\+luci-app-netbird|c2000max-netbird-job.*INSTALL|c2000max-service-worker.*INSTALL' "$ROOT/Makefile"; then
	fail 'board package still depends on or installs NetBird workers'
fi
grep -Fq 'rm -rf /etc/netbird /var/lib/netbird' "$DEFAULTS" ||
	fail 'preserved-upgrade NetBird state cleanup is missing'

grep -Fq 'nf_conntrack_buckets=16384' "$SYSCTL" &&
grep -Fq 'nf_conntrack_max=32768' "$SYSCTL" ||
	fail '512 MiB conntrack limits are missing'
grep -Fq 'tc qdisc del dev dae0 clsact' "$DAED_CLEANUP" &&
grep -Fq 'ip netns del daens' "$DAED_CLEANUP" ||
	fail 'daed BPF/netns cleanup is incomplete'
grep -Fq 'procd_set_param limits core="0 0"' "$DAED_PATCH" &&
grep -Fq 'service_stopped()' "$DAED_PATCH" ||
	fail 'daed generated feed patch does not release resources after stop'

grep -Fq "'connection_messages false'" "$APP_BRIDGE" &&
grep -Fq "'log_type error'" "$APP_BRIDGE" ||
	fail 'APP MQTT bridge still writes routine reconnect chatter to tmpfs'
if grep -Fq "'log_type notice'" "$APP_BRIDGE"; then
	fail 'APP MQTT bridge notice logging is still enabled'
fi

echo 'C2000MAX V36.10 low-memory service tests passed'
