# Makefile ABC

# Default installation directory
PREFIX ?= $(HOME)/.local

LDLIBS = -lpthread -g
SRCS = connect_flood_client.c  connect_flood_server.c
TARGETS = $(basename $(SRCS))

ALL : $(TARGETS)

.PHONY : clean
clean :
	rm -f $(TARGETS)

.PHONY : install
install :
	mkdir -p $(PREFIX)/bin
	cp $(TARGETS) $(PREFIX)/bin
