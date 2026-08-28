CC ?= cc
CFLAGS ?= -O2
CPPFLAGS ?=
LDFLAGS ?=

.PHONY: all clean

all: c2000max-stun

c2000max-stun: c2000max-stun.c
	$(CC) $(CPPFLAGS) $(CFLAGS) -std=c99 -Wall -Wextra -Wformat=2 -o $@ $< $(LDFLAGS)

clean:
	rm -f c2000max-stun
