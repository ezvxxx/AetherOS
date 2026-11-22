SHELL := /bin/bash

ZIG ?= zig
PYTHON ?= python3
XORRISO ?= xorriso
QEMU ?= qemu-system-x86_64
OVMF_CODE ?= /usr/share/edk2/x64/OVMF_CODE.4m.fd
OVMF_VARS_TEMPLATE ?= /usr/share/edk2/x64/OVMF_VARS.4m.fd
BUILD := build
export ZIG_GLOBAL_CACHE_DIR ?= $(abspath $(BUILD)/zig-global-cache)
ZIG_SOURCES := $(shell find arch apps boot drivers fs graphics memory network process shell system ui third_party -type f -name '*.zig' -print 2>/dev/null)

KERNEL := $(BUILD)/kernel.elf
EFI_LOADER := $(BUILD)/BOOTX64.EFI
ESP := $(BUILD)/aetheros-esp.img
ISO := $(BUILD)/aetheros.iso
OVMF_VARS := $(BUILD)/uefi-vars.fd
H264_SOURCES := $(sort $(wildcard third_party/tinyh264/native/*.c))
H264_OBJECTS := $(patsubst third_party/tinyh264/native/%.c,$(BUILD)/h264_%.o,$(H264_SOURCES))
MP3_OBJECT := $(BUILD)/aether_mp3.o
INTERRUPT_OBJECT := $(BUILD)/interrupt_stubs.o
PY_HELPER := tools/linux_boot_image.py

.PHONY: all kernel iso run clean help

all: iso

kernel: $(KERNEL)

iso: $(ISO)

run: $(ISO) $(OVMF_VARS)
	@test -r $(OVMF_CODE) || { echo 'OVMF code firmware not found: $(OVMF_CODE)' >&2; exit 1; }
	$(QEMU) \
		-machine pc -cpu max -m 1024M \
		-drive if=pflash,format=raw,unit=0,readonly=on,file=$(OVMF_CODE) \
		-drive if=pflash,format=raw,unit=1,file=$(OVMF_VARS) \
		-cdrom $(ISO) \
		-boot order=d \
		-display gtk

$(OVMF_VARS): | $(BUILD)
	@test -r $(OVMF_VARS_TEMPLATE) || { echo 'OVMF variables template not found: $(OVMF_VARS_TEMPLATE)' >&2; exit 1; }
	cp $(OVMF_VARS_TEMPLATE) $@

help:
	@echo 'make kernel  Build the x86-64 kernel ELF'
	@echo 'make iso     Build the UEFI bootable ISO'
	@echo 'make run     Build and launch the ISO in a GTK QEMU window'
	@echo 'make clean   Remove generated kernel and ISO outputs'

$(BUILD):
	mkdir -p $@

$(INTERRUPT_OBJECT): arch/interrupt_stubs.S | $(BUILD)
	$(ZIG) build-obj $< -target x86_64-freestanding-none -femit-bin=$@

$(MP3_OBJECT): third_party/minimp3/aether_mp3.c | $(BUILD)
	$(ZIG) build-obj $< -target x86_64-freestanding-none -O ReleaseFast -fno-builtin -Ithird_party/minimp3 -femit-bin=$@

$(BUILD)/h264_%.o: third_party/tinyh264/native/%.c | $(BUILD)
	$(ZIG) build-obj $< -target x86_64-freestanding-none -O ReleaseFast -fno-builtin \
		-Ithird_party/tinyh264/port -Ithird_party/tinyh264/native -femit-bin=$@

$(KERNEL): kernel.zig assets/aetheros-logo.png $(ZIG_SOURCES) $(INTERRUPT_OBJECT) $(MP3_OBJECT) $(H264_OBJECTS)
	$(ZIG) build-exe $(INTERRUPT_OBJECT) $(MP3_OBJECT) $(H264_OBJECTS) \
		-target x86_64-freestanding-none -mcmodel=kernel -mno-red-zone \
		-O ReleaseFast -fstrip -fentry=_start -Tlinker.ld -femit-bin=$(KERNEL) \
		--dep z2dimg --dep z2d --dep vp8 -Mroot=kernel.zig \
		--dep z2d --dep riff --dep vp8 -Mz2dimg=third_party/z2dimg/root.zig \
		--dep z2d_options -Mz2d=third_party/z2d/src/z2d.zig \
		-Mz2d_options=third_party/z2d_options.zig \
		-Mriff=third_party/riff/root.zig -Mvp8=third_party/vp8/root.zig
	$(PYTHON) $(PY_HELPER) compact $(KERNEL)

$(EFI_LOADER): boot/uefi.zig | $(BUILD)
	$(ZIG) build-exe $< -target x86_64-uefi -O ReleaseSmall -fstrip -femit-bin=$@

$(ESP): $(EFI_LOADER) $(KERNEL) $(PY_HELPER)
	$(PYTHON) $(PY_HELPER) esp --efi $(EFI_LOADER) --kernel $(KERNEL) --output $@

$(ISO): $(ESP) $(EFI_LOADER) Makefile | $(BUILD)
	rm -rf $(BUILD)/iso_root
	mkdir -p $(BUILD)/iso_root/boot $(BUILD)/iso_root/EFI/BOOT
	cp $(ESP) $(BUILD)/iso_root/boot/esp.img
	# ISO-mode USB writers copy the ISO filesystem instead of exposing the
	# nested El Torito ESP. Keep the kernel beside the loader's ISO fallback path.
	cp $(KERNEL) $(BUILD)/iso_root/boot/kernel.elf
	cp $(EFI_LOADER) $(BUILD)/iso_root/EFI/BOOT/BOOTX64.EFI
	$(XORRISO) -as mkisofs -R -r -J -iso-level 3 -eltorito-alt-boot \
		-e boot/esp.img -no-emul-boot -isohybrid-gpt-basdat $(BUILD)/iso_root -o $@

clean:
	rm -f $(KERNEL) $(EFI_LOADER) $(ESP) $(ISO) $(INTERRUPT_OBJECT) $(MP3_OBJECT) $(H264_OBJECTS)
	rm -rf $(BUILD)/iso_root
