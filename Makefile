PREFIX=/usr
BINDIR=$(PREFIX)/bin

install:
		install -dm755 $(DESTDIR)$(BINDIR)
		install -m755 kleber.sh $(DESTDIR)$(BINDIR)/kleber


deinstall:
		rm -f $(DESTDIR)$(BINDIR)/kleber
