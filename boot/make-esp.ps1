param(
    [Parameter(Mandatory = $true)][string]$EfiFile,
    [Parameter(Mandatory = $true)][string]$KernelFile,
    [Parameter(Mandatory = $true)][string]$ImageFile
)
$ErrorActionPreference = 'Stop'
$SectorSize = 512
$TotalSectors = 64000
# A 32 MiB FAT16 ESP is ample once the kernel's zero-fill BSS is not stored as
# hundreds of megabytes of padding in the ELF file. Keep it below the El Torito
# 16-bit load-size limit as well.
$SectorsPerCluster = 8
$FatSectors = 48
$RootEntries = 512
$RootSectors = 32
$DataStart = 1 + 2 * $FatSectors + $RootSectors
$ClusterBytes = $SectorSize * $SectorsPerCluster
$DataClusters = [int][Math]::Floor(($TotalSectors - $DataStart) / $SectorsPerCluster)
if ($DataClusters -lt 4085 -or $DataClusters -ge 65525) { throw 'The generated EFI volume does not fit FAT16 cluster limits.' }
$fullImage = [IO.Path]::GetFullPath($ImageFile)
$parent = [IO.Path]::GetDirectoryName($fullImage)
New-Item -ItemType Directory -Force -Path $parent | Out-Null
$bytes = [byte[]]::new($TotalSectors * $SectorSize)

function Put16([byte[]]$b, [int]$offset, [uint16]$value) {
    $b[$offset] = [byte]($value -band 255)
    $b[$offset + 1] = [byte](($value -shr 8) -band 255)
}
function Put32([byte[]]$b, [int]$offset, [uint32]$value) {
    for ($i = 0; $i -lt 4; $i++) { $b[$offset + $i] = [byte](($value -shr (8 * $i)) -band 255) }
}
function SetFat16([byte[]]$fat, [int]$cluster, [int]$value) {
    Put16 $fat ($cluster * 2) ([uint16]$value)
}
function SetEntry([byte[]]$b, [int]$offset, [string]$name, [byte]$attributes, [int]$cluster, [long]$size) {
    $n = [Text.Encoding]::ASCII.GetBytes($name.PadRight(11).Substring(0, 11))
    [Array]::Copy($n, 0, $b, $offset, 11)
    $b[$offset + 11] = $attributes
    Put16 $b ($offset + 26) ([uint16]$cluster)
    Put32 $b ($offset + 28) ([uint32]$size)
}

# FAT16 superfloppy boot sector (the ISO's El Torito EFI entry points here).
$bytes[0] = 0xeb; $bytes[1] = 0x3c; $bytes[2] = 0x90
[Array]::Copy([Text.Encoding]::ASCII.GetBytes('AETHEROS'), 0, $bytes, 3, 8)
Put16 $bytes 11 512; $bytes[13] = $SectorsPerCluster; Put16 $bytes 14 1
$bytes[16] = 2; Put16 $bytes 17 $RootEntries; Put16 $bytes 19 0
$bytes[32] = [byte]($TotalSectors -band 255)
$bytes[33] = [byte](($TotalSectors -shr 8) -band 255)
$bytes[34] = [byte](($TotalSectors -shr 16) -band 255)
$bytes[35] = [byte](($TotalSectors -shr 24) -band 255)
$bytes[21] = 0xf8; Put16 $bytes 22 $FatSectors; Put16 $bytes 24 18; Put16 $bytes 26 2
$bytes[38] = 0x29; Put32 $bytes 39 0x41544852
[Array]::Copy([Text.Encoding]::ASCII.GetBytes('AETHEROS   '), 0, $bytes, 43, 11)
[Array]::Copy([Text.Encoding]::ASCII.GetBytes('FAT16   '), 0, $bytes, 54, 8)
$bytes[510] = 0x55; $bytes[511] = 0xaa

$efiBytes = [IO.File]::ReadAllBytes([IO.Path]::GetFullPath($EfiFile))
$kernelBytes = [IO.File]::ReadAllBytes([IO.Path]::GetFullPath($KernelFile))
$efiClusters = [int][Math]::Ceiling($efiBytes.Length / [double]$ClusterBytes)
$kernelClusters = [int][Math]::Ceiling($kernelBytes.Length / [double]$ClusterBytes)
$kernelStart = 4 + $efiClusters
if ($efiClusters + $kernelClusters + 2 -gt $DataClusters) { throw 'The EFI loader and kernel do not fit in the generated FAT16 EFI image.' }
$fat = [byte[]]::new($FatSectors * $SectorSize)
SetFat16 $fat 0 0xfff8; SetFat16 $fat 1 0xffff
SetFat16 $fat 2 0xffff; SetFat16 $fat 3 0xffff
for ($i = 0; $i -lt $efiClusters; $i++) { SetFat16 $fat (4 + $i) $(if ($i + 1 -eq $efiClusters) { 0xffff } else { 5 + $i }) }
for ($i = 0; $i -lt $kernelClusters; $i++) { SetFat16 $fat ($kernelStart + $i) $(if ($i + 1 -eq $kernelClusters) { 0xffff } else { $kernelStart + $i + 1 }) }
for ($copy = 0; $copy -lt 2; $copy++) {
    [Array]::Copy($fat, 0, $bytes, (1 + $copy * $FatSectors) * $SectorSize, $fat.Length)
}

# Root -> EFI directory (cluster 2) -> BOOT directory (cluster 3) -> executable.
$rootOffset = (1 + 2 * $FatSectors) * $SectorSize
SetEntry $bytes $rootOffset 'EFI' 0x10 2 0
SetEntry $bytes ($rootOffset + 32) 'KERNEL  ELF' 0x20 $kernelStart $kernelBytes.Length
$dataOffset = $DataStart * $SectorSize
$efiDir = $dataOffset + (2 - 2) * $ClusterBytes
SetEntry $bytes $efiDir '.' 0x10 2 0; SetEntry $bytes ($efiDir + 32) '..' 0x10 0 0
SetEntry $bytes ($efiDir + 64) 'BOOT' 0x10 3 0
$bootDir = $dataOffset + (3 - 2) * $ClusterBytes
SetEntry $bytes $bootDir '.' 0x10 3 0; SetEntry $bytes ($bootDir + 32) '..' 0x10 2 0
SetEntry $bytes ($bootDir + 64) 'BOOTX64 EFI' 0x20 4 $efiBytes.Length
for ($i = 0; $i -lt $efiClusters; $i++) {
    $offset = $dataOffset + (4 + $i - 2) * $ClusterBytes
    $source = $i * $ClusterBytes
    $length = [Math]::Min($ClusterBytes, $efiBytes.Length - $source)
    [Array]::Copy($efiBytes, $source, $bytes, $offset, $length)
}
$kernelDataOffset = $dataOffset + ($kernelStart - 2) * $ClusterBytes
for ($i = 0; $i -lt $kernelClusters; $i++) {
    $offset = $kernelDataOffset + $i * $ClusterBytes
    $source = $i * $ClusterBytes
    $length = [Math]::Min($ClusterBytes, $kernelBytes.Length - $source)
    [Array]::Copy($kernelBytes, $source, $bytes, $offset, $length)
}
[IO.File]::WriteAllBytes($fullImage, $bytes)
Write-Host "Created EFI system image: $fullImage"
