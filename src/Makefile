# Makefile ABC

LDLIBS = -lpthread -g
SRCS = connect_flood_client.c  connect_flood_server.c
TARGETS = $(basename $(SRCS))

ALL : $(TARGETS)

. PHONY : clean
clean :
	rm -f $(TARGETS)
install :
	cp $(TARGETS) /usr/local/bin
