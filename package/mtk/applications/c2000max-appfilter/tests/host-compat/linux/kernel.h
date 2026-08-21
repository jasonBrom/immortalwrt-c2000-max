#ifndef OAF_HOST_LINUX_KERNEL_H
#define OAF_HOST_LINUX_KERNEL_H

#include <stddef.h>

#define ARRAY_SIZE(array) (sizeof(array) / sizeof((array)[0]))
#define min(left, right) ((left) < (right) ? (left) : (right))
#define min_t(type, left, right) \
	((type)(left) < (type)(right) ? (type)(left) : (type)(right))
#define fallthrough __attribute__((fallthrough))

#endif
