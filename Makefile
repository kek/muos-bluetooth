DEVICE ?= root@192.168.100.180
TARGET := aarch64-linux-gnu.2.38

.PHONY: build check-device sysroot deploy run clean

build:
	zig build -Dtarget=$(TARGET) -Doptimize=ReleaseSmall

# Every device-facing target below depends on this. It exists because
# something else answered $(DEVICE)'s IP for an unknown window during Task 7:
# a Nerves/Elixir box, not muOS, took over the address mid-session while the
# handheld was off. Until this check was added, `deploy` would have written
# our binary to that stranger with no complaint, and `sysroot` would have
# filled our build's link-time ABI reference with its libraries instead of
# the handheld's. /etc/os-release containing MustardOS is muOS's own
# identity string (see README), so it's a cheap, specific, read-only check -
# one ssh round trip on the success path.
check-device:
	@ssh $(DEVICE) 'grep -q MustardOS /etc/os-release 2>/dev/null && echo MUOS_OK' 2>/dev/null | grep -q MUOS_OK || { \
		echo "error: $(DEVICE) does not look like muOS (no MustardOS in /etc/os-release)." >&2; \
		echo "  what answered: $$(ssh $(DEVICE) 'head -1 /etc/os-release 2>/dev/null || echo "(nothing readable)"' 2>&1)" >&2; \
		exit 1; \
	}

# The device's own libraries are the link-time ABI reference. Not committed.
# Fix round 2, finding M9: libSDL2_image was pulled here (and linked in
# build.zig) with nothing in src/ ever calling an IMG_* function - dropped.
sysroot: check-device
	mkdir -p sysroot
	for f in libSDL2-2.0.so.0 libSDL2_ttf-2.0.so.0 libdbus-1.so.3; do \
		ssh $(DEVICE) "cat /usr/lib/$$f" > sysroot/$$f; \
	done
	cd sysroot && ln -sf libSDL2-2.0.so.0 libSDL2.so \
		&& ln -sf libSDL2_ttf-2.0.so.0 libSDL2_ttf.so \
		&& ln -sf libdbus-1.so.3 libdbus-1.so

deploy: build check-device
	ssh $(DEVICE) 'mkdir -p /mnt/mmc/MUOS/application/Bluetooth/bin'
	ssh $(DEVICE) 'cat > /mnt/mmc/MUOS/application/Bluetooth/bin/btui && chmod +x /mnt/mmc/MUOS/application/Bluetooth/bin/btui' < zig-out/bin/btui

run: deploy
	ssh $(DEVICE) '/mnt/mmc/MUOS/application/Bluetooth/bin/btui --dump'

clean:
	rm -rf zig-out .zig-cache
