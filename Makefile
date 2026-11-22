SHELL := /bin/bash

ZIG ?= zig
PYTHON ?= python3
XORRISO ?= xorriso
QEMU ?= qemu-system-x86_64
OVMF_CODE ?= /usr/share/edk2/x64/OVMF_CODE.4m.fd
OVMF_VARS_TEMPLATE ?= /usr/share/edk2/x64/OVMF_VARS.4m.fd
BUILD := build
export ZIG_GLOBAL_CACHE_DIR ?= $(abspath $(BUILD)/zig-global-cache)
ARIX := third_party/arix
GENERATED := $(BUILD)/arix_generated
STRALE_DIR := $(firstword $(wildcard $(ARIX)/zig-pkg/strale-* ))
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

$(GENERATED)/local_name.zig: $(ARIX)/src/gen/local_name.zig $(ARIX)/res/json/local_names.json | $(BUILD)
	mkdir -p $(GENERATED)
	cd $(ARIX) && $(ZIG) run src/gen/local_name.zig -- res/json/local_names.json ../../$(GENERATED)/local_name.zig

$(GENERATED)/named_ref.zig: $(ARIX)/src/gen/named_ref.zig $(ARIX)/res/json/named_char_refs.json | $(BUILD)
	mkdir -p $(GENERATED)
	cd $(ARIX) && $(ZIG) run src/gen/named_ref.zig -- res/json/named_char_refs.json ../../$(GENERATED)/named_ref.zig

$(INTERRUPT_OBJECT): arch/interrupt_stubs.S | $(BUILD)
	$(ZIG) build-obj $< -target x86_64-freestanding-none -femit-bin=$@

$(MP3_OBJECT): third_party/minimp3/aether_mp3.c | $(BUILD)
	$(ZIG) build-obj $< -target x86_64-freestanding-none -O ReleaseFast -fno-builtin -Ithird_party/minimp3 -femit-bin=$@

$(BUILD)/h264_%.o: third_party/tinyh264/native/%.c | $(BUILD)
	$(ZIG) build-obj $< -target x86_64-freestanding-none -O ReleaseFast -fno-builtin \
		-Ithird_party/tinyh264/port -Ithird_party/tinyh264/native -femit-bin=$@

$(KERNEL): kernel.zig assets/aetheros-logo.png $(ZIG_SOURCES) $(INTERRUPT_OBJECT) $(MP3_OBJECT) $(H264_OBJECTS) $(GENERATED)/local_name.zig $(GENERATED)/named_ref.zig
	@test -n '$(STRALE_DIR)' || { echo 'Missing Arix Strale dependency in third_party/arix/zig-pkg' >&2; exit 1; }
	$(ZIG) build-exe $(INTERRUPT_OBJECT) $(MP3_OBJECT) $(H264_OBJECTS) \
		-target x86_64-freestanding-none -mcmodel=kernel -mno-red-zone \
		-O ReleaseFast -fstrip -fentry=_start -Tlinker.ld -femit-bin=$(KERNEL) \
		--dep z2dimg --dep z2d --dep vp8 --dep arix_renderer -Mroot=kernel.zig \
		--dep z2d --dep riff --dep vp8 -Mz2dimg=third_party/z2dimg/root.zig \
		--dep z2d_options -Mz2d=third_party/z2d/src/z2d.zig \
		-Mz2d_options=third_party/z2d_options.zig \
		-Mriff=third_party/riff/root.zig -Mvp8=third_party/vp8/root.zig \
		--dep arix_core --dep strale --dep aether_font -Marix_renderer=ui/arix_renderer.zig \
		--dep strale --dep named_ref --dep local_name --dep config --dep aether_font \
		-Marix_core=third_party/arix/src/aether_renderer.zig \
		-Mstrale=$(STRALE_DIR)/src/strale.zig \
		-Mnamed_ref=$(GENERATED)/named_ref.zig \
		--dep strale -Mlocal_name=$(GENERATED)/local_name.zig \
		-Mconfig=third_party/arix/aether_config.zig \
		--dep z2d -Maether_font=arix_font.zig
	$(PYTHON) $(PY_HELPER) compact $(KERNEL)

$(EFI_LOADER): boot/uefi.zig | $(BUILD)
	$(ZIG) build-exe $< -target x86_64-uefi -O ReleaseSmall -fstrip -femit-bin=$@

$(ESP): $(EFI_LOADER) $(KERNEL) $(PY_HELPER)
	$(PYTHON) $(PY_HELPER) esp --efi $(EFI_LOADER) --kernel $(KERNEL) --output $@

$(ISO): $(ESP) $(EFI_LOADER) | $(BUILD)
	rm -rf $(BUILD)/iso_root
	mkdir -p $(BUILD)/iso_root/boot $(BUILD)/iso_root/EFI/BOOT
	cp $(ESP) $(BUILD)/iso_root/boot/esp.img
	cp $(EFI_LOADER) $(BUILD)/iso_root/EFI/BOOT/BOOTX64.EFI
	$(XORRISO) -as mkisofs -R -r -J -iso-level 3 -eltorito-alt-boot \
		-e boot/esp.img -no-emul-boot -isohybrid-gpt-basdat $(BUILD)/iso_root -o $@

clean:
	rm -f $(KERNEL) $(EFI_LOADER) $(ESP) $(ISO) $(INTERRUPT_OBJECT) $(MP3_OBJECT) $(H264_OBJECTS)
	rm -rf $(GENERATED) $(BUILD)/iso_root
