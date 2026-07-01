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

deb:
	dpkg-buildpackage -us -uc -b

clean:
	rm -rf build/ debian/tmp debian/pve-fclu-core debian/pve-fclu-hitachi debian/pve-fclu \
	       debian/.debhelper debian/files debian/debhelper-build-stamp debian/*.substvars
