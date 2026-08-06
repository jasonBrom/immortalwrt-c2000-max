#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# netbird-autoreconnect.sh — 保守自动重连:
# - 只有 netbird.runtime.desired_connected=1 时才尝试恢复。
# - 已连接时自动 adopt desired_connected=1,并清理历史 transient 错误。
# - 认证 fatal / NeedsLogin 会置 desired_connected=0,避免无限重试。
# - 不保存 setup key;首次注册失败仍要求用户重新点击连接。

TAG="luci-netbird-watchdog"
INTERVAL="${NB_AUTORECONNECT_INTERVAL:-30}"

# Keep the management plane alive on 512 MiB devices. This worker is
# recoverable and must lose an OOM tie against rpcd/uhttpd.
[ ! -w /proc/self/oom_score_adj ] ||
	echo 500 > /proc/self/oom_score_adj 2>/dev/null
# 重连连续失败时指数退避(INTERVAL→2x→…→封顶 MAX_INTERVAL),连上即复位;
# 避免长时间 outage 每 INTERVAL 秒一次高成本 do_up + 日志刷屏。
MAX_INTERVAL="${NB_AUTORECONNECT_MAX_INTERVAL:-300}"
backoff="$INTERVAL"
attempt_wait=0   # 距下次重连尝试还需等待的秒数(按 INTERVAL 递减);轮询本身不退避,保证恢复/清错及时

# 收到 procd/系统 TERM/INT 立即退出,避免卡在 sleep 或 ubus -t 90 上拖慢 stop/reboot。
trap 'exit 0' TERM INT

_log() {
	logger -t "$TAG" "$*"
}

_reset_backoff() {
	backoff="$INTERVAL"
}

_bump_backoff() {
	backoff=$((backoff * 2))
	[ "$backoff" -gt "$MAX_INTERVAL" ] && backoff="$MAX_INTERVAL"
}

_resolve_bin() {
	if command -v netbird >/dev/null 2>&1; then
		command -v netbird
		return 0
	fi
	for p in /usr/bin/netbird /usr/sbin/netbird; do
		[ -x "$p" ] && { echo "$p"; return 0; }
	done
	return 1
}

_desired() {
	uci -q get netbird.runtime.desired_connected 2>/dev/null
}

_runtime_set() {
	uci -q set "netbird.runtime.$1=$2" 2>/dev/null || return 1
	uci -q commit netbird 2>/dev/null || return 1
}

_set_desired() {
	_runtime_set desired_connected "$1" || _log "warning: failed to set desired_connected=$1"
}

_set_error() {
	_runtime_set last_error "$1" || _log "warning: failed to set last_error"
}

_clear_error() {
	_runtime_set last_error "" >/dev/null 2>&1 || true
}

_with_timeout_status() {
	bin="$1"
	if command -v timeout >/dev/null 2>&1; then
		timeout 6s "$bin" status 2>&1
	else
		"$bin" status 2>&1
	fi
}

_match() {
	printf '%s\n' "$1" | grep -Eiq "$2"
}

_is_connected() {
	_match "$1" 'Management:[[:space:]]*Connected'
}

_is_needs_login() {
	_match "$1" 'NeedsLogin|needs login|login required|no peer auth method provided'
}

_is_auth_fatal() {
	_match "$1" 'setup key is invalid|invalid setup key|setup key.*(expired|revoked|disabled|usage limit|not found|already used)|PermissionDenied|Unauthenticated|code[[:space:]]*=[[:space:]]*NotFound|peer not found|not registered|removed from network|login has expired'
}

_is_transient_disconnect() {
	_match "$1" 'Management:[[:space:]]*Disconnected|Unavailable|DeadlineExceeded|connection refused|i/o timeout|network is unreachable|no such host|temporary failure|TLS handshake timeout|context deadline exceeded|keepalive ping failed|transport is closing|connection reset|timeout after'
}

_attempt_reconnect() {
	local bin="$1"
	_log "management disconnected; applying NetBird settings outside rpcd"
	if [ -x /etc/init.d/netbird-settings ]; then
		if command -v timeout >/dev/null 2>&1; then
			out="$(timeout -k 2s 35s /etc/init.d/netbird-settings reload 2>&1)"
		else
			out="$(/etc/init.d/netbird-settings reload 2>&1)"
		fi
	else
		if command -v timeout >/dev/null 2>&1; then
			out="$(timeout -k 2s 20s "$bin" up --no-browser 2>&1)"
		else
			out="$("$bin" up --no-browser 2>&1)"
		fi
	fi
	rc=$?
	if [ "$rc" -ne 0 ]; then
		first_line="$(printf '%s\n' "$out" | sed -n '1p')"
		_log "reconnect failed rc=$rc: $first_line"
	fi
}

while :; do
	bin="$(_resolve_bin 2>/dev/null)"
	if [ -z "$bin" ]; then
		sleep "$INTERVAL"
		continue
	fi

	raw="$(_with_timeout_status "$bin")"
	want="$(_desired)"

	if _is_connected "$raw"; then
		[ "$want" = "1" ] || _set_desired 1
		_clear_error
		_reset_backoff
		attempt_wait=0
		sleep "$INTERVAL"
		continue
	fi

	[ "$want" = "1" ] || {
		_reset_backoff
		attempt_wait=0
		sleep "$INTERVAL"
		continue
	}

	if _is_auth_fatal "$raw"; then
		_set_desired 0
		_set_error "Authentication failed: the management server rejected this peer."
		"$bin" down >/dev/null 2>&1 || true
		_log "authentication fatal; stopped automatic reconnect"
		sleep "$INTERVAL"
		continue
	fi

	if _is_needs_login "$raw"; then
		_set_desired 0
		_set_error "Authentication failed: NetBird did not receive a valid setup key."
		_log "needs login; stopped automatic reconnect"
		sleep "$INTERVAL"
		continue
	fi

	if [ -z "$raw" ] || _is_transient_disconnect "$raw"; then
		# 退避只作用于"重连尝试"频率,不拖慢轮询:仅当 attempt_wait 归零才发起一次 do_up,
		# 随后按当前 backoff 设定下次尝试等待并增长 backoff;期间每 INTERVAL 仍轮询状态,
		# 故 outage 恢复(daemon 自愈)后能在一个 INTERVAL 内检测到并清错复位。
		if [ "$attempt_wait" -le 0 ]; then
			_attempt_reconnect "$bin"
			attempt_wait="$backoff"
			_bump_backoff
		fi
	fi

	[ "$attempt_wait" -gt 0 ] && attempt_wait=$(( attempt_wait - INTERVAL ))
	sleep "$INTERVAL"
done
