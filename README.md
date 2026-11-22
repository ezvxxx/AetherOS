# AetherOS

<p align="center"><img src="assets/aetheros-logo.png" alt="AetherOS logo" width="160"></p>

AetherOS is a small 64-bit x86 kernel written in Zig. The project includes a standalone UEFI ELF loader in `boot/uefi.zig`; the build no longer uses Limine.

## Build on Windows

Build the kernel ELF:

```powershell
.\build.ps1
```

Build a UEFI bootable ISO:

```powershell
.\build.ps1 -iso
```

For a newly created APFS data image, set its capacity in MiB (1–16,128 MiB, the current native allocator limit):

```powershell
.\build.ps1 -iso -ApfsSizeMiB 1024
```

The ISO is `build/aetheros.iso`. It contains an EFI System Partition with `BOOTX64.EFI`. The EFI loader embeds the kernel, initializes GOP, collects the UEFI memory map, exits boot services, and transfers control using the shared handoff in `boot/info.zig`. The script preserves the ext2 data disk at `build/aether-disk-ext2.img` and creates a separate 256 MiB raw APFS target at `build/aether-disk.img` by default. The size option applies only when that image is first created; existing images are preserved. ISO creation requires `xorriso` (MSYS2: `pacman -S xorriso`).

Run under QEMU with OVMF UEFI firmware:

```powershell
qemu-system-x86_64.exe -machine pc -cpu max -boot order=d -drive if=pflash,format=raw,unit=0,readonly=on,file=build/uefi-code.fd -drive if=pflash,format=raw,unit=1,file=build/uefi-vars.fd -m 1024M -device VGA,edid=on,xres=1920,yres=1080 -device qemu-xhci,id=xhci -drive if=none,id=usbdata,file=build/aetheros-usb-data.img,format=raw -device usb-storage,bus=xhci.0,drive=usbdata -drive file=build/aether-disk-ext2.img,format=raw,if=ide,index=0 -drive file=build/aether-disk.img,format=raw,if=ide,index=1 -netdev user,id=net0 -device e1000,netdev=net0 -cdrom build/aetheros.iso
```

Use the pflash drives for OVMF firmware; `-bios` expects a legacy BIOS image and cannot load this OVMF code file. Legacy BIOS boot is not implemented yet; the custom loader currently supports UEFI.

## Build on Linux

The Linux build uses the same x86-64 kernel sources and Zig module graph as the PowerShell build. It requires Zig 0.17.x, GNU Make, Python 3, and `xorriso` for ISO creation. On Arch Linux / EndeavourOS, install Zig and xorriso with:

```sh
sudo pacman -S --needed zig libisoburn
```

From this directory, build the kernel ELF or a bootable UEFI ISO (`make` builds the ISO by default):

```sh
make kernel
make iso
```

`make iso` writes `build/aetheros.iso`. Install `qemu-ui-gtk` to use `make run` for a native QEMU window; it uses OVMF from `/usr/share/edk2/x64/` and preserves the writable firmware variables file at `build/uefi-vars.fd`. `make clean` removes generated kernel, EFI loader, ESP, ISO, and intermediate object files. Persistent ext2/APFS/USB data-image provisioning from the Windows `build.ps1 -iso` workflow is not included in the Linux Makefile yet.

`drivers/sata.zig` is the native AHCI driver: it discovers PCI AHCI controllers, configures port DMA structures, and reads/writes ATA LBA48 sectors through 48-bit LBAs. The sector layer uses AHCI SATA when present, legacy IDE PIO as a fallback, and xHCI mass storage for USB. The build initializes a blank `aether-disk.img` with AetherOS's native Zig APFS formatter and refuses to format a non-empty image. `fs/apfs.zig` validates every reachable filesystem-tree node and fails closed on unreadable or checksum-invalid child nodes, scans contiguous or extent-tree-mapped checkpoint descriptor areas for the newest valid container superblock, resolves the checkpoint-mapped space-manager object, and validates its block size, device capacity, and free-block count before mounting and browsing unencrypted APFS volumes and reading plain, uncompressed data extents. It supports guarded same-size data overwrites on eligible external volumes. AetherOS-formatted volumes also support file creation/replacement, directory creation, rename, and recursive deletion using append-only COW metadata blocks and checkpoint NXSB-last publication. The native writer loads and cross-checks APFS CIBs and per-chunk bitmaps, then reserves free runs from those bitmaps for file data and COW metadata; file data can span multiple extents, and CIB counts and bitmap copies are updated before publishing the next checkpoint. Replacing or deleting files (including files removed by recursive directory deletion) returns their old data extents to the committed allocation bitmap after reserving the transaction's new COW metadata. The formatter and native allocator now cover all 126 chunk descriptors in one APFS CIB (up to 15.75 GiB at 4 KiB blocks). The filesystem-tree writer emits a root with multiple leaf nodes when needed and stores up to 2,048 filesystem records in static kernel workspace and lists up to 2,048 directory entries per browser view; commits update checkpoint-map references, the COW space manager, next object ID, inode counters, and APFS volume allocation counters. The formatter emits a minimal checkpoint ring, checkpoint map, space manager, chunk-info and bitmap blocks, and an empty reaper. The build upgrades only a rigorously checked empty image from the immediately prior AetherOS format; it leaves populated or unknown images untouched. This remains a limited unencrypted APFS implementation, not full APFS compatibility: each metadata transaction needs one contiguous run, old COW metadata is reclaimed by AetherOS journaled COW transactions when its checkpoint slot is evicted (the private journal does not implement APFS free queues), external-volume structural writes, deeper multi-level B-trees, snapshots, encryption, and compressed data are unsupported. The persistent `aether-disk-ext2.img` remains ext2 (4 KiB blocks), and FAT32 remains supported for existing images and USB media. Terminal commands include `help`, `ls`, `cd`, `pwd`, `mkdir`, `cat`, `touch`, `write`, `rm`, `edit`, `clear`, and `about`.

Wired networking currently targets QEMU's Intel E1000 adapter. DHCPv4 performs Discover/Offer/Request/Ack, validates the transaction and checksums, parses overloaded options, requests lease timers, MTU, DNS and classless routes, probes the offered address with ARP, sends DHCPDECLINE on a conflict, renews at T1, rebinds at T2, and clears an expired lease. The driver keeps the first two DNS servers and up to eight classless IPv4 routes.

`network/stack.zig` provides bounded IPv4/ARP, UDP socket queues, TCP client sockets, and TCP `listen`/`accept`. It validates IPv4 and transport checksums, reassembles four concurrent IPv4 datagrams up to 8 KiB, answers ICMP echo requests, returns UDP port-unreachable errors, reports incoming ICMP errors to sockets, manages expiring ARP neighbors, and sends UDP checksums. TCP includes MSS negotiation, sequence/window validation, randomized initial sequence numbers and ephemeral ports, a receive window, slow start, congestion avoidance, NewReno-style fast recovery, RTT-based retransmission timers, exponential timeout backoff, persist probes, retransmission, connection setup/teardown, and a small listen backlog. The implementation uses bounded buffers and polling. `network/dns.zig` provides asynchronous IPv4 A lookups, CNAME chains, TTL caching, EDNS0, randomized transaction IDs and source ports, retry/failover to a second DNS server, and DNS-over-TCP fallback. `network/tls.zig` wraps Zig's TLS 1.2/1.3 client with hostname and CA-bundle verification and PEM CA parsing. DHCP, DNS, TCP, and TLS randomness requires CPU RDRAND; use `-cpu max` in QEMU.

The Browser app is available from Start and the dock. Enter an HTTP or HTTPS URL or a search phrase in the address bar (`Ctrl+L` focuses it). Search uses Google's basic HTML results endpoint. The browser is IPv4-only and accepts ASCII hostnames.

AetherOS's native Zig web engine tokenizes HTML, applies a subset of CSS, lays out the document, and paints it with the OS graphics routines. It supports headings, links, lists, basic tables, inline images and SVG, and block and inline flow. CSS support includes tag, class, and ID selectors, colors, backgrounds, basic sizing and spacing, and text alignment. The browser also supports top-level literal `insertAdjacentHTML` calls on the document body and its children, including calls from scripts served by the same origin. It supports UTF-8 text, a fallback for common Simplified Chinese characters, and basic Arabic joining in right-to-left paragraphs. General JavaScript, full bidirectional shaping, interactive forms, Flexbox, and Grid are unsupported.

The Media Player handles WAV/MP3 audio, Motion JPEG in MP4, all-intra VP8 in MKV, and software-decoded H.264 Baseline/Constrained Baseline in MP4/MKV (CAVLC, I/P frames, no B-frames; video files are limited to 8 MiB and 4096 frames). First boot installs `H264 demo.mp4` and `H264 demo.mkv` in `/home/aether`.

The browser automatically saves HTTP attachments, non-page MIME types, and file URLs with extensions to `/home/<account>/Downloads`; the Downloads panel lists saved filenames and sizes. Download bodies are limited to 64 MiB. HTML and plain-text responses continue to render as pages.


This is a useful subset for the current QEMU/E1000 kernel, not complete RFC coverage. The IPv4 MTU defaults to 1500 and follows DHCP option 26 when provided. The stack has no IPv6, Neighbor Discovery, SLAAC, DHCPv6, VLAN, Wi-Fi, IPsec, DNSSEC, DNS-over-TLS, or DNS-over-HTTPS. TCP does not yet implement window scaling, SACK, timestamps, ECN, urgent data, or out-of-order receive buffering. TLS fails closed without trusted roots, a valid wall clock, and fresh hardware entropy.

## Source layout

- `boot/` — shared boot protocol, UEFI ELF loader, EFI system image generator.
- `arch/` — x86-64 CPU setup, I/O, IDT/PIC/PIT, and assembly interrupt stubs.
- `drivers/` — AHCI SATA, legacy ATA PIO, xHCI, E1000 Ethernet, PS/2 keyboard/mouse, and RTC.
- `fs/` — ext2 driver, FAT32 driver, and filesystem selector.
- `graphics/` — framebuffer drawing primitives and bitmap font.
- `network/` — IPv4 sockets, DNS, TLS, and the embedded Mozilla CA roots.
- `memory/` — physical page allocator, virtual page mapper, and early heap.
- `shell/` — in-kernel text editor.
- `system/` — shared kernel and desktop state.
- `ui/` — desktop, text browser, and built-in apps.
- `kernel.zig` — kernel startup and main loop.
- `build.ps1` — Windows kernel and ISO build.
