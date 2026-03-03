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
	@{ \
	  sed '/^# ── Source library modules/,/^unset _LIB_DIR/d' flap | \
	    sed '/^VERSION=/i # ── Inlined library modules ─────────────────────────────────────────────────'; \
	  echo ""; \
	  for f in lib/*.sh; do \
	    echo "# --- $$f ---"; \
	    grep -v '^#!/usr/bin/env bash' "$$f"; \
	    echo ""; \
	  done; \
	} > flap-standalone
	@chmod +x flap-standalone
	@echo "Built flap-standalone ($$(wc -l < flap-standalone) lines)"

.PHONY: install uninstall bundle
