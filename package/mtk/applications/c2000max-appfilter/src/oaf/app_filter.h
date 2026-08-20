/*
 * Based on OpenAppFilter by destan19 (https://www.openappfilter.com).
 * Modified for C2000MAX on 2026-08-18: acceleration-safe APP_ID tagging.
 */
#ifndef APP_FILTER_H
#define APP_FILTER_H

#define AF_VERSION "5.3.3-c2000max10-ikv4.2"
#define AF_FEATURE_CONFIG_FILE "/tmp/feature.cfg"

#define DEFAULT_DPI_PKT_NUM 8
#define MAX_DPI_PKT_NUM 64
#define OAF_UNKNOWN_APPID 1
#define OAF_ACCEL_BYPASS_MARK 0x00800000
#define MIN_HTTP_DATA_LEN 16
#define MAX_APP_NAME_LEN 64
#define MAX_FEATURE_NUM_PER_APP 512
#define MAX_FEATURE_NUM_TOTAL 32768
#define MIN_FEATURE_STR_LEN 8
#define MAX_LEGACY_FEATURE_STR_LEN 128
#define MAX_FEATURE_STR_LEN 512
#define MAX_HOST_URL_LEN 128
#define MAX_REQUEST_URL_LEN 128
#define MAX_FEATURE_BITS 16
#define MAX_POS_INFO_PER_FEATURE 16
#define MAX_FEATURE_LINE_LEN 600
#define MIN_FEATURE_LINE_LEN 16
#define MAX_URL_MATCH_LEN 256
#define MAX_BYPASS_DPI_PKT_LEN 600
#define MAX_AF_MAC_HASH_SIZE 64

#define HTTP_GET_METHOD_STR "GET"
#define HTTP_POST_METHOD_STR "POST"
#define HTTP_HEADER "HTTP"
#define NIPQUAD(addr) \
	((unsigned char *)&addr)[0], \
	((unsigned char *)&addr)[1], \
	((unsigned char *)&addr)[2], \
	((unsigned char *)&addr)[3]
#define NIPQUAD_FMT "%u.%u.%u.%u"
#define MAC_ARRAY(a) (a)[0], (a)[1], (a)[2], (a)[3], (a)[4], (a)[5]
#define MAC_FMT "%02x:%02x:%02x:%02x:%02x:%02x"

#define AF_TRUE 1
#define AF_FALSE 0

#define AF_MAX_APP_TYPE_NUM 32
#define AF_MAX_APP_ID_NUM 512
#define AF_APP_TYPE(a) (a) / 1000
#define AF_APP_ID(a) (a) % 1000
#define AF_APP_TYPE_INDEX(a) (AF_APP_TYPE(a) - 1)
#define AF_APP_ID_INDEX(a) (AF_APP_ID(a) - 1)
#define MAC_ADDR_LEN      		6

static inline int af_appid_valid(int appid)
{
	int type = AF_APP_TYPE(appid);
	int id = AF_APP_ID(appid);

	return type >= 1 && type <= AF_MAX_APP_TYPE_NUM &&
		id >= 1 && id <= AF_MAX_APP_ID_NUM;
}

#define HTTPS_URL_OFFSET		9
#define HTTPS_LEN_OFFSET		7

#define MAX_SEARCH_STR_LEN 32
#define MAX_IK_PATTERN_LEN 124
#define AF_HTTP_FIELD_COUNT 16
#define AF_HTTP_MAX_CLAUSES 4

/* IKprotocol direction values are kept verbatim in v4 feature records. */
enum af_ik_direction {
	AF_IK_DIR_BOTH = 0,
	AF_IK_DIR_ORIGINAL = 1,
	AF_IK_DIR_REPLY = 2,
};

enum af_ik_match_kind {
	AF_IK_MATCH_LEGACY = 0,
	AF_IK_MATCH_PORT,
	AF_IK_MATCH_URL,
	AF_IK_MATCH_EXACT,
	AF_IK_MATCH_BM,
	AF_IK_MATCH_REGEX,
	AF_IK_MATCH_SNI_EXACT,
	AF_IK_MATCH_SNI_BM,
	AF_IK_MATCH_SNI_REGEX,
	AF_IK_MATCH_TLS_EXACT,
	AF_IK_MATCH_TLS_BM,
	AF_IK_MATCH_TLS_REGEX,
	AF_IK_MATCH_HTTP_HOST_EXACT,
	AF_IK_MATCH_HTTP_HOST_BM,
	AF_IK_MATCH_HTTP_HOST_REGEX,
	AF_IK_MATCH_HTTP_REQUEST_EXACT,
	AF_IK_MATCH_HTTP_REQUEST_BM,
	AF_IK_MATCH_HTTP_REQUEST_REGEX,
	AF_IK_MATCH_HTTP_MULTI,
};

struct ik_regex;

enum af_http_clause_method {
	AF_HTTP_CLAUSE_EXACT = 0,
	AF_HTTP_CLAUSE_BM = 1,
	AF_HTTP_CLAUSE_REGEX = 2,
};

struct af_http_clause {
	u_int8_t field;
	u_int8_t method;
	u_int8_t pattern_offset;
	u_int8_t pattern_len;
	struct ik_regex *regex;
};

enum AF_FEATURE_PARAM_INDEX{
	AF_PROTO_PARAM_INDEX,
	AF_SRC_PORT_PARAM_INDEX,
	AF_DST_PORT_PARAM_INDEX,
	AF_HOST_URL_PARAM_INDEX,
	AF_REQUEST_URL_PARAM_INDEX,
	AF_DICT_PARAM_INDEX,
	AF_STR_PARAM_INDEX,
	AF_IGNORE_PARAM_INDEX,
};


#define OAF_NETLINK_ID 29
#define MAX_OAF_NL_MSG_LEN 1024

enum E_MSG_TYPE{
	AF_MSG_INIT,
	AF_MSG_ADD_FEATURE,
	AF_MSG_RELOAD_BEGIN,
	AF_MSG_RELOAD_COMMIT,
	AF_MSG_MAX
};
enum AF_WORK_MODE {
	AF_MODE_GATEWAY,
	AF_MODE_BYPASS,
	AF_MODE_BRIDGE,
};
#define MAX_AF_MSG_DATA_LEN 800
typedef struct af_msg{
	int action;
}af_msg_t;

typedef struct af_reload_commit_msg {
	af_msg_t hdr;
	u_int32_t expected_count;
} af_reload_commit_msg_t;

struct af_msg_hdr{
    int magic;
    int len;
};

enum e_http_method{
	HTTP_METHOD_GET = 1,
	HTTP_METHOD_POST,
};
typedef struct http_proto{
	int match;
	int method;
	char *url_pos;
	int url_len;
	char *host_pos;
	int host_len;
	char *data_pos;
	int data_len;
	char *field_pos[AF_HTTP_FIELD_COUNT];
	u_int16_t field_len[AF_HTTP_FIELD_COUNT];
}http_proto_t;

typedef struct https_proto{
	int match;
	char *url_pos;
	int url_len;
}https_proto_t;




typedef struct af_pos_info{
	int pos;
	unsigned char value;
}af_pos_info_t;

#define MAX_PORT_RANGE_NUM 9

typedef struct range_value
{
	int not ;
	int start;
	int end;
} range_value_t;

typedef struct port_info
{
	u_int8_t mode; // 0: match, 1: not match
	int num;
	range_value_t range_list[MAX_PORT_RANGE_NUM];
} port_info_t;

typedef struct af_feature_node{
	struct list_head  		head;
	u_int32_t app_id;
	char app_name[MAX_APP_NAME_LEN];
	char feature[MAX_FEATURE_STR_LEN];
	u_int32_t proto;
	u_int32_t sport;
	u_int32_t dport;
	port_info_t dport_info;
	char host_url[MAX_HOST_URL_LEN];
	char request_url[MAX_REQUEST_URL_LEN];
	int pos_num;
	char search_str[MAX_SEARCH_STR_LEN];
	int ignore;
	af_pos_info_t pos_info[MAX_POS_INFO_PER_FEATURE];
	u_int8_t feature_version;
	u_int8_t direction;
	s8 pkt_seq;
	u_int8_t pkt_seq_mask;
	u_int8_t match_kind;
	s16 match_offset;
	u_int8_t priority;
	u_int16_t specificity;
	u_int32_t load_order;
	u_int8_t pattern_len;
	u_int8_t pattern[MAX_IK_PATTERN_LEN];
	u_int8_t prefilter_valid;
	u_int8_t prefilter_byte;
	port_info_t payload_len_info;
	u_int32_t server_addr;
	u_int32_t server_mask;
	u_int8_t fallback;
	struct ik_regex *native_regex;
	u_int8_t http_clause_count;
	struct af_http_clause http_clauses[AF_HTTP_MAX_CLAUSES];
}af_feature_node_t;




typedef struct flow_info{
	struct nf_conn *ct;
	u_int32_t src;
	u_int32_t dst;
	struct in6_addr *src6;
	struct in6_addr *dst6;
	int l4_protocol;
	u_int16_t sport;
	u_int16_t dport;
	unsigned char *l4_data;
	int l4_len;
	http_proto_t http;
	https_proto_t https;
	u_int32_t app_id;
	u_int8_t app_name[MAX_APP_NAME_LEN];
	u_int8_t drop;
	u_int8_t ignore;
	u_int8_t dir;
	u_int8_t pkt_seq;
	u_int8_t fallback;
	u_int16_t total_len;
	u_int8_t client_hello;
	char matched_feature[MAX_FEATURE_STR_LEN];
}flow_info_t;



int regexp_match(char *reg, char *text);
int hash_mac(unsigned char *mac);
char *ipv6_to_str(const struct in6_addr *addr, char *str);
int af_send_msg_to_user(char *pbuf, uint16_t len);

#endif
