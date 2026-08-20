/* SPDX-License-Identifier: GPL-2.0 */
#ifndef OAF_IK_REGEX_H
#define OAF_IK_REGEX_H

#include <linux/types.h>

struct ik_regex;

/*
 * Compile and execute the bounded, byte-oriented IKprotocol regex subset.
 * Both pattern and input are length-delimited, so embedded NUL bytes are
 * ordinary data.  The compiler accepts ^ $ . [] [^] () | * + ?, escaped
 * metacharacters, \xNN, ASCII \d/\s/\w classes (and their inverses), \b/\B
 * word boundaries, and \r/\n/\t/\f/\v.  Backreferences/lookaround are
 * intentionally not part of the dialect.
 */
#define IK_REGEX_PACKET_STEP_BUDGET 65536U

int ik_regex_compile(const u8 *pattern, size_t len, struct ik_regex **result);
bool ik_regex_match(const struct ik_regex *regex, const u8 *data, size_t len,
		    u32 *step_budget);
bool ik_regex_prefilter_byte(const struct ik_regex *regex, u8 *value);
void ik_regex_free(struct ik_regex *regex);

#endif
