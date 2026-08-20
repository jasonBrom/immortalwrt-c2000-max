// SPDX-License-Identifier: GPL-2.0
/*
 * A small, byte-oriented Thompson-NFA engine for IKprotocol signatures.
 *
 * The old OAF regexp implementation is NUL-terminated and recursively
 * backtracks, so it is unsuitable for arbitrary packet bytes.  This engine
 * compiles a deliberately small regex dialect once, when a feature is loaded,
 * and executes it with bounded memory and a hard instruction budget in the
 * packet path.  It has no captures, backreferences or lookaround.
 */
#include <linux/errno.h>
#include <linux/kernel.h>
#include <linux/slab.h>
#include <linux/string.h>

#include "app_filter.h"
#include "ik_regex.h"

#define IK_RE_MAX_AST          (MAX_IK_PATTERN_LEN * 2 + 8)
#define IK_RE_MAX_INST         (MAX_IK_PATTERN_LEN * 2 + 8)
#define IK_RE_MAX_CLASSES      (MAX_IK_PATTERN_LEN / 2 + 2)
#define IK_RE_MAX_PATCH        (IK_RE_MAX_INST * 2)
#define IK_RE_MAX_DEPTH        32
#define IK_RE_MAX_INPUT        3000
#define IK_RE_REQUIRED_MAX     16
#define IK_RE_NONE             ((u16)0xffff)

enum ik_ast_op {
	IK_AST_CHAR,
	IK_AST_ANY,
	IK_AST_CLASS,
	IK_AST_BOL,
	IK_AST_EOL,
	IK_AST_WORD_BOUNDARY,
	IK_AST_NOT_WORD_BOUNDARY,
	IK_AST_CAT,
	IK_AST_ALT,
	IK_AST_STAR,
	IK_AST_PLUS,
	IK_AST_QUESTION,
};

enum ik_inst_op {
	IK_INST_CHAR,
	IK_INST_ANY,
	IK_INST_CLASS,
	IK_INST_SPLIT,
	IK_INST_BOL,
	IK_INST_EOL,
	IK_INST_WORD_BOUNDARY,
	IK_INST_NOT_WORD_BOUNDARY,
	IK_INST_MATCH,
};

struct ik_ast_node {
	s16 left;
	s16 right;
	u8 op;
	u8 value;
	u8 class_id;
};

struct ik_re_class {
	u8 map[32];
};

struct ik_re_inst {
	u16 out;
	u16 out1;
	u8 op;
	u8 value;
	u8 class_id;
};

struct ik_patch {
	u16 inst;
	u16 next;
	u8 which;
};

struct ik_fragment {
	u16 start;
	u16 head;
	u16 tail;
};

struct ik_regex {
	u16 start;
	u16 inst_count;
	u16 class_count;
	u16 min_len;
	u8 anchored;
	u8 anchored_first_valid;
	u8 anchored_first;
	u8 required_len;
	u8 required[IK_RE_REQUIRED_MAX];
	u8 required_lps[IK_RE_REQUIRED_MAX];
	struct ik_re_inst *inst;
	struct ik_re_class *classes;
};

/*
 * Conservative literal facts about an AST subtree.  `bytes` is either the
 * whole literal-only subtree (capped once it is already a strong 16-byte
 * filter), or a byte string present contiguously in every accepted string.
 * We intentionally derive nothing for alternation: missing an optimisation
 * is preferable to rejecting a valid packet.
 */
struct ik_literal_info {
	u8 literal_only;
	u8 len;
	u8 bytes[IK_RE_REQUIRED_MAX];
};

struct ik_compile_ctx {
	const u8 *pattern;
	size_t len;
	size_t pos;
	unsigned int depth;
	int error;

	struct ik_ast_node *ast;
	u16 ast_count;
	struct ik_re_class *classes;
	u16 class_count;
	struct ik_re_inst *inst;
	u16 inst_count;
	struct ik_patch *patch;
	u16 patch_count;
	s16 *sequence;
	u16 sequence_used;
};

struct ik_state_list {
	u16 count;
	u16 pc[IK_RE_MAX_INST];
};

static int ik_hex_value(u8 ch)
{
	if (ch >= '0' && ch <= '9')
		return ch - '0';
	if (ch >= 'a' && ch <= 'f')
		return ch - 'a' + 10;
	if (ch >= 'A' && ch <= 'F')
		return ch - 'A' + 10;
	return -EINVAL;
}

static void ik_class_set(struct ik_re_class *class, u8 ch)
{
	class->map[ch >> 3] |= (u8)(1U << (ch & 7));
}

static bool ik_class_test(const struct ik_re_class *class, u8 ch)
{
	return !!(class->map[ch >> 3] & (u8)(1U << (ch & 7)));
}

static int ik_new_ast(struct ik_compile_ctx *ctx, u8 op, int left,
			      int right, u8 value, u8 class_id)
{
	struct ik_ast_node *node;

	if (ctx->ast_count >= IK_RE_MAX_AST)
		return -E2BIG;
	node = &ctx->ast[ctx->ast_count];
	node->op = op;
	node->left = left;
	node->right = right;
	node->value = value;
	node->class_id = class_id;
	return ctx->ast_count++;
}

static int ik_parse_escaped_byte(struct ik_compile_ctx *ctx, u8 *value)
{
	int hi;
	int lo;

	if (ctx->pos >= ctx->len)
		return -EINVAL;
	if (ctx->pattern[ctx->pos] != 'x') {
		switch (ctx->pattern[ctx->pos++]) {
		case 'n':
			*value = '\n';
			break;
		case 'r':
			*value = '\r';
			break;
		case 't':
			*value = '\t';
			break;
		case 'f':
			*value = '\f';
			break;
		case 'v':
			*value = '\v';
			break;
		case 'b':
			*value = '\b';
			break;
		default:
			*value = ctx->pattern[ctx->pos - 1];
			break;
		}
		return 0;
	}
	if (ctx->pos + 2 >= ctx->len)
		return -EINVAL;
	hi = ik_hex_value(ctx->pattern[ctx->pos + 1]);
	lo = ik_hex_value(ctx->pattern[ctx->pos + 2]);
	if (hi < 0 || lo < 0)
		return -EINVAL;
	*value = (u8)((hi << 4) | lo);
	ctx->pos += 3;
	return 0;
}

static bool ik_add_class_shorthand(struct ik_re_class *class, u8 shorthand)
{
	struct ik_re_class shorthand_class = { { 0 } };
	bool negate = false;
	int i;

	if (!class)
		return false;
	switch (shorthand) {
	case 'D':
		negate = true;
		fallthrough;
	case 'd':
		for (i = '0'; i <= '9'; i++)
			ik_class_set(&shorthand_class, i);
		break;
	case 'S':
		negate = true;
		fallthrough;
	case 's':
		ik_class_set(&shorthand_class, ' ');
		ik_class_set(&shorthand_class, '\t');
		ik_class_set(&shorthand_class, '\r');
		ik_class_set(&shorthand_class, '\n');
		ik_class_set(&shorthand_class, '\f');
		ik_class_set(&shorthand_class, '\v');
		break;
	case 'W':
		negate = true;
		fallthrough;
	case 'w':
		for (i = '0'; i <= '9'; i++)
			ik_class_set(&shorthand_class, i);
		for (i = 'A'; i <= 'Z'; i++)
			ik_class_set(&shorthand_class, i);
		for (i = 'a'; i <= 'z'; i++)
			ik_class_set(&shorthand_class, i);
		ik_class_set(&shorthand_class, '_');
		break;
	default:
		return false;
	}
	if (negate)
		for (i = 0; i < ARRAY_SIZE(shorthand_class.map); i++)
			shorthand_class.map[i] = ~shorthand_class.map[i];
	for (i = 0; i < ARRAY_SIZE(class->map); i++)
		class->map[i] |= shorthand_class.map[i];
	return true;
}

static int ik_parse_class_byte(struct ik_compile_ctx *ctx, u8 *value)
{
	if (ctx->pos >= ctx->len)
		return -EINVAL;
	if (ctx->pattern[ctx->pos] != '\\') {
		*value = ctx->pattern[ctx->pos++];
		return 0;
	}
	ctx->pos++;
	return ik_parse_escaped_byte(ctx, value);
}

static int ik_parse_class(struct ik_compile_ctx *ctx)
{
	struct ik_re_class *class;
	bool negate = false;
	bool have_item = false;
	u8 first;
	u8 last;
	int i;
	int id;

	if (ctx->class_count >= IK_RE_MAX_CLASSES)
		return -E2BIG;
	id = ctx->class_count++;
	class = &ctx->classes[id];
	memset(class, 0, sizeof(*class));

	if (ctx->pos < ctx->len && ctx->pattern[ctx->pos] == '^') {
		negate = true;
		ctx->pos++;
	}

	while (ctx->pos < ctx->len) {
		if (ctx->pattern[ctx->pos] == ']' && have_item) {
			ctx->pos++;
			if (negate)
				for (i = 0; i < ARRAY_SIZE(class->map); i++)
					class->map[i] = ~class->map[i];
			return id;
		}
		if (ctx->pattern[ctx->pos] == '\\' &&
		    ctx->pos + 1 < ctx->len &&
		    ik_add_class_shorthand(class, ctx->pattern[ctx->pos + 1])) {
			ctx->pos += 2;
			have_item = true;
			/* A class shorthand cannot be a byte-range endpoint. */
			if (ctx->pos < ctx->len && ctx->pattern[ctx->pos] == '-' &&
			    ctx->pos + 1 < ctx->len && ctx->pattern[ctx->pos + 1] != ']')
				return -EINVAL;
			continue;
		}

		if (ik_parse_class_byte(ctx, &first) < 0)
			return -EINVAL;
		have_item = true;

		if (ctx->pos < ctx->len && ctx->pattern[ctx->pos] == '-' &&
		    ctx->pos + 1 < ctx->len && ctx->pattern[ctx->pos + 1] != ']') {
			ctx->pos++;
			if (ik_parse_class_byte(ctx, &last) < 0 ||
			    last < first)
				return -EINVAL;
			for (i = first; i <= last; i++)
				ik_class_set(class, (u8)i);
		} else {
			ik_class_set(class, first);
		}
	}
	return -EINVAL;
}

static int ik_parse_expr(struct ik_compile_ctx *ctx);

static int ik_parse_atom(struct ik_compile_ctx *ctx)
{
	u8 ch;
	u8 value;
	int node;
	int class_id;

	if (ctx->pos >= ctx->len)
		return -EINVAL;
	ch = ctx->pattern[ctx->pos++];
	switch (ch) {
	case '(':
		if (++ctx->depth > IK_RE_MAX_DEPTH)
			return -E2BIG;
		node = ik_parse_expr(ctx);
		ctx->depth--;
		if (node < 0 || ctx->pos >= ctx->len ||
		    ctx->pattern[ctx->pos++] != ')')
			return -EINVAL;
		return node;
	case '.':
		return ik_new_ast(ctx, IK_AST_ANY, -1, -1, 0, 0);
	case '^':
		return ik_new_ast(ctx, IK_AST_BOL, -1, -1, 0, 0);
	case '$':
		return ik_new_ast(ctx, IK_AST_EOL, -1, -1, 0, 0);
	case '[':
		class_id = ik_parse_class(ctx);
		if (class_id < 0)
			return class_id;
		return ik_new_ast(ctx, IK_AST_CLASS, -1, -1, 0,
				  (u8)class_id);
	case '\\':
		if (ctx->pos < ctx->len &&
		    (ctx->pattern[ctx->pos] == 'd' ||
		     ctx->pattern[ctx->pos] == 'D' ||
		     ctx->pattern[ctx->pos] == 's' ||
		     ctx->pattern[ctx->pos] == 'S' ||
		     ctx->pattern[ctx->pos] == 'w' ||
		     ctx->pattern[ctx->pos] == 'W')) {
			if (ctx->class_count >= IK_RE_MAX_CLASSES)
				return -E2BIG;
			class_id = ctx->class_count++;
			memset(&ctx->classes[class_id], 0,
			       sizeof(ctx->classes[class_id]));
			if (!ik_add_class_shorthand(&ctx->classes[class_id],
						    ctx->pattern[ctx->pos++]))
				return -EINVAL;
			return ik_new_ast(ctx, IK_AST_CLASS, -1, -1, 0,
					  (u8)class_id);
		}
		if (ctx->pos < ctx->len && ctx->pattern[ctx->pos] == 'b') {
			ctx->pos++;
			return ik_new_ast(ctx, IK_AST_WORD_BOUNDARY, -1, -1,
					  0, 0);
		}
		if (ctx->pos < ctx->len && ctx->pattern[ctx->pos] == 'B') {
			ctx->pos++;
			return ik_new_ast(ctx, IK_AST_NOT_WORD_BOUNDARY, -1, -1,
					  0, 0);
		}
		if (ik_parse_escaped_byte(ctx, &value) < 0)
			return -EINVAL;
		return ik_new_ast(ctx, IK_AST_CHAR, -1, -1, value, 0);
	case ')':
	case '|':
	case '*':
	case '+':
	case '?':
		return -EINVAL;
	default:
		return ik_new_ast(ctx, IK_AST_CHAR, -1, -1, ch, 0);
	}
}

static int ik_parse_repeat(struct ik_compile_ctx *ctx)
{
	int node;
	u8 ch;
	u8 op;

	node = ik_parse_atom(ctx);
	if (node < 0 || ctx->pos >= ctx->len)
		return node;

	ch = ctx->pattern[ctx->pos];
	if (ch != '*' && ch != '+' && ch != '?')
		return node;
	ctx->pos++;
	op = ch == '*' ? IK_AST_STAR :
	     ch == '+' ? IK_AST_PLUS : IK_AST_QUESTION;
	node = ik_new_ast(ctx, op, node, -1, 0, 0);
	if (node < 0)
		return node;

	/* Lazy and greedy quantifiers have the same accepted language. */
	if (ctx->pos < ctx->len && ctx->pattern[ctx->pos] == '?')
		ctx->pos++;
	if (ctx->pos < ctx->len &&
	    (ctx->pattern[ctx->pos] == '*' ||
	     ctx->pattern[ctx->pos] == '+' ||
	     ctx->pattern[ctx->pos] == '?'))
		return -EINVAL;
	return node;
}

static int ik_build_balanced(struct ik_compile_ctx *ctx, u16 base, u16 count,
			     u8 op)
{
	u16 left_count;
	int left;
	int right;

	if (count == 1)
		return ctx->sequence[base];
	left_count = count / 2;
	left = ik_build_balanced(ctx, base, left_count, op);
	if (left < 0)
		return left;
	right = ik_build_balanced(ctx, base + left_count,
				  count - left_count, op);
	if (right < 0)
		return right;
	return ik_new_ast(ctx, op, left, right, 0, 0);
}

static bool ik_atom_follows(struct ik_compile_ctx *ctx)
{
	u8 ch;

	if (ctx->pos >= ctx->len)
		return false;
	ch = ctx->pattern[ctx->pos];
	return ch != ')' && ch != '|' && ch != '*' && ch != '+' && ch != '?';
}

static int ik_parse_concat(struct ik_compile_ctx *ctx)
{
	u16 base = ctx->sequence_used;
	u16 count = 0;
	int node;

	while (ik_atom_follows(ctx)) {
		if (ctx->sequence_used >= IK_RE_MAX_AST)
			return -E2BIG;
		node = ik_parse_repeat(ctx);
		if (node < 0)
			return node;
		ctx->sequence[ctx->sequence_used++] = node;
		count++;
	}
	if (!count)
		return -EINVAL;
	node = ik_build_balanced(ctx, base, count, IK_AST_CAT);
	ctx->sequence_used = base;
	return node;
}

static int ik_parse_expr(struct ik_compile_ctx *ctx)
{
	u16 base = ctx->sequence_used;
	u16 count = 0;
	int node;

	for (;;) {
		if (ctx->sequence_used >= IK_RE_MAX_AST)
			return -E2BIG;
		node = ik_parse_concat(ctx);
		if (node < 0)
			return node;
		ctx->sequence[ctx->sequence_used++] = node;
		count++;
		if (ctx->pos >= ctx->len || ctx->pattern[ctx->pos] != '|')
			break;
		ctx->pos++;
	}
	node = ik_build_balanced(ctx, base, count, IK_AST_ALT);
	ctx->sequence_used = base;
	return node;
}

static int ik_new_inst(struct ik_compile_ctx *ctx, u8 op, u8 value,
			       u8 class_id, u16 out, u16 out1)
{
	struct ik_re_inst *inst;

	if (ctx->inst_count >= IK_RE_MAX_INST)
		return -E2BIG;
	inst = &ctx->inst[ctx->inst_count];
	inst->op = op;
	inst->value = value;
	inst->class_id = class_id;
	inst->out = out;
	inst->out1 = out1;
	return ctx->inst_count++;
}

static struct ik_fragment ik_bad_fragment(void)
{
	struct ik_fragment fragment = {
		.start = IK_RE_NONE,
		.head = IK_RE_NONE,
		.tail = IK_RE_NONE,
	};

	return fragment;
}

static struct ik_fragment ik_new_fragment(struct ik_compile_ctx *ctx,
					  u16 start, u8 which)
{
	struct ik_fragment fragment = ik_bad_fragment();
	struct ik_patch *patch;

	if (ctx->patch_count >= IK_RE_MAX_PATCH)
		return fragment;
	patch = &ctx->patch[ctx->patch_count];
	patch->inst = start;
	patch->which = which;
	patch->next = IK_RE_NONE;
	fragment.start = start;
	fragment.head = ctx->patch_count;
	fragment.tail = ctx->patch_count;
	ctx->patch_count++;
	return fragment;
}

static struct ik_fragment ik_append_fragment(struct ik_compile_ctx *ctx,
					     struct ik_fragment first,
					     struct ik_fragment second)
{
	if (first.head == IK_RE_NONE)
		return second;
	if (second.head == IK_RE_NONE)
		return first;
	ctx->patch[first.tail].next = second.head;
	first.tail = second.tail;
	return first;
}

static int ik_patch_fragment(struct ik_compile_ctx *ctx,
			     struct ik_fragment fragment, u16 target)
{
	u16 index = fragment.head;
	struct ik_patch *patch;

	while (index != IK_RE_NONE) {
		if (index >= ctx->patch_count)
			return -EINVAL;
		patch = &ctx->patch[index];
		if (patch->inst >= ctx->inst_count)
			return -EINVAL;
		if (patch->which == 0)
			ctx->inst[patch->inst].out = target;
		else if (patch->which == 1)
			ctx->inst[patch->inst].out1 = target;
		else
			return -EINVAL;
		index = patch->next;
	}
	return 0;
}

static struct ik_fragment ik_compile_ast(struct ik_compile_ctx *ctx, int node_id)
{
	struct ik_ast_node *node;
	struct ik_fragment left;
	struct ik_fragment right;
	struct ik_fragment out;
	int inst;

	if (node_id < 0 || node_id >= ctx->ast_count)
		return ik_bad_fragment();
	node = &ctx->ast[node_id];
	switch (node->op) {
	case IK_AST_CHAR:
		inst = ik_new_inst(ctx, IK_INST_CHAR, node->value, 0,
				   IK_RE_NONE, IK_RE_NONE);
		return inst < 0 ? ik_bad_fragment() :
		       ik_new_fragment(ctx, inst, 0);
	case IK_AST_ANY:
		inst = ik_new_inst(ctx, IK_INST_ANY, 0, 0,
				   IK_RE_NONE, IK_RE_NONE);
		return inst < 0 ? ik_bad_fragment() :
		       ik_new_fragment(ctx, inst, 0);
	case IK_AST_CLASS:
		inst = ik_new_inst(ctx, IK_INST_CLASS, 0, node->class_id,
				   IK_RE_NONE, IK_RE_NONE);
		return inst < 0 ? ik_bad_fragment() :
		       ik_new_fragment(ctx, inst, 0);
	case IK_AST_BOL:
		inst = ik_new_inst(ctx, IK_INST_BOL, 0, 0,
				   IK_RE_NONE, IK_RE_NONE);
		return inst < 0 ? ik_bad_fragment() :
		       ik_new_fragment(ctx, inst, 0);
	case IK_AST_EOL:
		inst = ik_new_inst(ctx, IK_INST_EOL, 0, 0,
				   IK_RE_NONE, IK_RE_NONE);
		return inst < 0 ? ik_bad_fragment() :
		       ik_new_fragment(ctx, inst, 0);
	case IK_AST_WORD_BOUNDARY:
		inst = ik_new_inst(ctx, IK_INST_WORD_BOUNDARY, 0, 0,
				   IK_RE_NONE, IK_RE_NONE);
		return inst < 0 ? ik_bad_fragment() :
		       ik_new_fragment(ctx, inst, 0);
	case IK_AST_NOT_WORD_BOUNDARY:
		inst = ik_new_inst(ctx, IK_INST_NOT_WORD_BOUNDARY, 0, 0,
				   IK_RE_NONE, IK_RE_NONE);
		return inst < 0 ? ik_bad_fragment() :
		       ik_new_fragment(ctx, inst, 0);
	case IK_AST_CAT:
		left = ik_compile_ast(ctx, node->left);
		right = ik_compile_ast(ctx, node->right);
		if (left.start == IK_RE_NONE || right.start == IK_RE_NONE ||
		    ik_patch_fragment(ctx, left, right.start) < 0)
			return ik_bad_fragment();
		right.start = left.start;
		return right;
	case IK_AST_ALT:
		left = ik_compile_ast(ctx, node->left);
		right = ik_compile_ast(ctx, node->right);
		if (left.start == IK_RE_NONE || right.start == IK_RE_NONE)
			return ik_bad_fragment();
		inst = ik_new_inst(ctx, IK_INST_SPLIT, 0, 0,
				   left.start, right.start);
		if (inst < 0)
			return ik_bad_fragment();
		out = ik_append_fragment(ctx, left, right);
		out.start = inst;
		return out;
	case IK_AST_STAR:
		left = ik_compile_ast(ctx, node->left);
		if (left.start == IK_RE_NONE)
			return ik_bad_fragment();
		inst = ik_new_inst(ctx, IK_INST_SPLIT, 0, 0,
				   left.start, IK_RE_NONE);
		if (inst < 0 || ik_patch_fragment(ctx, left, inst) < 0)
			return ik_bad_fragment();
		return ik_new_fragment(ctx, inst, 1);
	case IK_AST_PLUS:
		left = ik_compile_ast(ctx, node->left);
		if (left.start == IK_RE_NONE)
			return ik_bad_fragment();
		inst = ik_new_inst(ctx, IK_INST_SPLIT, 0, 0,
				   left.start, IK_RE_NONE);
		if (inst < 0 || ik_patch_fragment(ctx, left, inst) < 0)
			return ik_bad_fragment();
		out = ik_new_fragment(ctx, inst, 1);
		out.start = left.start;
		return out;
	case IK_AST_QUESTION:
		left = ik_compile_ast(ctx, node->left);
		if (left.start == IK_RE_NONE)
			return ik_bad_fragment();
		inst = ik_new_inst(ctx, IK_INST_SPLIT, 0, 0,
				   left.start, IK_RE_NONE);
		if (inst < 0)
			return ik_bad_fragment();
		right = ik_new_fragment(ctx, inst, 1);
		out = ik_append_fragment(ctx, left, right);
		out.start = inst;
		return out;
	default:
		return ik_bad_fragment();
	}
}

static u16 ik_ast_min_len(const struct ik_compile_ctx *ctx, int node_id)
{
	const struct ik_ast_node *node;
	u16 left;
	u16 right;

	if (node_id < 0 || node_id >= ctx->ast_count)
		return MAX_IK_PATTERN_LEN + 1;
	node = &ctx->ast[node_id];
	switch (node->op) {
	case IK_AST_CHAR:
	case IK_AST_ANY:
	case IK_AST_CLASS:
		return 1;
	case IK_AST_BOL:
	case IK_AST_EOL:
	case IK_AST_WORD_BOUNDARY:
	case IK_AST_NOT_WORD_BOUNDARY:
	case IK_AST_STAR:
	case IK_AST_QUESTION:
		return 0;
	case IK_AST_PLUS:
		return ik_ast_min_len(ctx, node->left);
	case IK_AST_CAT:
		left = ik_ast_min_len(ctx, node->left);
		right = ik_ast_min_len(ctx, node->right);
		return min_t(u16, left + right, MAX_IK_PATTERN_LEN + 1);
	case IK_AST_ALT:
		left = ik_ast_min_len(ctx, node->left);
		right = ik_ast_min_len(ctx, node->right);
		return min(left, right);
	default:
		return MAX_IK_PATTERN_LEN + 1;
	}
}

static struct ik_literal_info
ik_ast_literal_info(const struct ik_compile_ctx *ctx, int node_id)
{
	struct ik_literal_info out = { 0 };
	struct ik_literal_info left;
	struct ik_literal_info right;
	const struct ik_ast_node *node;
	u8 copy_len;

	if (node_id < 0 || node_id >= ctx->ast_count)
		return out;
	node = &ctx->ast[node_id];
	switch (node->op) {
	case IK_AST_CHAR:
		out.literal_only = 1;
		out.len = 1;
		out.bytes[0] = node->value;
		break;
	case IK_AST_BOL:
	case IK_AST_EOL:
	case IK_AST_WORD_BOUNDARY:
	case IK_AST_NOT_WORD_BOUNDARY:
		out.literal_only = 1;
		break;
	case IK_AST_CAT:
		left = ik_ast_literal_info(ctx, node->left);
		right = ik_ast_literal_info(ctx, node->right);
		if (left.literal_only && right.literal_only) {
			out.literal_only = 1;
			out.len = left.len;
			memcpy(out.bytes, left.bytes, left.len);
			copy_len = min_t(u8, right.len,
					 IK_RE_REQUIRED_MAX - out.len);
			memcpy(out.bytes + out.len, right.bytes, copy_len);
			out.len += copy_len;
		} else if (left.len >= right.len) {
			out.len = left.len;
			memcpy(out.bytes, left.bytes, left.len);
		} else {
			out.len = right.len;
			memcpy(out.bytes, right.bytes, right.len);
		}
		break;
	case IK_AST_PLUS:
		out = ik_ast_literal_info(ctx, node->left);
		/* One or more copies are not one fixed literal string. */
		out.literal_only = 0;
		break;
	case IK_AST_ANY:
	case IK_AST_CLASS:
	case IK_AST_ALT:
	case IK_AST_STAR:
	case IK_AST_QUESTION:
	default:
		break;
	}
	return out;
}

static void ik_set_required_literal(struct ik_regex *regex,
				    const struct ik_compile_ctx *ctx,
				    int root)
{
	struct ik_literal_info info;
	u8 i;
	u8 matched = 0;

	if (!regex || !ctx)
		return;
	info = ik_ast_literal_info(ctx, root);
	regex->required_len = info.len;
	memcpy(regex->required, info.bytes, info.len);

	/* Prefix table for a linear-time, budgeted KMP prefilter. */
	for (i = 1; i < regex->required_len; i++) {
		while (matched && regex->required[i] != regex->required[matched])
			matched = regex->required_lps[matched - 1];
		if (regex->required[i] == regex->required[matched])
			matched++;
		regex->required_lps[i] = matched;
	}
}

static void ik_set_anchored_first(struct ik_regex *regex, const u8 *pattern,
				  size_t len)
{
	size_t pos = 1;
	size_t i;
	int hi;
	int lo;
	int depth = 0;
	bool in_class = false;
	u8 ch;

	if (!regex || !pattern || len < 2 || pattern[0] != '^')
		return;
	/* `^a|b` is not globally anchored; never use a lossy prefilter. */
	for (i = 0; i < len; i++) {
		if (pattern[i] == '\\') {
			i++;
			continue;
		}
		if (pattern[i] == '[') {
			in_class = true;
			continue;
		}
		if (pattern[i] == ']' && in_class) {
			in_class = false;
			continue;
		}
		if (in_class)
			continue;
		if (pattern[i] == '(')
			depth++;
		else if (pattern[i] == ')' && depth > 0)
			depth--;
		else if (pattern[i] == '|' && depth == 0)
			return;
	}
	regex->anchored = 1;
	ch = pattern[pos++];
	if (ch == '\\') {
		if (pos >= len)
			return;
		ch = pattern[pos++];
		if (ch == 'd' || ch == 'D' || ch == 's' || ch == 'S' ||
		    ch == 'w' || ch == 'W' || ch == 'b' || ch == 'B')
			return;
		if (ch == 'x') {
			if (pos + 1 >= len)
				return;
			hi = ik_hex_value(pattern[pos]);
			lo = ik_hex_value(pattern[pos + 1]);
			if (hi < 0 || lo < 0)
				return;
			ch = (u8)((hi << 4) | lo);
			pos += 2;
		} else if (ch == 'n')
			ch = '\n';
		else if (ch == 'r')
			ch = '\r';
		else if (ch == 't')
			ch = '\t';
		else if (ch == 'f')
			ch = '\f';
		else if (ch == 'v')
			ch = '\v';
	} else if (ch == '.' || ch == '[' || ch == '(' || ch == '^' ||
		   ch == '$' ||
		   ch == '*' || ch == '+' || ch == '?' || ch == '|') {
		return;
	}
	/* `^a*` and `^a?` do not require the first byte to be `a`. */
	if (pos < len && (pattern[pos] == '*' || pattern[pos] == '?'))
		return;
	regex->anchored_first = ch;
	regex->anchored_first_valid = 1;
}

static void ik_compile_ctx_free(struct ik_compile_ctx *ctx)
{
	if (!ctx)
		return;
	kfree(ctx->sequence);
	kfree(ctx->patch);
	kfree(ctx->inst);
	kfree(ctx->classes);
	kfree(ctx->ast);
	kfree(ctx);
}

void ik_regex_free(struct ik_regex *regex)
{
	if (!regex)
		return;
	kfree(regex->classes);
	kfree(regex->inst);
	kfree(regex);
}

static unsigned int ik_prefilter_rarity(u8 ch)
{
	/* This is only a performance hint: every selected byte comes from a
	 * literal which all successful matches must contain.  Prefer bytes which
	 * are less common in HTTP/TLS payloads so the packet-wide bitmap rejects
	 * more regexes before the NFA is entered. */
	if (ch < 0x20 || ch >= 0x7f)
		return 6;
	if (ch >= '0' && ch <= '9')
		return 3;
	if ((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z')) {
		switch (ch | 0x20) {
		case 'q': case 'x': case 'z': case 'j': case 'v': case 'k':
			return 5;
		default:
			return 2;
		}
	}
	return ch == '.' || ch == '/' || ch == '-' || ch == '_' ? 1 : 4;
}

bool ik_regex_prefilter_byte(const struct ik_regex *regex, u8 *value)
{
	unsigned int best_score = 0;
	u8 best = 0;
	u8 i;

	if (!regex || !value)
		return false;
	if (regex->required_len) {
		for (i = 0; i < regex->required_len; i++) {
			unsigned int score = ik_prefilter_rarity(regex->required[i]);

			if (i == 0 || score > best_score) {
				best = regex->required[i];
				best_score = score;
			}
		}
		*value = best;
		return true;
	}
	if (regex->anchored_first_valid) {
		*value = regex->anchored_first;
		return true;
	}
	return false;
}

int ik_regex_compile(const u8 *pattern, size_t len, struct ik_regex **result)
{
	struct ik_compile_ctx *ctx = NULL;
	struct ik_fragment fragment;
	struct ik_regex *regex = NULL;
	int root;
	int match;
	int ret = -ENOMEM;

	if (!result)
		return -EINVAL;
	*result = NULL;
	if (!pattern || !len || len > MAX_IK_PATTERN_LEN)
		return -EINVAL;

	ctx = kzalloc(sizeof(*ctx), GFP_KERNEL);
	if (!ctx)
		goto out;
	ctx->ast = kcalloc(IK_RE_MAX_AST, sizeof(*ctx->ast), GFP_KERNEL);
	ctx->classes = kcalloc(IK_RE_MAX_CLASSES, sizeof(*ctx->classes),
			       GFP_KERNEL);
	ctx->inst = kcalloc(IK_RE_MAX_INST, sizeof(*ctx->inst), GFP_KERNEL);
	ctx->patch = kcalloc(IK_RE_MAX_PATCH, sizeof(*ctx->patch), GFP_KERNEL);
	ctx->sequence = kcalloc(IK_RE_MAX_AST, sizeof(*ctx->sequence),
				GFP_KERNEL);
	if (!ctx->ast || !ctx->classes || !ctx->inst || !ctx->patch ||
	    !ctx->sequence)
		goto out;
	ctx->pattern = pattern;
	ctx->len = len;

	root = ik_parse_expr(ctx);
	if (root < 0 || ctx->pos != ctx->len) {
		ret = root < 0 ? root : -EINVAL;
		goto out;
	}
	fragment = ik_compile_ast(ctx, root);
	if (fragment.start == IK_RE_NONE) {
		ret = -E2BIG;
		goto out;
	}
	match = ik_new_inst(ctx, IK_INST_MATCH, 0, 0, IK_RE_NONE,
			    IK_RE_NONE);
	if (match < 0 || ik_patch_fragment(ctx, fragment, match) < 0) {
		ret = -E2BIG;
		goto out;
	}

	regex = kzalloc(sizeof(*regex), GFP_KERNEL);
	if (!regex)
		goto out;
	regex->inst = kmemdup(ctx->inst,
			      sizeof(*ctx->inst) * ctx->inst_count,
			      GFP_KERNEL);
	if (!regex->inst)
		goto out;
	if (ctx->class_count) {
		regex->classes = kmemdup(ctx->classes,
					 sizeof(*ctx->classes) * ctx->class_count,
					 GFP_KERNEL);
		if (!regex->classes)
			goto out;
	}
	regex->start = fragment.start;
	regex->inst_count = ctx->inst_count;
	regex->class_count = ctx->class_count;
	regex->min_len = ik_ast_min_len(ctx, root);
	ik_set_required_literal(regex, ctx, root);
	ik_set_anchored_first(regex, pattern, len);
	*result = regex;
	regex = NULL;
	ret = 0;

out:
	ik_regex_free(regex);
	ik_compile_ctx_free(ctx);
	return ret;
}

static bool ik_is_word_byte(u8 ch)
{
	return (ch >= '0' && ch <= '9') ||
	       (ch >= 'A' && ch <= 'Z') ||
	       (ch >= 'a' && ch <= 'z') || ch == '_';
}

static bool ik_add_state(const struct ik_regex *regex,
			 struct ik_state_list *list, u8 *seen, u16 start,
			 const u8 *data, size_t pos, size_t len,
			 u32 *step_budget)
{
	u16 stack[IK_RE_MAX_INST];
	u16 stack_count = 0;
	u16 pc;
	const struct ik_re_inst *inst;

	if (start == IK_RE_NONE || start >= regex->inst_count)
		return false;
	stack[stack_count++] = start;
	while (stack_count) {
		if (!*step_budget)
			return false;
		(*step_budget)--;
		pc = stack[--stack_count];
		if (pc >= regex->inst_count || seen[pc])
			continue;
		seen[pc] = 1;
		inst = &regex->inst[pc];
		switch (inst->op) {
		case IK_INST_SPLIT:
			if (stack_count + 2 > ARRAY_SIZE(stack) ||
			    inst->out == IK_RE_NONE || inst->out1 == IK_RE_NONE)
				return false;
			stack[stack_count++] = inst->out;
			stack[stack_count++] = inst->out1;
			break;
		case IK_INST_BOL:
			if (pos == 0) {
				if (stack_count >= ARRAY_SIZE(stack) ||
				    inst->out == IK_RE_NONE)
					return false;
				stack[stack_count++] = inst->out;
			}
			break;
		case IK_INST_EOL:
			if (pos == len) {
				if (stack_count >= ARRAY_SIZE(stack) ||
				    inst->out == IK_RE_NONE)
					return false;
				stack[stack_count++] = inst->out;
			}
			break;
		case IK_INST_WORD_BOUNDARY:
		case IK_INST_NOT_WORD_BOUNDARY: {
			bool previous = pos > 0 && ik_is_word_byte(data[pos - 1]);
			bool following = pos < len && ik_is_word_byte(data[pos]);
			bool boundary = previous != following;

			if ((inst->op == IK_INST_WORD_BOUNDARY && boundary) ||
			    (inst->op == IK_INST_NOT_WORD_BOUNDARY && !boundary)) {
				if (stack_count >= ARRAY_SIZE(stack) ||
				    inst->out == IK_RE_NONE)
					return false;
				stack[stack_count++] = inst->out;
			}
			break;
		}
		default:
			if (list->count >= ARRAY_SIZE(list->pc))
				return false;
			list->pc[list->count++] = pc;
			break;
		}
	}
	return true;
}

static bool ik_list_has_match(const struct ik_regex *regex,
			      const struct ik_state_list *list)
{
	u16 i;

	for (i = 0; i < list->count; i++)
		if (regex->inst[list->pc[i]].op == IK_INST_MATCH)
			return true;
	return false;
}

static bool ik_required_present(const struct ik_regex *regex, const u8 *data,
				size_t len, u32 *step_budget)
{
	size_t pos = 0;
	u8 matched = 0;

	if (!regex->required_len)
		return true;
	if (len < regex->required_len)
		return false;

	while (pos < len) {
		while (matched && data[pos] != regex->required[matched]) {
			if (!*step_budget)
				return false;
			(*step_budget)--;
			matched = regex->required_lps[matched - 1];
		}
		if (!*step_budget)
			return false;
		(*step_budget)--;
		if (data[pos] == regex->required[matched])
			matched++;
		pos++;
		if (matched == regex->required_len)
			return true;
	}
	return false;
}

bool ik_regex_match(const struct ik_regex *regex, const u8 *data, size_t len,
		    u32 *step_budget)
{
	struct ik_state_list first;
	struct ik_state_list second;
	struct ik_state_list *active = &first;
	struct ik_state_list *next = &second;
	struct ik_state_list *swap;
	u8 current_seen[IK_RE_MAX_INST];
	u8 next_seen[IK_RE_MAX_INST];
	const struct ik_re_inst *inst;
	size_t pos;
	u16 i;
	bool matched;

	if (!regex || (!data && len) || !step_budget || !*step_budget ||
	    !regex->inst ||
	    !regex->inst_count || regex->inst_count > IK_RE_MAX_INST ||
	    regex->start >= regex->inst_count || len > IK_RE_MAX_INPUT)
		return false;
	if (len < regex->min_len ||
	    (regex->anchored_first_valid &&
	     (!len || data[0] != regex->anchored_first)))
		return false;
	if (!ik_required_present(regex, data, len, step_budget))
		return false;

	memset(active, 0, sizeof(*active));
	memset(current_seen, 0, sizeof(current_seen));
	for (pos = 0; pos <= len; pos++) {
		/* Starting the NFA at each byte implements unanchored search. */
		if ((!regex->anchored || pos == 0) &&
		    !ik_add_state(regex, active, current_seen, regex->start,
				  data, pos, len, step_budget))
			return false;
		if (ik_list_has_match(regex, active))
			return true;
		if (pos == len)
			break;

		memset(next, 0, sizeof(*next));
		memset(next_seen, 0, sizeof(next_seen));
		for (i = 0; i < active->count; i++) {
			if (!*step_budget)
				return false;
			(*step_budget)--;
			inst = &regex->inst[active->pc[i]];
			matched = inst->op == IK_INST_ANY ||
				  (inst->op == IK_INST_CHAR &&
				   inst->value == data[pos]) ||
				  (inst->op == IK_INST_CLASS &&
				   inst->class_id < regex->class_count &&
				   ik_class_test(&regex->classes[inst->class_id],
						 data[pos]));
			if (matched && !ik_add_state(regex, next, next_seen,
						    inst->out, data, pos + 1, len,
						    step_budget))
				return false;
		}
		swap = active;
		active = next;
		next = swap;
		memcpy(current_seen, next_seen, sizeof(current_seen));
		if (regex->anchored && !active->count)
			return false;
	}
	return false;
}
