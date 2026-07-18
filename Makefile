# pve-FCLUPlugin — vendor-neutral FCLU storage framework.
#
# Pure Perl; nothing to compile. `make test` runs the unit suite; `make install`
# lays the modules out under the Perl vendorlib (partitioned into the core and
# per-vendor Debian binary packages by debian/*.install); `make deb` builds the
# multi-binary source package (ARCHITECTURE.md §11).

include version.mk

DESTDIR=
PREFIX=/usr
PERL_VENDORLIB=$(PREFIX)/share/perl5
FCLU=$(DESTDIR)$(PERL_VENDORLIB)/PVE/Storage/FCLU
CUSTOM=$(DESTDIR)$(PERL_VENDORLIB)/PVE/Storage/Custom
PVE_MANAGER_JS=$(DESTDIR)$(PREFIX)/share/pve-manager/js
SYSTEMD_UNIT_DIR=$(DESTDIR)/lib/systemd/system
CORE_DOC=$(DESTDIR)$(PREFIX)/share/doc/pve-fclu-core
HITACHI_DOC=$(DESTDIR)$(PREFIX)/share/doc/pve-fclu-hitachi
INDEX_TPL=$(PREFIX)/share/pve-manager/index.html.tpl
GUI_JS=pve-fclu-hitachi.js

.PHONY: all test clean install deb

all:
	@echo "$(PACKAGE) $(VERSION) — pure Perl; 'make test' runs the suite, 'make deb' builds packages"

test:
	prove -Isrc -r t/unit/

# Install every SHIPPABLE module preserving the PVE::Storage tree. debian/*.install
# then partitions these into pve-fclu-core (the vendor-neutral spine) and
# pve-fclu-hitachi (the driver + thin plugin). FCLU/Driver/Mock.pm is the test-only
# reference driver and is deliberately NOT installed.
install:
	# --- pve-fclu-core: vendor-neutral spine ---
	install -d $(FCLU)/Host
	install -m0644 src/PVE/Storage/FCLU/Plugin.pm       $(FCLU)/
	install -m0644 src/PVE/Storage/FCLU/Registry.pm     $(FCLU)/
	install -m0644 src/PVE/Storage/FCLU/Credentials.pm  $(FCLU)/
	install -m0644 src/PVE/Storage/FCLU/Label.pm        $(FCLU)/
	install -m0644 src/PVE/Storage/FCLU/Capabilities.pm $(FCLU)/
	install -m0644 src/PVE/Storage/FCLU/Error.pm        $(FCLU)/
	install -m0644 src/PVE/Storage/FCLU/Driver.pm       $(FCLU)/
	install -m0644 src/PVE/Storage/FCLU/Host/Connector.pm   $(FCLU)/Host/
	install -m0644 src/PVE/Storage/FCLU/Host/FCMultipath.pm $(FCLU)/Host/
	# --- pve-fclu-hitachi: array backend + thin type()='hitachiblock' plugin ---
	install -d $(FCLU)/Driver/Hitachi
	install -m0644 src/PVE/Storage/FCLU/Driver/Hitachi.pm            $(FCLU)/Driver/
	install -m0644 src/PVE/Storage/FCLU/Driver/Hitachi/RestClient.pm $(FCLU)/Driver/Hitachi/
	install -d $(CUSTOM)
	install -m0644 src/PVE/Storage/Custom/HitachiBlockPlugin.pm $(CUSTOM)/
	# migration tool: reference pve-storage-hitachiblock store -> FCLU registry format
	install -d $(FCLU)/Migrate
	install -m0644 src/PVE/Storage/FCLU/Migrate/Hitachi.pm $(FCLU)/Migrate/
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m0755 bin/pve-fclu-cg $(DESTDIR)$(PREFIX)/bin/
	install -m0755 bin/pve-fclu-host $(DESTDIR)$(PREFIX)/bin/
	install -m0755 bin/pve-fclu-migrate-hitachi $(DESTDIR)$(PREFIX)/bin/
	# --- pve-fclu-hitachi: web UI panel, opt-in SCSI-3 PR units, config examples ---
	install -d $(PVE_MANAGER_JS)
	install -m0644 src/www/manager6/hitachiblock.js $(PVE_MANAGER_JS)/$(GUI_JS)
	# qemu-pr-helper units ship DISABLED (dh_installsystemd --no-enable --no-start,
	# see debian/rules); the operator enables the socket only for persistent_reservations.
	install -d $(SYSTEMD_UNIT_DIR)
	install -m0644 conf/systemd/qemu-pr-helper.socket  $(SYSTEMD_UNIT_DIR)/
	install -m0644 conf/systemd/qemu-pr-helper.service $(SYSTEMD_UNIT_DIR)/
	# Operator documentation ships with the package it documents: the vendor-neutral
	# guide with the core, the driver/migration guides with the Hitachi driver.
	# Developer-facing docs (test-plan, packaging-obs, implementation-plan, branding)
	# stay in-tree — they document how to BUILD the project, not how to run it.
	install -d $(CORE_DOC)
	install -m0644 docs/user-guide.md $(CORE_DOC)/
	install -d $(HITACHI_DOC)
	install -m0644 conf/storage.cfg.example                    $(HITACHI_DOC)/
	install -m0644 conf/multipath.conf.d/hitachiblock-vsp.conf $(HITACHI_DOC)/
	install -m0644 docs/driver-hitachi.md                      $(HITACHI_DOC)/
	install -m0644 docs/migration-hitachi.md                   $(HITACHI_DOC)/
	# Source installs (empty DESTDIR) wire the UI <script> into the live index
	# template; the .deb does this via debian/pve-fclu-hitachi.{postinst,triggers}.
	@if [ -z "$(DESTDIR)" ] && [ -f "$(INDEX_TPL)" ]; then \
	  if grep -q '$(GUI_JS)' "$(INDEX_TPL)"; then \
	    sed -i 's#$(GUI_JS)?ver=[^"]*#$(GUI_JS)?ver=$(VERSION)#' "$(INDEX_TPL)"; \
	  else \
	    sed -i '\#pvemanagerlib.js#a\        <script type="text/javascript" src="/pve2/js/$(GUI_JS)?ver=$(VERSION)"></script>' "$(INDEX_TPL)"; \
	  fi; \
	  echo "Wired the FCLU Hitachi UI panel into $(INDEX_TPL) (reload the web UI with Ctrl-Shift-R)."; \
	fi

deb:
	dpkg-buildpackage -us -uc -b

clean:
	rm -rf build/ debian/tmp debian/pve-fclu-core debian/pve-fclu-hitachi debian/pve-fclu \
	       debian/.debhelper debian/files debian/debhelper-build-stamp debian/*.substvars
