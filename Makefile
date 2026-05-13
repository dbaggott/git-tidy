PREFIX ?= $(HOME)/.local
BINDIR := $(PREFIX)/bin

.PHONY: install uninstall test help

help:
	@echo "Targets:"
	@echo "  install    Install git-tidy to \$$PREFIX/bin (default: \$$HOME/.local/bin)"
	@echo "  uninstall  Remove git-tidy from \$$PREFIX/bin"
	@echo "  test       Run shellcheck against the scripts"
	@echo ""
	@echo "Override install location with: make install PREFIX=/usr/local"

install:
	@install -d "$(BINDIR)"
	@install -m 0755 git-tidy "$(BINDIR)/git-tidy"
	@echo "Installed $(BINDIR)/git-tidy"

uninstall:
	@rm -f "$(BINDIR)/git-tidy"
	@echo "Removed $(BINDIR)/git-tidy"

test:
	@shellcheck git-tidy install.sh
