#!/bin/bash

set -euo pipefail

ROOT="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
TOP="$(CDPATH= cd "$ROOT/../../.." && pwd)"
RPC="$TOP/package/custom/qmodem/application/qmodem/files/usr/libexec/rpcd/qmodem"
API="$TOP/package/custom/qmodem/luci/luci-app-qmodem-next/htdocs/luci-static/resources/qmodem/qmodem.js"
INCLUDE="$TOP/package/custom/qmodem/luci/luci-app-qmodem-next/htdocs/luci-static/resources/view/status/include/11_modem.js"
ACL="$TOP/package/custom/qmodem/luci/luci-app-qmodem-next/root/usr/share/rpcd/acl.d/luci-app-qmodem-next.json"
STATUS="$TOP/package/custom/luci-mod-status/htdocs/luci-static/resources/view/status/index.js"

fail() { echo "FAIL: $*" >&2; exit 1; }

sh -n "$RPC" || fail 'QModem RPC script has invalid shell syntax'
python3 -m json.tool "$ACL" >/dev/null || fail 'QModem ACL is invalid JSON'

grep -Fq 'overview_info()' "$RPC" &&
grep -Fq 'cache_only: true' "$RPC" &&
grep -Fq '/tmp/cache_base_info_$section' "$RPC" &&
grep -Fq '/tmp/cache_cell_info_$section' "$RPC" ||
	fail 'cache-only QModem overview RPC is incomplete'

grep -Fq "method: 'overview_info'" "$API" &&
grep -Fq 'getOverviewInfo: function(section)' "$API" &&
grep -Fq 'qmodem.getOverviewInfo(section.id)' "$INCLUDE" ||
	fail 'status modem card does not use the cache-only RPC'

grep -Fq '"qmodem": [ "overview_info", "cell_info", "base_info" ]' "$ACL" ||
	fail 'status overview ACL is missing cache-first or background-refresh calls'
grep -Fq 'STATUS_INCLUDE_TIMEOUT = 3500' "$STATUS" &&
grep -Fq 'boundedLoad(network.flushCache()' "$STATUS" &&
grep -Fq 'End the global "Loading view..." state immediately' "$STATUS" &&
grep -Fq 'startLiveRefresh(sections)' "$INCLUDE" &&
grep -Fq 'if (liveRefresh || now - liveRefreshStarted' "$INCLUDE" ||
	fail 'asynchronous bounded status loading is not wired into the build'

echo 'C2000MAX bounded status overview tests passed'
