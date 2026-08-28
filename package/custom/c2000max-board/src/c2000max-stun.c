#define _POSIX_C_SOURCE 200809L

/*
 * Small RFC 3489 / RFC 5389 / RFC 5780 STUN diagnostic client.
 *
 * This is deliberately a one-shot utility: it opens no listening service and
 * consumes no memory or CPU when the LuCI diagnostics page is idle.
 */

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define STUN_BINDING_REQUEST 0x0001
#define STUN_BINDING_SUCCESS 0x0101
#define STUN_BINDING_ERROR   0x0111
#define STUN_MAGIC_COOKIE    0x2112a442U

#define ATTR_MAPPED_ADDRESS      0x0001
#define ATTR_CHANGE_REQUEST      0x0003
#define ATTR_CHANGED_ADDRESS     0x0005
#define ATTR_ERROR_CODE          0x0009
#define ATTR_XOR_MAPPED_ADDRESS  0x0020
#define ATTR_RESPONSE_ORIGIN     0x802b
#define ATTR_OTHER_ADDRESS       0x802c

#define CHANGE_PORT 0x02U
#define CHANGE_IP   0x04U

#define REQUEST_MAX 64
#define RESPONSE_MAX 2048
#define DEFAULT_PORT "3478"
#define TIMEOUT_MS 1200
#define RETRIES 2

struct endpoint {
	struct sockaddr_storage ss;
	socklen_t len;
	int present;
};

struct response {
	int ok;
	int error_code;
	char error_reason[128];
	struct endpoint mapped;
	struct endpoint other;
	struct endpoint changed;
	struct endpoint origin;
	struct endpoint peer;
	long rtt_ms;
};

static uint16_t get16(const unsigned char *p)
{
	return (uint16_t)(((uint16_t)p[0] << 8) | p[1]);
}

static uint32_t get32(const unsigned char *p)
{
	return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
	       ((uint32_t)p[2] << 8) | p[3];
}

static void put16(unsigned char *p, uint16_t value)
{
	p[0] = (unsigned char)(value >> 8);
	p[1] = (unsigned char)value;
}

static void put32(unsigned char *p, uint32_t value)
{
	p[0] = (unsigned char)(value >> 24);
	p[1] = (unsigned char)(value >> 16);
	p[2] = (unsigned char)(value >> 8);
	p[3] = (unsigned char)value;
}

static long monotonic_ms(void)
{
	struct timespec ts;

	if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
		return 0;
	return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

static int random_bytes(unsigned char *buf, size_t len)
{
	int fd;
	size_t done = 0;

	fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
	if (fd >= 0) {
		while (done < len) {
			ssize_t n = read(fd, buf + done, len - done);
			if (n <= 0)
				break;
			done += (size_t)n;
		}
		close(fd);
	}
	if (done == len)
		return 0;

	srand((unsigned int)(time(NULL) ^ getpid() ^ monotonic_ms()));
	while (done < len)
		buf[done++] = (unsigned char)(rand() & 0xff);
	return 0;
}

static int endpoint_family(const struct endpoint *ep)
{
	return ep->present ? ((const struct sockaddr *)&ep->ss)->sa_family : AF_UNSPEC;
}

static uint16_t endpoint_port(const struct endpoint *ep)
{
	if (!ep->present)
		return 0;
	if (endpoint_family(ep) == AF_INET)
		return ntohs(((const struct sockaddr_in *)&ep->ss)->sin_port);
	if (endpoint_family(ep) == AF_INET6)
		return ntohs(((const struct sockaddr_in6 *)&ep->ss)->sin6_port);
	return 0;
}

static void endpoint_set_port(struct endpoint *ep, uint16_t port)
{
	if (endpoint_family(ep) == AF_INET)
		((struct sockaddr_in *)&ep->ss)->sin_port = htons(port);
	else if (endpoint_family(ep) == AF_INET6)
		((struct sockaddr_in6 *)&ep->ss)->sin6_port = htons(port);
}

static int endpoint_same_ip(const struct endpoint *a, const struct endpoint *b)
{
	if (!a->present || !b->present || endpoint_family(a) != endpoint_family(b))
		return 0;
	if (endpoint_family(a) == AF_INET) {
		const struct sockaddr_in *sa = (const struct sockaddr_in *)&a->ss;
		const struct sockaddr_in *sb = (const struct sockaddr_in *)&b->ss;
		return sa->sin_addr.s_addr == sb->sin_addr.s_addr;
	}
	if (endpoint_family(a) == AF_INET6) {
		const struct sockaddr_in6 *sa = (const struct sockaddr_in6 *)&a->ss;
		const struct sockaddr_in6 *sb = (const struct sockaddr_in6 *)&b->ss;
		return memcmp(&sa->sin6_addr, &sb->sin6_addr,
		              sizeof(sa->sin6_addr)) == 0;
	}
	return 0;
}

static int endpoint_same(const struct endpoint *a, const struct endpoint *b)
{
	return endpoint_same_ip(a, b) && endpoint_port(a) == endpoint_port(b);
}

static void endpoint_copy(struct endpoint *dst, const struct sockaddr *src,
                          socklen_t len)
{
	memset(dst, 0, sizeof(*dst));
	if (!src || len > sizeof(dst->ss))
		return;
	memcpy(&dst->ss, src, len);
	dst->len = len;
	dst->present = 1;
}

static const char *endpoint_text(const struct endpoint *ep, char *buf,
                                 size_t buflen)
{
	char address[INET6_ADDRSTRLEN];
	const void *src;

	if (!ep->present) {
		if (buflen) buf[0] = 0;
		return buf;
	}
	if (endpoint_family(ep) == AF_INET)
		src = &((const struct sockaddr_in *)&ep->ss)->sin_addr;
	else if (endpoint_family(ep) == AF_INET6)
		src = &((const struct sockaddr_in6 *)&ep->ss)->sin6_addr;
	else {
		if (buflen) buf[0] = 0;
		return buf;
	}
	if (!inet_ntop(endpoint_family(ep), src, address, sizeof(address))) {
		if (buflen) buf[0] = 0;
		return buf;
	}
	if (endpoint_family(ep) == AF_INET6)
		snprintf(buf, buflen, "[%s]:%u", address, endpoint_port(ep));
	else
		snprintf(buf, buflen, "%s:%u", address, endpoint_port(ep));
	return buf;
}

static void json_string(const char *s)
{
	const unsigned char *p = (const unsigned char *)(s ? s : "");
	putchar('"');
	for (; *p; p++) {
		switch (*p) {
		case '"': fputs("\\\"", stdout); break;
		case '\\': fputs("\\\\", stdout); break;
		case '\b': fputs("\\b", stdout); break;
		case '\f': fputs("\\f", stdout); break;
		case '\n': fputs("\\n", stdout); break;
		case '\r': fputs("\\r", stdout); break;
		case '\t': fputs("\\t", stdout); break;
		default:
			if (*p < 0x20)
				printf("\\u%04x", *p);
			else
				putchar(*p);
		}
	}
	putchar('"');
}

static int split_server(const char *spec, char *host, size_t hostlen,
                        char *port, size_t portlen)
{
	const char *last_colon;
	size_t n;

	if (!spec || !*spec)
		return -1;
	if (spec[0] == '[') {
		const char *end = strchr(spec + 1, ']');
		if (!end)
			return -1;
		n = (size_t)(end - spec - 1);
		if (n == 0 || n >= hostlen)
			return -1;
		memcpy(host, spec + 1, n);
		host[n] = 0;
		if (end[1] == ':' && end[2])
			snprintf(port, portlen, "%s", end + 2);
		else if (!end[1])
			snprintf(port, portlen, "%s", DEFAULT_PORT);
		else
			return -1;
		return 0;
	}

	last_colon = strrchr(spec, ':');
	if (last_colon && strchr(spec, ':') == last_colon) {
		n = (size_t)(last_colon - spec);
		if (n == 0 || n >= hostlen || !last_colon[1])
			return -1;
		memcpy(host, spec, n);
		host[n] = 0;
		snprintf(port, portlen, "%s", last_colon + 1);
	} else {
		if (strlen(spec) >= hostlen)
			return -1;
		snprintf(host, hostlen, "%s", spec);
		snprintf(port, portlen, "%s", DEFAULT_PORT);
	}
	return 0;
}

static int resolve_server(const char *spec, int family, struct endpoint *server,
                          char *error, size_t errorlen)
{
	char host[256];
	char port[16];
	struct addrinfo hints;
	struct addrinfo *results = NULL;
	struct addrinfo *it;
	int rc;

	if (split_server(spec, host, sizeof(host), port, sizeof(port)) != 0) {
		snprintf(error, errorlen, "invalid_server");
		return -1;
	}
	memset(&hints, 0, sizeof(hints));
	hints.ai_family = family;
	hints.ai_socktype = SOCK_DGRAM;
	hints.ai_protocol = IPPROTO_UDP;
	rc = getaddrinfo(host, port, &hints, &results);
	if (rc != 0) {
		snprintf(error, errorlen, "dns_no_%s_address",
		         family == AF_INET6 ? "ipv6" : "ipv4");
		return -1;
	}
	for (it = results; it; it = it->ai_next) {
		if (it->ai_addrlen <= sizeof(server->ss)) {
			endpoint_copy(server, it->ai_addr, it->ai_addrlen);
			break;
		}
	}
	freeaddrinfo(results);
	if (!server->present) {
		snprintf(error, errorlen, "dns_no_%s_address",
		         family == AF_INET6 ? "ipv6" : "ipv4");
		return -1;
	}
	return 0;
}

static int parse_address_attr(const unsigned char *p, size_t len, int xored,
                              const unsigned char txid[12], struct endpoint *ep)
{
	uint16_t port;
	unsigned char address[16];
	int family;
	size_t address_len;

	if (len < 4)
		return -1;
	family = p[1] == 0x01 ? AF_INET : (p[1] == 0x02 ? AF_INET6 : AF_UNSPEC);
	address_len = family == AF_INET ? 4 : (family == AF_INET6 ? 16 : 0);
	if (!address_len || len < 4 + address_len)
		return -1;
	port = get16(p + 2);
	memcpy(address, p + 4, address_len);
	if (xored) {
		static const unsigned char cookie[4] = { 0x21, 0x12, 0xa4, 0x42 };
		size_t i;
		port ^= (uint16_t)(STUN_MAGIC_COOKIE >> 16);
		for (i = 0; i < address_len; i++)
			address[i] ^= i < 4 ? cookie[i] : txid[i - 4];
	}
	memset(ep, 0, sizeof(*ep));
	if (family == AF_INET) {
		struct sockaddr_in *sa = (struct sockaddr_in *)&ep->ss;
		sa->sin_family = AF_INET;
		sa->sin_port = htons(port);
		memcpy(&sa->sin_addr, address, 4);
		ep->len = sizeof(*sa);
	} else {
		struct sockaddr_in6 *sa = (struct sockaddr_in6 *)&ep->ss;
		sa->sin6_family = AF_INET6;
		sa->sin6_port = htons(port);
		memcpy(&sa->sin6_addr, address, 16);
		ep->len = sizeof(*sa);
	}
	ep->present = 1;
	return 0;
}

static int parse_response(const unsigned char *buf, size_t len,
                          const unsigned char txid[12], struct response *out)
{
	size_t end;
	size_t pos;
	uint16_t message_type;

	if (len < 20 || get32(buf + 4) != STUN_MAGIC_COOKIE ||
	    memcmp(buf + 8, txid, 12) != 0)
		return -1;
	end = 20U + get16(buf + 2);
	if (end > len)
		return -1;
	message_type = get16(buf);
	if (message_type != STUN_BINDING_SUCCESS &&
	    message_type != STUN_BINDING_ERROR)
		return -1;

	for (pos = 20; pos + 4 <= end;) {
		uint16_t type = get16(buf + pos);
		uint16_t attr_len = get16(buf + pos + 2);
		const unsigned char *value = buf + pos + 4;
		size_t next = pos + 4U + ((attr_len + 3U) & ~3U);
		if (pos + 4U + attr_len > end || next > end)
			return -1;
		switch (type) {
		case ATTR_XOR_MAPPED_ADDRESS:
			parse_address_attr(value, attr_len, 1, txid, &out->mapped);
			break;
		case ATTR_MAPPED_ADDRESS:
			if (!out->mapped.present)
				parse_address_attr(value, attr_len, 0, txid, &out->mapped);
			break;
		case ATTR_OTHER_ADDRESS:
			parse_address_attr(value, attr_len, 0, txid, &out->other);
			break;
		case ATTR_CHANGED_ADDRESS:
			parse_address_attr(value, attr_len, 0, txid, &out->changed);
			break;
		case ATTR_RESPONSE_ORIGIN:
			parse_address_attr(value, attr_len, 0, txid, &out->origin);
			break;
		case ATTR_ERROR_CODE:
			if (attr_len >= 4) {
				size_t reason_len = attr_len - 4;
				out->error_code = (value[2] & 0x07) * 100 + value[3];
				if (reason_len >= sizeof(out->error_reason))
					reason_len = sizeof(out->error_reason) - 1;
				memcpy(out->error_reason, value + 4, reason_len);
				out->error_reason[reason_len] = 0;
			}
			break;
		default:
			break;
		}
		pos = next;
	}
	out->ok = message_type == STUN_BINDING_SUCCESS && out->mapped.present;
	return 0;
}

static int stun_exchange(int fd, const struct endpoint *destination,
                         uint32_t change, struct response *response)
{
	unsigned char request[REQUEST_MAX];
	unsigned char reply[RESPONSE_MAX];
	unsigned char txid[12];
	size_t request_len = 20;
	int attempt;
	long started = monotonic_ms();

	memset(response, 0, sizeof(*response));
	memset(request, 0, sizeof(request));
	random_bytes(txid, sizeof(txid));
	put16(request, STUN_BINDING_REQUEST);
	put32(request + 4, STUN_MAGIC_COOKIE);
	memcpy(request + 8, txid, sizeof(txid));
	if (change) {
		put16(request + 20, ATTR_CHANGE_REQUEST);
		put16(request + 22, 4);
		put32(request + 24, change);
		request_len = 28;
	}
	put16(request + 2, (uint16_t)(request_len - 20));

	for (attempt = 0; attempt < RETRIES; attempt++) {
		long deadline;
		if (sendto(fd, request, request_len, 0,
		           (const struct sockaddr *)&destination->ss,
		           destination->len) < 0)
			continue;
		deadline = monotonic_ms() + TIMEOUT_MS;
		for (;;) {
			struct pollfd pfd;
			long remaining = deadline - monotonic_ms();
			struct sockaddr_storage peer;
			socklen_t peer_len = sizeof(peer);
			ssize_t n;
			if (remaining <= 0)
				break;
			pfd.fd = fd;
			pfd.events = POLLIN;
			pfd.revents = 0;
			if (poll(&pfd, 1, (int)remaining) <= 0)
				break;
			n = recvfrom(fd, reply, sizeof(reply), 0,
			             (struct sockaddr *)&peer, &peer_len);
			if (n < 0)
				continue;
			if (parse_response(reply, (size_t)n, txid, response) != 0)
				continue;
			endpoint_copy(&response->peer, (struct sockaddr *)&peer, peer_len);
			response->rtt_ms = monotonic_ms() - started;
			return response->ok ? 0 : -1;
		}
	}
	response->rtt_ms = monotonic_ms() - started;
	snprintf(response->error_reason, sizeof(response->error_reason), "timeout");
	return -1;
}

static int socket_for_server(const struct endpoint *server, int *fd_out,
                             struct endpoint *local, char *error,
                             size_t errorlen)
{
	int fd;
	int probe;
	struct sockaddr_storage ss;
	socklen_t len = sizeof(ss);

	fd = socket(endpoint_family(server), SOCK_DGRAM | SOCK_CLOEXEC, IPPROTO_UDP);
	if (fd < 0) {
		snprintf(error, errorlen, "socket_failed");
		return -1;
	}
	if (endpoint_family(server) == AF_INET) {
		struct sockaddr_in bind_addr;
		memset(&bind_addr, 0, sizeof(bind_addr));
		bind_addr.sin_family = AF_INET;
		if (bind(fd, (struct sockaddr *)&bind_addr, sizeof(bind_addr)) != 0) {
			close(fd);
			snprintf(error, errorlen, "bind_failed");
			return -1;
		}
	} else {
		struct sockaddr_in6 bind_addr;
		memset(&bind_addr, 0, sizeof(bind_addr));
		bind_addr.sin6_family = AF_INET6;
		if (bind(fd, (struct sockaddr *)&bind_addr, sizeof(bind_addr)) != 0) {
			close(fd);
			snprintf(error, errorlen, "bind_failed");
			return -1;
		}
	}
	if (getsockname(fd, (struct sockaddr *)&ss, &len) != 0) {
		close(fd);
		snprintf(error, errorlen, "getsockname_failed");
		return -1;
	}
	endpoint_copy(local, (struct sockaddr *)&ss, len);

	/* Determine the route-selected source address without connecting the
	 * diagnostic socket, which must remain able to receive changed-address
	 * responses from RFC 3489/5780 servers. */
	probe = socket(endpoint_family(server), SOCK_DGRAM | SOCK_CLOEXEC, IPPROTO_UDP);
	if (probe >= 0 && connect(probe, (const struct sockaddr *)&server->ss,
	                          server->len) == 0) {
		len = sizeof(ss);
		if (getsockname(probe, (struct sockaddr *)&ss, &len) == 0) {
			uint16_t port = endpoint_port(local);
			endpoint_copy(local, (struct sockaddr *)&ss, len);
			endpoint_set_port(local, port);
		}
	}
	if (probe >= 0)
		close(probe);
	*fd_out = fd;
	return 0;
}

static const struct endpoint *response_source(const struct response *response)
{
	return response->origin.present ? &response->origin : &response->peer;
}

static int response_changed_as_requested(const struct response *response,
                                         const struct endpoint *primary,
                                         uint32_t change)
{
	const struct endpoint *source = response_source(response);
	int ip_changed = !endpoint_same_ip(source, primary);
	int port_changed = endpoint_port(source) != endpoint_port(primary);

	if (!response->ok)
		return 0;
	if ((change & CHANGE_IP) && !ip_changed)
		return 0;
	if (!(change & CHANGE_IP) && ip_changed)
		return 0;
	if ((change & CHANGE_PORT) && !port_changed)
		return 0;
	return 1;
}

static void emit_failure(const char *family, const char *server,
                         const char *code, const char *detail)
{
	fputs("{\"success\":false,\"family\":", stdout);
	json_string(family);
	fputs(",\"server\":", stdout);
	json_string(server);
	fputs(",\"error\":", stdout);
	json_string(code);
	fputs(",\"detail\":", stdout);
	json_string(detail ? detail : "");
	fputs("}\n", stdout);
}

static int run_test(int family, const char *server_spec)
{
	struct endpoint primary;
	struct endpoint local;
	struct endpoint alternate;
	struct endpoint mapping_test2;
	struct response first;
	struct response classic_change;
	struct response classic_alt;
	struct response classic_port;
	struct response map2;
	struct response map3;
	struct response filter_both;
	struct response filter_port;
	char error[128] = "";
	char primary_text[128];
	char local_text[128];
	char mapped_text[128];
	const char *family_name = family == AF_INET6 ? "ipv6" : "ipv4";
	const char *classic_code = "unavailable";
	const char *mapping_code = "unavailable";
	const char *filtering_code = "unavailable";
	int classic_available = 0;
	int behavior_available = 0;
	int nat_present;
	int fd = -1;

	memset(&primary, 0, sizeof(primary));
	memset(&local, 0, sizeof(local));
	memset(&alternate, 0, sizeof(alternate));
	memset(&mapping_test2, 0, sizeof(mapping_test2));
	memset(&classic_change, 0, sizeof(classic_change));
	memset(&classic_alt, 0, sizeof(classic_alt));
	memset(&classic_port, 0, sizeof(classic_port));
	memset(&map2, 0, sizeof(map2));
	memset(&map3, 0, sizeof(map3));
	memset(&filter_both, 0, sizeof(filter_both));
	memset(&filter_port, 0, sizeof(filter_port));

	if (resolve_server(server_spec, family, &primary, error, sizeof(error)) != 0) {
		emit_failure(family_name, server_spec, error, "");
		return 2;
	}
	if (socket_for_server(&primary, &fd, &local, error, sizeof(error)) != 0) {
		emit_failure(family_name, server_spec, error, strerror(errno));
		return 2;
	}
	if (stun_exchange(fd, &primary, 0, &first) != 0) {
		close(fd);
		emit_failure(family_name, server_spec,
		             first.error_reason[0] ? first.error_reason : "stun_failed",
		             first.error_code ? "stun_error_response" : "");
		return 3;
	}
	nat_present = !endpoint_same(&local, &first.mapped);

	/* RFC 3489 classic classification. RFC 5780 OTHER-ADDRESS is accepted
	 * as the modern equivalent of CHANGED-ADDRESS. */
	if (first.changed.present)
		alternate = first.changed;
	else if (first.other.present)
		alternate = first.other;
	if (alternate.present) {
		stun_exchange(fd, &primary, CHANGE_IP | CHANGE_PORT, &classic_change);
		if (response_changed_as_requested(&classic_change, &primary,
		                                  CHANGE_IP | CHANGE_PORT)) {
			classic_available = 1;
			classic_code = nat_present ? "full_cone_nat" : "open_internet";
		} else if (!nat_present) {
			classic_available = 1;
			classic_code = "symmetric_udp_firewall";
		} else if (stun_exchange(fd, &alternate, 0, &classic_alt) == 0) {
			classic_available = 1;
			if (!endpoint_same(&first.mapped, &classic_alt.mapped)) {
				classic_code = "symmetric_nat";
			} else {
				stun_exchange(fd, &primary, CHANGE_PORT, &classic_port);
				classic_code = response_changed_as_requested(&classic_port,
				                                             &primary, CHANGE_PORT) ?
				               "restricted_cone_nat" :
				               "port_restricted_cone_nat";
			}
		}
	}

	/* RFC 5780 behavior discovery requires both RESPONSE-ORIGIN and
	 * OTHER-ADDRESS. Servers which merely answer Binding requests are not
	 * reported as if they had supplied a complete NAT classification. */
	if (first.origin.present && first.other.present &&
	    endpoint_family(&first.origin) == family &&
	    endpoint_family(&first.other) == family) {
		mapping_test2 = first.other;
		endpoint_set_port(&mapping_test2, endpoint_port(&first.origin));
		if (stun_exchange(fd, &mapping_test2, 0, &map2) == 0 &&
		    stun_exchange(fd, &first.other, 0, &map3) == 0) {
			behavior_available = 1;
			if (endpoint_same(&first.mapped, &map2.mapped))
				mapping_code = "endpoint_independent";
			else if (endpoint_same(&map2.mapped, &map3.mapped))
				mapping_code = "address_dependent";
			else
				mapping_code = "address_port_dependent";
		}

		stun_exchange(fd, &primary, CHANGE_IP | CHANGE_PORT, &filter_both);
		if (response_changed_as_requested(&filter_both, &primary,
		                                  CHANGE_IP | CHANGE_PORT)) {
			filtering_code = "endpoint_independent";
		} else {
			stun_exchange(fd, &primary, CHANGE_PORT, &filter_port);
			filtering_code = response_changed_as_requested(&filter_port,
			                                              &primary, CHANGE_PORT) ?
			                 "address_dependent" :
			                 "address_port_dependent";
		}
	}
	close(fd);

	fputs("{\"success\":true,\"family\":", stdout);
	json_string(family_name);
	fputs(",\"server\":", stdout);
	json_string(server_spec);
	fputs(",\"server_address\":", stdout);
	json_string(endpoint_text(&primary, primary_text, sizeof(primary_text)));
	fputs(",\"local_endpoint\":", stdout);
	json_string(endpoint_text(&local, local_text, sizeof(local_text)));
	fputs(",\"public_endpoint\":", stdout);
	json_string(endpoint_text(&first.mapped, mapped_text, sizeof(mapped_text)));
	printf(",\"rtt_ms\":%ld,\"nat_present\":%s",
	       first.rtt_ms, nat_present ? "true" : "false");
	fputs(",\"rfc3489\":{\"available\":", stdout);
	fputs(classic_available ? "true" : "false", stdout);
	fputs(",\"type\":", stdout);
	json_string(classic_code);
	fputs("},\"rfc5780\":{\"available\":", stdout);
	fputs(behavior_available ? "true" : "false", stdout);
	fputs(",\"mapping\":", stdout);
	json_string(mapping_code);
	fputs(",\"filtering\":", stdout);
	json_string(behavior_available ? filtering_code : "unavailable");
	fputs(",\"other_address\":", stdout);
	json_string(endpoint_text(&first.other, primary_text, sizeof(primary_text)));
	fputs("}}\n", stdout);
	return 0;
}

static int validate_address(const char *family_name, const char *address)
{
	unsigned char binary[sizeof(struct in6_addr)];
	int family;

	if (!strcmp(family_name, "ipv4"))
		family = AF_INET;
	else if (!strcmp(family_name, "ipv6"))
		family = AF_INET6;
	else
		return 1;
	return inet_pton(family, address, binary) == 1 ? 0 : 1;
}

static void usage(const char *program)
{
	fprintf(stderr, "Usage: %s -4|-6 host[:port]\n"
	                "       %s --validate-address ipv4|ipv6 address\n",
	        program, program);
}

int main(int argc, char **argv)
{
	int family;

	if (argc == 4 && !strcmp(argv[1], "--validate-address"))
		return validate_address(argv[2], argv[3]);
	if (argc != 3) {
		usage(argv[0]);
		return 1;
	}
	if (!strcmp(argv[1], "-4"))
		family = AF_INET;
	else if (!strcmp(argv[1], "-6"))
		family = AF_INET6;
	else {
		usage(argv[0]);
		return 1;
	}
	return run_test(family, argv[2]);
}
