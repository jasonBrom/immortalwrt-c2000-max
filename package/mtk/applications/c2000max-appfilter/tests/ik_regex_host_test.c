#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ik_regex.h"

struct regex_case {
	const char *name;
	const char *pattern;
	const char *input;
	int expected;
};

static const struct regex_case cases[] = {
	{
		"bilibili live URI",
		"live-bvc.*.m4s",
		"/live-bvc/569553/live_test/620088691.m4s?token=test",
		1,
	},
	{
		"bilibili video host",
		"\\.(acg|bili)video.com$",
		"upos-sz-estghw.bilivideo.com",
		1,
	},
	{
		"bilibili hdslb host",
		"\\.hdslb.com$",
		"i2.hdslb.com",
		1,
	},
	{
		"unrelated m4s",
		"live-bvc.*.m4s",
		"/video/foo.m4s",
		0,
	},
};

int main(void)
{
	size_t i;

	for (i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
		struct ik_regex *regex = NULL;
		u32 budget = IK_REGEX_PACKET_STEP_BUDGET;
		int result;

		if (ik_regex_compile((const u8 *)cases[i].pattern,
				     strlen(cases[i].pattern), &regex) < 0) {
			fprintf(stderr, "compile failed: %s\n", cases[i].name);
			return 1;
		}
		result = ik_regex_match(regex, (const u8 *)cases[i].input,
					strlen(cases[i].input), &budget);
		ik_regex_free(regex);
		if (!!result != cases[i].expected) {
			fprintf(stderr, "mismatch: %s result=%d\n",
				cases[i].name, result);
			return 1;
		}
		printf("PASS: %s budget_used=%u\n", cases[i].name,
		       IK_REGEX_PACKET_STEP_BUDGET - budget);
	}
	return 0;
}
