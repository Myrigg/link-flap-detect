PREFIX ?= /usr/local
BINDIR  = $(PREFIX)/bin
LIBDIR  = $(PREFIX)/lib/link-flap

LIBS = $(wildcard lib/*.sh)

install:
	install -Dm755 flap $(DESTDIR)$(BINDIR)/flap
	install -d $(DESTDIR)$(LIBDIR)
	install -m644 $(LIBS) $(DESTDIR)$(LIBDIR)/

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/flap
	rm -rf $(DESTDIR)$(LIBDIR)

# Build a standalone single-file script with all libs inlined (for -H remote mode).
bundle:
	@awk '\
	  /^# ── Source library modules/,/^unset _LIB_DIR/ { \
	    if (/^# ── Source library modules/) { \
	      print "# ── Inlined library modules ─────────────────────────────────────────────────"; \
	      cmd = "for f in lib/*.sh; do echo \"# --- $$f ---\"; grep -v \"^#!/usr/bin/env bash\" \"$$f\"; echo; done"; \
	      system(cmd); \
	    } \
	    next; \
	  } \
	  { print }' flap > flap-standalone
	@chmod +x flap-standalone
	@echo "Built flap-standalone ($$(wc -l < flap-standalone) lines)"

.PHONY: install uninstall bundle
