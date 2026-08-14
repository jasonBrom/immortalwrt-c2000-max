#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
RPCD="$ROOT/root/usr/libexec/rpcd/luci.argon_wallpaper"
UI="$(CDPATH= cd -- "$ROOT/../luci-app-argon-config" && pwd)/htdocs/luci-static/resources/view/argon-config.js"

sh -n "$RPCD"
grep -Fq "o.value('bing_cn', _('Bing China (Mainland optimized)'))" "$UI" || {
	echo 'FAIL: mainland wallpaper option is missing' >&2
	exit 1
}
if grep -Fq "o.value('wallhaven'" "$UI" || grep -Fq 'wallhaven.cc' "$RPCD"; then
	echo 'FAIL: retired Wallhaven source is still exposed or queried' >&2
	exit 1
fi
grep -Fq "wallhaven|wallhaven_*) WEB_PIC_SRC='bing_cn'" "$RPCD" || {
	echo 'FAIL: existing Wallhaven selections are not migrated' >&2
	exit 1
}

# Exercise the exact source functions with deterministic command stubs.
FUNCTIONS="$(sed -n '/^valid_key()/,/^try_update()/p' "$RPCD" | sed '$d')"
eval "$FUNCTIONS"

wget() {
	case "$*" in
		*cn.bing.com* ) [ "${FAIL_CN:-0}" = 0 ] || return 1 ;;
	esac
	printf '{"images":[{"url":"/th?id=test_1920x1080.jpg"}]}\n'
}
jsonfilter() {
	input="$(cat)"
	[ -n "$input" ] || return 1
	printf '/th?id=test_1920x1080.jpg\n'
}

WEB_PIC_SRC=bing_cn
FAIL_CN=0
[ "$(fetch_pic_url)" = 'https://cn.bing.com/th?id=test_UHD.jpg' ] || {
	echo 'FAIL: mainland Bing URL was not selected' >&2
	exit 1
}
FAIL_CN=1
[ "$(fetch_pic_url)" = 'https://www.bing.com/th?id=test_UHD.jpg' ] || {
	echo 'FAIL: global Bing fallback did not run' >&2
	exit 1
}

echo 'Argon mainland wallpaper source tests passed'
