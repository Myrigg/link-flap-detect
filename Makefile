PREFIX ?= /usr/local
BINDIR  = $(PREFIX)/bin

install:
	install -Dm755 flap $(DESTDIR)$(BINDIR)/flap

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/flap

.PHONY: install uninstall
