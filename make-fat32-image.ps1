param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [ValidateRange(64, 2048)]
    [int]$SizeMiB = 128
)

$ErrorActionPreference = "Stop"
$SectorSize = 512
$PartitionStart = 2048
$PartitionSectors = [uint32]($SizeMiB * 2048)
$ReservedSectors = [uint32]32
$FatCount = [uint32]2
$FatSectors = [uint32]1

while ($true) {
    $ClusterCount = [uint32]($PartitionSectors - $ReservedSectors - ($FatCount * $FatSectors))
    $NeededFatSectors = [uint32][Math]::Ceiling(($ClusterCount + 2) / 128.0)
    if ($NeededFatSectors -eq $FatSectors) { break }
    $FatSectors = $NeededFatSectors
}
$ClusterCount = [uint32]($PartitionSectors - $ReservedSectors - ($FatCount * $FatSectors))
if ($ClusterCount -lt 65525) { throw "The selected image is too small for a FAT32 data region." }

function Set-U16([byte[]]$Buffer, [int]$Offset, [uint16]$Value) {
    $Bytes = [BitConverter]::GetBytes($Value)
    [Array]::Copy($Bytes, 0, $Buffer, $Offset, 2)
}

function Set-U32([byte[]]$Buffer, [int]$Offset, [long]$Value) {
    $UnsignedValue = $Value -band 0xffffffffL
    $Buffer[$Offset] = [byte]($UnsignedValue -band 0xff)
    $Buffer[$Offset + 1] = [byte](($UnsignedValue -shr 8) -band 0xff)
    $Buffer[$Offset + 2] = [byte](($UnsignedValue -shr 16) -band 0xff)
    $Buffer[$Offset + 3] = [byte](($UnsignedValue -shr 24) -band 0xff)
}

function Write-Sector([System.IO.FileStream]$Stream, [long]$Lba, [byte[]]$Data) {
    $Stream.Position = $Lba * 512
    $Stream.Write($Data, 0, 512)
}

$FullPath = [System.IO.Path]::GetFullPath($Path)
$Parent = [System.IO.Path]::GetDirectoryName($FullPath)
if (-not (Test-Path -LiteralPath $Parent)) { New-Item -ItemType Directory -Force -Path $Parent | Out-Null }
$FileMode = [System.IO.FileMode]::CreateNew
if (Test-Path -LiteralPath $FullPath) {
    $Existing = [System.IO.File]::OpenRead($FullPath)
    try {
        $ExistingBoot = [byte[]]::new(512)
        if ($Existing.Length -ge (([long]$PartitionStart + 1) * 512)) {
            $Existing.Position = [long]$PartitionStart * 512
            [void]$Existing.Read($ExistingBoot, 0, 512)
        }
        $HasFat32BootSector = $ExistingBoot[510] -eq 0x55 -and $ExistingBoot[511] -eq 0xaa -and
            [BitConverter]::ToUInt16($ExistingBoot, 11) -eq 512 -and
            [Text.Encoding]::ASCII.GetString($ExistingBoot, 82, 5) -eq "FAT32"
    } finally {
        $Existing.Dispose()
    }
    if ($HasFat32BootSector) {
        Write-Host "Preserving existing FAT32 disk image: $FullPath"
        return
    }
    Write-Warning "Replacing an incomplete FAT32 image created by a failed generator run."
    $FileMode = [System.IO.FileMode]::Create
}

$Stream = [System.IO.File]::Open($FullPath, $FileMode, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
try {
    $DiskSectors = [long]$PartitionStart + [long]$PartitionSectors
    $Stream.SetLength($DiskSectors * $SectorSize)

    $Mbr = [byte[]]::new($SectorSize)
    $Mbr[446] = 0
    $Mbr[447] = 0
    $Mbr[448] = 2
    $Mbr[449] = 0
    $Mbr[450] = 0x0c
    $Mbr[451] = 0xff
    $Mbr[452] = 0xff
    $Mbr[453] = 0xff
    Set-U32 $Mbr 454 ([uint32]$PartitionStart)
    Set-U32 $Mbr 458 $PartitionSectors
    $Mbr[510] = 0x55
    $Mbr[511] = 0xaa
    Write-Sector $Stream 0 $Mbr

    $Boot = [byte[]]::new($SectorSize)
    $Boot[0] = 0xeb
    $Boot[1] = 0x58
    $Boot[2] = 0x90
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes("AETHEROS"), 0, $Boot, 3, 8)
    Set-U16 $Boot 11 512
    $Boot[13] = 1
    Set-U16 $Boot 14 ([uint16]$ReservedSectors)
    $Boot[16] = [byte]$FatCount
    Set-U16 $Boot 17 0
    Set-U16 $Boot 19 0
    $Boot[21] = 0xf8
    Set-U16 $Boot 22 0
    Set-U16 $Boot 24 63
    Set-U16 $Boot 26 255
    Set-U32 $Boot 28 ([uint32]$PartitionStart)
    Set-U32 $Boot 32 $PartitionSectors
    Set-U32 $Boot 36 $FatSectors
    Set-U16 $Boot 40 0
    Set-U16 $Boot 42 0
    Set-U32 $Boot 44 2
    Set-U16 $Boot 48 1
    Set-U16 $Boot 50 6
    $Boot[64] = 0x80
    $Boot[66] = 0x29
    Set-U32 $Boot 67 0xAE7E2026
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes("AETHEROS   "), 0, $Boot, 71, 11)
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes("FAT32   "), 0, $Boot, 82, 8)
    $Boot[510] = 0x55
    $Boot[511] = 0xaa
    Write-Sector $Stream $PartitionStart $Boot
    Write-Sector $Stream ($PartitionStart + 6) $Boot

    $FsInfo = [byte[]]::new($SectorSize)
    Set-U32 $FsInfo 0 0x41615252
    Set-U32 $FsInfo 484 0x61417272
    Set-U32 $FsInfo 488 ($ClusterCount - 1)
    Set-U32 $FsInfo 492 3
    Set-U32 $FsInfo 508 0xaa550000
    Write-Sector $Stream ($PartitionStart + 1) $FsInfo
    Write-Sector $Stream ($PartitionStart + 7) $FsInfo

    $FatStart = [long]$PartitionStart + $ReservedSectors
    for ($Copy = 0; $Copy -lt $FatCount; $Copy++) {
        $FirstFatSector = [byte[]]::new($SectorSize)
        Set-U32 $FirstFatSector 0 0x0ffffff8
        Set-U32 $FirstFatSector 4 0xffffffff
        Set-U32 $FirstFatSector 8 0x0fffffff
        Write-Sector $Stream ($FatStart + ($Copy * $FatSectors)) $FirstFatSector
    }
} finally {
    $Stream.Dispose()
}

Write-Host "Created $SizeMiB MiB FAT32 disk image: $FullPath"
