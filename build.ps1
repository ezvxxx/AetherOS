param(
    [string]$Zig = "zig",
    [switch]$Iso,
    [switch]$SkipDiskImageChecks,
    [string]$Xorriso = "xorriso",
    [ValidateRange(1, 16128)][int]$ApfsSizeMiB = 256
)

$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot
$Build = Join-Path $Root "build"
New-Item -ItemType Directory -Force -Path $Build | Out-Null

$InterruptObject = Join-Path $Build "interrupt_stubs.o"
& $Zig build-obj (Join-Path $Root "arch\interrupt_stubs.S") `
    -target x86_64-freestanding-none ("-femit-bin=" + $InterruptObject)
if ($LASTEXITCODE -ne 0) { throw "Could not assemble x86-64 interrupt stubs." }

$Mp3Object = Join-Path $Build "aether_mp3.o"
& $Zig build-obj (Join-Path $Root "third_party\minimp3\aether_mp3.c") `
    -target x86_64-freestanding-none -O ReleaseFast -fno-builtin `
    ("-I" + (Join-Path $Root "third_party\minimp3")) `
    ("-femit-bin=" + $Mp3Object)
if ($LASTEXITCODE -ne 0) { throw "Could not build the freestanding MP3 decoder." }

# TinyH264 is the Apache-2.0 h264bsd C decoder. Compile each translation unit
# separately so its file-local helper symbols remain isolated.
$H264Objects = @()
$H264Native = Join-Path $Root "third_party\tinyh264\native"
foreach ($source in Get-ChildItem $H264Native -Filter "*.c" | Sort-Object Name) {
    $object = Join-Path $Build ("h264_" + $source.BaseName + ".o")
    & $Zig build-obj $source.FullName -target x86_64-freestanding-none -O ReleaseFast -fno-builtin `
        ("-I" + (Join-Path $Root "third_party\tinyh264\port")) `
        ("-I" + $H264Native) `
        ("-femit-bin=" + $object)
    if ($LASTEXITCODE -ne 0) { throw "Could not compile TinyH264 source $($source.Name)." }
    $H264Objects += $object
}

# Generate Arix's HTML entity, local-name, and encoding tables without running
# its desktop build (which also resolves host font libraries).
$ArixRoot = Join-Path $Root "third_party\arix"
$ArixGenerated = Join-Path $Build "arix_generated"
New-Item -ItemType Directory -Force -Path $ArixGenerated | Out-Null
Push-Location $ArixRoot
try {
    & $Zig run src\gen\local_name.zig -- res\json\local_names.json (Join-Path $ArixGenerated "local_name.zig")
    if ($LASTEXITCODE -ne 0) { throw "Could not generate Arix local-name tables." }
    & $Zig run src\gen\named_ref.zig -- res\json\named_char_refs.json (Join-Path $ArixGenerated "named_ref.zig")
    if ($LASTEXITCODE -ne 0) { throw "Could not generate Arix HTML entity tables." }
} finally {
    Pop-Location
}
$Strale = Get-ChildItem (Join-Path $ArixRoot "zig-pkg") -Directory | Where-Object Name -Like "strale-*" | Select-Object -First 1
if (-not $Strale) { throw "Arix Strale dependency is missing from third_party\arix\zig-pkg." }

& $Zig build-exe $InterruptObject $Mp3Object $H264Objects `
    -target x86_64-freestanding-none -mcmodel=kernel -mno-red-zone `
    -O ReleaseFast -fstrip -fentry=_start `
    ("-T" + (Join-Path $Root "linker.ld")) `
    ("-femit-bin=" + (Join-Path $Build "kernel.elf")) `
    --dep z2dimg --dep z2d --dep vp8 --dep arix_renderer ("-Mroot=" + (Join-Path $Root "kernel.zig")) `
    --dep z2d --dep riff --dep vp8 ("-Mz2dimg=" + (Join-Path $Root "third_party\z2dimg\root.zig")) `
    --dep z2d_options ("-Mz2d=" + (Join-Path $Root "third_party\z2d\src\z2d.zig")) `
    ("-Mz2d_options=" + (Join-Path $Root "third_party\z2d_options.zig")) `
    ("-Mriff=" + (Join-Path $Root "third_party\riff\root.zig")) `
    ("-Mvp8=" + (Join-Path $Root "third_party\vp8\root.zig")) `
    --dep arix_core --dep strale --dep aether_font ("-Marix_renderer=" + (Join-Path $Root "ui\arix_renderer.zig")) `
    --dep strale --dep named_ref --dep local_name --dep config --dep aether_font ("-Marix_core=" + (Join-Path $ArixRoot "src\aether_renderer.zig")) `
    ("-Mstrale=" + (Join-Path $Strale.FullName "src\strale.zig")) `
    ("-Mnamed_ref=" + (Join-Path $ArixGenerated "named_ref.zig")) `
    --dep strale ("-Mlocal_name=" + (Join-Path $ArixGenerated "local_name.zig")) `
    ("-Mconfig=" + (Join-Path $ArixRoot "aether_config.zig")) `
    --dep z2d ("-Maether_font=" + (Join-Path $Root "arix_font.zig"))
if ($LASTEXITCODE -ne 0) { throw "Zig kernel build failed with exit code $LASTEXITCODE" }
& (Join-Path $Root "boot\compact-kernel.ps1") -Path (Join-Path $Build "kernel.elf")
if ($LASTEXITCODE -ne 0) { throw "Could not compact the kernel's zero-filled BSS segment." }
Write-Host "Built $Build\kernel.elf"
if (-not $Iso) { exit 0 }

$xorrisoCommand = Get-Command $Xorriso -ErrorAction SilentlyContinue
if (-not $xorrisoCommand -and $Xorriso -eq "xorriso") {
    foreach ($candidate in @("C:\msys64\usr\bin\xorriso.exe", "C:\tools\msys64\usr\bin\xorriso.exe")) {
        if (Test-Path -LiteralPath $candidate) { $xorrisoCommand = Get-Item -LiteralPath $candidate; break }
    }
}
if (-not $xorrisoCommand) { throw "xorriso is required for -iso. Install it with MSYS2 (pacman -S xorriso), add it to PATH, or pass -Xorriso <path>." }
$xorrisoExe = if ($xorrisoCommand -is [System.IO.FileInfo]) { $xorrisoCommand.FullName } elseif ($xorrisoCommand.Source) { $xorrisoCommand.Source } else { $xorrisoCommand.Path }


$efiLoader = Join-Path $Build "BOOTX64.EFI"
& $Zig build-exe (Join-Path $Root "boot\uefi.zig") -target x86_64-uefi -O ReleaseSmall -fstrip ("-femit-bin=" + $efiLoader)
if ($LASTEXITCODE -ne 0) { throw "Could not build the AetherOS UEFI loader." }

$esp = Join-Path $Build "aetheros-esp.img"
& (Join-Path $Root "boot\make-esp.ps1") -EfiFile $efiLoader -KernelFile (Join-Path $Build "kernel.elf") -ImageFile $esp
if ($LASTEXITCODE -ne 0) { throw "Could not create the EFI system image." }

$isoRoot = Join-Path $Build "iso_root"
if (Test-Path -LiteralPath $isoRoot) {
    $buildFull = [System.IO.Path]::GetFullPath($Build).TrimEnd('\') + '\'
    $isoRootFull = [System.IO.Path]::GetFullPath($isoRoot)
    if (-not $isoRootFull.StartsWith($buildFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clear an ISO staging path outside the build directory."
    }
}
$isoBoot = Join-Path $isoRoot "boot"
$isoEfi = Join-Path $isoRoot "EFI\BOOT"
New-Item -ItemType Directory -Force -Path $isoBoot, $isoEfi | Out-Null
# Older builds placed a second kernel ELF here even though the UEFI boot image
# already contains it. Remove that stale copy so the ISO stays compact.
Remove-Item (Join-Path $isoBoot "kernel.elf") -Force -ErrorAction SilentlyContinue
Copy-Item $esp (Join-Path $isoBoot "esp.img") -Force
Copy-Item $efiLoader (Join-Path $isoEfi "BOOTX64.EFI") -Force
$isoPath = Join-Path $Build "aetheros.iso"
$isoRootFull = [System.IO.Path]::GetFullPath($isoRoot)
$driveLetter = $isoRootFull.Substring(0, 1).ToLowerInvariant()
$isoRootArg = "/$driveLetter/" + $isoRootFull.Substring(3).Replace("\", "/")
$isoPathArg = $isoPath.Replace("\", "/")
& $xorrisoExe -as mkisofs -R -r -J -iso-level 3 `
    -eltorito-alt-boot -e boot/esp.img -no-emul-boot -isohybrid-gpt-basdat `
    $isoRootArg -o $isoPathArg
if ($LASTEXITCODE -ne 0) { throw "xorriso failed with exit code $LASTEXITCODE" }
if ($SkipDiskImageChecks) {
    Write-Host "Skipped persistent disk image checks; existing ext2, APFS, and USB images were left untouched."
} else {
    $dataImage = Join-Path $Build "aether-disk-ext2.img"
    $legacyDataImage = Join-Path $Build "aetheros-data.img"
    if (-not (Test-Path -LiteralPath $dataImage) -and (Test-Path -LiteralPath $legacyDataImage)) {
        Move-Item -LiteralPath $legacyDataImage -Destination $dataImage
        Write-Host "Renamed the existing persistent ext2 disk to $dataImage"
    }
    & (Join-Path $Root "make-ext2-image.ps1") -Path $dataImage
    if ($LASTEXITCODE -ne 0) { throw "Could not create or verify the persistent ext2 data image." }
    # Keep the APFS target separate from the existing ext2 disk. The formatter is
    # native Zig code shared with the kernel driver; it refuses non-empty images.
    $apfsImage = Join-Path $Build "aether-disk.img"
    if (-not (Test-Path -LiteralPath $apfsImage)) {
        $stream = [IO.File]::Open($apfsImage, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.SetLength([long]$ApfsSizeMiB * 1MB) } finally { $stream.Dispose() }
        Write-Host "Created APFS target disk: $apfsImage"
    }
    $apfsMagicStream = [IO.File]::OpenRead($apfsImage)
    try {
        if ($apfsMagicStream.Length -lt 4096) { throw "APFS target image is too small." }
        $null = $apfsMagicStream.Seek(32, [IO.SeekOrigin]::Begin)
        $apfsMagicBytes = New-Object byte[] 4
        $null = $apfsMagicStream.Read($apfsMagicBytes, 0, 4)
        $apfsMagic = [Text.Encoding]::ASCII.GetString($apfsMagicBytes)
        $apfsMarkerMagic = ""
        $apfsMarkerVersion = 0
        if ($apfsMagicStream.Length -ge 8192) {
            $null = $apfsMagicStream.Seek($apfsMagicStream.Length - 4096, [IO.SeekOrigin]::Begin)
            $apfsMarkerMagicBytes = New-Object byte[] 8
            $null = $apfsMagicStream.Read($apfsMarkerMagicBytes, 0, 8)
            $apfsMarkerMagic = [Text.Encoding]::ASCII.GetString($apfsMarkerMagicBytes)
            $apfsMarkerVersionBytes = New-Object byte[] 4
            $null = $apfsMagicStream.Read($apfsMarkerVersionBytes, 0, 4)
            $apfsMarkerVersion = [BitConverter]::ToUInt32($apfsMarkerVersionBytes, 0)
        }
    } finally {
        $apfsMagicStream.Dispose()
    }
    $apfsFormatter = Join-Path $Build "apfs-format"
    & $Zig build-exe (Join-Path $Root "fs\apfs_format_image.zig") -O ReleaseFast ("-femit-bin=" + $apfsFormatter)
    if ($LASTEXITCODE -ne 0) { throw "Could not build the native APFS formatter." }
    $apfsFormatterExe = $apfsFormatter + ".exe"
    Copy-Item -LiteralPath $apfsFormatter -Destination $apfsFormatterExe -Force
    if ($apfsMagic -eq "NXSB") {
        if ($apfsMarkerMagic -eq "AETHAPFS" -and $apfsMarkerVersion -eq 1) {
            # Upgrade only the exact pristine prior AetherOS layout. The Zig host
            # tool validates it and scans the unallocated region before writing.
            & $apfsFormatterExe --upgrade-virgin $apfsImage
        } else {
            Write-Host "Preserving existing APFS disk image: $apfsImage (allocator marker version $apfsMarkerVersion)"
        }
    } else {
        & $apfsFormatterExe $apfsImage
    }
    if ($LASTEXITCODE -ne 0) { throw "APFS format/upgrade failed with exit code $LASTEXITCODE." }
    $usbDataImage = Join-Path $Build "aetheros-usb-data.img"
    & (Join-Path $Root "make-fat32-image.ps1") -Path $usbDataImage
    if ($LASTEXITCODE -ne 0) { throw "Could not create or verify the USB FAT32 test image." }
}
Write-Host "Built UEFI bootable ISO: $isoPath"
$qemuShare = "C:\Program Files\qemu\share"
$ovmfCode = Join-Path $qemuShare "edk2-x86_64-code.fd"
$ovmfVars = Join-Path $qemuShare "edk2-i386-vars.fd"
if ((Test-Path -LiteralPath $ovmfCode) -and (Test-Path -LiteralPath $ovmfVars)) {
    Copy-Item -LiteralPath $ovmfCode -Destination (Join-Path $Build "uefi-code.fd") -Force
    $varsCopy = Join-Path $Build "uefi-vars.fd"
    # Start with clean firmware NVRAM. A stale BootOrder/Boot#### entry can
    # send OVMF to its shell instead of the freshly built removable-media ISO.
    Copy-Item -LiteralPath $ovmfVars -Destination $varsCopy -Force
    Write-Host "Run: qemu-system-x86_64.exe -machine pc -cpu max -boot order=d -drive if=pflash,format=raw,unit=0,readonly=on,file=build/uefi-code.fd -drive if=pflash,format=raw,unit=1,file=build/uefi-vars.fd -m 1024M -device VGA,edid=on,xres=1920,yres=1080 -device qemu-xhci,id=xhci -drive if=none,id=usbdata,file=build/aetheros-usb-data.img,format=raw -device usb-storage,bus=xhci.0,drive=usbdata -drive file=build/aether-disk-ext2.img,format=raw,if=ide,index=0 -drive file=build/aether-disk.img,format=raw,if=ide,index=1 -netdev user,id=net0 -device e1000,netdev=net0 -cdrom build/aetheros.iso"
} else {
    Write-Host "Run with OVMF using -drive if=pflash (not -bios), adding its code and writable vars images as units 0 and 1."
}
