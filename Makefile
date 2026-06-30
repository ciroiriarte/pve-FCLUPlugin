# pve-FCLUPlugin — vendor-neutral FCLU storage framework.
#
# Pure Perl; there is nothing to compile. Packaging (multi-binary core +
# per-vendor drivers) lands later per ARCHITECTURE.md §11. For now this drives
# the unit-test suite, matching the reference plugin's conventions.

.PHONY: all test clean

all:
	@echo "pve-FCLUPlugin — early implementation (pure Perl); 'make test' runs the suite"

test:
	prove -Isrc -r t/unit/

clean:
	rm -rf build/
