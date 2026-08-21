#ifndef OAF_HOST_LINUX_SLAB_H
#define OAF_HOST_LINUX_SLAB_H

#include <stdlib.h>
#include <string.h>

#define GFP_KERNEL 0

#define kzalloc(size, flags) calloc(1, (size))
#define kcalloc(count, size, flags) calloc((count), (size))
#define kfree(pointer) free((pointer))

static inline void *kmemdup(const void *source, size_t size, int flags)
{
	void *copy = malloc(size);

	(void)flags;
	if (copy)
		memcpy(copy, source, size);
	return copy;
}

#endif
