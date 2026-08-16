DEVICE ?= root@192.168.100.180
TARGET := aarch64-linux-gnu.2.38

.PHONY: build sysroot deploy run clean

build:
	zig build -Dtarget=$(TARGET) -Doptimize=ReleaseSmall

# The device's own libraries are the link-time ABI reference. Not committed.
sysroot:
	mkdir -p sysroot
	for f in libSDL2-2.0.so.0 libSDL2_ttf-2.0.so.0 libSDL2_image-2.0.so.0 libdbus-1.so.3; do \
		ssh $(DEVICE) "cat /usr/lib/$$f" > sysroot/$$f; \
	done
	cd sysroot && ln -sf libSDL2-2.0.so.0 libSDL2.so \
		&& ln -sf libSDL2_ttf-2.0.so.0 libSDL2_ttf.so \
		&& ln -sf libSDL2_image-2.0.so.0 libSDL2_image.so \
		&& ln -sf libdbus-1.so.3 libdbus-1.so

deploy: build
	ssh $(DEVICE) 'mkdir -p /mnt/mmc/MUOS/application/Bluetooth/bin'
	ssh $(DEVICE) 'cat > /mnt/mmc/MUOS/application/Bluetooth/bin/btui && chmod +x /mnt/mmc/MUOS/application/Bluetooth/bin/btui' < zig-out/bin/btui

run: deploy
	ssh $(DEVICE) '/mnt/mmc/MUOS/application/Bluetooth/bin/btui --dump'

clean:
	rm -rf zig-out .zig-cache
