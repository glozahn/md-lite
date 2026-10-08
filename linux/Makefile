# Build and install MD Lite for Linux (GTK 4).
#   make            build the release binary
#   make install    install under $(PREFIX) (use DESTDIR for staging)
#   make rpm        build an RPM package into dist/

PREFIX ?= /usr/local
DESTDIR ?=
APP_ID = io.github.glozahn.MDLite
BINDIR = $(DESTDIR)$(PREFIX)/bin
DATADIR = $(DESTDIR)$(PREFIX)/share
CARGO ?= cargo
TARGET_DIR ?= target

.PHONY: all build install uninstall rpm test clean

all: build

build:
	$(CARGO) build --release --locked --target-dir $(TARGET_DIR)

test:
	$(CARGO) test --locked

install:
	install -Dm755 $(TARGET_DIR)/release/md-lite $(BINDIR)/md-lite
	install -Dm644 data/$(APP_ID).desktop $(DATADIR)/applications/$(APP_ID).desktop
	install -Dm644 data/$(APP_ID).metainfo.xml $(DATADIR)/metainfo/$(APP_ID).metainfo.xml
	install -Dm644 data/icons/hicolor/scalable/apps/$(APP_ID).svg $(DATADIR)/icons/hicolor/scalable/apps/$(APP_ID).svg
	install -Dm644 data/icons/hicolor/symbolic/apps/$(APP_ID)-symbolic.svg $(DATADIR)/icons/hicolor/symbolic/apps/$(APP_ID)-symbolic.svg
	install -Dm644 ../LICENSE $(DATADIR)/licenses/md-lite/LICENSE
	install -Dm644 ../Resources/Mermaid/LICENSE $(DATADIR)/licenses/md-lite/mermaid-LICENSE

uninstall:
	rm -f $(BINDIR)/md-lite
	rm -f $(DATADIR)/applications/$(APP_ID).desktop
	rm -f $(DATADIR)/metainfo/$(APP_ID).metainfo.xml
	rm -f $(DATADIR)/icons/hicolor/scalable/apps/$(APP_ID).svg
	rm -f $(DATADIR)/icons/hicolor/symbolic/apps/$(APP_ID)-symbolic.svg
	rm -rf $(DATADIR)/licenses/md-lite

rpm:
	./packaging/build-rpm.sh

clean:
	$(CARGO) clean
	rm -rf dist
