/*
	author: derry
	date:2019/1/10
	C2000MAX changes: 2026/8/18, preserve routing marks and gate offload
	while application classification is pending.
*/
#include <linux/init.h>
#include <linux/module.h>
#include <linux/version.h>
#include <net/tcp.h>
#include <linux/netfilter.h>
#include <linux/capability.h>
#include <net/netfilter/nf_conntrack.h>
#include <net/netlink.h>
#include <linux/skbuff.h>
#include <net/ip.h>
#include <uapi/linux/ipv6.h>
#include <linux/types.h>
#include <net/sock.h>
#include <linux/etherdevice.h>
#include <linux/cdev.h>
#include <linux/device.h>
#include <linux/tcp.h>
#include <linux/ip.h>
#include <linux/netfilter_ipv4.h>
#include <linux/netfilter_ipv6.h>
#include <linux/ipv6.h>
#include <linux/in6.h>
#include <linux/workqueue.h>
#include <linux/ctype.h>
#include <linux/list_sort.h>
#include <linux/mutex.h>
#include <linux/random.h>
#include <linux/sched.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include "app_filter.h"
#include "af_utils.h"
#include "af_log.h"
#include "af_client.h"
#include "af_client_fs.h"
#include "cJSON.h"
#include "af_conntrack.h"
#include "af_config.h"
#include "af_rule_config.h"
#include "af_user_config.h"
#include "af_whitelist_config.h"
#include "ik_regex.h"

/* Optional MediaTek HNAT API.  symbol_get() keeps OAF loadable on targets
 * without the proprietary accelerator module and takes a module reference
 * only for the duration of the bounded queue operation. */
extern int mtk_hnat_kick_conntrack(struct nf_conn *ct);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("destan19@126.com");
MODULE_DESCRIPTION("app filter module");
MODULE_VERSION(AF_VERSION);

#define AF_FEATURE_PROTO_BUCKETS 3
#define AF_FEATURE_FAMILY_COUNT 4
#define AF_MATCH_LIST_MAX (AF_FEATURE_FAMILY_COUNT * 2)

enum af_feature_proto_bucket {
	AF_FEATURE_PROTO_ANY = 0,
	AF_FEATURE_PROTO_TCP,
	AF_FEATURE_PROTO_UDP,
};

enum af_feature_family {
	AF_FEATURE_FAMILY_RAW = 0,
	AF_FEATURE_FAMILY_HTTP,
	AF_FEATURE_FAMILY_SNI,
	AF_FEATURE_FAMILY_TLS,
};

struct af_feature_db {
	struct list_head heads[AF_FEATURE_PROTO_BUCKETS][AF_FEATURE_FAMILY_COUNT];
	u32 count;
	u32 load_order;
};

static struct af_feature_db af_feature_boot_db;
static struct af_feature_db *af_feature_active = &af_feature_boot_db;
static struct af_feature_db *af_feature_staging;
static bool af_feature_reload_failed;
static DEFINE_MUTEX(af_feature_reload_lock);

static void af_feature_db_sort(struct af_feature_db *db);

DEFINE_RWLOCK(af_feature_lock);

u_int32_t g_update_jiffies = 0;

#define feature_list_read_lock() read_lock_bh(&af_feature_lock);
#define feature_list_read_unlock() read_unlock_bh(&af_feature_lock);
#define feature_list_write_lock() write_lock_bh(&af_feature_lock);
#define feature_list_write_unlock() write_unlock_bh(&af_feature_lock);

#define SET_APPID(mark, appid) (mark = appid)
#define GET_APPID(mark) (mark)
#define OAF_CT_TAG(ct) ((ct)->secmark)
#define MAX_OAF_NETLINK_MSG_LEN 1024
#define OAF_USER_NETLINK_PORTID 999
#define MAX_AF_SUPPORT_DATA_LEN 3000
#define MAX_HOST_LEN 253
#define MIN_HOST_LEN 4
#define APPID_QUIC 10
#define AF_IK_OFFSET_NONE ((s16)-32768)
#define AF_IK_DEFAULT_PRIORITY 100
#define NF_PAYLOAD_SEQ_MAX 7
#define AF_FEATURE_PACKET_NODE_BUDGET 16384U
#define AF_HTTP_PREFIX_SLOTS 128U
#define AF_HTTP_PREFIX_TIMEOUT (5 * HZ)
#define AF_TLS_PREFIX_MAX 8192U
#define AF_TLS_ECH_EXTENSION 0xfe0d

enum af_prefix_kind {
	AF_PREFIX_NONE = 0,
	AF_PREFIX_HTTP,
	AF_PREFIX_TLS,
};

struct af_http_prefix_slot {
	struct nf_conn *ct;
	unsigned long updated;
	u32 next_seq;
	u16 len;
	u8 kind;
	bool seq_valid;
	bool complete;
	u8 data[AF_TLS_PREFIX_MAX];
};

struct af_http_stats {
	atomic64_t parse_ok, parse_fail;
	atomic64_t uri_checked, host_checked, ua_checked;
	atomic64_t candidate_rules, rule_match, rule_no_match, unsupported_rule;
	atomic64_t priority_candidates, priority_rule_match;
	atomic64_t priority_budget_expired, field_prefilter_reject;
	atomic64_t generic_set, generic_upgraded, generic_finalize_timeout;
	atomic64_t generic_finalize_deferred;
	atomic64_t pktseq_wait, pktseq_match, pktseq_budget_expired;
	atomic64_t prefix_alloc, prefix_complete, prefix_restarted;
	atomic64_t prefix_budget_expired, prefix_oom;
	atomic64_t tls_prefix_alloc, tls_prefix_complete;
	atomic64_t tls_prefix_budget_expired, tls_prefix_oom;
	atomic64_t tls_client_hello, tls_sni_ok, tls_sni_missing, tls_ech_seen;
	atomic64_t sni_candidates, sni_rule_match, sni_rule_no_match;
	atomic64_t sni_priority_rule_match, sni_prepass_match;
	atomic64_t sni_pktseq_bypassed;
	atomic64_t policy_hold_seen, policy_hold_published;
	atomic64_t appid1_flows;
	atomic64_t terminal_generic_set, terminal_generic_reentry;
	atomic64_t terminal_generic_upgrade_attempt, terminal_generic_upgrade_ok;
};

#define AF_CLASSIFY_RECENT_MAX 16
struct af_classify_recent {
	u32 src, dst;
	struct in6_addr src6, dst6;
	u16 sport, dport;
	u8 proto, family;
	u16 old_raw, old_appid, new_appid;
	u8 terminal, attempt, ok;
	unsigned long when;
};

static struct af_classify_recent af_classify_recent[AF_CLASSIFY_RECENT_MAX];
static unsigned int af_classify_recent_head;
static DEFINE_SPINLOCK(af_classify_recent_lock);
static struct proc_dir_entry *af_classify_recent_proc;

#define AF_HTTP_MATCH_RECENT_MAX 16
struct af_http_match_recent {
	u32 src, dst;
	u16 sport, dport, appid;
	u8 proto, match_kind, priority, field, fallback, policy_priority;
	char uri[96];
	char host[64];
	char user_agent[64];
	unsigned long when;
};

static struct af_http_match_recent af_http_match_recent[AF_HTTP_MATCH_RECENT_MAX];
static unsigned int af_http_match_recent_head;
static DEFINE_SPINLOCK(af_http_match_recent_lock);
static struct proc_dir_entry *af_http_match_recent_proc;

#define AF_SNI_RECENT_MAX 16
enum af_sni_result {
	AF_SNI_OK = 0,
	AF_SNI_MISSING,
	AF_SNI_ECH,
};

struct af_sni_recent {
	u32 src, dst;
	struct in6_addr src6, dst6;
	u16 sport, dport;
	u16 prefix_len, record_len;
	u8 proto, family, result;
	char sni[64];
	unsigned long when;
};

static struct af_sni_recent af_sni_recent[AF_SNI_RECENT_MAX];
static unsigned int af_sni_recent_head;
static DEFINE_SPINLOCK(af_sni_recent_lock);
static struct proc_dir_entry *af_sni_recent_proc;

#define AF_SNI_MATCH_RECENT_MAX 16
struct af_sni_match_recent {
	u32 src, dst;
	struct in6_addr src6, dst6;
	u16 sport, dport, appid;
	u8 proto, family, match_kind, priority, policy_priority;
	u8 pkt_seq, pkt_seq_mask;
	char sni[64];
	unsigned long when;
};

static struct af_sni_match_recent af_sni_match_recent[AF_SNI_MATCH_RECENT_MAX];
static unsigned int af_sni_match_recent_head;
static DEFINE_SPINLOCK(af_sni_match_recent_lock);
static struct proc_dir_entry *af_sni_match_recent_proc;

static struct af_http_prefix_slot af_http_prefix[AF_HTTP_PREFIX_SLOTS];
static DEFINE_SPINLOCK(af_http_prefix_lock);
static struct af_http_stats af_http_stats;
static struct proc_dir_entry *af_http_stats_proc;


#if LINUX_VERSION_CODE > KERNEL_VERSION(5,10,197)
extern void nf_send_reset(struct net *net, struct sock *sk, struct sk_buff *oldskb, int hook);
#elif LINUX_VERSION_CODE > KERNEL_VERSION(4,4,1)
extern void nf_send_reset(struct net *net,  struct sk_buff *oldskb, int hook);
#else
extern void nf_send_reset(sk_buff *oldskb, int hook);
#endif

char *ipv6_to_str(const struct in6_addr *addr, char *str)
{
    sprintf(str, "%pI6c", addr);
    return str;
}
int hash_mac(unsigned char *mac)
{
	if (!mac)
		return 0;
	return ((mac[0] ^ mac[1]) + (mac[2] ^ mac[3]) + (mac[4] ^ mac[5])) % MAX_AF_MAC_HASH_SIZE;
}

struct parsed_app_feature {
	int proto;
	int src_port;
	port_info_t dport_info;
	char host_url[MAX_HOST_URL_LEN];
	char request_url[MAX_REQUEST_URL_LEN];
	char search_str[MAX_SEARCH_STR_LEN];
	int ignore;
	int pos_num;
	af_pos_info_t pos_info[MAX_POS_INFO_PER_FEATURE];
	u8 feature_version;
	u8 direction;
	s8 pkt_seq;
	u8 pkt_seq_mask;
	u8 match_kind;
	s16 match_offset;
	u8 priority;
	u8 pattern_len;
	u8 pattern[MAX_IK_PATTERN_LEN];
	u8 prefilter_valid;
	u8 prefilter_byte;
	port_info_t payload_len_info;
	u32 server_addr;
	u32 server_mask;
	u8 fallback;
	struct ik_regex *native_regex;
	u8 http_clause_count;
	struct af_http_clause http_clauses[AF_HTTP_MAX_CLAUSES];
};

static void af_http_clauses_free(struct af_http_clause *clauses, u8 count)
{
	int i;

	if (!clauses)
		return;
	for (i = 0; i < min_t(u8, count, AF_HTTP_MAX_CLAUSES); i++) {
		ik_regex_free(clauses[i].regex);
		clauses[i].regex = NULL;
	}
}

static void af_parsed_feature_cleanup(struct parsed_app_feature *parsed)
{
	if (!parsed)
		return;
	ik_regex_free(parsed->native_regex);
	parsed->native_regex = NULL;
	af_http_clauses_free(parsed->http_clauses,
			     parsed->http_clause_count);
	parsed->http_clause_count = 0;
}

static void af_feature_node_cleanup(af_feature_node_t *node)
{
	if (!node)
		return;
	ik_regex_free(node->native_regex);
	node->native_regex = NULL;
	af_http_clauses_free(node->http_clauses,
			     node->http_clause_count);
	node->http_clause_count = 0;
}

static int copy_feature_field(char *dst, size_t dst_size, const char *src)
{
	size_t len;

	if (!dst || !src || dst_size == 0)
		return -EINVAL;

	len = strnlen(src, dst_size);
	if (len >= dst_size)
		return -E2BIG;

	memcpy(dst, src, len);
	dst[len] = '\0';
	return 0;
}

static int parse_range_value(const char *range_str, range_value_t *range)
{
	char range_buf[16];
	char *value;
	char *dash;
	int start;
	int end;
	int is_not = 0;

	if (!range_str || !range ||
	    copy_feature_field(range_buf, sizeof(range_buf), range_str) < 0)
		return -EINVAL;

	value = strim(range_buf);
	if (*value == '!') {
		is_not = 1;
		value = strim(value + 1);
	}
	if (*value == '\0')
		return -EINVAL;

	dash = strchr(value, '-');
	if (dash) {
		if (strchr(dash + 1, '-'))
			return -EINVAL;
		*dash = '\0';
		if (kstrtoint(strim(value), 10, &start) < 0 ||
		    kstrtoint(strim(dash + 1), 10, &end) < 0)
			return -EINVAL;
	} else {
		if (kstrtoint(value, 10, &start) < 0)
			return -EINVAL;
		end = start;
	}

	if (start < 1 || start > 65535 || end < start || end > 65535)
		return -ERANGE;

	range->not = is_not;
	range->start = start;
	range->end = end;
	return 0;
}

static int parse_port_info(const char *port_str, port_info_t *info)
{
	char port_buf[128];
	char *cursor;
	char *token;

	if (!port_str || !info)
		return -EINVAL;

	memset(info, 0, sizeof(*info));
	if (*port_str == '\0')
		return 0;
	if (copy_feature_field(port_buf, sizeof(port_buf), port_str) < 0)
		return -E2BIG;

	cursor = port_buf;
	while ((token = strsep(&cursor, "|")) != NULL) {
		if (info->num >= MAX_PORT_RANGE_NUM)
			return -E2BIG;
		if (parse_range_value(token, &info->range_list[info->num]) < 0)
			return -EINVAL;
		info->num++;
	}

	return 0;
}

static int parse_length_range_value(const char *range_str,
				    range_value_t *range)
{
	char range_buf[24];
	char *value;
	char *dash;
	int start;
	int end;

	if (!range_str || !range ||
	    copy_feature_field(range_buf, sizeof(range_buf), range_str) < 0)
		return -EINVAL;
	value = strim(range_buf);
	if (*value == '\0' || *value == '!')
		return -EINVAL;
	dash = strchr(value, '-');
	if (dash) {
		if (strchr(dash + 1, '-'))
			return -EINVAL;
		*dash = '\0';
		if (kstrtoint(strim(value), 10, &start) < 0 ||
		    kstrtoint(strim(dash + 1), 10, &end) < 0)
			return -EINVAL;
	} else {
		if (kstrtoint(value, 10, &start) < 0)
			return -EINVAL;
		end = start;
	}
	if (start < 0 || end < start || end > 65535)
		return -ERANGE;
	range->not = 0;
	range->start = start;
	range->end = end;
	return 0;
}

static int parse_length_info(const char *value, port_info_t *info)
{
	char buffer[128];
	char *cursor;
	char *token;

	if (!value || !info)
		return -EINVAL;
	memset(info, 0, sizeof(*info));
	if (*value == '\0')
		return 0;
	if (copy_feature_field(buffer, sizeof(buffer), value) < 0)
		return -E2BIG;
	cursor = buffer;
	while ((token = strsep(&cursor, "|")) != NULL) {
		if (info->num >= 5 ||
		    parse_length_range_value(token,
					 &info->range_list[info->num]) < 0)
			return -EINVAL;
		info->num++;
	}
	return 0;
}

static int parse_packet_sequences(const char *value, bool extended,
				  s8 *legacy_seq, u8 *mask)
{
	char buffer[32];
	char *cursor;
	char *token;
	int seq;

	if (!value || !legacy_seq || !mask)
		return -EINVAL;
	*legacy_seq = -1;
	*mask = 0;
	if (*value == '\0' || !strcmp(value, "-1") || !strcmp(value, "0"))
		return 0;
	if (copy_feature_field(buffer, sizeof(buffer), value) < 0)
		return -E2BIG;
	cursor = buffer;
	while ((token = strsep(&cursor, "|")) != NULL) {
		if (kstrtoint(token, 10, &seq) < 0 || seq < 1 ||
		    seq > (extended ? NF_PAYLOAD_SEQ_MAX : 5))
			return -ERANGE;
		*mask |= BIT(seq - 1);
	}
	if (!*mask)
		return -EINVAL;
	if (!extended && hweight8(*mask) != 1)
		return -EINVAL;
	*legacy_seq = __ffs(*mask) + 1;
	return 0;
}

static bool af_ipv4_mask_valid(u32 mask)
{
	u32 inverse;

	if (!mask)
		return false;
	inverse = ~mask;
	return !(inverse & (inverse + 1));
}

static int parse_dict_positions(const char *dict,
				struct parsed_app_feature *parsed)
{
	char dict_buf[128];
	char *cursor;
	char *token;
	char *colon;
	int index;
	unsigned int value;

	if (!dict || !parsed)
		return -EINVAL;
	if (*dict == '\0')
		return 0;
	if (copy_feature_field(dict_buf, sizeof(dict_buf), dict) < 0)
		return -E2BIG;

	cursor = dict_buf;
	while ((token = strsep(&cursor, "|")) != NULL) {
		token = strim(token);
		if (*token == '\0' || parsed->pos_num >= MAX_POS_INFO_PER_FEATURE)
			return -EINVAL;

		colon = strchr(token, ':');
		if (!colon || strchr(colon + 1, ':'))
			return -EINVAL;
		*colon = '\0';
		if (kstrtoint(strim(token), 10, &index) < 0 ||
		    kstrtouint(strim(colon + 1), 16, &value) < 0 ||
		    value > 0xff)
			return -EINVAL;
		if (index < -MAX_AF_SUPPORT_DATA_LEN ||
		    index >= MAX_AF_SUPPORT_DATA_LEN)
			return -ERANGE;

		parsed->pos_info[parsed->pos_num].pos = index;
		parsed->pos_info[parsed->pos_num].value = value;
		parsed->pos_num++;
	}

	return 0;
}

static int parse_source_port(const char *value, int *port)
{
	if (!value || !port)
		return -EINVAL;
	if (*value == '\0') {
		*port = 0;
		return 0;
	}
	if (kstrtoint(value, 10, port) < 0 || *port < 1 || *port > 65535)
		return -EINVAL;
	return 0;
}

static int parse_ik_match_kind(const char *value, u8 *kind)
{
	static const struct {
		const char *name;
		u8 kind;
	} kinds[] = {
		{ "port", AF_IK_MATCH_PORT },
		{ "url", AF_IK_MATCH_URL },
		{ "exact", AF_IK_MATCH_EXACT },
		{ "bm", AF_IK_MATCH_BM },
		{ "regex", AF_IK_MATCH_REGEX },
		{ "sni_exact", AF_IK_MATCH_SNI_EXACT },
		{ "sni_bm", AF_IK_MATCH_SNI_BM },
		{ "sni_regex", AF_IK_MATCH_SNI_REGEX },
		{ "tls_exact", AF_IK_MATCH_TLS_EXACT },
		{ "tls_bm", AF_IK_MATCH_TLS_BM },
		{ "tls_regex", AF_IK_MATCH_TLS_REGEX },
		{ "http_host_exact", AF_IK_MATCH_HTTP_HOST_EXACT },
		{ "http_host_bm", AF_IK_MATCH_HTTP_HOST_BM },
		{ "http_host_regex", AF_IK_MATCH_HTTP_HOST_REGEX },
		{ "http_request_exact", AF_IK_MATCH_HTTP_REQUEST_EXACT },
		{ "http_request_bm", AF_IK_MATCH_HTTP_REQUEST_BM },
		{ "http_request_regex", AF_IK_MATCH_HTTP_REQUEST_REGEX },
		{ "http_multi", AF_IK_MATCH_HTTP_MULTI },
	};
	int i;

	if (!value || !kind)
		return -EINVAL;
	for (i = 0; i < ARRAY_SIZE(kinds); i++) {
		if (!strcmp(value, kinds[i].name)) {
			*kind = kinds[i].kind;
			return 0;
		}
	}
	return -EINVAL;
}

static int parse_hex_pattern(const char *value, u8 *pattern, u8 *pattern_len)
{
	size_t hex_len;
	size_t i;
	int high;
	int low;

	if (!value || !pattern || !pattern_len)
		return -EINVAL;
	hex_len = strlen(value);
	if (!hex_len) {
		*pattern_len = 0;
		return 0;
	}
	if ((hex_len & 1) || hex_len > MAX_IK_PATTERN_LEN * 2)
		return -E2BIG;
	for (i = 0; i < hex_len; i += 2) {
		high = hex_to_bin(value[i]);
		low = hex_to_bin(value[i + 1]);
		if (high < 0 || low < 0)
			return -EINVAL;
		pattern[i / 2] = (u8)((high << 4) | low);
	}
	*pattern_len = hex_len / 2;
	return 0;
}

static bool af_ik_kind_is_regex(u8 kind)
{
	return kind == AF_IK_MATCH_REGEX ||
	       kind == AF_IK_MATCH_SNI_REGEX ||
	       kind == AF_IK_MATCH_TLS_REGEX ||
	       kind == AF_IK_MATCH_HTTP_HOST_REGEX ||
	       kind == AF_IK_MATCH_HTTP_REQUEST_REGEX;
}

static bool af_ik_kind_has_pattern(u8 kind)
{
	return kind >= AF_IK_MATCH_EXACT &&
	       kind <= AF_IK_MATCH_HTTP_MULTI;
}

static bool af_http_field_supported(u8 field)
{
	switch (field) {
	case 0:  /* request target */
	case 1:  /* Host */
	case 2:  /* User-Agent */
	case 3:  /* Referer */
	case 5:  /* Cache-Control */
	case 7:  /* Cookie */
	case 9:  /* Pragma */
	case 12: /* Content-Type */
	case 13: /* Range */
	case 15: /* Connection */
		return true;
	default:
		return false;
	}
}

/* v4.2 HTTP compound pattern: count, followed by up to four
 * (field, method, length, bytes...) clauses.  Every regexp is compiled while
 * staging the database, so packet matching remains allocation-free. */
static int parse_http_multi_pattern(struct parsed_app_feature *parsed)
{
	struct af_http_clause *clause;
	u8 count;
	u8 pos = 0;
	int i;
	int ret;

	if (!parsed || parsed->pattern_len < 4)
		return -EINVAL;
	count = parsed->pattern[pos++];
	if (!count || count > AF_HTTP_MAX_CLAUSES)
		return -EINVAL;
	parsed->http_clause_count = count;
	for (i = 0; i < count; i++) {
		if (pos > parsed->pattern_len - 3)
			goto invalid;
		clause = &parsed->http_clauses[i];
		clause->field = parsed->pattern[pos++];
		clause->method = parsed->pattern[pos++];
		clause->pattern_len = parsed->pattern[pos++];
		clause->pattern_offset = pos;
		if (!af_http_field_supported(clause->field) ||
		    clause->method > AF_HTTP_CLAUSE_REGEX ||
		    !clause->pattern_len ||
		    clause->pattern_len > parsed->pattern_len - pos)
			goto invalid;
		if (clause->method == AF_HTTP_CLAUSE_REGEX) {
			ret = ik_regex_compile(parsed->pattern + pos,
					       clause->pattern_len,
					       &clause->regex);
			if (ret < 0) {
				af_http_clauses_free(parsed->http_clauses,
						     parsed->http_clause_count);
				parsed->http_clause_count = 0;
				return ret;
			}
			clause->prefilter_valid =
				ik_regex_prefilter_byte(clause->regex,
							&clause->prefilter_byte);
		} else {
			clause->prefilter_valid = 1;
			clause->prefilter_byte = parsed->pattern[pos];
		}
		pos += clause->pattern_len;
	}
	if (pos != parsed->pattern_len)
		goto invalid;
	return 0;

invalid:
	af_http_clauses_free(parsed->http_clauses,
			     parsed->http_clause_count);
	parsed->http_clause_count = 0;
	return -EINVAL;
}

static void af_set_parsed_prefilter(struct parsed_app_feature *parsed)
{
	const struct af_http_clause *clause;
	u8 i;
	u8 value;

	if (!parsed || !parsed->pattern_len)
		return;
	if (parsed->match_kind == AF_IK_MATCH_HTTP_MULTI) {
		for (i = 0; i < parsed->http_clause_count; i++) {
			clause = &parsed->http_clauses[i];
			if (!clause->prefilter_valid)
				continue;
			value = clause->prefilter_byte;
			parsed->prefilter_valid = 1;
			parsed->prefilter_byte = value;
			return;
		}
		return;
	}
	if (af_ik_kind_is_regex(parsed->match_kind)) {
		if (!ik_regex_prefilter_byte(parsed->native_regex, &value))
			return;
	} else if (parsed->match_kind == AF_IK_MATCH_EXACT ||
		   parsed->match_kind == AF_IK_MATCH_BM ||
		   parsed->match_kind == AF_IK_MATCH_SNI_EXACT ||
		   parsed->match_kind == AF_IK_MATCH_SNI_BM ||
		   parsed->match_kind == AF_IK_MATCH_TLS_EXACT ||
		   parsed->match_kind == AF_IK_MATCH_TLS_BM ||
		   parsed->match_kind == AF_IK_MATCH_HTTP_HOST_EXACT ||
		   parsed->match_kind == AF_IK_MATCH_HTTP_HOST_BM ||
		   parsed->match_kind == AF_IK_MATCH_HTTP_REQUEST_EXACT ||
		   parsed->match_kind == AF_IK_MATCH_HTTP_REQUEST_BM) {
		value = parsed->pattern[0];
	} else {
		return;
	}
	parsed->prefilter_valid = 1;
	parsed->prefilter_byte = value;
}

static u16 af_feature_specificity(const struct parsed_app_feature *parsed)
{
	u16 score = 0;
	u8 sequence_count;

	if (!parsed || !parsed->feature_version)
		return 0;

	/* iKuai stores port/IP/length, raw payload, SNI and HTTP rules in
	 * different matcher tables.  Its numeric priority only orders comparable
	 * entries inside those tables; treating it as one global score allowed a
	 * broad priority-100 port or parent-domain rule to steal a flow from a
	 * lower-priority, longer SNI/HTTP signature.  Encode evidence strength
	 * first, then use source priority only as a tie-breaker below. */
	switch (parsed->match_kind) {
	case AF_IK_MATCH_HTTP_MULTI:
		score = 1200 + parsed->http_clause_count * 64;
		break;
	case AF_IK_MATCH_SNI_EXACT:
	case AF_IK_MATCH_HTTP_HOST_EXACT:
	case AF_IK_MATCH_HTTP_REQUEST_EXACT:
		score = 1100;
		break;
	case AF_IK_MATCH_SNI_BM:
	case AF_IK_MATCH_SNI_REGEX:
	case AF_IK_MATCH_HTTP_HOST_BM:
	case AF_IK_MATCH_HTTP_HOST_REGEX:
	case AF_IK_MATCH_HTTP_REQUEST_BM:
	case AF_IK_MATCH_HTTP_REQUEST_REGEX:
		score = 1000;
		break;
	case AF_IK_MATCH_TLS_EXACT:
		score = 950;
		break;
	case AF_IK_MATCH_TLS_BM:
	case AF_IK_MATCH_TLS_REGEX:
		score = 900;
		break;
	case AF_IK_MATCH_EXACT:
		score = 850;
		break;
	case AF_IK_MATCH_BM:
	case AF_IK_MATCH_REGEX:
	case AF_IK_MATCH_URL:
		score = 750;
		break;
	case AF_IK_MATCH_PORT:
		score = 100;
		break;
	default:
		break;
	}

	/* Destination evidence is useful, but a shared CDN /24 must not outrank
	 * an application payload or hostname.  Reward actual mask precision rather
	 * than assigning every subnet the same oversized value. */
	if (parsed->server_mask)
		score += hweight32(parsed->server_mask) * 6;
	if (parsed->payload_len_info.num)
		score += 96;
	if (parsed->pkt_seq_mask) {
		sequence_count = hweight8(parsed->pkt_seq_mask);
		/* Fewer accepted packet ordinals are more specific, not less. */
		score += 32 + (8 - min_t(u8, sequence_count, 7)) * 4;
	}
	if (parsed->direction != AF_IK_DIR_BOTH)
		score += 24;
	if (parsed->dport_info.num || parsed->src_port)
		score += 24;
	if (parsed->match_offset != AF_IK_OFFSET_NONE)
		score += 48;
	score += min_t(u16, parsed->pattern_len, 124) * 2;
	return score;
}

static u8 af_feature_proto_bucket(u8 proto)
{
	if (proto == IPPROTO_TCP)
		return AF_FEATURE_PROTO_TCP;
	if (proto == IPPROTO_UDP)
		return AF_FEATURE_PROTO_UDP;
	return AF_FEATURE_PROTO_ANY;
}

static u8 af_feature_family(u8 kind)
{
	switch (kind) {
	case AF_IK_MATCH_HTTP_HOST_EXACT:
	case AF_IK_MATCH_HTTP_HOST_BM:
	case AF_IK_MATCH_HTTP_HOST_REGEX:
	case AF_IK_MATCH_HTTP_REQUEST_EXACT:
	case AF_IK_MATCH_HTTP_REQUEST_BM:
	case AF_IK_MATCH_HTTP_REQUEST_REGEX:
	case AF_IK_MATCH_HTTP_MULTI:
		return AF_FEATURE_FAMILY_HTTP;
	case AF_IK_MATCH_SNI_EXACT:
	case AF_IK_MATCH_SNI_BM:
	case AF_IK_MATCH_SNI_REGEX:
		return AF_FEATURE_FAMILY_SNI;
	case AF_IK_MATCH_TLS_EXACT:
	case AF_IK_MATCH_TLS_BM:
	case AF_IK_MATCH_TLS_REGEX:
		return AF_FEATURE_FAMILY_TLS;
	default:
		/* Legacy URL rules can match both HTTP Host and TLS SNI, so retain
		 * them in the always-considered raw family. */
		return AF_FEATURE_FAMILY_RAW;
	}
}

static bool af_feature_precedes(const af_feature_node_t *left,
				const af_feature_node_t *right)
{
	if (!left)
		return false;
	if (!right)
		return true;
	if (left->feature_version == 4 && right->feature_version == 4) {
		/* Generic/weak candidates never terminate a match, so place concrete
		 * evidence first.  This also avoids spending the bounded packet budget
		 * on generic protocol labels before application signatures. */
		if (left->fallback != right->fallback)
			return left->fallback < right->fallback;
		if (left->specificity != right->specificity)
			return left->specificity > right->specificity;
		if (left->priority != right->priority)
			return left->priority > right->priority;
		/* Native feature ties retain deterministic source order. */
		return left->load_order < right->load_order;
	} else {
		if (left->priority != right->priority)
			return left->priority > right->priority;
		if (left->specificity != right->specificity)
			return left->specificity > right->specificity;
		/* Preserve the legacy v3 rule that later equal-priority definitions
		 * win ties.  A validated profile never mixes v3 and v4 records. */
		return left->load_order > right->load_order;
	}
}

static int parse_app_feature(const char *feature,
			     struct parsed_app_feature *parsed)
{
	char parse_buf[MAX_FEATURE_STR_LEN];
	char src_port[16];
	char dst_port[128];
	char dict[128];
	char *fields[18];
	char *cursor;
	size_t feature_len;
	int field_count = 1;
	int ignore = 0;
	int direction;
	int offset;
	int priority;
	u32 server_addr;
	u32 server_mask;
	int fallback;
	int ret;

	if (!feature || !parsed)
		return -EINVAL;
	feature_len = strnlen(feature, MAX_FEATURE_STR_LEN);
	if (feature_len < MIN_FEATURE_STR_LEN ||
	    feature_len >= MAX_FEATURE_STR_LEN)
		return -EINVAL;

	memset(parsed, 0, sizeof(*parsed));
	parsed->direction = AF_IK_DIR_BOTH;
	parsed->pkt_seq = -1;
	parsed->match_kind = AF_IK_MATCH_LEGACY;
	parsed->match_offset = AF_IK_OFFSET_NONE;
	parsed->priority = AF_IK_DEFAULT_PRIORITY;
	if (copy_feature_field(parse_buf, sizeof(parse_buf), feature) < 0)
		return -E2BIG;

	fields[0] = parse_buf;
	for (cursor = parse_buf; *cursor; cursor++) {
		if (*cursor != ';')
			continue;
		if (field_count >= (int)ARRAY_SIZE(fields))
			return -EINVAL;
		*cursor = '\0';
		fields[field_count++] = cursor + 1;
	}
	if (field_count != 6 && field_count != 8 &&
	    field_count != 14 && field_count != 18)
		return -EINVAL;
	if (field_count != 14 && field_count != 18 &&
	    feature_len >= MAX_LEGACY_FEATURE_STR_LEN)
		return -EINVAL;

	if (!strcmp(fields[AF_PROTO_PARAM_INDEX], "tcp"))
		parsed->proto = IPPROTO_TCP;
	else if (!strcmp(fields[AF_PROTO_PARAM_INDEX], "udp"))
		parsed->proto = IPPROTO_UDP;
	else if ((field_count == 14 || field_count == 18) &&
		 !strcmp(fields[AF_PROTO_PARAM_INDEX], "any"))
		parsed->proto = 0;
	else
		return -EINVAL;

	if (copy_feature_field(src_port, sizeof(src_port),
				       fields[AF_SRC_PORT_PARAM_INDEX]) < 0 ||
	    copy_feature_field(dst_port, sizeof(dst_port),
				       fields[AF_DST_PORT_PARAM_INDEX]) < 0 ||
	    copy_feature_field(parsed->host_url, sizeof(parsed->host_url),
				       fields[AF_HOST_URL_PARAM_INDEX]) < 0 ||
	    copy_feature_field(parsed->request_url, sizeof(parsed->request_url),
				       fields[AF_REQUEST_URL_PARAM_INDEX]) < 0 ||
	    copy_feature_field(dict, sizeof(dict),
				       fields[AF_DICT_PARAM_INDEX]) < 0)
		return -E2BIG;

	if (field_count == 8 || field_count == 14 || field_count == 18) {
		if (copy_feature_field(parsed->search_str,
				       sizeof(parsed->search_str),
				       fields[AF_STR_PARAM_INDEX]) < 0)
			return -E2BIG;
		if (*fields[AF_IGNORE_PARAM_INDEX] != '\0' &&
		    kstrtoint(fields[AF_IGNORE_PARAM_INDEX], 10, &ignore) < 0)
			return -EINVAL;
		if (ignore != 0 && ignore != 1)
			return -EINVAL;
		parsed->ignore = ignore;
	}

	if (parse_source_port(src_port, &parsed->src_port) < 0 ||
	    parse_port_info(dst_port, &parsed->dport_info) < 0 ||
	    parse_dict_positions(dict, parsed) < 0)
		return -EINVAL;

	if (field_count != 14 && field_count != 18)
		return 0;

	parsed->feature_version = 4;
	if (kstrtoint(fields[8], 10, &direction) < 0 ||
	    direction < AF_IK_DIR_BOTH || direction > AF_IK_DIR_REPLY)
		return -EINVAL;
	parsed->direction = direction;

	if (parse_packet_sequences(fields[9], field_count == 18,
				   &parsed->pkt_seq,
				   &parsed->pkt_seq_mask) < 0)
		return -ERANGE;

	if (parse_ik_match_kind(fields[10], &parsed->match_kind) < 0)
		return -EINVAL;
	if (*fields[11] != '\0') {
		if (kstrtoint(fields[11], 10, &offset) < 0 ||
		    offset < -MAX_AF_SUPPORT_DATA_LEN ||
		    offset >= MAX_AF_SUPPORT_DATA_LEN)
			return -ERANGE;
		parsed->match_offset = offset;
	}
	ret = parse_hex_pattern(fields[12], parsed->pattern,
				&parsed->pattern_len);
	if (ret < 0)
		return ret;
	if (*fields[13] != '\0') {
		if (kstrtoint(fields[13], 10, &priority) < 0 ||
		    priority < 0 || priority > 255)
			return -ERANGE;
		parsed->priority = priority;
	}
	if (field_count == 18) {
		if (parse_length_info(fields[14],
				      &parsed->payload_len_info) < 0)
			return -EINVAL;
		if (!!*fields[15] != !!*fields[16])
			return -EINVAL;
		if (*fields[15]) {
			if (strlen(fields[15]) != 8 || strlen(fields[16]) != 8 ||
			    kstrtou32(fields[15], 16, &server_addr) < 0 ||
			    kstrtou32(fields[16], 16, &server_mask) < 0 ||
			    !af_ipv4_mask_valid(server_mask) ||
			    (server_addr & server_mask) != server_addr)
				return -EINVAL;
			parsed->server_addr = server_addr;
			parsed->server_mask = server_mask;
		}
		if (kstrtoint(fields[17], 10, &fallback) < 0 ||
		    (fallback != 0 && fallback != 1))
			return -EINVAL;
		parsed->fallback = fallback;
	}

	if (parsed->match_kind == AF_IK_MATCH_PORT) {
		if ((!parsed->src_port && !parsed->dport_info.num &&
		     !parsed->payload_len_info.num && !parsed->server_mask) ||
		    parsed->pattern_len ||
		    parsed->match_offset != AF_IK_OFFSET_NONE ||
		    parsed->host_url[0] || parsed->request_url[0] ||
		    parsed->pos_num || parsed->search_str[0])
			return -EINVAL;
	} else if (parsed->match_kind == AF_IK_MATCH_URL) {
		if (parsed->pattern_len ||
		    parsed->match_offset != AF_IK_OFFSET_NONE ||
		    (!parsed->host_url[0] && !parsed->request_url[0]) ||
		    parsed->pos_num || parsed->search_str[0])
			return -EINVAL;
	} else if (af_ik_kind_has_pattern(parsed->match_kind)) {
		if (!parsed->pattern_len || parsed->host_url[0] ||
		    parsed->request_url[0] || parsed->pos_num ||
		    parsed->search_str[0])
			return -EINVAL;
		if (parsed->match_kind == AF_IK_MATCH_HTTP_MULTI &&
		    parsed->match_offset != AF_IK_OFFSET_NONE)
			return -EINVAL;
	} else {
		return -EINVAL;
	}

	if (parsed->match_kind == AF_IK_MATCH_HTTP_MULTI) {
		ret = parse_http_multi_pattern(parsed);
		if (ret < 0)
			return ret;
	} else if (af_ik_kind_is_regex(parsed->match_kind)) {
		ret = ik_regex_compile(parsed->pattern, parsed->pattern_len,
				       &parsed->native_regex);
		if (ret < 0)
			return ret;
	}
	af_set_parsed_prefilter(parsed);

	return 0;
}

static int __add_app_feature(struct af_feature_db *db, const char *feature,
			     int appid, const char *name,
			     struct parsed_app_feature *parsed)
{
	af_feature_node_t *node = NULL;
	struct list_head *bucket;

	if (!db || !parsed)
		return -EINVAL;

	node = kzalloc(sizeof(af_feature_node_t), GFP_KERNEL);
	if (node == NULL)
		return -ENOMEM;

	if (strscpy(node->app_name, name, sizeof(node->app_name)) < 0 ||
	    strscpy(node->feature, feature, sizeof(node->feature)) < 0 ||
	    strscpy(node->host_url, parsed->host_url,
		    sizeof(node->host_url)) < 0 ||
	    strscpy(node->request_url, parsed->request_url,
		    sizeof(node->request_url)) < 0 ||
	    strscpy(node->search_str, parsed->search_str,
		    sizeof(node->search_str)) < 0) {
		kfree(node);
		return -E2BIG;
	}

	node->app_id = appid;
	node->proto = parsed->proto;
	node->dport_info = parsed->dport_info;
	node->sport = parsed->src_port;
	node->ignore = parsed->ignore;
	node->pos_num = parsed->pos_num;
	node->feature_version = parsed->feature_version;
	node->direction = parsed->direction;
	node->pkt_seq = parsed->pkt_seq;
	node->pkt_seq_mask = parsed->pkt_seq_mask;
	node->match_kind = parsed->match_kind;
	node->match_offset = parsed->match_offset;
	node->priority = parsed->priority;
	node->specificity = af_feature_specificity(parsed);
	node->pattern_len = parsed->pattern_len;
	node->prefilter_valid = parsed->prefilter_valid;
	node->prefilter_byte = parsed->prefilter_byte;
	node->payload_len_info = parsed->payload_len_info;
	node->server_addr = parsed->server_addr;
	node->server_mask = parsed->server_mask;
	node->fallback = parsed->fallback;
	memcpy(node->pattern, parsed->pattern, parsed->pattern_len);
	node->native_regex = parsed->native_regex;
	parsed->native_regex = NULL;
	node->http_clause_count = parsed->http_clause_count;
	memcpy(node->http_clauses, parsed->http_clauses,
	       sizeof(node->http_clauses));
	memset(parsed->http_clauses, 0, sizeof(parsed->http_clauses));
	parsed->http_clause_count = 0;
	memcpy(node->pos_info, parsed->pos_info,
	       sizeof(af_pos_info_t) * parsed->pos_num);
	if (parsed->ignore)
		AF_DEBUG("add feature %s, ignore = %d\n", feature,
			 parsed->ignore);

	bucket = &db->heads[af_feature_proto_bucket(node->proto)]
			   [af_feature_family(node->match_kind)];

	if (db->count >= MAX_FEATURE_NUM_TOTAL) {
		af_feature_node_cleanup(node);
		kfree(node);
		return -E2BIG;
	}
	node->load_order = db->load_order++;
	/* Loading a native IK database used to insertion-sort every new node in
	 * its linked list.  A 14k-rule profile caused tens of millions of pointer
	 * walks in the non-preemptible module-init thread.  Append in O(1) here and
	 * sort each complete bucket once before it becomes visible to readers. */
	list_add_tail(&node->head, bucket);
	db->count++;
	return 0;
}

static int af_feature_node_compare(void *priv, const struct list_head *a,
				   const struct list_head *b)
{
	const af_feature_node_t *left =
		list_entry(a, af_feature_node_t, head);
	const af_feature_node_t *right =
		list_entry(b, af_feature_node_t, head);

	/* Every bucket must use the exact same total order as the k-way merge in
	 * match_feature().  Sorting v4 buckets by source priority here while the
	 * merge compared specificity first left a high-priority generic domain or
	 * port at the head of one bucket, hiding a more specific application rule
	 * behind it. */
	if (af_feature_precedes(left, right))
		return -1;
	if (af_feature_precedes(right, left))
		return 1;
	return 0;
}

static void af_feature_db_sort(struct af_feature_db *db)
{
	int proto;
	int family;

	if (!db)
		return;
	for (proto = 0; proto < AF_FEATURE_PROTO_BUCKETS; proto++) {
		for (family = 0; family < AF_FEATURE_FAMILY_COUNT; family++) {
			list_sort(NULL, &db->heads[proto][family],
				  af_feature_node_compare);
			/* This function is used during module init and netlink reload in
			 * process context.  PREEMPT_NONE must get an explicit scheduling
			 * point while a large native database is prepared. */
			cond_resched();
		}
	}
}

static int af_match_port(port_info_t *info, int port)
{
	int i;
	int with_not = 0;
	if (info->num == 0)
		return 1;
	for (i = 0; i < info->num; i++)
	{
		if (info->range_list[i].not )
		{
			with_not = 1;
			break;
		}
	}
	for (i = 0; i < info->num; i++)
	{
		if (with_not)
		{
			if (info->range_list[i].not &&port >= info->range_list[i].start && port <= info->range_list[i].end)
			{
				return 0;
			}
		}
		else
		{
			if (port >= info->range_list[i].start && port <= info->range_list[i].end)
			{
				return 1;
			}
		}
	}
	if (with_not)
		return 1;
	else
		return 0;
}
//[tcp;;443;baidu.com;;]
static int add_app_feature(struct af_feature_db *db, int appid,
			   const char *name, const char *feature)
{
	struct parsed_app_feature parsed;
	int ret;

	if (!db || !name || !feature || !af_appid_valid(appid)) {
		AF_ERROR("error, name or feature is null\n");
		return -EINVAL;
	}
	if (strnlen(name, MAX_APP_NAME_LEN) == 0 ||
	    strnlen(name, MAX_APP_NAME_LEN) >= MAX_APP_NAME_LEN)
		return -E2BIG;
	ret = parse_app_feature(feature, &parsed);
	if (ret < 0)
		return ret;

	ret = __add_app_feature(db, feature, appid, name, &parsed);
	af_parsed_feature_cleanup(&parsed);
	return ret;
}

static int process_feature_list(const char *feature_begin,
				const char *feature_end, int app_id,
				const char *app_name, int add,
				struct af_feature_db *db)
{
	const char *cursor = feature_begin;
	const char *separator;
	const char *segment_end;
	char feature[MAX_FEATURE_STR_LEN];
	struct parsed_app_feature parsed;
	size_t segment_len;
	int feature_count = 0;
	int ret;

	if (!feature_begin || !feature_end || feature_begin >= feature_end)
		return -EINVAL;

	while (cursor < feature_end) {
		separator = memchr(cursor, ',', feature_end - cursor);
		segment_end = separator ? separator : feature_end;
		segment_len = segment_end - cursor;
		if (segment_len == 0 || segment_len >= sizeof(feature) ||
		    feature_count >= MAX_FEATURE_NUM_PER_APP)
			return -EINVAL;

		memcpy(feature, cursor, segment_len);
		feature[segment_len] = '\0';
		if (add)
			ret = add_app_feature(db, app_id, app_name, feature);
		else {
			ret = parse_app_feature(feature, &parsed);
			if (ret >= 0)
				af_parsed_feature_cleanup(&parsed);
		}
		if (ret < 0)
			return ret;
		feature_count++;

		if (!separator)
			break;
		cursor = separator + 1;
		if (cursor == feature_end)
			return -EINVAL;
	}

	return feature_count > 0 ? 0 : -EINVAL;
}

static int af_init_feature(char *feature_str, struct af_feature_db *db)
{
	char app_id_buf[12];
	char app_name[MAX_APP_NAME_LEN];
	char *cursor;
	char *id_end;
	char *name_begin;
	char *name_end;
	char *feature_sep;
	char *feature_end;
	char *tail;
	size_t line_len;
	size_t id_len;
	size_t name_len;
	int app_id;
	int ret;

	if (!feature_str || !db)
		return -EINVAL;
	line_len = strnlen(feature_str, MAX_FEATURE_LINE_LEN);
	if (line_len < MIN_FEATURE_LINE_LEN || line_len >= MAX_FEATURE_LINE_LEN)
		return -EINVAL;

	cursor = feature_str;
	while (*cursor && isspace((unsigned char)*cursor))
		cursor++;
	if (*cursor == '\0' || *cursor == '#' || strchr(cursor, '#'))
		return -EINVAL;

	feature_sep = strstr(cursor, ":[");
	if (!feature_sep)
		return -EINVAL;
	feature_end = strrchr(feature_sep + 2, ']');
	if (!feature_end || feature_end <= feature_sep + 2)
		return -EINVAL;
	for (tail = feature_end + 1; *tail; tail++) {
		if (!isspace((unsigned char)*tail))
			return -EINVAL;
	}

	id_end = cursor;
	while (*id_end && isdigit((unsigned char)*id_end))
		id_end++;
	id_len = id_end - cursor;
	if (id_len == 0 || id_len >= sizeof(app_id_buf) ||
	    !isspace((unsigned char)*id_end))
		return -EINVAL;
	memcpy(app_id_buf, cursor, id_len);
	app_id_buf[id_len] = '\0';
	if (kstrtoint(app_id_buf, 10, &app_id) < 0 ||
	    !af_appid_valid(app_id))
		return -EINVAL;

	name_begin = id_end;
	while (name_begin < feature_sep &&
	       isspace((unsigned char)*name_begin))
		name_begin++;
	name_end = feature_sep;
	while (name_end > name_begin &&
	       isspace((unsigned char)name_end[-1]))
		name_end--;
	name_len = name_end - name_begin;
	if (name_len == 0 || name_len >= sizeof(app_name))
		return -EINVAL;
	memcpy(app_name, name_begin, name_len);
	app_name[name_len] = '\0';

	/* Native imports intentionally emit one feature per repeated APP line. */
	if (!memchr(feature_sep + 2, ',', feature_end - (feature_sep + 2))) {
		*feature_end = '\0';
		ret = add_app_feature(db, app_id, app_name, feature_sep + 2);
		*feature_end = ']';
		return ret;
	}

	/* Validate the complete line before publishing any feature nodes. */
	if (process_feature_list(feature_sep + 2, feature_end, app_id,
				 app_name, 0, db) < 0)
		return -EINVAL;
	return process_feature_list(feature_sep + 2, feature_end, app_id,
				    app_name, 1, db);
}

static void load_feature_buf_from_file(char **config_buf)
{
	struct inode *inode = NULL;
	struct file *fp = NULL;
#if LINUX_VERSION_CODE <= KERNEL_VERSION(5, 7, 19)
	mm_segment_t fs;
#endif
	off_t size;
	fp = filp_open(AF_FEATURE_CONFIG_FILE, O_RDONLY, 0);


	if (IS_ERR(fp))
	{
		return;
	}

	inode = fp->f_inode;
	size = inode->i_size;
	if (size == 0)
	{
		filp_close(fp, NULL);
		return;
	}
	/* The parser walks until a NUL byte. The old exact-size allocation read
	 * beyond EOF and could leave the feature list empty depending on adjacent
	 * slab contents. */
	*config_buf = (char *)kzalloc(sizeof(char) * (size + 1), GFP_KERNEL);
	if (NULL == *config_buf)
	{
		AF_ERROR("alloc buf fail\n");
		filp_close(fp, NULL);
		return;
	}

#if LINUX_VERSION_CODE <= KERNEL_VERSION(5, 7, 19)
	fs = get_fs();
	set_fs(KERNEL_DS);
#endif
// 4.14rc3 vfs_read-->kernel_read
#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 14, 0)
	kernel_read(fp, *config_buf, size, &(fp->f_pos));
#else
	vfs_read(fp, *config_buf, size, &(fp->f_pos));
#endif

#if LINUX_VERSION_CODE <= KERNEL_VERSION(5, 7, 19)
	set_fs(fs);
#endif
	filp_close(fp, NULL);
}

static __maybe_unused int load_feature_config(void)
{
	char *feature_buf = NULL;
	char *p;
	char *begin;
	char line[MAX_FEATURE_LINE_LEN] = {0};
	u32 parsed_lines = 0;

	load_feature_buf_from_file(&feature_buf);
	if (!feature_buf)
	{
		return -1;
	}
	p = begin = feature_buf;
	while (*p++)
	{
		if (*p == '\n')
		{
			if (p - begin < MIN_FEATURE_LINE_LEN || p - begin > MAX_FEATURE_LINE_LEN)
			{
				begin = p + 1;
				continue;
			}
			memset(line, 0x0, sizeof(line));
			strncpy(line, begin, p - begin);
			af_init_feature(line, af_feature_active);
			if (!(++parsed_lines & 0x1f))
				cond_resched();
			begin = p + 1;
		}
	}

	if (p != begin)
	{
		if (p - begin >= MIN_FEATURE_LINE_LEN && p - begin <= MAX_FEATURE_LINE_LEN) {
			memset(line, 0x0, sizeof(line));
			strncpy(line, begin, p - begin);
			af_init_feature(line, af_feature_active);
		}
	}
	af_feature_db_sort(af_feature_active);
	if (feature_buf)
		kfree(feature_buf);
	g_feature_init = af_feature_active->count;
	return 0;
}


static void af_feature_db_init(struct af_feature_db *db)
{
	int proto;
	int family;

	for (proto = 0; proto < AF_FEATURE_PROTO_BUCKETS; proto++)
		for (family = 0; family < AF_FEATURE_FAMILY_COUNT; family++)
			INIT_LIST_HEAD(&db->heads[proto][family]);
	db->count = 0;
	db->load_order = 0;
}

static struct af_feature_db *af_feature_db_alloc(gfp_t flags)
{
	struct af_feature_db *db;

	db = kzalloc(sizeof(*db), flags);
	if (db)
		af_feature_db_init(db);
	return db;
}

static void af_feature_db_clear(struct af_feature_db *db)
{
	af_feature_node_t *node;
	struct list_head *bucket;
	int proto;
	int family;

	if (!db)
		return;
	for (proto = 0; proto < AF_FEATURE_PROTO_BUCKETS; proto++) {
		for (family = 0; family < AF_FEATURE_FAMILY_COUNT; family++) {
			bucket = &db->heads[proto][family];
			while (!list_empty(bucket)) {
				node = list_first_entry(bucket, af_feature_node_t,
						head);
				list_del(&node->head);
				af_feature_node_cleanup(node);
				kfree(node);
			}
		}
	}
	db->count = 0;
	db->load_order = 0;
}

static void af_feature_db_free(struct af_feature_db *db)
{
	if (!db)
		return;
	af_feature_db_clear(db);
	if (db != &af_feature_boot_db)
		kfree(db);
}

static void af_clean_feature_list(void)
{
	struct af_feature_db *active;
	struct af_feature_db *staging;

	mutex_lock(&af_feature_reload_lock);
	staging = af_feature_staging;
	af_feature_staging = NULL;
	af_feature_reload_failed = true;
	feature_list_write_lock();
	active = af_feature_active;
	if (active != &af_feature_boot_db)
		af_feature_active = &af_feature_boot_db;
	else
		af_feature_db_clear(active);
	g_feature_init = 0;
	feature_list_write_unlock();
	mutex_unlock(&af_feature_reload_lock);

	if (active != &af_feature_boot_db)
		af_feature_db_free(active);
	af_feature_db_free(staging);
}

static int af_begin_feature_reload(void)
{
	struct af_feature_db *new_db;
	struct af_feature_db *old_db;

	new_db = af_feature_db_alloc(GFP_KERNEL);
	mutex_lock(&af_feature_reload_lock);
	WRITE_ONCE(g_feature_reload_attempt,
		   READ_ONCE(g_feature_reload_attempt) + 1);
	WRITE_ONCE(g_feature_reload_loaded, 0);
	WRITE_ONCE(g_feature_reload_errno, new_db ? 0 : ENOMEM);
	old_db = af_feature_staging;
	af_feature_staging = new_db;
	af_feature_reload_failed = !new_db;
	mutex_unlock(&af_feature_reload_lock);

	/* A repeated BEGIN abandons only the previous staging database. */
	af_feature_db_free(old_db);
	return new_db ? 0 : -ENOMEM;
}

static int af_commit_feature_reload(u32 expected_count, u32 *actual_count)
{
	struct af_feature_db *new_db;
	struct af_feature_db *old_db = NULL;
	int ret = -EINVAL;

	mutex_lock(&af_feature_reload_lock);
	new_db = af_feature_staging;
	if (actual_count)
		*actual_count = new_db ? new_db->count : 0;
	if (!new_db || af_feature_reload_failed || !expected_count ||
	    expected_count > MAX_FEATURE_NUM_TOTAL ||
	    new_db->count != expected_count) {
		af_feature_reload_failed = true;
		WRITE_ONCE(g_feature_reload_loaded, new_db ? new_db->count : 0);
		if (!READ_ONCE(g_feature_reload_errno))
			WRITE_ONCE(g_feature_reload_errno, EINVAL);
		goto out_unlock;
	}
	af_feature_db_sort(new_db);

	/* Readers see either complete database. The writer waits for every old
	 * reader before the O(1) pointer swap; old nodes are freed afterwards. */
	feature_list_write_lock();
	old_db = af_feature_active;
	af_feature_active = new_db;
	af_feature_staging = NULL;
	g_feature_init = new_db->count;
	WRITE_ONCE(g_feature_reload_loaded, new_db->count);
	WRITE_ONCE(g_feature_reload_errno, 0);
	g_feature_generation++;
	if (!(g_feature_generation & 0x1fffU))
		g_feature_generation++;
	feature_list_write_unlock();
	af_feature_reload_failed = false;
	ret = 0;

out_unlock:
	mutex_unlock(&af_feature_reload_lock);
	if (!ret)
		af_feature_db_free(old_db);
	return ret;
}

static void af_fail_feature_reload(int error)
{
	mutex_lock(&af_feature_reload_lock);
	af_feature_reload_failed = true;
	if (error < 0)
		error = -error;
	if (!error)
		error = EINVAL;
	if (!READ_ONCE(g_feature_reload_errno))
		WRITE_ONCE(g_feature_reload_errno, error);
	mutex_unlock(&af_feature_reload_lock);
}

static int af_add_feature_msg_handle(char *data, int len)
{
	char feature[MAX_FEATURE_LINE_LEN] = {0};
	int ret;

	if (!data || len <= 1 || len >= MAX_FEATURE_LINE_LEN ||
	    data[len - 1] != '\0' ||
	    strnlen(data, len) != len - 1) {
		printk("warn, feature data len = %d\n", len);
		af_fail_feature_reload(EINVAL);
		return -EINVAL;
	}
	memcpy(feature, data, len);
	mutex_lock(&af_feature_reload_lock);
	if (!af_feature_staging || af_feature_reload_failed) {
		ret = -EINVAL;
		goto out_unlock;
	}
	AF_DEBUG("stage feature %s\n", feature);
	ret = af_init_feature(feature, af_feature_staging);
	if (ret < 0) {
		af_feature_reload_failed = true;
		if (!READ_ONCE(g_feature_reload_errno))
			WRITE_ONCE(g_feature_reload_errno, -ret);
	} else {
		WRITE_ONCE(g_feature_reload_loaded,
			   af_feature_staging->count);
	}

out_unlock:
	mutex_unlock(&af_feature_reload_lock);
	if (ret < 0)
		AF_ERROR("reject invalid feature definition\n");
	return ret;
}
// free by caller
static unsigned char *read_skb(struct sk_buff *skb, unsigned int from, unsigned int len)
{
	unsigned char *msg_buf;

	/*
	 * skb_seq_read() returns the complete current fragment and does not
	 * clamp it to the sequence upper bound.  Copying that value into a
	 * len-sized buffer therefore overruns whenever a GRO/non-linear skb's
	 * first fragment is larger than the requested L4 payload.  Let the skb
	 * core copy exactly len bytes across the linear area and fragments.
	 */
	if (!skb || !len || from > skb->len || len > skb->len - from)
		return NULL;

	msg_buf = kmalloc(len, GFP_ATOMIC);
	if (!msg_buf)
		return NULL;

	if (skb_copy_bits(skb, from, msg_buf, len)) {
		kfree(msg_buf);
		return NULL;
	}

	return msg_buf;
}

static int parse_flow_proto(struct sk_buff *skb, flow_info_t *flow)
{
	unsigned int network_offset;
	unsigned int transport_offset;
	unsigned int transport_header_len;
	int packet_len;
	int ipp_len;
	struct tcphdr *tcph = NULL;
	struct udphdr *udph = NULL;
	struct iphdr *iph = NULL;
	struct ipv6hdr *ip6h = NULL;
	if (!skb || !flow)
		return -1;
	network_offset = skb_network_offset(skb);
	if (network_offset >= skb->len)
		return -1;
	switch (skb->protocol)
	{
	case htons(ETH_P_IP):
		if (!pskb_may_pull(skb, network_offset + sizeof(*iph)))
			return -1;
		iph = ip_hdr(skb);
		if (!iph || iph->ihl < 5 || ntohs(iph->tot_len) < iph->ihl * 4)
			return -1;
		packet_len = ntohs(iph->tot_len);
		if (packet_len > skb->len - network_offset ||
		    (ntohs(iph->frag_off) & IP_OFFSET))
			return -1;
		transport_offset = network_offset + iph->ihl * 4;
		if (transport_offset > network_offset + packet_len)
			return -1;
		flow->src = iph->saddr;
		flow->dst = iph->daddr;
		flow->l4_protocol = iph->protocol;
		ipp_len = network_offset + packet_len - transport_offset;
		break;
	case htons(ETH_P_IPV6):
		if (!pskb_may_pull(skb, network_offset + sizeof(*ip6h)))
			return -1;
		ip6h = ipv6_hdr(skb);
		if (!ip6h)
			return -1;
		packet_len = sizeof(*ip6h) + ntohs(ip6h->payload_len);
		if (packet_len > skb->len - network_offset)
			return -1;
		transport_offset = network_offset + sizeof(*ip6h);
		flow->l4_protocol = ip6h->nexthdr;
		ipp_len = ntohs(ip6h->payload_len);
		break;
	default:
		return -1;
	}

	switch (flow->l4_protocol)
	{
	case IPPROTO_TCP:
		if (ipp_len < sizeof(struct tcphdr))
			return -1;
		if (!pskb_may_pull(skb, transport_offset + sizeof(*tcph)))
			return -1;
		tcph = (struct tcphdr *)(skb->data + transport_offset);
		if (tcph->doff < 5 || tcph->doff * 4 > ipp_len)
			return -1;
		transport_header_len = tcph->doff * 4;
		if (!pskb_may_pull(skb, transport_offset + transport_header_len))
			return -1;
		tcph = (struct tcphdr *)(skb->data + transport_offset);
		flow->l4_len = ipp_len - transport_header_len;
		flow->total_len = min_t(int, flow->l4_len, 65535);
		flow->l4_data = skb->data + transport_offset + transport_header_len;
		flow->dport = ntohs(tcph->dest);
		flow->sport = ntohs(tcph->source);
		if (skb->protocol == htons(ETH_P_IPV6)) {
			ip6h = ipv6_hdr(skb);
			flow->src6 = &ip6h->saddr;
			flow->dst6 = &ip6h->daddr;
		}
		return 0;
	case IPPROTO_UDP:
		if (ipp_len < sizeof(struct udphdr))
			return -1;
		if (!pskb_may_pull(skb, transport_offset + sizeof(*udph)))
			return -1;
		udph = (struct udphdr *)(skb->data + transport_offset);
		if (ntohs(udph->len) < sizeof(struct udphdr) ||
		    ntohs(udph->len) > ipp_len)
			return -1;
		flow->l4_len = ntohs(udph->len) - sizeof(struct udphdr);
		flow->total_len = min_t(int, flow->l4_len, 65535);
		flow->l4_data = skb->data + transport_offset + sizeof(*udph);
		flow->dport = ntohs(udph->dest);
		flow->sport = ntohs(udph->source);
		if (skb->protocol == htons(ETH_P_IPV6)) {
			ip6h = ipv6_hdr(skb);
			flow->src6 = &ip6h->saddr;
			flow->dst6 = &ip6h->daddr;
		}
		return 0;
	case IPPROTO_ICMP:
		break;
	default:
		return -1;
	}
	return -1;
}

static int check_domain(const u8 *h, int len)
{
	int i;
	for (i = 0; i < len; i++)
	{
		if ((h[i] >= 'a' && h[i] <= 'z') || (h[i] >= 'A' && h[i] <= 'Z') ||
			(h[i] >= '0' && h[i] <= '9') || h[i] == '.' || h[i] == '-' ||  h[i] == ':')
		{
			continue;
		}
		else
			return 0;
	}
	return 1;
}

static void af_sni_recent_add(const flow_info_t *flow, enum af_sni_result result,
			      const u8 *sni, u16 sni_len,
			      u16 prefix_len, u16 record_len)
{
	struct af_sni_recent *recent;
	u16 copy_len;

	if (!flow)
		return;
	spin_lock_bh(&af_sni_recent_lock);
	recent = &af_sni_recent[af_sni_recent_head++ % AF_SNI_RECENT_MAX];
	memset(recent, 0, sizeof(*recent));
	recent->src = flow->src;
	recent->dst = flow->dst;
	if (flow->src6 && flow->dst6) {
		recent->family = NFPROTO_IPV6;
		recent->src6 = *flow->src6;
		recent->dst6 = *flow->dst6;
	} else {
		recent->family = NFPROTO_IPV4;
	}
	recent->sport = flow->sport;
	recent->dport = flow->dport;
	recent->proto = flow->l4_protocol;
	recent->prefix_len = prefix_len;
	recent->record_len = record_len;
	recent->result = result;
	copy_len = min_t(u16, sni_len, sizeof(recent->sni) - 1);
	if (sni && copy_len)
		memcpy(recent->sni, sni, copy_len);
	recent->sni[copy_len] = '\0';
	recent->when = jiffies;
	spin_unlock_bh(&af_sni_recent_lock);
}

static int dpi_https_proto(flow_info_t *flow)
{
	int i;
	int end;
	int pos;
	int ext_end;
	int name_end;
	u16 value_len;
	u16 url_len;
	u16 ext_type;
	u16 ext_len;
	u16 record_len = 0;
	u32 hello_len;
	u8 *p;
	const u8 *sni = NULL;
	u16 sni_len = 0;
	int data_len;
	bool complete_hello = false;
	bool ech_seen = false;

	if (NULL == flow)
	{
		AF_ERROR("flow is NULL\n");
		return -1;
	}
	p = flow->l4_data;
	data_len = flow->l4_len;
	if (NULL == p || data_len < 16)
	{
		return -1;
	}
	if (!((p[0] == 0x16 && p[1] == 0x03) || flow->client_hello))
		return -1;

	/* Parse a complete TLS ClientHello first. */
	if (data_len >= 9 && p[0] == 0x16 && p[1] == 0x03 && p[5] == 0x01) {
		record_len = ((u16)p[3] << 8) | p[4];
		end = min_t(int, data_len, 5 + record_len);
		hello_len = ((u32)p[6] << 16) | ((u32)p[7] << 8) | p[8];
		complete_hello = data_len >= 5 + record_len &&
				  9 + hello_len <= 5 + record_len;
		end = min_t(int, end, 9 + hello_len);
		pos = 9;
		if (pos + 34 <= end) {
			pos += 34; /* legacy_version + random */
			if (pos + 1 <= end) {
				value_len = p[pos++];
				if (pos + value_len <= end)
					pos += value_len;
				else
					pos = end;
			}
			if (pos + 2 <= end) {
				value_len = ((u16)p[pos] << 8) | p[pos + 1];
				pos += 2;
				if (pos + value_len <= end)
					pos += value_len;
				else
					pos = end;
			}
			if (pos + 1 <= end) {
				value_len = p[pos++];
				if (pos + value_len <= end)
					pos += value_len;
				else
					pos = end;
			}
			if (pos + 2 <= end) {
				value_len = ((u16)p[pos] << 8) | p[pos + 1];
				pos += 2;
				ext_end = min_t(int, end, pos + value_len);
				while (pos + 4 <= ext_end) {
					ext_type = ((u16)p[pos] << 8) | p[pos + 1];
					ext_len = ((u16)p[pos + 2] << 8) | p[pos + 3];
					pos += 4;
					if (pos + ext_len > ext_end)
						break;
					if (ext_type == AF_TLS_ECH_EXTENSION)
						ech_seen = true;
					if (ext_type == 0 && ext_len >= 5) {
						name_end = pos + ext_len;
						i = pos + 2; /* server_name_list length */
						while (i + 3 <= name_end) {
							url_len = ((u16)p[i + 1] << 8) |
								  p[i + 2];
							i += 3;
							if (i + url_len > name_end)
								break;
							if (p[i - 3] == 0 &&
							    url_len > MIN_HOST_LEN &&
							    url_len <= MAX_HOST_LEN &&
							    check_domain(p + i, url_len)) {
								sni = p + i;
								sni_len = url_len;
								break;
							}
							i += url_len;
						}
					}
					pos += ext_len;
				}
			}
		}
		if (complete_hello)
			atomic64_inc(&af_http_stats.tls_client_hello);
		if (ech_seen)
			atomic64_inc(&af_http_stats.tls_ech_seen);
		if (sni) {
			flow->https.match = AF_TRUE;
			flow->https.url_pos = (char *)sni;
			flow->https.url_len = sni_len;
			flow->client_hello = 0;
			atomic64_inc(&af_http_stats.tls_sni_ok);
			af_sni_recent_add(flow, ech_seen ? AF_SNI_ECH : AF_SNI_OK,
					  sni, sni_len, data_len, record_len);
			return 0;
		}
	}

	/* Bounded fallback for a split/non-standard ClientHello. */
	for (i = 0; i + HTTPS_URL_OFFSET <= data_len; i++)
	{
		if (p[i] == 0x0 && p[i + 1] == 0x0 && p[i + 2] == 0x0 && p[i + 3] != 0x0)
		{
			url_len = ((u16)p[i + HTTPS_LEN_OFFSET] << 8) |
				  p[i + HTTPS_LEN_OFFSET + 1];

			if (url_len <= MIN_HOST_LEN || url_len > MAX_HOST_LEN)
			{
				continue;
			}

			if (i + HTTPS_URL_OFFSET + url_len <= data_len)
			{
				if (!check_domain(p + i + HTTPS_URL_OFFSET, url_len)){
					AF_INFO("invalid url, len = %d\n", url_len);
					continue;
				}
				flow->https.match = AF_TRUE;
				flow->https.url_pos = p + i + HTTPS_URL_OFFSET;
				flow->https.url_len = url_len;
				flow->client_hello = 0;
				atomic64_inc(&af_http_stats.tls_sni_ok);
				af_sni_recent_add(flow, AF_SNI_OK,
						  p + i + HTTPS_URL_OFFSET, url_len,
						  data_len, record_len);
				return 0;
			}
		}
	}
	if (complete_hello) {
		atomic64_inc(&af_http_stats.tls_sni_missing);
		af_sni_recent_add(flow, ech_seen ? AF_SNI_ECH : AF_SNI_MISSING,
				  NULL, 0, data_len, record_len);
	}
	if (p[0] == 0x16 && p[1] == 0x03)
		flow->client_hello = 1;
	return -1;
}

static int af_http_header_field(const char *name, int len)
{
	static const struct {
		const char *name;
		u8 len;
		u8 field;
	} headers[] = {
		{ "Host", 4, 1 },
		{ "User-Agent", 10, 2 },
		{ "Referer", 7, 3 },
		{ "Cache-Control", 13, 5 },
		{ "Cookie", 6, 7 },
		{ "Pragma", 6, 9 },
		{ "Content-Type", 12, 12 },
		{ "Range", 5, 13 },
		{ "Connection", 10, 15 },
	};
	int i;

	if (!name || len <= 0)
		return -EINVAL;
	for (i = 0; i < ARRAY_SIZE(headers); i++)
		if (len == headers[i].len &&
		    !strncasecmp(name, headers[i].name, len))
			return headers[i].field;
	return -ENOENT;
}

static bool af_http_method_prefix(const u8 *p, int len)
{
	static const char * const methods[] = {
		"GET ", "POST ", "HEAD ", "PUT ", "DELETE ",
		"OPTIONS ", "PATCH ", "CONNECT "
	};
	int i;

	if (!p || len < 4)
		return false;
	for (i = 0; i < ARRAY_SIZE(methods); i++) {
		int n = strlen(methods[i]);
		if (len >= n && !memcmp(p, methods[i], n))
			return true;
	}
	return false;
}

static bool af_tls_client_hello_prefix(const u8 *p, int len)
{
	return p && len >= 5 && p[0] == 0x16 && p[1] == 0x03 &&
	       p[2] <= 0x04 && (len == 5 || p[5] == 0x01);
}

static u8 af_prefix_start_kind(const u8 *p, int len)
{
	if (af_http_method_prefix(p, len))
		return AF_PREFIX_HTTP;
	if (af_tls_client_hello_prefix(p, len))
		return AF_PREFIX_TLS;
	return AF_PREFIX_NONE;
}

static unsigned int af_http_prefix_index(struct nf_conn *ct)
{
	return hash_ptr(ct, ilog2(AF_HTTP_PREFIX_SLOTS));
}

static bool af_http_prefix_pending(struct nf_conn *ct)
{
	struct af_http_prefix_slot *slot;
	bool found;

	spin_lock_bh(&af_http_prefix_lock);
	slot = &af_http_prefix[af_http_prefix_index(ct)];
	found = slot->ct == ct && !slot->complete &&
		time_before(jiffies, slot->updated + AF_HTTP_PREFIX_TIMEOUT);
	spin_unlock_bh(&af_http_prefix_lock);
	return found;
}

static void af_http_prefix_forget(struct nf_conn *ct)
{
	struct af_http_prefix_slot *slot;

	spin_lock_bh(&af_http_prefix_lock);
	slot = &af_http_prefix[af_http_prefix_index(ct)];
	if (slot->ct == ct)
		memset(slot, 0, sizeof(*slot));
	spin_unlock_bh(&af_http_prefix_lock);
}

/* Reassemble only the bounded HTTP request prefix.  This is not a TCP stream
 * engine: it accepts contiguous original-direction segments, trims a simple
 * retransmission overlap and abandons gaps/collisions.  The snapshot returned
 * to the matcher is private, so no softirq holds the table lock while running
 * thousands of IK candidates. */
static u8 *af_http_prefix_snapshot(struct sk_buff *skb, struct nf_conn *ct,
					 flow_info_t *flow, int *snapshot_len)
{
	struct af_http_prefix_slot *slot;
	const struct tcphdr *th;
	u32 seq, skip = 0;
	u32 limit;
	u32 tls_record_len;
	u8 *copy = NULL;
	u8 start_kind;
	bool starts;

	*snapshot_len = 0;
	if (!skb || !ct || !flow || flow->dir != AF_IK_DIR_ORIGINAL ||
	    flow->l4_protocol != IPPROTO_TCP || flow->l4_len <= 0)
		return NULL;
	start_kind = af_prefix_start_kind(flow->l4_data, flow->l4_len);
	starts = start_kind != AF_PREFIX_NONE;
	if (!starts && !af_http_prefix_pending(ct))
		return NULL;
	th = tcp_hdr(skb);
	seq = ntohl(th->seq);

	spin_lock_bh(&af_http_prefix_lock);
	slot = &af_http_prefix[af_http_prefix_index(ct)];
	if (slot->ct == ct && starts && slot->complete &&
	    (!slot->seq_valid || !before(seq, slot->next_seq))) {
		/* A keep-alive connection can carry many independent requests.  The
		 * old code retained the first complete request forever and appended
		 * later GETs to it, so dpi_http_proto() kept parsing the stale Host/URI
		 * on every generic re-entry.  Start a fresh bounded prefix only after
		 * the previous request's sequence range; an overlapping retransmission
		 * still follows the normal trim path below. */
		memset(slot, 0, sizeof(*slot));
		slot->ct = ct;
		slot->kind = start_kind;
		if (start_kind == AF_PREFIX_HTTP)
			atomic64_inc(&af_http_stats.prefix_restarted);
		else
			atomic64_inc(&af_http_stats.tls_prefix_alloc);
	}
	if (slot->ct != ct) {
		if (!starts || (slot->ct &&
		    time_before(jiffies, slot->updated + AF_HTTP_PREFIX_TIMEOUT))) {
			if (start_kind == AF_PREFIX_TLS)
				atomic64_inc(&af_http_stats.tls_prefix_budget_expired);
			else
				atomic64_inc(&af_http_stats.prefix_budget_expired);
			goto out;
		}
		memset(slot, 0, sizeof(*slot));
		slot->ct = ct;
		slot->kind = start_kind;
		if (start_kind == AF_PREFIX_TLS)
			atomic64_inc(&af_http_stats.tls_prefix_alloc);
		else
			atomic64_inc(&af_http_stats.prefix_alloc);
	}
	if (slot->kind == AF_PREFIX_NONE)
		slot->kind = start_kind;
	if (slot->seq_valid) {
		if (before(seq, slot->next_seq))
			skip = min_t(u32, slot->next_seq - seq, flow->l4_len);
		else if (seq != slot->next_seq) {
			if (slot->kind == AF_PREFIX_TLS)
				atomic64_inc(&af_http_stats.tls_prefix_budget_expired);
			else
				atomic64_inc(&af_http_stats.prefix_budget_expired);
			memset(slot, 0, sizeof(*slot));
			goto out;
		}
	}
	limit = slot->kind == AF_PREFIX_TLS ? AF_TLS_PREFIX_MAX :
		MAX_AF_SUPPORT_DATA_LEN;
	if (flow->l4_len - skip > limit - slot->len) {
		if (slot->kind == AF_PREFIX_TLS)
			atomic64_inc(&af_http_stats.tls_prefix_budget_expired);
		else
			atomic64_inc(&af_http_stats.prefix_budget_expired);
		memset(slot, 0, sizeof(*slot));
		goto out;
	}
	memcpy(slot->data + slot->len, flow->l4_data + skip,
	       flow->l4_len - skip);
	slot->len += flow->l4_len - skip;
	slot->next_seq = seq + flow->l4_len;
	slot->seq_valid = true;
	slot->updated = jiffies;
	copy = kmemdup(slot->data, slot->len, GFP_ATOMIC);
	if (!copy) {
		if (slot->kind == AF_PREFIX_TLS)
			atomic64_inc(&af_http_stats.tls_prefix_oom);
		else
			atomic64_inc(&af_http_stats.prefix_oom);
		goto out;
	}
	*snapshot_len = slot->len;
	if (!slot->complete && slot->kind == AF_PREFIX_HTTP &&
	    strnstr(copy, "\r\n\r\n", slot->len)) {
		slot->complete = true;
		atomic64_inc(&af_http_stats.prefix_complete);
	} else if (!slot->complete && slot->kind == AF_PREFIX_TLS &&
		   slot->len >= 5) {
		tls_record_len = 5 + (((u16)slot->data[3] << 8) |
				      slot->data[4]);
		if (tls_record_len > AF_TLS_PREFIX_MAX || tls_record_len < 9) {
			atomic64_inc(&af_http_stats.tls_prefix_budget_expired);
			memset(slot, 0, sizeof(*slot));
		} else if (slot->len >= tls_record_len) {
			slot->complete = true;
			atomic64_inc(&af_http_stats.tls_prefix_complete);
		}
	}
out:
	spin_unlock_bh(&af_http_prefix_lock);
	return copy;
}

static void dpi_http_proto(flow_info_t *flow)
{
	static const struct {
		const char *name;
		u8 len;
		u8 method;
	} methods[] = {
		{ "GET", 3, HTTP_METHOD_GET },
		{ "POST", 4, HTTP_METHOD_POST },
		{ "HEAD", 4, 0 },
		{ "PUT", 3, 0 },
		{ "DELETE", 6, 0 },
		{ "OPTIONS", 7, 0 },
		{ "PATCH", 5, 0 },
		{ "CONNECT", 7, 0 },
	};
	char *data;
	int data_len;
	int start = 0;
	int end;
	int line_len;
	int method_len = 0;
	int target_start;
	int target_end;
	int value_start;
	int value_end;
	int colon;
	int field;
	int i;
	if (!flow)
	{
		AF_ERROR("flow is null\n");
		return;
	}
	if (flow->l4_protocol != IPPROTO_TCP)
	{
		return;
	}

	data = flow->l4_data;
	data_len = flow->l4_len;
	if (data_len < MIN_HTTP_DATA_LEN)
	{
		return;
	}

	while (start < data_len) {
		for (end = start; end + 1 < data_len; end++)
			if (data[end] == '\r' && data[end + 1] == '\n')
				break;
		if (end + 1 >= data_len)
			break;
		line_len = end - start;

		if (start == 0) {
			for (i = 0; i < ARRAY_SIZE(methods); i++) {
				if (line_len > methods[i].len &&
				    data[methods[i].len] == ' ' &&
				    !memcmp(data, methods[i].name, methods[i].len)) {
					method_len = methods[i].len;
					flow->http.method = methods[i].method;
					break;
				}
			}
			if (method_len) {
				target_start = method_len + 1;
				target_end = target_start;
				while (target_end < end && data[target_end] != ' ')
					target_end++;
				if (target_end > target_start) {
					flow->http.match = AF_TRUE;
					flow->http.url_pos = data + target_start;
					flow->http.url_len = target_end - target_start;
					flow->http.field_pos[0] = data + target_start;
					flow->http.field_len[0] = target_end - target_start;
				}
			}
		} else if (line_len > 2) {
			for (colon = start; colon < end && data[colon] != ':';
			     colon++)
				;
			field = colon < end ?
				af_http_header_field(data + start, colon - start) : -1;
			if (field >= 0 && !flow->http.field_pos[field]) {
				value_start = colon + 1;
				while (value_start < end &&
				       (data[value_start] == ' ' ||
					data[value_start] == '\t'))
					value_start++;
				value_end = end;
				while (value_end > value_start &&
				       (data[value_end - 1] == ' ' ||
					data[value_end - 1] == '\t'))
					value_end--;
				if (value_end > value_start) {
					flow->http.field_pos[field] = data + value_start;
					flow->http.field_len[field] = value_end - value_start;
					if (field == 1) {
						flow->http.host_pos = data + value_start;
						flow->http.host_len = value_end - value_start;
					}
				}
			}
		}

		start = end + 2;
		if (!line_len) {
			flow->http.data_pos = data + start;
			flow->http.data_len = data_len - start;
			break;
		}
	}
	if (flow->http.match) {
		atomic64_inc(&af_http_stats.parse_ok);
		if (flow->http.field_pos[0])
			atomic64_inc(&af_http_stats.uri_checked);
		if (flow->http.field_pos[1])
			atomic64_inc(&af_http_stats.host_checked);
		if (flow->http.field_pos[2])
			atomic64_inc(&af_http_stats.ua_checked);
	} else if (af_http_method_prefix(data, data_len)) {
		atomic64_inc(&af_http_stats.parse_fail);
	}
}

static void dump_http_flow_info(http_proto_t *http)
{
	if (!http)
	{
		AF_ERROR("http ptr is NULL\n");
		return;
	}
	if (!http->match)
		return;
	if (http->method == HTTP_METHOD_GET)
	{
		printk("Http method: " HTTP_GET_METHOD_STR "\n");
	}
	else if (http->method == HTTP_METHOD_POST)
	{
		printk("Http method: " HTTP_POST_METHOD_STR "\n");
	}
	if (http->url_len > 0 && http->url_pos)
	{
		dump_str("Request url", http->url_pos, http->url_len);
	}

	if (http->host_len > 0 && http->host_pos)
	{
		dump_str("Host", http->host_pos, http->host_len);
	}

	printk("--------------------------------------------------------\n\n\n");
}

static void dump_https_flow_info(https_proto_t *https)
{
	if (!https)
	{
		AF_ERROR("https ptr is NULL\n");
		return;
	}
	if (!https->match)
		return;

	if (https->url_len > 0 && https->url_pos)
	{
		dump_str("https server name", https->url_pos, https->url_len);
	}

	printk("--------------------------------------------------------\n\n\n");
}
static void dump_flow_info(flow_info_t *flow)
{
	if (!flow)
	{
		AF_ERROR("flow is null\n");
		return;
	}
	if (flow->l4_len > 0)
	{
		AF_LMT_INFO("src=" NIPQUAD_FMT ",dst=" NIPQUAD_FMT ",sport: %d, dport: %d, data_len: %d\n",
					NIPQUAD(flow->src), NIPQUAD(flow->dst), flow->sport, flow->dport, flow->l4_len);
	}

	if (flow->l4_protocol == IPPROTO_TCP)
	{
		if (AF_TRUE == flow->http.match)
		{
			printk("-------------------http protocol-------------------------\n");
			printk("protocol:TCP , sport: %-8d, dport: %-8d, data_len: %-8d\n",
				   flow->sport, flow->dport, flow->l4_len);
			dump_http_flow_info(&flow->http);
		}
		if (AF_TRUE == flow->https.match)
		{
			printk("-------------------https protocol-------------------------\n");
			dump_https_flow_info(&flow->https);
		}
	}
}


static bool af_memmem_bounded(const u8 *data, size_t data_len,
			      const u8 *pattern, size_t pattern_len,
			      u32 *step_budget)
{
	size_t i;
	size_t j;

	if (!data || !pattern || !pattern_len || pattern_len > data_len ||
	    !step_budget)
		return false;
	for (i = 0; i + pattern_len <= data_len; i++) {
		for (j = 0; j < pattern_len; j++) {
			if (!*step_budget)
				return false;
			(*step_budget)--;
			if (data[i + j] != pattern[j])
				break;
		}
		if (j == pattern_len)
			return true;
	}
	return false;
}

static int af_match_by_pos(flow_info_t *flow, af_feature_node_t *node,
			   u32 *step_budget)
{
	int i;
	unsigned int pos = 0;

	if (!flow || !node)
		return AF_FALSE;
	if (node->pos_num > 0) {
		for (i = 0; i < node->pos_num && i < MAX_POS_INFO_PER_FEATURE; i++)
		{
			// -1
			if (node->pos_info[i].pos < 0)
			{
				pos = flow->l4_len + node->pos_info[i].pos;
			}
			else
			{
				pos = node->pos_info[i].pos;
			}
			if (pos >= flow->l4_len)
			{
				return AF_FALSE;
			}
			if (flow->l4_data[pos] != node->pos_info[i].value)
			{
				return AF_FALSE;
			}
			else{
				AF_DEBUG("match pos[%d] = %x\n", pos, node->pos_info[i].value);
			}
		}
	}
	/* A legacy pure-search feature is a payload search, not a port-only rule. */
	if (node->search_str[0]) {
		if (!af_memmem_bounded(flow->l4_data, flow->l4_len,
				       node->search_str, strlen(node->search_str),
				       step_budget))
			return AF_FALSE;
		AF_DEBUG("match by search str, appid=%d, search_str=%s\n",
			 node->app_id, node->search_str);
	}
	return node->pos_num > 0 || node->search_str[0] ? AF_TRUE : AF_FALSE;
}

static int af_match_by_url(flow_info_t *flow, af_feature_node_t *node)
{
	char reg_url_buf[MAX_URL_MATCH_LEN] = {0};

	if (!flow || !node)
		return AF_FALSE;
	// match host or https url
	if (flow->https.match == AF_TRUE && flow->https.url_pos)
	{
		if (flow->https.url_len >= MAX_URL_MATCH_LEN)
			strncpy(reg_url_buf, flow->https.url_pos, MAX_URL_MATCH_LEN - 1);
		else
			strncpy(reg_url_buf, flow->https.url_pos, flow->https.url_len);
	}
	else if (flow->http.match == AF_TRUE && flow->http.host_pos)
	{
		if (flow->http.host_len >= MAX_URL_MATCH_LEN)
			strncpy(reg_url_buf, flow->http.host_pos, MAX_URL_MATCH_LEN - 1);
		else
			strncpy(reg_url_buf, flow->http.host_pos, flow->http.host_len);
	}
	if (strlen(reg_url_buf) > 0 && strlen(node->host_url) > 0 &&
	    regexp_match(node->host_url, reg_url_buf) > 0)
	{
		AF_DEBUG("match url:%s	 reg = %s, appid=%d\n",
				 reg_url_buf, node->host_url, node->app_id);
		return AF_TRUE;
	}

	// match request url
	if (flow->http.match == AF_TRUE && flow->http.url_pos)
	{
		memset(reg_url_buf, 0x0, sizeof(reg_url_buf));
		if (flow->http.url_len >= MAX_URL_MATCH_LEN)
			strncpy(reg_url_buf, flow->http.url_pos, MAX_URL_MATCH_LEN - 1);
		else
			strncpy(reg_url_buf, flow->http.url_pos, flow->http.url_len);
		if (strlen(reg_url_buf) > 0 && strlen(node->request_url) &&
		    regexp_match(node->request_url, reg_url_buf) > 0)
		{
			AF_DEBUG("match request:%s   reg:%s appid=%d\n",
					 reg_url_buf, node->request_url, node->app_id);
			return AF_TRUE;
		}
	}
	return AF_FALSE;
}

static int af_ik_match_method(u8 kind)
{
	switch (kind) {
	case AF_IK_MATCH_EXACT:
	case AF_IK_MATCH_SNI_EXACT:
	case AF_IK_MATCH_TLS_EXACT:
	case AF_IK_MATCH_HTTP_HOST_EXACT:
	case AF_IK_MATCH_HTTP_REQUEST_EXACT:
		return AF_IK_MATCH_EXACT;
	case AF_IK_MATCH_BM:
	case AF_IK_MATCH_SNI_BM:
	case AF_IK_MATCH_TLS_BM:
	case AF_IK_MATCH_HTTP_HOST_BM:
	case AF_IK_MATCH_HTTP_REQUEST_BM:
		return AF_IK_MATCH_BM;
	case AF_IK_MATCH_REGEX:
	case AF_IK_MATCH_SNI_REGEX:
	case AF_IK_MATCH_TLS_REGEX:
	case AF_IK_MATCH_HTTP_HOST_REGEX:
	case AF_IK_MATCH_HTTP_REQUEST_REGEX:
		return AF_IK_MATCH_REGEX;
	default:
		return -EINVAL;
	}
}

static bool af_ik_payload_slice(const u8 **data, size_t *len, s16 offset)
{
	int start;

	if (!data || !*data || !len)
		return false;
	if (offset == AF_IK_OFFSET_NONE) {
		*len = min_t(size_t, *len, MAX_AF_SUPPORT_DATA_LEN);
		return true;
	}
	/* A negative IK offset is relative to the real payload tail. */
	if (offset < 0) {
		start = (int)*len + offset;
	} else {
		*len = min_t(size_t, *len, MAX_AF_SUPPORT_DATA_LEN);
		start = offset;
	}
	if (start < 0 || start > *len)
		return false;
	*data += start;
	*len -= start;
	*len = min_t(size_t, *len, MAX_AF_SUPPORT_DATA_LEN);
	return true;
}

static int af_match_http_multi(flow_info_t *flow, af_feature_node_t *node,
			       u32 *step_budget)
{
	const struct af_http_clause *clause;
	const u8 *data;
	const u8 *pattern;
	size_t len;
	int i;

	if (!flow || !node || !step_budget || !node->http_clause_count)
		return AF_FALSE;
	for (i = 0; i < node->http_clause_count; i++) {
		clause = &node->http_clauses[i];
		if (clause->field >= AF_HTTP_FIELD_COUNT ||
		    !flow->http.field_pos[clause->field] ||
		    !flow->http.field_len[clause->field] ||
		    clause->pattern_offset > node->pattern_len ||
		    clause->pattern_len >
			node->pattern_len - clause->pattern_offset)
			return AF_FALSE;
		data = flow->http.field_pos[clause->field];
		len = flow->http.field_len[clause->field];
		pattern = node->pattern + clause->pattern_offset;
		/* The packet-wide bitmap is deliberately only a cheap first gate.  On
		 * long media request-targets its byte may occur in another header,
		 * causing thousands of unrelated regex NFAs to consume the shared
		 * packet budget before Host/User-Agent rules are reached.  Recheck the
		 * compiled required byte inside the clause's actual field. */
		if (clause->prefilter_valid &&
		    !memchr(data, clause->prefilter_byte, len)) {
			atomic64_inc(&af_http_stats.field_prefilter_reject);
			return AF_FALSE;
		}
		switch (clause->method) {
		case AF_HTTP_CLAUSE_EXACT:
			if (len != clause->pattern_len ||
			    *step_budget < clause->pattern_len)
				return AF_FALSE;
			*step_budget -= clause->pattern_len;
			if (memcmp(data, pattern, clause->pattern_len))
				return AF_FALSE;
			break;
		case AF_HTTP_CLAUSE_BM:
			if (!af_memmem_bounded(data, len, pattern,
					       clause->pattern_len, step_budget))
				return AF_FALSE;
			break;
		case AF_HTTP_CLAUSE_REGEX:
			if (!ik_regex_match(clause->regex, data, len, step_budget))
				return AF_FALSE;
			break;
		default:
			return AF_FALSE;
		}
	}
	return AF_TRUE;
}

static int af_match_ik_payload(flow_info_t *flow, af_feature_node_t *node,
			       u32 *step_budget)
{
	const u8 *data = flow->l4_data;
	size_t len = flow->l4_len;
	int method;

	if (node->match_kind == AF_IK_MATCH_HTTP_MULTI)
		return af_match_http_multi(flow, node, step_budget);

	switch (node->match_kind) {
	case AF_IK_MATCH_SNI_EXACT:
	case AF_IK_MATCH_SNI_BM:
	case AF_IK_MATCH_SNI_REGEX:
		if (!flow->https.match || !flow->https.url_pos ||
		    flow->https.url_len <= 0)
			return AF_FALSE;
		data = flow->https.url_pos;
		len = flow->https.url_len;
		break;
	case AF_IK_MATCH_HTTP_HOST_EXACT:
	case AF_IK_MATCH_HTTP_HOST_BM:
	case AF_IK_MATCH_HTTP_HOST_REGEX:
		if (!flow->http.host_pos || flow->http.host_len <= 0)
			return AF_FALSE;
		data = flow->http.host_pos;
		len = flow->http.host_len;
		break;
	case AF_IK_MATCH_HTTP_REQUEST_EXACT:
	case AF_IK_MATCH_HTTP_REQUEST_BM:
	case AF_IK_MATCH_HTTP_REQUEST_REGEX:
		if (!flow->http.url_pos || flow->http.url_len <= 0)
			return AF_FALSE;
		data = flow->http.url_pos;
		len = flow->http.url_len;
		break;
	default:
		break;
	}

	if (!af_ik_payload_slice(&data, &len, node->match_offset))
		return AF_FALSE;
	method = af_ik_match_method(node->match_kind);
	if (method == AF_IK_MATCH_EXACT) {
		if (node->pattern_len > len ||
		    ((node->match_kind == AF_IK_MATCH_SNI_EXACT ||
		      node->match_kind == AF_IK_MATCH_HTTP_HOST_EXACT ||
		      node->match_kind == AF_IK_MATCH_HTTP_REQUEST_EXACT) &&
		     node->pattern_len != len) ||
		    *step_budget < node->pattern_len)
			return AF_FALSE;
		*step_budget -= node->pattern_len;
		return !memcmp(data, node->pattern, node->pattern_len);
	}
	if (method == AF_IK_MATCH_BM)
		return af_memmem_bounded(data, len, node->pattern,
					 node->pattern_len, step_budget);
	if (method == AF_IK_MATCH_REGEX)
		return ik_regex_match(node->native_regex, data, len, step_budget);
	return AF_FALSE;
}

static int af_match_one(flow_info_t *flow, af_feature_node_t *node,
			 u32 *step_budget)
{
	int ret = AF_FALSE;
	int match_port;
	u8 family;
	bool parsed_request_seq;
	if (!flow || !node)
	{
		AF_ERROR("node or flow is NULL\n");
		return AF_FALSE;
	}
	if (node->proto > 0 && flow->l4_protocol != node->proto)
		return AF_FALSE;
	if (flow->l4_len <= 0)
		return AF_FALSE;
	if (node->feature_version == 4) {
		family = af_feature_family(node->match_kind);
		if (node->direction != AF_IK_DIR_BOTH &&
		    node->direction != flow->dir)
			return AF_FALSE;
		/* Native HTTP pkt_seq=1 means the first parsable HTTP request, not
		 * necessarily the first arbitrary TCP payload (a bootstrap record may
		 * precede it).  SNI is likewise matched against a reconstructed
		 * ClientHello, whose completion packet can have any ordinal.  Old R20.5
		 * compilers incorrectly copied a raw table bucket (usually 1|2) onto all
		 * SNI rules even though the source rule's pkt_seq is zero.  A validated
		 * parsed header therefore supersedes those transport ordinals.  Raw
		 * IKAPP rules retain their directional payload ordinals. */
		parsed_request_seq =
			(family == AF_FEATURE_FAMILY_HTTP && flow->http.match &&
			 (node->pkt_seq_mask & BIT(0))) ||
			(family == AF_FEATURE_FAMILY_SNI && flow->https.match);
		if (node->pkt_seq_mask &&
		    !parsed_request_seq &&
		    (flow->pkt_seq < 1 || flow->pkt_seq > NF_PAYLOAD_SEQ_MAX ||
		     !(node->pkt_seq_mask & BIT(flow->pkt_seq - 1)))) {
			atomic64_inc(&af_http_stats.pktseq_wait);
			return AF_FALSE;
		}
		if (node->pkt_seq_mask) {
			if (family == AF_FEATURE_FAMILY_SNI && parsed_request_seq &&
			    (flow->pkt_seq < 1 || flow->pkt_seq > NF_PAYLOAD_SEQ_MAX ||
			     !(node->pkt_seq_mask & BIT(flow->pkt_seq - 1))))
				atomic64_inc(&af_http_stats.sni_pktseq_bypassed);
			atomic64_inc(&af_http_stats.pktseq_match);
		}
		if (node->payload_len_info.num &&
		    !af_match_port(&node->payload_len_info,
				   flow->total_len ? flow->total_len : flow->l4_len))
			return AF_FALSE;
		if (node->server_mask) {
			u32 server;

			if (!flow->src || !flow->dst)
				return AF_FALSE;
			server = ntohl(flow->dir == AF_IK_DIR_REPLY ?
				       flow->src : flow->dst);
			if ((server & node->server_mask) != node->server_addr)
				return AF_FALSE;
		}
	}

	if (node->sport != 0 && flow->sport != node->sport)
	{
		return AF_FALSE;
	}

	match_port = node->feature_version == 4 &&
		     flow->dir == AF_IK_DIR_REPLY ? flow->sport : flow->dport;
	if (!af_match_port(&node->dport_info, match_port))
	{
		return AF_FALSE;
	}
	if (node->feature_version == 4) {
		if (node->match_kind == AF_IK_MATCH_PORT)
			return AF_TRUE;
		if (node->match_kind == AF_IK_MATCH_URL)
			return af_match_by_url(flow, node);
		return af_match_ik_payload(flow, node, step_budget);
	}

	if (strlen(node->request_url) > 0 ||
		strlen(node->host_url) > 0)
	{
		ret = af_match_by_url(flow, node);
	}
	else if (node->pos_num > 0 || node->search_str[0])
	{
		ret = af_match_by_pos(flow, node, step_budget);
	}
	else
	{
		AF_DEBUG("node is empty, match sport:%d,dport:%d, appid = %d\n",
				 node->sport, node->dport, node->app_id);
		return AF_TRUE;
	}

	return ret;
}


static int af_match_quic(flow_info_t *flow)
{
	unsigned char *data;
	unsigned char first_byte;
	unsigned int version;

	if (flow->l4_protocol != IPPROTO_UDP) {
		return AF_FALSE;
	}

	if (!flow->l4_data || flow->l4_len < 8) {
		return AF_FALSE;
	}

	data = flow->l4_data;
	first_byte = data[0];

	if (first_byte & 0x80) {
		if (flow->l4_len >= 5) {
			version = (data[1] << 24) | (data[2] << 16) | (data[3] << 8) | data[4];

			if (version == 0x00000001 ||
				version == 0x00000000 ||
				version == 0x6b3343cf ||
				(version >= 0xff000000 && version <= 0xffffffff)) {
				AF_LMT_DEBUG("match quic, version = %x\n", version);
				return AF_TRUE;
			}
		}
		if (flow->dport == 443) {
			return AF_TRUE;
		}
		return AF_FALSE;
	}
	return AF_FALSE;
}

static void af_http_recent_copy(char *dest, size_t dest_size,
				const char *source, size_t source_len,
				bool strip_query)
{
	size_t i;
	size_t copy_len;

	if (!dest || !dest_size)
		return;
	dest[0] = '\0';
	if (!source || !source_len)
		return;
	copy_len = min(source_len, dest_size - 1);
	for (i = 0; i < copy_len; i++) {
		u8 ch = source[i];

		if (strip_query && ch == '?')
			break;
		dest[i] = ch >= 0x20 && ch < 0x7f ? ch : '.';
	}
	dest[i] = '\0';
}

static void af_http_match_recent_add(flow_info_t *flow,
				     af_feature_node_t *node,
				     bool policy_priority)
{
	struct af_http_match_recent *recent;
	u8 field = 0xff;

	if (!flow || !node || !flow->http.match)
		return;
	if (node->match_kind == AF_IK_MATCH_HTTP_MULTI &&
	    node->http_clause_count == 1)
		field = node->http_clauses[0].field;
	spin_lock_bh(&af_http_match_recent_lock);
	recent = &af_http_match_recent[af_http_match_recent_head++ %
						 AF_HTTP_MATCH_RECENT_MAX];
	memset(recent, 0, sizeof(*recent));
	recent->src = flow->src;
	recent->dst = flow->dst;
	recent->sport = flow->sport;
	recent->dport = flow->dport;
	recent->proto = flow->l4_protocol;
	recent->appid = node->app_id;
	recent->match_kind = node->match_kind;
	recent->priority = node->priority;
	recent->field = field;
	recent->fallback = node->fallback;
	recent->policy_priority = policy_priority;
	recent->when = jiffies;
	af_http_recent_copy(recent->uri, sizeof(recent->uri),
			    flow->http.field_pos[0], flow->http.field_len[0], true);
	af_http_recent_copy(recent->host, sizeof(recent->host),
			    flow->http.field_pos[1], flow->http.field_len[1], false);
	af_http_recent_copy(recent->user_agent, sizeof(recent->user_agent),
			    flow->http.field_pos[2], flow->http.field_len[2], false);
	spin_unlock_bh(&af_http_match_recent_lock);
}

static void af_sni_match_recent_add(flow_info_t *flow,
				    af_feature_node_t *node,
				    bool policy_priority)
{
	struct af_sni_match_recent *recent;

	if (!flow || !node || !flow->https.match || !flow->https.url_pos ||
	    flow->https.url_len <= 0)
		return;
	spin_lock_bh(&af_sni_match_recent_lock);
	recent = &af_sni_match_recent[af_sni_match_recent_head++ %
						 AF_SNI_MATCH_RECENT_MAX];
	memset(recent, 0, sizeof(*recent));
	recent->src = flow->src;
	recent->dst = flow->dst;
	if (flow->src6 && flow->dst6) {
		recent->family = NFPROTO_IPV6;
		recent->src6 = *flow->src6;
		recent->dst6 = *flow->dst6;
	} else {
		recent->family = NFPROTO_IPV4;
	}
	recent->sport = flow->sport;
	recent->dport = flow->dport;
	recent->proto = flow->l4_protocol;
	recent->appid = node->app_id;
	recent->match_kind = node->match_kind;
	recent->priority = node->priority;
	recent->policy_priority = policy_priority;
	recent->pkt_seq = flow->pkt_seq;
	recent->pkt_seq_mask = node->pkt_seq_mask;
	af_http_recent_copy(recent->sni, sizeof(recent->sni),
			    flow->https.url_pos, flow->https.url_len, false);
	recent->when = jiffies;
	spin_unlock_bh(&af_sni_match_recent_lock);
}


enum af_match_pass_result {
	AF_MATCH_PASS_NONE = 0,
	AF_MATCH_PASS_SPECIFIC,
	AF_MATCH_PASS_FALLBACK,
};

static int af_match_feature_pass(flow_info_t *flow,
				 struct list_head **heads, int list_count,
				 u32 payload_bitmap[8], bool *bitmap_ready,
				 bool priority_only)
{
	struct list_head *cursor[AF_MATCH_LIST_MAX];
	af_feature_node_t *node;
	af_feature_node_t *candidate;
	u32 step_budget = IK_REGEX_PACKET_STEP_BUDGET;
	u32 node_budget = AF_FEATURE_PACKET_NODE_BUDGET;
	int best;
	int i;
	bool fallback_found = false;
	u8 family;

	for (i = 0; i < list_count; i++)
		cursor[i] = heads[i]->next;

	while (step_budget && node_budget--) {
		best = -1;
		node = NULL;
		for (i = 0; i < list_count; i++) {
			if (cursor[i] == heads[i])
				continue;
			candidate = list_entry(cursor[i], af_feature_node_t, head);
			if (best < 0 || af_feature_precedes(candidate, node)) {
				best = i;
				node = candidate;
			}
		}
		if (best < 0)
			break;
		cursor[best] = cursor[best]->next;
		/* nftables consumes pure APPIDs from secmark, but it cannot influence
		 * the order of a 14k-entry native matcher.  Userspace mirrors the union
		 * of active policy APPIDs into this existing status bitmap.  Scan those
		 * rules once with an independent budget before the audit-wide pass, so a
		 * long media URI cannot starve the very application being blocked. */
		if (priority_only && !af_get_app_status_fast(node->app_id))
			continue;
		/* Metadata-only failures are still work in softirq context. */
		step_budget--;
		if (node->prefilter_valid) {
			if (!*bitmap_ready) {
				size_t head_len = min_t(size_t, flow->l4_len,
							    MAX_AF_SUPPORT_DATA_LEN);
				size_t tail_start = flow->l4_len > MAX_AF_SUPPORT_DATA_LEN ?
					flow->l4_len - MAX_AF_SUPPORT_DATA_LEN : head_len;
				size_t pos;

				for (pos = 0; flow->l4_data && pos < head_len; pos++)
					payload_bitmap[flow->l4_data[pos] >> 5] |=
						BIT(flow->l4_data[pos] & 31);
				/* Negative IK offsets are relative to the real payload tail.
				 * Include the bounded tail window as well as the head window so
				 * this rejection hint can never hide a valid tail signature. */
				for (pos = tail_start; flow->l4_data &&
				     pos < flow->l4_len; pos++)
					payload_bitmap[flow->l4_data[pos] >> 5] |=
						BIT(flow->l4_data[pos] & 31);
				*bitmap_ready = true;
			}
			if (!(payload_bitmap[node->prefilter_byte >> 5] &
			      BIT(node->prefilter_byte & 31)))
				continue;
		}
		family = af_feature_family(node->match_kind);
		if (family == AF_FEATURE_FAMILY_HTTP) {
			if (priority_only)
				atomic64_inc(&af_http_stats.priority_candidates);
			else
				atomic64_inc(&af_http_stats.candidate_rules);
		} else if (family == AF_FEATURE_FAMILY_SNI) {
			atomic64_inc(&af_http_stats.sni_candidates);
		}
		if (af_match_one(flow, node, &step_budget)) {
			if (family == AF_FEATURE_FAMILY_HTTP) {
				atomic64_inc(&af_http_stats.rule_match);
				if (priority_only)
					atomic64_inc(&af_http_stats.priority_rule_match);
				af_http_match_recent_add(flow, node, priority_only);
			} else if (family == AF_FEATURE_FAMILY_SNI) {
				atomic64_inc(&af_http_stats.sni_rule_match);
				if (priority_only)
					atomic64_inc(&af_http_stats.sni_priority_rule_match);
				af_sni_match_recent_add(flow, node, priority_only);
			}
			/* A weak/fallback rule remains pending.  The policy fast pass is
			 * only for concrete applications; normal fallback selection stays
			 * in the complete pass below. */
			if (priority_only && node->fallback)
				continue;
			if (node->fallback && fallback_found)
				continue;
			AF_LMT_INFO("match feature, appid=%d, feature = %s\n",
				    node->app_id, node->feature);
			flow->app_id = node->app_id;
			flow->ignore = node->ignore ? 1 : 0;
			flow->fallback = node->fallback ? 1 : 0;
			strscpy(flow->matched_feature, node->feature,
				sizeof(flow->matched_feature));
			strncpy(flow->app_name, node->app_name,
				sizeof(flow->app_name) - 1);
			if (!node->fallback) {
				return AF_MATCH_PASS_SPECIFIC;
			}
			/* A generic protocol is only a candidate. Keep scanning this
			 * packet for a real application and retain the best ordered
			 * fallback only when no specific signature matches. */
			fallback_found = true;
		} else if (!priority_only) {
			if (family == AF_FEATURE_FAMILY_HTTP)
				atomic64_inc(&af_http_stats.rule_no_match);
			else if (family == AF_FEATURE_FAMILY_SNI)
				atomic64_inc(&af_http_stats.sni_rule_no_match);
		}
	}
	if (!step_budget || !node_budget) {
		if (priority_only)
			atomic64_inc(&af_http_stats.priority_budget_expired);
		else
			atomic64_inc(&af_http_stats.pktseq_budget_expired);
	}
	return fallback_found ? AF_MATCH_PASS_FALLBACK : AF_MATCH_PASS_NONE;
}

static int match_feature(flow_info_t *flow)
{
	struct af_feature_db *db;
	struct list_head *heads[AF_MATCH_LIST_MAX];
	struct list_head *sni_heads[2];
	u32 payload_bitmap[8] = { 0 };
	u8 families[AF_FEATURE_FAMILY_COUNT];
	u8 proto;
	int family_count = 0;
	int list_count = 0;
	int result;
	int i;
	bool bitmap_ready = false;

	if (!flow)
		return AF_FALSE;
	feature_list_read_lock();
	db = af_feature_active;
	if (flow->l4_protocol == IPPROTO_TCP)
		proto = AF_FEATURE_PROTO_TCP;
	else if (flow->l4_protocol == IPPROTO_UDP)
		proto = AF_FEATURE_PROTO_UDP;
	else {
		feature_list_read_unlock();
		return AF_FALSE;
	}

	/* Raw payload/port rules are always candidates. Header-specific families
	 * are only scanned after the bounded protocol parser proved that this
	 * packet can satisfy them. This avoids walking thousands of HTTP/SNI rules
	 * for opaque traffic while preserving one global priority order. */
	families[family_count++] = AF_FEATURE_FAMILY_RAW;
	if (flow->http.match)
		families[family_count++] = AF_FEATURE_FAMILY_HTTP;
	if (flow->https.match)
		families[family_count++] = AF_FEATURE_FAMILY_SNI;
	if (flow->l4_data && flow->l4_len >= 3 &&
	    flow->l4_data[0] >= 0x14 && flow->l4_data[0] <= 0x17 &&
	    flow->l4_data[1] == 0x03)
		families[family_count++] = AF_FEATURE_FAMILY_TLS;

	for (i = 0; i < family_count; i++) {
		heads[list_count++] = &db->heads[proto][families[i]];
		heads[list_count++] = &db->heads[AF_FEATURE_PROTO_ANY][families[i]];
	}

	if (af_has_app_status()) {
		result = af_match_feature_pass(flow, heads, list_count,
					       payload_bitmap, &bitmap_ready, true);
		if (result == AF_MATCH_PASS_SPECIFIC) {
			feature_list_read_unlock();
			return AF_TRUE;
		}
	}
	/* Parsed SNI is bounded, normalized application evidence.  Scan only the
	 * two SNI buckets before mixing in thousands of raw/TLS regex candidates.
	 * On the live desktop flow the parser exposed i2.hdslb.com, but the shared
	 * packet step budget was exhausted before the priority-90 .hdslb.com row
	 * when userspace's optional policy bitmap was momentarily empty.  Duplicate
	 * cross-application predicates were already removed by the compiler, so
	 * this prepass changes cost/order only; it does not weaken a predicate. */
	if (flow->https.match) {
		sni_heads[0] = &db->heads[proto][AF_FEATURE_FAMILY_SNI];
		sni_heads[1] = &db->heads[AF_FEATURE_PROTO_ANY][AF_FEATURE_FAMILY_SNI];
		result = af_match_feature_pass(flow, sni_heads, ARRAY_SIZE(sni_heads),
					       payload_bitmap, &bitmap_ready, false);
		if (result == AF_MATCH_PASS_SPECIFIC) {
			atomic64_inc(&af_http_stats.sni_prepass_match);
			feature_list_read_unlock();
			return AF_TRUE;
		}
	}
	result = af_match_feature_pass(flow, heads, list_count, payload_bitmap,
				       &bitmap_ready, false);
	feature_list_read_unlock();
	return result != AF_MATCH_PASS_NONE ? AF_TRUE : AF_FALSE;
}


static int match_app_filter_user(af_client_info_t *client){
	if (!g_user_mode){ // auto mode
		if (af_whitelist_mac_find(client->mac)){
			AF_LMT_DEBUG("match whitelist mac = " MAC_FMT "\n", MAC_ARRAY(client->mac));
			return AF_FALSE;
		}
	}
	else{ // manual mode
		if (!af_mac_find(client->mac))
			return AF_FALSE;
	}
	return AF_TRUE;
}


static int match_app_filter_rule(int appid, af_client_info_t *client)
{
	if (!match_app_filter_user(client))
		return AF_FALSE;

	// All apps mode: skip appid check, match user only
	if (g_app_filter_mode == 1) {
		return AF_TRUE;
	}

	// Specified apps mode: check appid status
	if (af_get_app_status(appid))
	{
		return AF_TRUE;
	}
	return AF_FALSE;
}


/*1000 0000 0000 0000 0000 0000 0000 0000*/
#define NF_DROP_BIT 0x80000000
/*0100 0000 0000 0000 0000 0000 0000 0000*/
#define NF_CLIENT_HELLO_BIT 0x40000000
/*0010 0000 0000 0000 0000 0000 0000 0000*/
#define NF_IGNORE_BIT 0x20000000
/* OAF-owned secmark bits: direction-local application-payload ordinals. */
#define NF_ORIGINAL_SEQ_SHIFT 16
#define NF_ORIGINAL_SEQ_MASK  0x00070000
#define NF_REPLY_SEQ_SHIFT    19
#define NF_REPLY_SEQ_MASK     0x00380000
#define NF_PAYLOAD_COUNT_SHIFT 22
#define NF_PAYLOAD_COUNT_MASK  0x1fc00000
#define NF_PAYLOAD_COUNT_MAX   127
#define NF_PROFILE_EPOCH_SHIFT 16
#define NF_PROFILE_EPOCH_MASK  0x1fff0000
/* R20 ABI: secmark low16 is always a pure APPID.  R19 temporarily used bit15
 * as PENDING, producing externally visible 0x8001 values which nftables and
 * traffic accounting correctly interpreted as the nonexistent APPID 32769.
 * Keep the legacy masks only to migrate live R19 conntracks on first sight. */
#define NF_APPID_VALUE_MASK       0x0000ffff
#define NF_LEGACY_PENDING_APP_BIT 0x00008000
#define NF_LEGACY_APPID_MASK      0x00007fff

/* Native IK profiles can contain more than ten thousand candidates.  A burst
 * of previously established connections may otherwise run the full matcher
 * concurrently on both Cortex-A53 CPUs as soon as auditing is enabled, starving
 * the watchdog and the Ethernet housekeeping path.  One packet owns the global
 * DPI slot; deferred packets remain unresolved and retry later without
 * consuming their direction-local payload ordinal. */
static atomic_t af_dpi_global_owner = ATOMIC_INIT(0);
static unsigned long af_dpi_next_admission;

static bool af_dpi_global_try_enter(bool urgent_http)
{
	if ((!urgent_http &&
	     time_before(jiffies, READ_ONCE(af_dpi_next_admission))) ||
	    atomic_cmpxchg(&af_dpi_global_owner, 0, 1) != 0)
		return false;
	/* A contender can observe the old deadline just before the previous owner
	 * publishes a new one.  Recheck after ownership acquisition. */
	if (!urgent_http &&
	    time_before(jiffies, READ_ONCE(af_dpi_next_admission))) {
		atomic_set(&af_dpi_global_owner, 0);
		return false;
	}
	return true;
}

static bool af_appid_is_generic(u16 app_id)
{
	return app_id == OAF_UNKNOWN_APPID || app_id == 8073 || app_id == 8092;
}

static u32 af_current_profile_epoch(void);

static bool af_ct_generic_pending(u32 tag)
{
	u16 app_id = tag & NF_APPID_VALUE_MASK;

	/* Pending packets carry direction ordinals/counts in bits 16..28. A
	 * terminal publication atomically replaces those transient bits with the
	 * active profile epoch. This keeps low16 pure without another state bit. */
	return af_appid_is_generic(app_id) &&
	       (tag & NF_PROFILE_EPOCH_MASK) != af_current_profile_epoch();
}

static u16 af_ct_generic_app(u32 tag)
{
	u16 app_id = tag & NF_APPID_VALUE_MASK;

	return af_appid_is_generic(app_id) ? app_id : 0;
}

static void af_classify_recent_add(struct nf_conn *ct, u16 old_raw,
					   u16 old_appid, u16 new_appid,
					   bool terminal, bool attempt, bool ok)
{
	struct af_classify_recent *r;
	const struct nf_conntrack_tuple *tuple;

	if (!ct)
		return;
	spin_lock_bh(&af_classify_recent_lock);
	r = &af_classify_recent[af_classify_recent_head++ % AF_CLASSIFY_RECENT_MAX];
	memset(r, 0, sizeof(*r));
	tuple = &ct->tuplehash[IP_CT_DIR_ORIGINAL].tuple;
	if (tuple->src.l3num == NFPROTO_IPV4) {
		r->family = NFPROTO_IPV4;
		r->src = tuple->src.u3.ip;
		r->dst = tuple->dst.u3.ip;
	} else if (tuple->src.l3num == NFPROTO_IPV6) {
		r->family = NFPROTO_IPV6;
		r->src6 = tuple->src.u3.in6;
		r->dst6 = tuple->dst.u3.in6;
	}
	r->proto = tuple->dst.protonum;
	r->sport = ntohs(tuple->src.u.all);
	r->dport = ntohs(tuple->dst.u.all);
	r->old_raw = old_raw;
	r->old_appid = old_appid;
	r->new_appid = new_appid;
	r->terminal = terminal;
	r->attempt = attempt;
	r->ok = ok;
	r->when = jiffies;
	spin_unlock_bh(&af_classify_recent_lock);
}

static bool af_payload_may_upgrade_generic(flow_info_t *flow,
					   struct nf_conn *ct)
{
	if (!flow || flow->l4_len <= 0 || flow->dir != AF_IK_DIR_ORIGINAL)
		return false;
	if (flow->l4_protocol == IPPROTO_TCP &&
	    (af_http_method_prefix(flow->l4_data, flow->l4_len) ||
	     af_http_prefix_pending(ct)))
		return true;
	return flow->l4_protocol == IPPROTO_TCP && flow->l4_len >= 3 &&
	       (u8)flow->l4_data[0] == 0x16 &&
	       (u8)flow->l4_data[1] == 0x03;
}

static void af_ct_reopen_generic(struct nf_conn *ct, u16 app_id)
{
	u32 tag;
	u16 old_raw;
	bool terminal = false;

	spin_lock_bh(&ct->lock);
	tag = OAF_CT_TAG(ct);
	old_raw = tag & NF_APPID_VALUE_MASK;
	if (af_ct_generic_app(tag) == app_id) {
		terminal = !af_ct_generic_pending(tag);
		/* Reopen with a fresh bounded window; low16 remains the pure APPID. */
		tag &= ~(NF_PAYLOAD_COUNT_MASK | NF_ORIGINAL_SEQ_MASK |
			 NF_REPLY_SEQ_MASK | NF_IGNORE_BIT);
		tag = (tag & ~NF_APPID_VALUE_MASK) | app_id;
		OAF_CT_TAG(ct) = tag;
	}
	spin_unlock_bh(&ct->lock);
	if (terminal) {
		/* A terminal generic result belongs to the request which just ended.
		 * Never feed that completed prefix back into a later keep-alive request;
		 * the current method-leading packet will allocate its own prefix. */
		af_http_prefix_forget(ct);
		atomic64_inc(&af_http_stats.terminal_generic_reentry);
		af_classify_recent_add(ct, old_raw, app_id, app_id,
				       true, false, false);
	}
}

static void af_dpi_global_leave(void)
{
	/* One scheduler tick between full matcher runs bounds sustained softirq CPU
	 * duty without reducing the per-flow packet window. */
	WRITE_ONCE(af_dpi_next_admission, jiffies + 1);
	smp_wmb();
	atomic_set(&af_dpi_global_owner, 0);
}

static void af_dpi_global_cancel(void)
{
	atomic_set(&af_dpi_global_owner, 0);
}

static u32 af_ct_tag_read(struct nf_conn *ct)
{
	u32 tag;
	u16 raw;
	u16 base = 0;
	bool migrated = false;

	if (!ct)
		return 0;
	spin_lock_bh(&ct->lock);
	tag = OAF_CT_TAG(ct);
	raw = tag & NF_APPID_VALUE_MASK;
	if ((raw & NF_LEGACY_PENDING_APP_BIT) &&
	    af_appid_is_generic(raw & NF_LEGACY_APPID_MASK)) {
		base = raw & NF_LEGACY_APPID_MASK;
		tag = (tag & ~NF_APPID_VALUE_MASK) |
		      base;
		tag &= ~(NF_PAYLOAD_COUNT_MASK | NF_ORIGINAL_SEQ_MASK |
			 NF_REPLY_SEQ_MASK | NF_IGNORE_BIT);
		OAF_CT_TAG(ct) = tag;
		migrated = true;
	}
	spin_unlock_bh(&ct->lock);
	if (migrated) {
		atomic64_inc(&af_http_stats.terminal_generic_reentry);
		af_classify_recent_add(ct, raw, base, base, true, false, false);
	}
	return tag;
}

/* The packet mark used by the original integration only protects one skb.
 * Some MediaTek external-device paths rebuild that skb before the proprietary
 * HNAT bind point, and software flow offload does not consult it at all.  Keep
 * the same reserved bit on the conntrack while DPI is pending or the policy
 * verdict is BLOCK.  This is deliberately a single bit so mwan/PBR/QoS mark
 * namespaces remain intact. */
static bool af_ct_set_no_offload_locked(struct nf_conn *ct, bool enabled)
{
#if IS_ENABLED(CONFIG_NF_CONNTRACK_MARK)
	u32 mark, old_mark;

	if (!ct)
		return false;
	old_mark = READ_ONCE(ct->mark);
	mark = old_mark;
	if (enabled)
		mark |= OAF_CT_NO_OFFLOAD_MARK;
	else
		mark &= ~OAF_CT_NO_OFFLOAD_MARK;
	if (mark == old_mark)
		return false;
	WRITE_ONCE(ct->mark, mark);
	return true;
#else
	return false;
#endif
}

static bool af_ct_set_no_offload(struct nf_conn *ct, bool enabled)
{
	bool changed;

	if (!ct)
		return false;
	spin_lock_bh(&ct->lock);
	changed = af_ct_set_no_offload_locked(ct, enabled);
	spin_unlock_bh(&ct->lock);
	return changed;
}

static void af_hnat_kick_conntrack(struct nf_conn *ct)
{
	int (*kick)(struct nf_conn *ct);

	if (!ct)
		return;
	kick = symbol_get(mtk_hnat_kick_conntrack);
	if (!kick)
		return;
	kick(ct);
	symbol_put(mtk_hnat_kick_conntrack);
}

/* Existing terminal flows need a KICK only when their durable admission bit
 * transitions to BLOCK.  First-time classifications are kicked explicitly in
 * af_ct_publish_classification(), including when DPI_PENDING already held the
 * same bit. */
static void af_ct_apply_terminal_offload(struct nf_conn *ct, bool blocked)
{
	if (af_ct_set_no_offload(ct, blocked) && blocked)
		af_hnat_kick_conntrack(ct);
}

/* mark_control runs before OAF and therefore its skb mark would otherwise
 * survive even after an ALLOW classification cleared the durable ct mark.
 * MediaTek's bind hook consults both namespaces, so clear/set the dedicated
 * bit on the current packet together with the terminal conntrack decision. */
static void af_skb_apply_terminal_offload(struct sk_buff *skb, bool blocked)
{
	if (!skb)
		return;
	if (blocked)
		skb->mark |= OAF_ACCEL_BYPASS_MARK;
	else
		skb->mark &= ~OAF_ACCEL_BYPASS_MARK;
}

static u32 af_current_profile_epoch(void)
{
	return (READ_ONCE(g_feature_generation) & 0x1fffU) <<
	       NF_PROFILE_EPOCH_SHIFT;
}

static bool af_ct_reset_stale_profile(struct nf_conn *ct, u32 *result)
{
	u32 tag;
	u16 classification;
	bool reset = false;

	if (!ct)
		return false;
	spin_lock_bh(&ct->lock);
	tag = OAF_CT_TAG(ct);
	classification = tag & NF_APPID_VALUE_MASK;
	if (classification && !af_ct_generic_pending(tag) &&
	    (tag & NF_PROFILE_EPOCH_MASK) != af_current_profile_epoch()) {
		/* secmark is OAF's private namespace.  Terminal APPIDs from a prior
		 * module/profile must never be interpreted using the new catalog. */
		tag = 0;
		OAF_CT_TAG(ct) = 0;
		reset = true;
	}
	spin_unlock_bh(&ct->lock);
	if (result)
		*result = tag;
	return reset;
}

/*
 * All secmark read/modify/write operations go through ct->lock.  Original
 * and reply packets can run on different CPUs; without this merge helper an
 * APPID/flag publication could erase the other direction's payload ordinal,
 * or the ordinal update could restore an old APPID.
 */
static u32 af_ct_tag_update(struct nf_conn *ct, u32 clear_mask, u32 set_mask)
{
	u32 tag;

	if (!ct)
		return 0;
	spin_lock_bh(&ct->lock);
	tag = (OAF_CT_TAG(ct) & ~clear_mask) | set_mask;
	OAF_CT_TAG(ct) = tag;
	spin_unlock_bh(&ct->lock);
	return tag;
}

static bool af_ct_publish_classification(struct nf_conn *ct, u16 app_id,
					 bool ignore, bool drop,
					 bool policy_no_offload, u32 *result)
{
	u32 tag;
	u16 current_app;
	u16 pending_app;
	bool upgrade_attempt;
	bool old_terminal;
	bool published = false;

	if (!ct)
		return false;
	spin_lock_bh(&ct->lock);
	tag = OAF_CT_TAG(ct);
	current_app = tag & NF_APPID_VALUE_MASK;
	pending_app = af_ct_generic_pending(tag) ? af_ct_generic_app(tag) : 0;
	upgrade_attempt = af_appid_is_generic(current_app) &&
			  !af_appid_is_generic(app_id) && af_appid_valid(app_id);
	old_terminal = af_appid_is_generic(current_app) &&
		       !af_ct_generic_pending(tag);
	if (upgrade_attempt) {
		atomic64_inc(&af_http_stats.terminal_generic_upgrade_attempt);
		af_classify_recent_add(ct, current_app, current_app, app_id,
				       old_terminal, true, false);
	}
	/* First terminal decision wins.  A late DPI packet must not replace an
	 * already published valid APPID from the other CPU.  A valid result may
	 * still replace UNKNOWN at the DPI-window boundary. */
	if (!current_app || af_ct_generic_pending(tag) || upgrade_attempt) {
		tag = (tag & ~(NF_APPID_VALUE_MASK | NF_PROFILE_EPOCH_MASK |
			       NF_IGNORE_BIT | NF_DROP_BIT)) |
		      app_id | af_current_profile_epoch() |
		      (ignore ? NF_IGNORE_BIT : 0) |
		      (drop ? NF_DROP_BIT : 0);
		OAF_CT_TAG(ct) = tag;
		/* Strict policy marks the skb/conntrack before OAF's -149 hook.  That
		 * hold is only an admission barrier while APPID is unknown: release it
		 * for a completed result, then the -148 nft rule pins only a matching
		 * blocked APPID before reject.  Keeping it here would push every flow of
		 * a selected client through the CPUs indefinitely. */
		af_ct_set_no_offload_locked(ct, drop);
		published = true;
		if (policy_no_offload)
			atomic64_inc(&af_http_stats.policy_hold_published);
		if (app_id == OAF_UNKNOWN_APPID)
			atomic64_inc(&af_http_stats.appid1_flows);
		if (pending_app && af_appid_is_generic(pending_app) &&
		    !af_appid_is_generic(app_id))
			atomic64_inc(&af_http_stats.generic_upgraded);
		if (upgrade_attempt) {
			atomic64_inc(&af_http_stats.terminal_generic_upgrade_ok);
			af_classify_recent_add(ct, current_app, current_app, app_id,
					       old_terminal, true, true);
		}
	}
	spin_unlock_bh(&ct->lock);
	/* Publication ends the current bounded request/DPI window.  Specific
	 * results are final; terminal generic results may be reopened only by a
	 * fresh original-direction HTTP request, which must not inherit this
	 * request's prefix. */
	if (published)
		af_http_prefix_forget(ct);
	if (published && (drop || policy_no_offload))
		af_hnat_kick_conntrack(ct);
	if (result)
		*result = tag;
	return published;
}

static bool af_ct_note_fallback(struct nf_conn *ct, u16 app_id, u32 *result)
{
	u32 tag;
	u16 current_class;
	bool stored = false;

	if (!ct || !af_appid_valid(app_id))
		return false;
	spin_lock_bh(&ct->lock);
	tag = OAF_CT_TAG(ct);
	current_class = tag & NF_APPID_VALUE_MASK;
	if (!current_class) {
		tag = (tag & ~NF_APPID_VALUE_MASK) | app_id;
		OAF_CT_TAG(ct) = tag;
		stored = true;
		atomic64_inc(&af_http_stats.generic_set);
	} else if (af_ct_generic_pending(tag)) {
		/* match_feature() is priority/specificity ordered: keep the first
		 * generic candidate observed for this connection. */
		stored = true;
	}
	spin_unlock_bh(&ct->lock);
	if (result)
		*result = tag;
	return stored;
}

enum af_dpi_begin_result {
	AF_DPI_BEGIN_OK = 0,
	AF_DPI_BEGIN_BUSY,
	AF_DPI_BEGIN_CLASSIFIED,
};

static int af_ct_begin_payload_dpi(struct nf_conn *ct, u8 direction,
				   u8 *packet_seq, u8 *payload_count,
				   u32 *result_tag)
{
	u32 mask;
	u32 shift;
	u32 tag;
	u8 seq;
	u8 total;
	int result = AF_DPI_BEGIN_OK;

	if (!ct || !packet_seq || !payload_count)
		return AF_DPI_BEGIN_CLASSIFIED;
	if (direction == AF_IK_DIR_REPLY) {
		mask = NF_REPLY_SEQ_MASK;
		shift = NF_REPLY_SEQ_SHIFT;
	} else {
		mask = NF_ORIGINAL_SEQ_MASK;
		shift = NF_ORIGINAL_SEQ_SHIFT;
	}

	spin_lock_bh(&ct->lock);
	tag = OAF_CT_TAG(ct);
	if ((tag & NF_APPID_VALUE_MASK) && !af_ct_generic_pending(tag)) {
		result = AF_DPI_BEGIN_CLASSIFIED;
		goto out;
	}
	/* Before APPID publication NF_IGNORE_BIT is an in-flight latch.  Once
	 * low16 becomes nonzero the publisher atomically gives the bit its normal
	 * IGNORE meaning.  This serialises packet ordinals and UNKNOWN publication
	 * for a conn without storing APP_ID in ct->mark.  The separate reserved
	 * NO_OFFLOAD bit may still be present there while classification is pending. */
	if (tag & NF_IGNORE_BIT) {
		result = AF_DPI_BEGIN_BUSY;
		goto out;
	}
	tag |= NF_IGNORE_BIT;
	seq = (tag & mask) >> shift;
	if (seq < NF_PAYLOAD_SEQ_MAX)
		seq++;
	total = (tag & NF_PAYLOAD_COUNT_MASK) >> NF_PAYLOAD_COUNT_SHIFT;
	if (total < NF_PAYLOAD_COUNT_MAX)
		total++;
	tag = (tag & ~(mask | NF_PAYLOAD_COUNT_MASK)) |
	      ((u32)seq << shift) |
	      ((u32)total << NF_PAYLOAD_COUNT_SHIFT);
	OAF_CT_TAG(ct) = tag;
	*packet_seq = seq;
	*payload_count = total;
out:
	if (result_tag)
		*result_tag = tag;
	spin_unlock_bh(&ct->lock);
	return result;
}

static void af_ct_end_payload_dpi(struct nf_conn *ct)
{
	if (!ct)
		return;
	spin_lock_bh(&ct->lock);
	if (!(OAF_CT_TAG(ct) & NF_APPID_VALUE_MASK) ||
	    af_ct_generic_pending(OAF_CT_TAG(ct)))
		OAF_CT_TAG(ct) &= ~NF_IGNORE_BIT;
	spin_unlock_bh(&ct->lock);
}


static int af_get_visit_index(af_client_info_t *node, int app_id)
{
	int i;
	for (i = 0; i < MAX_RECORD_APP_NUM; i++)
	{
		if (node->visit_info[i].app_id == app_id || node->visit_info[i].app_id == 0)
		{
			return i;
		}
	}
	// default 0
	return 0;
}

static int af_update_client_app_info(af_client_info_t *node, int app_id, int drop)
{
	int index = -1;
	if (!node)
		return -1;

	index = af_get_visit_index(node, app_id);
	if (index < 0 || index >= MAX_RECORD_APP_NUM)
		return 0;
	node->visit_info[index].total_num++;
	if (drop)
		node->visit_info[index].drop_num++;
	node->visit_info[index].app_id = app_id;
	node->visit_info[index].latest_time = af_get_timestamp_sec();
	node->visit_info[index].latest_action = drop;
	if (app_id > 0){
		node->visiting.app_time = af_get_timestamp_sec();
		node->visiting.visiting_app = app_id;
	}
	return 0;
}

int af_send_msg_to_user(char *pbuf, uint16_t len);
static __maybe_unused int af_match_bcast_packet(flow_info_t *f)
{
	if (!f)
		return 0;
	if (0 == f->src || 0 == f->dst || 0xffffffff == f->dst || 0 == f->dst)
		return 1;
	return 0;
}

static int af_match_local_packet(flow_info_t *f)
{
	if (!f)
		return 0;
	if (0x0100007f == f->src || 0x0100007f == f->dst)
	{
		return 1;
	}
	return 0;
}

static int update_url_visiting_info(af_client_info_t *client, flow_info_t *flow)
{
	char *host = NULL;
	unsigned int len = 0;
    if (!client || !flow)
        return -1;

    if (flow->https.match){
        host = flow->https.url_pos;
        len = flow->https.url_len;
    }
    else if (flow->http.match){
        host = flow->http.host_pos;
        len = flow->http.host_len;
    }
    if (!host || len < MIN_REPORT_URL_LEN || len >= MAX_REPORT_URL_LEN)
        return -1;

    memcpy(client->visiting.visiting_url, host, len);
    client->visiting.visiting_url[len] = 0x0;
    client->visiting.url_time = af_get_timestamp_sec();
    return 0;
}


static int dpi_main(struct sk_buff *skb, flow_info_t *flow)
{
	dpi_http_proto(flow);
	dpi_https_proto(flow);
	if (TEST_MODE())
		dump_flow_info(flow);
	return 0;
}

static void af_get_smac(struct sk_buff *skb, u_int8_t *smac)
{
	struct ethhdr *ethhdr = NULL;
	ethhdr = eth_hdr(skb);
	if (ethhdr)
		memcpy(smac, ethhdr->h_source, ETH_ALEN);
	else
		memcpy(smac, &skb->cb[40], ETH_ALEN);
}
static int is_ipv4_broadcast(uint32_t ip)
{
	return (ip & 0x00FFFFFF) == 0x00FFFFFF;
}

static int is_ipv4_multicast(uint32_t ip)
{
	return (ip & 0xF0000000) == 0xE0000000;
}
static int af_check_bcast_ip(flow_info_t *f)
{

	if (0 == f->src || 0 == f->dst)
		return 1;
	if (is_ipv4_broadcast(ntohl(f->src)) || is_ipv4_broadcast(ntohl(f->dst)))
	{
		return 1;
	}
	if (is_ipv4_multicast(ntohl(f->src)) || is_ipv4_multicast(ntohl(f->dst)))
	{
		return 1;
	}

	return 0;
}

/*
	action: 0: accept, 1: drop
	return: 0: no change, 1: change
*/
static u_int32_t check_app_action_changed(int action, u_int32_t app_id, af_client_info_t *client)
{
	int changed = 0;
	u_int32_t max_jiffies = 30 * HZ;
	u_int32_t interval_jiffies = jiffies - g_update_jiffies;
	if (interval_jiffies < max_jiffies){
		AF_LMT_DEBUG("config changed, update app action\n");
		if (match_app_filter_rule(app_id, client)){
			AF_LMT_DEBUG("match appid = %d, action = %d\n", app_id, action);
			if (!action)
				changed = 1;
		}
		else{
			if (action)
				changed = 1;
		}
	}
	return changed;
}

static u_int32_t app_filter_hook_bypass_handle(struct sk_buff *skb, struct net_device *dev)
{
	flow_info_t flow;
	af_conn_t *conn;
	u_int8_t smac[ETH_ALEN];
	af_client_info_t *client = NULL;
	u_int32_t ret = NF_ACCEPT;
	u_int8_t malloc_data = 0;

	if (!skb || !dev)
		return NF_ACCEPT;
	if (0 == af_lan_ip || 0 == af_lan_mask)
		return NF_ACCEPT;
	if (strstr(dev->name, "docker"))
		return NF_ACCEPT;

	memset((char *)&flow, 0x0, sizeof(flow_info_t));
	if (parse_flow_proto(skb, &flow) < 0)
		return NF_ACCEPT;
	flow.dir = AF_IK_DIR_ORIGINAL;
	// bypass mode, only handle ipv4
	if (flow.src || flow.dst)
	{
		if (af_lan_ip == flow.src || af_lan_ip == flow.dst)
		{
			return NF_ACCEPT;
		}
		if (af_check_bcast_ip(&flow) || af_match_local_packet(&flow))
			return NF_ACCEPT;

		if ((flow.src & af_lan_mask) != (af_lan_ip & af_lan_mask))
		{
			return NF_ACCEPT;
		}
	}
	else
	{
		return NF_ACCEPT;
	}
	af_get_smac(skb, smac);

	AF_CLIENT_LOCK_W();
	client = find_and_add_af_client(smac);
	if (!client)
	{
		AF_CLIENT_UNLOCK_W();
		return NF_ACCEPT;
	}
	client->update_jiffies = jiffies;
	if (flow.src)
		client->ip = flow.src;
	AF_CLIENT_UNLOCK_W();


	spin_lock(&af_conn_lock);
	conn = af_conn_find_and_add(flow.src, flow.dst, flow.sport, flow.dport, flow.l4_protocol);
	if (!conn){
		spin_unlock(&af_conn_lock);
		return NF_ACCEPT;
	}

	conn->last_jiffies = jiffies;
	if (flow.l4_len > 0)
		conn->total_pkts++;
	if (!conn->app_id && conn->fallback_app_id &&
	    conn->total_pkts > g_max_dpi_packets)
		conn->app_id = conn->fallback_app_id;
	flow.pkt_seq = min_t(u32, conn->total_pkts, NF_PAYLOAD_SEQ_MAX);
    spin_unlock(&af_conn_lock);

	if (conn->drop && g_app_filter_mode){
		AF_LMT_INFO("bypass mod drop all app\n");
		return NF_DROP;
	}

	if (conn->app_id != 0)
	{
		flow.app_id = conn->app_id;
		flow.drop = conn->drop;
		if (g_disable_quic && flow.drop && flow.app_id == APPID_QUIC){
			AF_LMT_INFO("bypass drop quic\n");
			return NF_DROP;
		}

		if (check_app_action_changed(flow.drop, flow.app_id, client)){
			flow.drop = !flow.drop;
			AF_LMT_DEBUG("update appid %d action, new action = %s\n", flow.app_id, flow.drop ? "drop" : "accept");
		}
	}
	else{
		if (g_by_pass_accl) {
			if (conn->total_pkts > 256)	{
				return NF_ACCEPT;
			}
		}


		if (skb_is_nonlinear(skb) && flow.l4_len > 0)
		{
			flow.l4_len = min_t(int, flow.l4_len,
					    MAX_AF_SUPPORT_DATA_LEN);
			flow.l4_data = read_skb(skb, flow.l4_data - skb->data,
					    flow.l4_len);
			if (!flow.l4_data)
				return NF_ACCEPT;
			AF_LMT_DEBUG("##match nonlinear skb, len = %d\n", flow.l4_len);
			malloc_data = 1;
		}
		if (g_disable_quic && af_match_quic(&flow) &&
		    match_app_filter_user(client)) {
			conn->app_id = APPID_QUIC;
			conn->drop = 1;
			AF_LMT_INFO("match quic proto, drop\n");
			ret = NF_DROP;
			goto EXIT;
		}
		flow.client_hello = conn->client_hello;

		dpi_main(skb, &flow);
		conn->client_hello = flow.client_hello;
		update_url_visiting_info(client, &flow);

		if (!match_feature(&flow) && 0 == g_app_filter_mode)
			goto EXIT;
		if (flow.fallback) {
			spin_lock(&af_conn_lock);
			if (!conn->fallback_app_id)
				conn->fallback_app_id = flow.app_id;
			spin_unlock(&af_conn_lock);
			goto EXIT;
		}

		if (g_oaf_filter_enable){
			if (match_app_filter_rule(flow.app_id, client)){
				flow.drop = 1;
				AF_INFO("##Drop appid %d\n",flow.app_id);
				if (skb->protocol == htons(ETH_P_IP) && g_tcp_rst){
				#if LINUX_VERSION_CODE > KERNEL_VERSION(5,10,197)
					nf_send_reset(&init_net, skb->sk, skb, NF_INET_PRE_ROUTING);
				#elif LINUX_VERSION_CODE > KERNEL_VERSION(4,4,1)
				// 5.4 kernel panic
			//		nf_send_reset(&init_net, skb, NF_INET_PRE_ROUTING);
				#else
					nf_send_reset(skb, NF_INET_PRE_ROUTING);
				#endif
				}

			}
		}
		conn->app_id = flow.app_id;
		conn->drop = flow.drop;
		if (flow.ignore){
			AF_LMT_DEBUG("match ignore feature, feature = %s, appid = %d\n",
				flow.matched_feature, flow.app_id);
			conn->ignore = 1;
		}
		else{
			conn->ignore = 0;
		}
		conn->state = AF_CONN_DPI_FINISHED;
	}

	if (g_oaf_record_enable	){
		if (!conn->ignore){
			af_update_client_app_info(client, flow.app_id, flow.drop);
		}
		else{
			AF_LMT_DEBUG("update ignore appid = %d, drop = %d\n", flow.app_id, flow.drop);
		}

	}

	if (flow.drop && g_oaf_filter_enable)
	{
		AF_LMT_INFO("drop appid = %d\n", flow.app_id);
		ret = NF_DROP;
	}

EXIT:
	if (malloc_data)
	{
		if (flow.l4_data)
		{
			kfree(flow.l4_data);
		}
	}
	return ret;
}


static u_int32_t app_filter_hook_gateway_handle(struct sk_buff *skb,
					const struct net_device *in,
					const struct net_device *out)
{
	flow_info_t flow;
	enum ip_conntrack_info ctinfo;
	struct nf_conn *ct = NULL;
	af_client_info_t *client = NULL;
	u_int32_t ret = NF_ACCEPT;
	u_int32_t app_id = 0;
	u_int32_t tag;
	u_int8_t payload_count = 0;
	u_int8_t malloc_data = 0;
	u8 *skb_copy_data = NULL;
	u8 *prefix_data = NULL;
	int prefix_len = 0;
	bool urgent_http;
	bool published;
	bool policy_no_offload;
	bool dpi_global_owned = false;
	int dpi_begin;

	if (!af_netdev_is_lan(in, g_lan_ifname) &&
	    !af_netdev_is_lan(out, g_lan_ifname))
		return NF_ACCEPT;

	memset((char *)&flow, 0x0, sizeof(flow_info_t));
	if (parse_flow_proto(skb, &flow) < 0)
		return NF_ACCEPT;

	ct = nf_ct_get(skb, &ctinfo);
	if (ct == NULL)
		return NF_ACCEPT;
	/* nft mark_control runs at -150, immediately before this -149 hook.  Capture
	 * its skb mark before OAF adds the same compatibility bit for balanced or
	 * precise DPI, so a strict per-client hold can survive APPID publication. */
	policy_no_offload = !!(skb->mark & OAF_ACCEL_BYPASS_MARK);
	if (policy_no_offload)
		atomic64_inc(&af_http_stats.policy_hold_seen);
	flow.ct = ct;
	flow.dir = CTINFO2DIR(ctinfo) == IP_CT_DIR_REPLY ?
		   AF_IK_DIR_REPLY : AF_IK_DIR_ORIGINAL;

	if (flow.l4_protocol == IPPROTO_TCP && !nf_ct_is_confirmed(ct)){
		return NF_ACCEPT;
	}

	AF_CLIENT_LOCK_R();
	if (flow.dir == AF_IK_DIR_REPLY) {
		if (flow.dst)
			client = find_af_client_by_ip(flow.dst);
		else if (flow.dst6)
			client = find_af_client_by_ipv6(flow.dst6);
	} else {
		if (flow.src)
			client = find_af_client_by_ip(flow.src);
		else if (flow.src6)
			client = find_af_client_by_ipv6(flow.src6);
	}

	if (!client)
	{
		AF_CLIENT_UNLOCK_R();
		return NF_ACCEPT;
	}
	client->update_jiffies = jiffies;
	AF_CLIENT_UNLOCK_R();



	/*
	 * C2000MAX modification (2026-08-18): keep APP_ID out of ct->mark.
	 * mwan3, policy routing and EQoS all own portions of the normal mark.  The
	 * conntrack security mark is a separate 32-bit namespace and survives both
	 * software flow offload and MediaTek PPE MIB-to-conntrack synchronization.
	 * Only OAF_CT_NO_OFFLOAD_MARK is reserved in ct->mark as a per-flow
	 * accelerator admission guard; all other mark bits are preserved.
	 */
	tag = af_ct_tag_read(ct);
	if (tag && af_ct_reset_stale_profile(ct, &tag))
		goto CLASSIFY_PENDING;
	if (tag != 0)
	{
		u_int32_t orig_tag = tag;

		app_id = tag & NF_APPID_VALUE_MASK;
		if (af_ct_generic_pending(tag)) {
			/* A generic protocol match is deliberately non-terminal.  Keep
			 * looking for a specific application on later payload packets. */
			app_id = 0;
			if (tag & NF_CLIENT_HELLO_BIT)
				flow.client_hello = 1;
			goto CLASSIFY_PENDING;
		}
		// 1: drop , 0: accept
		int ct_action = !!(tag & NF_DROP_BIT);
		flow.ignore = !!(tag & NF_IGNORE_BIT);
		if (af_appid_is_generic(app_id) &&
		    af_payload_may_upgrade_generic(&flow, ct)) {
			af_ct_reopen_generic(ct, app_id);
			goto CLASSIFY_PENDING;
		}
		if (app_id == OAF_UNKNOWN_APPID) {
			af_ct_set_no_offload(ct, false);
			af_skb_apply_terminal_offload(skb, false);
			return NF_ACCEPT;
		}
		if (flow.ignore){
			AF_LMT_DEBUG("match ignore appid = %d, drop = %d\n", app_id, ct_action);
		}

		if (g_oaf_filter_enable){
			// quic proto
			if (g_disable_quic && app_id == APPID_QUIC && ct_action){
				af_ct_apply_terminal_offload(ct, true);
				af_skb_apply_terminal_offload(skb, true);
				AF_LMT_INFO("secmark = %x,drop appid = %d\n", tag, app_id);
				return NF_DROP;
			}

			if (g_app_filter_mode && ct_action){
				af_ct_apply_terminal_offload(ct, true);
				af_skb_apply_terminal_offload(skb, true);
				AF_LMT_INFO("ct drop all app\n");
				return NF_DROP;
			}
		}

		if (af_appid_valid(app_id))
		{
			AF_LMT_DEBUG("appid = %d, ct_action = %d\n", app_id, ct_action);
			if (check_app_action_changed(ct_action, app_id, client)){
				if (ct_action) // drop --> accept
					tag = af_ct_tag_update(ct, NF_DROP_BIT, 0);
				else
					tag = af_ct_tag_update(ct, 0, NF_DROP_BIT);
				ct_action = !ct_action;
				AF_LMT_DEBUG("update appid %d action to %s, secmark = %x-->%x\n",
						 app_id, ct_action ? "drop" : "accept", orig_tag, tag);
			}
			af_ct_apply_terminal_offload(ct,
						    g_oaf_filter_enable && ct_action);
			af_skb_apply_terminal_offload(skb,
						     g_oaf_filter_enable && ct_action);

			if (g_oaf_record_enable){
				AF_CLIENT_LOCK_W();
				if (!flow.ignore){
					af_update_client_app_info(client, app_id, ct_action);
				}
				else{
					AF_LMT_DEBUG(" ignore appid = %d, drop = %d, not update status\n", app_id, ct_action);
				}
				AF_CLIENT_UNLOCK_W();
			}
			if (g_oaf_filter_enable && ct_action) {
				AF_LMT_DEBUG("drop appid = %d, ct_action = %d\n", app_id, ct_action);
				return NF_DROP;
			}
			else{
				AF_LMT_DEBUG("accept appid = %d, ct_action = %d\n", app_id, ct_action);
				return NF_ACCEPT;
			}
		}
		else {
			af_ct_set_no_offload(ct, false);
			af_skb_apply_terminal_offload(skb, false);
			AF_LMT_DEBUG("ct->secmark = %x\n", tag);
			if (tag & NF_CLIENT_HELLO_BIT) {
				AF_LMT_INFO("match ct client hello...\n");
				flow.client_hello = 1;
			}
		}
	}

CLASSIFY_PENDING:
	/* Keep this connection, not the whole device or accelerator, on CPU until
	 * DPI reaches ALLOW/BLOCK/UNKNOWN.  The skb bit remains as protection for
	 * the current packet and compatibility with older HNAT paths. */
	af_ct_set_no_offload(ct, !!g_hold_acceleration || policy_no_offload);
	/* Handshake/ACK-only packets are neither DPI input nor part of its window. */
	if (flow.l4_len <= 0) {
		/* Precise/balanced must still keep the flow off PPE until payload
		 * classification; seamless deliberately leaves this bit clear. */
		if (g_hold_acceleration || policy_no_offload)
			skb->mark |= OAF_ACCEL_BYPASS_MARK;
		return NF_ACCEPT;
	}
	if (g_hold_acceleration || policy_no_offload)
		skb->mark |= OAF_ACCEL_BYPASS_MARK;
	/* Capture a ClientHello/HTTP prefix before taking the global matcher slot.
	 * A busy slot must delay expensive matching, not discard the first TCP
	 * segment which anchors stream reassembly.  The bounded per-conn slot keeps
	 * the bytes; these private copies are released on every early return. */
	if (skb_is_nonlinear(skb) && flow.l4_len > 0)
	{
		flow.l4_len = min_t(int, flow.l4_len, MAX_AF_SUPPORT_DATA_LEN);
		flow.l4_data = read_skb(skb, flow.l4_data - skb->data,
				    flow.l4_len);
		if (!flow.l4_data)
			return NF_ACCEPT;
		skb_copy_data = flow.l4_data;
		malloc_data = 1;
	}
	prefix_data = af_http_prefix_snapshot(skb, ct, &flow, &prefix_len);
	if (prefix_data) {
		flow.l4_data = prefix_data;
		flow.l4_len = prefix_len;
	}
	urgent_http = flow.dir == AF_IK_DIR_ORIGINAL &&
		(flow.l4_protocol == IPPROTO_TCP) &&
		(af_http_method_prefix(flow.l4_data, flow.l4_len) ||
		 af_tls_client_hello_prefix(flow.l4_data, flow.l4_len) ||
		 af_http_prefix_pending(ct));
	if (!af_dpi_global_try_enter(urgent_http)) {
		if (malloc_data)
			kfree(skb_copy_data);
		kfree(prefix_data);
		return NF_ACCEPT;
	}
	dpi_global_owned = true;
	dpi_begin = af_ct_begin_payload_dpi(ct, flow.dir, &flow.pkt_seq,
					      &payload_count, &tag);
	if (dpi_begin == AF_DPI_BEGIN_BUSY) {
		af_dpi_global_cancel();
		if (malloc_data)
			kfree(skb_copy_data);
		kfree(prefix_data);
		return NF_ACCEPT;
	}
	if (dpi_begin == AF_DPI_BEGIN_CLASSIFIED) {
		af_dpi_global_cancel();
		if (malloc_data)
			kfree(skb_copy_data);
		kfree(prefix_data);
		af_skb_apply_terminal_offload(skb,
					       g_oaf_filter_enable &&
					       !!(tag & NF_DROP_BIT));
		return g_oaf_filter_enable && (tag & NF_DROP_BIT) ?
		       NF_DROP : NF_ACCEPT;
	}

	if (payload_count > g_max_dpi_packets && !prefix_data) {
		app_id = af_ct_generic_app(tag);
		if (app_id) {
			atomic64_inc(&af_http_stats.terminal_generic_set);
			af_classify_recent_add(ct, app_id, app_id, app_id,
					       true, false, false);
		}
		flow.drop = app_id && g_oaf_filter_enable &&
			    match_app_filter_rule(app_id, client);
		af_ct_publish_classification(ct,
					     app_id ? app_id : OAF_UNKNOWN_APPID,
					     false, flow.drop, policy_no_offload,
					     &tag);
		af_skb_apply_terminal_offload(skb,
					       g_oaf_filter_enable &&
					       !!(tag & NF_DROP_BIT));
		if (g_oaf_filter_enable && (tag & NF_DROP_BIT))
			ret = NF_DROP;
		goto EXIT;
	}
	if (payload_count > g_max_dpi_packets)
		atomic64_inc(&af_http_stats.generic_finalize_deferred);
	/* Balanced/precise profiles keep an unknown flow on CPU until DPI decides
	 * ALLOW/BLOCK. Seamless inspects only packets that naturally reach CPU.
	 * QUIC must run after nonlinear payloads have been copied safely. */
	if (g_oaf_filter_enable && g_disable_quic && af_match_quic(&flow) &&
	    match_app_filter_user(client)) {
		af_ct_publish_classification(ct, APPID_QUIC, false, true,
					     policy_no_offload, &tag);
		af_skb_apply_terminal_offload(skb, true);
		if ((tag & NF_APPID_VALUE_MASK) != APPID_QUIC) {
			ret = tag & NF_DROP_BIT ? NF_DROP : NF_ACCEPT;
			goto EXIT;
		}
		if (!(tag & NF_DROP_BIT))
			goto EXIT;
		AF_LMT_INFO("match quic drop, %s %pI4(%d)-->%pI4(%d) len=%d\n",
			    IPPROTO_TCP == flow.l4_protocol ? "tcp" : "udp",
			    &flow.src, flow.sport, &flow.dst, flow.dport,
			    flow.l4_len);
		ret = NF_DROP;
		goto EXIT;
	}
	dpi_main(skb, &flow);

	update_url_visiting_info(client, &flow);
	if (flow.client_hello) {
		af_ct_tag_update(ct, 0, NF_CLIENT_HELLO_BIT);
	}
	else {
		af_ct_tag_update(ct, NF_CLIENT_HELLO_BIT, 0);
	}


	if (!match_feature(&flow) && 0 == g_app_filter_mode)
		goto EXIT;
	if (flow.fallback) {
		af_ct_note_fallback(ct, flow.app_id, &tag);
		goto EXIT;
	}


	 if (TEST_MODE()){
		if (flow.l4_protocol == IPPROTO_UDP){
			if (flow.dport > 5000 && flow.l4_len > 16 && flow.l4_len < 500){
				printk(" %s %pI4(%d)--> %pI4(%d) len = %d [%02x %02x %02x %02x %02x %02x %02x %02x] \n ", IPPROTO_TCP == flow.l4_protocol ? "tcp" : "udp",
					&flow.src, flow.sport, &flow.dst, flow.dport, flow.l4_len, flow.l4_data[0], flow.l4_data[1],flow.l4_data[2], flow.l4_data[3],flow.l4_data[4], flow.l4_data[5],flow.l4_data[6], flow.l4_data[7]);
			}
		}
	}


	if (g_oaf_filter_enable){
		if (match_app_filter_rule(flow.app_id, client))
			flow.drop = 1;
	}

	published = af_ct_publish_classification(ct, flow.app_id,
						 flow.ignore, flow.drop,
						 policy_no_offload, &tag);
	af_skb_apply_terminal_offload(skb,
				       g_oaf_filter_enable && !!(tag & NF_DROP_BIT));
	if (!published) {
		app_id = tag & NF_APPID_VALUE_MASK;
		if (af_ct_generic_pending(tag))
			goto EXIT;
		if (app_id == OAF_UNKNOWN_APPID ||
		    (app_id && !af_appid_valid(app_id)))
			goto EXIT;
		flow.app_id = app_id;
		flow.ignore = !!(tag & NF_IGNORE_BIT);
		flow.drop = !!(tag & NF_DROP_BIT);
	}
	if (flow.ignore)
		AF_LMT_DEBUG("gateway set ignore bit, ct->secmark = %x\n", tag);

	if (g_oaf_filter_enable && flow.drop)
	{
			flow.drop = 1;
			AF_LMT_INFO("##Drop app %s flow, appid is %d\n", flow.app_name, flow.app_id);
			if (skb->protocol == htons(ETH_P_IP) && g_tcp_rst){
			#if LINUX_VERSION_CODE > KERNEL_VERSION(5,10,197)
				nf_send_reset(&init_net, skb->sk, skb, NF_INET_PRE_ROUTING);
			#elif LINUX_VERSION_CODE > KERNEL_VERSION(4,4,1)
				//5.4 kernel panic
				//nf_send_reset(&init_net, skb, NF_INET_PRE_ROUTING);
			#else
				nf_send_reset(skb, NF_INET_PRE_ROUTING);
			#endif
			}
			ret = NF_DROP;
	}

	if (g_oaf_record_enable){
		AF_CLIENT_LOCK_W();
		if (!flow.ignore){
			af_update_client_app_info(client, flow.app_id, flow.drop);
		}

		AF_CLIENT_UNLOCK_W();
		AF_LMT_INFO("match %s %pI4(%d)--> %pI4(%d) len = %d, %d\n ", IPPROTO_TCP == flow.l4_protocol ? "tcp" : "udp",
					&flow.src, flow.sport, &flow.dst, flow.dport, skb->len, flow.app_id);
	}

EXIT:
	af_ct_end_payload_dpi(ct);
	if (dpi_global_owned)
		af_dpi_global_leave();
	if (malloc_data)
	{
		kfree(skb_copy_data);
	}
	kfree(prefix_data);
	return ret;
}

#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 4, 0)
static u_int32_t app_filter_hook(void *priv,
								 struct sk_buff *skb,
								 const struct nf_hook_state *state)
{
#else
static u_int32_t app_filter_hook(unsigned int hook,
								 struct sk_buff *skb,
								 const struct net_device *in,
								 const struct net_device *out,
								 int (*okfn)(struct sk_buff *))
{
#endif

	if (AF_MODE_BYPASS == af_work_mode)
		return NF_ACCEPT;
	/* Module registration precedes the userspace daemon applying UCI.  Do not
	 * classify the router's live connection set during that initialization
	 * window when neither recording nor filtering is active. */
	if (!READ_ONCE(g_oaf_record_enable) &&
	    !READ_ONCE(g_oaf_filter_enable))
		return NF_ACCEPT;
#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 4, 0)
	return app_filter_hook_gateway_handle(skb, state->in, state->out);
#else
	return app_filter_hook_gateway_handle(skb, in, out);
#endif
}

#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 4, 0)
static u_int32_t app_filter_by_pass_hook(void *priv,
										 struct sk_buff *skb,
										 const struct nf_hook_state *state)
{
#else
static u_int32_t app_filter_by_pass_hook(unsigned int hook,
										 struct sk_buff *skb,
										 const struct net_device *in,
										 const struct net_device *out,
										 int (*okfn)(struct sk_buff *))
{
#endif
	if (AF_MODE_GATEWAY == af_work_mode)
		return NF_ACCEPT;
	return app_filter_hook_bypass_handle(skb, skb->dev);
}

#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 16, 0)
static struct nf_hook_ops app_filter_ops[] __read_mostly = {
	{
		.hook = app_filter_hook,
		.pf = NFPROTO_INET,
		.hooknum = NF_INET_FORWARD,
		.priority = NF_IP_PRI_MANGLE + 1,

	},
	{
		.hook = app_filter_by_pass_hook,
		.pf = NFPROTO_INET,
		.hooknum = NF_INET_PRE_ROUTING,
		.priority = NF_IP_PRI_MANGLE + 1,
	},
};
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(4, 4, 0)
static struct nf_hook_ops app_filter_ops[] __read_mostly = {
	{
		.hook = app_filter_hook,
		.pf = NFPROTO_IPV4,
		.hooknum = NF_INET_FORWARD,
		.priority = NF_IP_PRI_MANGLE + 1,
	},
	{
		.hook = app_filter_by_pass_hook,
		.pf = NFPROTO_IPV4,
		.hooknum = NF_INET_PRE_ROUTING,
		.priority = NF_IP_PRI_MANGLE + 1,
	},
	{
		.hook = app_filter_hook,
		.pf = NFPROTO_IPV6,
		.hooknum = NF_INET_FORWARD,
		.priority = NF_IP_PRI_MANGLE + 1,

	},
	{
		.hook = app_filter_by_pass_hook,
		.pf = NFPROTO_IPV6,
		.hooknum = NF_INET_PRE_ROUTING,
		.priority = NF_IP_PRI_MANGLE + 1,
	},
};
#else
static struct nf_hook_ops app_filter_ops[] __read_mostly = {
	{
		.hook = app_filter_hook,
		.owner = THIS_MODULE,
		.pf = NFPROTO_IPV4,
		.hooknum = NF_INET_FORWARD,
		.priority = NF_IP_PRI_MANGLE + 1,
	},
	{
		.hook = app_filter_hook,
		.owner = THIS_MODULE,
		.pf = NFPROTO_IPV6,
		.hooknum = NF_INET_FORWARD,
		.priority = NF_IP_PRI_MANGLE + 1,
	},
};
#endif

static struct delayed_work oaf_maintenance_work;
int report_flag = 0;
#define OAF_MAINTENANCE_INTERVAL 1
static void oaf_maintenance_work_handler(struct work_struct *work)
{
	static int count = 0;

	(void)work;

	if (count % 60 == 0)
		check_client_expire();

	count++;
	af_conn_clean_timeout();

	queue_delayed_work(af_workqueue, &oaf_maintenance_work,
			   OAF_MAINTENANCE_INTERVAL * HZ);
}

static void init_oaf_maintenance_work(void)
{
	INIT_DELAYED_WORK(&oaf_maintenance_work, oaf_maintenance_work_handler);
	queue_delayed_work(af_workqueue, &oaf_maintenance_work,
			   OAF_MAINTENANCE_INTERVAL * HZ);
	AF_INFO("init oaf maintenance work...ok");
}

static void fini_oaf_maintenance_work(void)
{
	cancel_delayed_work_sync(&oaf_maintenance_work);
	AF_INFO("cancel oaf maintenance work...ok");
}

static struct sock *oaf_sock = NULL;

#define OAF_EXTRA_MSG_BUF_LEN 128
int af_send_msg_to_user(char *pbuf, uint16_t len)
{
	struct sk_buff *nl_skb;
	struct nlmsghdr *nlh;
	struct sock *sock;
	int buf_len = OAF_EXTRA_MSG_BUF_LEN + len;
	char *msg_buf = NULL;
	struct af_msg_hdr *hdr = NULL;
	char *p_data = NULL;
	int ret;
	if (len >= MAX_OAF_NL_MSG_LEN)
		return -1;
	sock = READ_ONCE(oaf_sock);
	if (!sock)
		return -1;

	msg_buf = kmalloc(buf_len, GFP_ATOMIC);
	if (!msg_buf)
		return -1;

	memset(msg_buf, 0x0, buf_len);
	nl_skb = nlmsg_new(len + sizeof(struct af_msg_hdr), GFP_ATOMIC);
	if (!nl_skb)
	{
		ret = -1;
		goto fail;
	}

	nlh = nlmsg_put(nl_skb, 0, 0, OAF_NETLINK_ID, len + sizeof(struct af_msg_hdr), 0);
	if (nlh == NULL)
	{
		nlmsg_free(nl_skb);
		ret = -1;
		goto fail;
	}

	hdr = (struct af_msg_hdr *)msg_buf;
	hdr->magic = 0xa0b0c0d0;
	hdr->len = len;
	p_data = msg_buf + sizeof(struct af_msg_hdr);
	memcpy(p_data, pbuf, len);
	memcpy(nlmsg_data(nlh), msg_buf, len + sizeof(struct af_msg_hdr));
	ret = netlink_unicast(sock, nl_skb, 999, MSG_DONTWAIT);

fail:
	kfree(msg_buf);
	return ret;
}

static void oaf_user_msg_handle(char *data, int len)
{
	char *msg_data = data + sizeof(af_msg_t);
	af_reload_commit_msg_t *commit;
	u32 actual_count = 0;
	if (len < sizeof(af_msg_t))
		return;
	af_msg_t *msg = (af_msg_t *)data;
	AF_INFO("msg action = %d\n", msg->action);
	switch (msg->action)
	{
	case AF_MSG_INIT:
		af_client_list_reset_report_num();
		report_flag = 1;
		break;
	case AF_MSG_ADD_FEATURE:
		if (af_add_feature_msg_handle(msg_data,
					      len - sizeof(af_msg_t)) < 0)
			af_fail_feature_reload(EINVAL);
		break;
	case AF_MSG_RELOAD_BEGIN:
		if (len != sizeof(af_msg_t)) {
			af_fail_feature_reload(EINVAL);
			break;
		}
		AF_INFO("begin atomic feature reload\n");
		if (af_begin_feature_reload() < 0)
			AF_ERROR("cannot allocate feature staging database\n");
		break;
	case AF_MSG_RELOAD_COMMIT:
		if (len != sizeof(*commit)) {
			af_fail_feature_reload(EINVAL);
			break;
		}
		commit = (af_reload_commit_msg_t *)data;
		if (af_commit_feature_reload(commit->expected_count,
					     &actual_count) < 0)
			AF_ERROR("reject incomplete feature reload, expected=%u actual=%u\n",
				 commit->expected_count, actual_count);
		break;
	default:
		break;
	}
}
static void oaf_msg_rcv(struct sk_buff *skb)
{
	struct nlmsghdr *nlh;
	struct af_msg_hdr *af_hdr;
	size_t payload_len;
	void *udata;

	if (!skb || !netlink_capable(skb, CAP_NET_ADMIN) ||
	    NETLINK_CB(skb).portid != OAF_USER_NETLINK_PORTID ||
	    skb->len < nlmsg_total_size(0))
		return;

	nlh = nlmsg_hdr(skb);
	if (!nlmsg_ok(nlh, skb->len))
		return;
	payload_len = nlmsg_len(nlh);
	if (payload_len < sizeof(*af_hdr) + sizeof(af_msg_t))
		return;

	af_hdr = nlmsg_data(nlh);
	if (af_hdr->magic != 0xa0b0c0d0 ||
	    af_hdr->len < sizeof(af_msg_t) ||
	    af_hdr->len >= MAX_OAF_NETLINK_MSG_LEN ||
	    (size_t)af_hdr->len > payload_len - sizeof(*af_hdr))
		return;

	udata = (u8 *)af_hdr + sizeof(*af_hdr);
	oaf_user_msg_handle(udata, af_hdr->len);
}

static int netlink_oaf_init(void)
{
	struct netlink_kernel_cfg nl_cfg = {0};
	nl_cfg.input = oaf_msg_rcv;
	oaf_sock = netlink_kernel_create(&init_net, OAF_NETLINK_ID, &nl_cfg);

	if (NULL == oaf_sock)
	{
		AF_ERROR("init oaf netlink failed, id=%d\n", OAF_NETLINK_ID);
		return -1;
	}
	AF_INFO("init oaf netlink ok, id = %d\n", OAF_NETLINK_ID);
	return 0;
}

static int af_http_stats_show(struct seq_file *m, void *v)
{
#define AF_STAT(name) seq_printf(m, #name "=%lld\n", \
	(long long)atomic64_read(&af_http_stats.name))
	AF_STAT(parse_ok); AF_STAT(parse_fail);
	AF_STAT(uri_checked); AF_STAT(host_checked); AF_STAT(ua_checked);
	AF_STAT(candidate_rules); AF_STAT(rule_match); AF_STAT(rule_no_match);
	AF_STAT(unsupported_rule);
	AF_STAT(priority_candidates); AF_STAT(priority_rule_match);
	AF_STAT(priority_budget_expired); AF_STAT(field_prefilter_reject);
	AF_STAT(generic_set); AF_STAT(generic_upgraded);
	AF_STAT(generic_finalize_timeout);
	AF_STAT(generic_finalize_deferred);
	AF_STAT(pktseq_wait); AF_STAT(pktseq_match); AF_STAT(pktseq_budget_expired);
	AF_STAT(prefix_alloc); AF_STAT(prefix_complete);
	AF_STAT(prefix_restarted);
	AF_STAT(prefix_budget_expired); AF_STAT(prefix_oom);
	AF_STAT(tls_prefix_alloc); AF_STAT(tls_prefix_complete);
	AF_STAT(tls_prefix_budget_expired); AF_STAT(tls_prefix_oom);
	AF_STAT(tls_client_hello); AF_STAT(tls_sni_ok);
	AF_STAT(tls_sni_missing); AF_STAT(tls_ech_seen);
	AF_STAT(sni_candidates); AF_STAT(sni_rule_match);
	AF_STAT(sni_rule_no_match); AF_STAT(sni_priority_rule_match);
	AF_STAT(sni_prepass_match);
	AF_STAT(sni_pktseq_bypassed);
	AF_STAT(policy_hold_seen); AF_STAT(policy_hold_published);
	AF_STAT(appid1_flows);
	AF_STAT(terminal_generic_set); AF_STAT(terminal_generic_reentry);
	AF_STAT(terminal_generic_upgrade_attempt);
	AF_STAT(terminal_generic_upgrade_ok);
#undef AF_STAT
	return 0;
}

static int af_http_stats_open(struct inode *inode, struct file *file)
{
	return single_open(file, af_http_stats_show, NULL);
}

static const struct proc_ops af_http_stats_ops = {
	.proc_open = af_http_stats_open,
	.proc_read = seq_read,
	.proc_lseek = seq_lseek,
	.proc_release = single_release,
};

static int af_classify_recent_show(struct seq_file *m, void *v)
{
	unsigned int head, count, i, index;
	struct af_classify_recent r;

	spin_lock_bh(&af_classify_recent_lock);
	head = af_classify_recent_head;
	count = min_t(unsigned int, head, AF_CLASSIFY_RECENT_MAX);
	spin_unlock_bh(&af_classify_recent_lock);
	for (i = 0; i < count; i++) {
		index = (head - count + i) % AF_CLASSIFY_RECENT_MAX;
		spin_lock_bh(&af_classify_recent_lock);
		r = af_classify_recent[index];
		spin_unlock_bh(&af_classify_recent_lock);
		if (r.family == NFPROTO_IPV6)
			seq_printf(m, "flow=[%pI6c]:%u->[%pI6c]:%u ",
				   &r.src6, r.sport, &r.dst6, r.dport);
		else
			seq_printf(m, "flow=%pI4:%u->%pI4:%u ",
				   &r.src, r.sport, &r.dst, r.dport);
		seq_printf(m,
			   "proto=%u age_ms=%u "
			   "old_raw=0x%04x old_appid=%u terminal=%u "
			   "upgrade_attempt=%u upgrade_ok=%u new_appid=%u\n",
			   r.proto, jiffies_to_msecs(jiffies - r.when), r.old_raw,
			   r.old_appid, r.terminal, r.attempt, r.ok,
			   r.new_appid);
	}
	return 0;
}

static int af_classify_recent_open(struct inode *inode, struct file *file)
{
	return single_open(file, af_classify_recent_show, NULL);
}

static const struct proc_ops af_classify_recent_ops = {
	.proc_open = af_classify_recent_open,
	.proc_read = seq_read,
	.proc_lseek = seq_lseek,
	.proc_release = single_release,
};

static int af_http_match_recent_show(struct seq_file *m, void *v)
{
	unsigned int head, count, i, index;
	struct af_http_match_recent recent;

	spin_lock_bh(&af_http_match_recent_lock);
	head = af_http_match_recent_head;
	count = min_t(unsigned int, head, AF_HTTP_MATCH_RECENT_MAX);
	spin_unlock_bh(&af_http_match_recent_lock);
	for (i = 0; i < count; i++) {
		index = (head - count + i) % AF_HTTP_MATCH_RECENT_MAX;
		spin_lock_bh(&af_http_match_recent_lock);
		recent = af_http_match_recent[index];
		spin_unlock_bh(&af_http_match_recent_lock);
		seq_printf(m,
			   "flow=%pI4:%u->%pI4:%u proto=%u age_ms=%u "
			   "appid=%u kind=%u priority=%u field=%u fallback=%u "
			   "policy_priority=%u uri=%s host=%s ua=%s\n",
			   &recent.src, recent.sport, &recent.dst, recent.dport,
			   recent.proto,
			   jiffies_to_msecs(jiffies - recent.when), recent.appid,
			   recent.match_kind, recent.priority, recent.field,
			   recent.fallback, recent.policy_priority, recent.uri,
			   recent.host, recent.user_agent);
	}
	return 0;
}

static int af_http_match_recent_open(struct inode *inode, struct file *file)
{
	return single_open(file, af_http_match_recent_show, NULL);
}

static const struct proc_ops af_http_match_recent_ops = {
	.proc_open = af_http_match_recent_open,
	.proc_read = seq_read,
	.proc_lseek = seq_lseek,
	.proc_release = single_release,
};

static const char *af_sni_result_name(u8 result)
{
	switch (result) {
	case AF_SNI_OK:
		return "ok";
	case AF_SNI_ECH:
		return "ech";
	default:
		return "missing";
	}
}

static int af_sni_recent_show(struct seq_file *m, void *v)
{
	unsigned int head, count, i, index;
	struct af_sni_recent recent;

	spin_lock_bh(&af_sni_recent_lock);
	head = af_sni_recent_head;
	count = min_t(unsigned int, head, AF_SNI_RECENT_MAX);
	spin_unlock_bh(&af_sni_recent_lock);
	for (i = 0; i < count; i++) {
		index = (head - count + i) % AF_SNI_RECENT_MAX;
		spin_lock_bh(&af_sni_recent_lock);
		recent = af_sni_recent[index];
		spin_unlock_bh(&af_sni_recent_lock);
		if (recent.family == NFPROTO_IPV6)
			seq_printf(m,
				   "flow=[%pI6c]:%u->[%pI6c]:%u proto=%u age_ms=%u ",
				   &recent.src6, recent.sport, &recent.dst6,
				   recent.dport, recent.proto,
				   jiffies_to_msecs(jiffies - recent.when));
		else
			seq_printf(m,
				   "flow=%pI4:%u->%pI4:%u proto=%u age_ms=%u ",
				   &recent.src, recent.sport, &recent.dst,
				   recent.dport, recent.proto,
				   jiffies_to_msecs(jiffies - recent.when));
		seq_printf(m,
			   "prefix_len=%u record_len=%u result=%s sni=%s\n",
			   recent.prefix_len, recent.record_len,
			   af_sni_result_name(recent.result), recent.sni);
	}
	return 0;
}

static int af_sni_recent_open(struct inode *inode, struct file *file)
{
	return single_open(file, af_sni_recent_show, NULL);
}

static const struct proc_ops af_sni_recent_ops = {
	.proc_open = af_sni_recent_open,
	.proc_read = seq_read,
	.proc_lseek = seq_lseek,
	.proc_release = single_release,
};

static int af_sni_match_recent_show(struct seq_file *m, void *v)
{
	unsigned int head, count, i, index;
	struct af_sni_match_recent recent;

	spin_lock_bh(&af_sni_match_recent_lock);
	head = af_sni_match_recent_head;
	count = min_t(unsigned int, head, AF_SNI_MATCH_RECENT_MAX);
	spin_unlock_bh(&af_sni_match_recent_lock);
	for (i = 0; i < count; i++) {
		index = (head - count + i) % AF_SNI_MATCH_RECENT_MAX;
		spin_lock_bh(&af_sni_match_recent_lock);
		recent = af_sni_match_recent[index];
		spin_unlock_bh(&af_sni_match_recent_lock);
		if (recent.family == NFPROTO_IPV6)
			seq_printf(m,
				   "flow=[%pI6c]:%u->[%pI6c]:%u ",
				   &recent.src6, recent.sport, &recent.dst6,
				   recent.dport);
		else
			seq_printf(m, "flow=%pI4:%u->%pI4:%u ",
				   &recent.src, recent.sport, &recent.dst,
				   recent.dport);
		seq_printf(m,
			   "proto=%u age_ms=%u appid=%u kind=%u priority=%u "
			   "policy_priority=%u pkt_seq=%u pkt_seq_mask=0x%02x "
			   "sni=%s\n",
			   recent.proto,
			   jiffies_to_msecs(jiffies - recent.when), recent.appid,
			   recent.match_kind, recent.priority,
			   recent.policy_priority, recent.pkt_seq,
			   recent.pkt_seq_mask, recent.sni);
	}
	return 0;
}

static int af_sni_match_recent_open(struct inode *inode, struct file *file)
{
	return single_open(file, af_sni_match_recent_show, NULL);
}

static const struct proc_ops af_sni_match_recent_ops = {
	.proc_open = af_sni_match_recent_open,
	.proc_read = seq_read,
	.proc_lseek = seq_lseek,
	.proc_release = single_release,
};

static int __init app_filter_init(void)
{
	int err;
	err = af_conn_init();
	if (err)
		return err;
	err = af_log_init();
	if (err)
		goto err_conn;
	/* Terminal conntrack APPIDs carry a 13-bit profile epoch.  A random
	 * nonzero module-start value prevents stale secmarks surviving an unload
	 * or reboot from colliding with the next feature database. */
	g_feature_generation = get_random_u32();
	if (!(g_feature_generation & 0x1fffU))
		g_feature_generation++;
	af_feature_db_init(&af_feature_boot_db);
	af_feature_active = &af_feature_boot_db;
	/* Load the boot database synchronously. Live updates still use netlink,
	 * but initial classification must not depend on a later daemon timer. */
	if (load_feature_config() < 0 || g_feature_init == 0)
		pr_warn("oaf: no application features loaded at module start\n");
	err = af_register_dev();
	if (err)
		goto err_features;
	af_mac_list_init();
	af_whitelist_mac_init();

	af_init_app_status();
	err = init_af_client_procfs();
	if (err)
		goto err_procfs;
	err = af_client_init();
	if (err)
		goto err_procfs;
	/* Expose the reload socket only after the boot database and every object
	 * used by a reload are fully initialized. */
	err = netlink_oaf_init();
	if (err)
		goto err_client;
#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 3, 0)
	err = nf_register_net_hooks(&init_net, app_filter_ops, ARRAY_SIZE(app_filter_ops));
#else
	err = nf_register_hooks(app_filter_ops, ARRAY_SIZE(app_filter_ops));
#endif
	if (err)
	{
		AF_ERROR("oaf register filter hooks failed!\n");
		goto err_netlink;
	}
	af_http_stats_proc = proc_create("oaf_http_stats", 0444,
					 init_net.proc_net, &af_http_stats_ops);
	if (!af_http_stats_proc)
		pr_warn("oaf: cannot create /proc/net/oaf_http_stats\n");
	af_classify_recent_proc = proc_create("oaf_classify_recent", 0444,
					      init_net.proc_net,
					      &af_classify_recent_ops);
	if (!af_classify_recent_proc)
		pr_warn("oaf: cannot create /proc/net/oaf_classify_recent\n");
	af_http_match_recent_proc = proc_create("oaf_http_match_recent", 0444,
					       init_net.proc_net,
					       &af_http_match_recent_ops);
	if (!af_http_match_recent_proc)
		pr_warn("oaf: cannot create /proc/net/oaf_http_match_recent\n");
	af_sni_recent_proc = proc_create("oaf_sni_recent", 0444,
					init_net.proc_net, &af_sni_recent_ops);
	if (!af_sni_recent_proc)
		pr_warn("oaf: cannot create /proc/net/oaf_sni_recent\n");
	af_sni_match_recent_proc = proc_create("oaf_sni_match_recent", 0444,
					      init_net.proc_net,
					      &af_sni_match_recent_ops);
	if (!af_sni_match_recent_proc)
		pr_warn("oaf: cannot create /proc/net/oaf_sni_match_recent\n");
	init_oaf_maintenance_work();
	printk("oaf: Driver ver. %s - Copyright(c) 2019-2026, destan19(TT), <www.openappfilter.com>\n", AF_VERSION);
	printk("oaf: init ok\n");
	return 0;

err_netlink:
	/* Client work can report through oaf_sock. Stop its hooks and wait for
	 * every deferred callback before releasing the netlink socket. */
	af_client_exit();
	if (oaf_sock) {
		netlink_kernel_release(oaf_sock);
		oaf_sock = NULL;
	}
	goto err_procfs;
err_client:
	af_client_exit();
err_procfs:
	finit_af_client_procfs();
	af_mac_list_flush();
	af_whitelist_mac_flush();
	af_unregister_dev();
err_features:
	af_clean_feature_list();
	af_log_exit();
err_conn:
	af_conn_exit();
	return err;
}

static void app_filter_fini(void)
{
	AF_INFO("app filter module exit\n");
	if (af_http_stats_proc) {
		proc_remove(af_http_stats_proc);
		af_http_stats_proc = NULL;
	}
	if (af_classify_recent_proc) {
		proc_remove(af_classify_recent_proc);
		af_classify_recent_proc = NULL;
	}
	if (af_http_match_recent_proc) {
		proc_remove(af_http_match_recent_proc);
		af_http_match_recent_proc = NULL;
	}
	if (af_sni_recent_proc) {
		proc_remove(af_sni_recent_proc);
		af_sni_recent_proc = NULL;
	}
	if (af_sni_match_recent_proc) {
		proc_remove(af_sni_match_recent_proc);
		af_sni_match_recent_proc = NULL;
	}
	fini_oaf_maintenance_work();
#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 3, 0)
	nf_unregister_net_hooks(&init_net, app_filter_ops, ARRAY_SIZE(app_filter_ops));
#else
	nf_unregister_hooks(app_filter_ops, ARRAY_SIZE(app_filter_ops));
#endif
	/* Client work can report through oaf_sock. Unregister its packet hooks
	 * and synchronously stop/free it before releasing the socket. */
	af_client_exit();
	/* Stop reload messages before detaching active/staging databases. */
	if (oaf_sock) {
		netlink_kernel_release(oaf_sock);
		oaf_sock = NULL;
	}
	finit_af_client_procfs();
	af_clean_feature_list();
	af_mac_list_flush();
	af_whitelist_mac_flush();
	af_unregister_dev();
	af_log_exit();
	af_conn_exit();
	return;
}

module_init(app_filter_init);
module_exit(app_filter_fini);
