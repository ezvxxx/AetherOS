param(
    [Parameter(Mandatory = $true)][string]$Path,
    [ValidateRange(64, 128)][int]$SizeMiB = 128
)
$ErrorActionPreference = "Stop"
$BlockSize = 4096
$BlockCount = $SizeMiB * 256
$InodeCount = [Math]::Max(1024, [int]($BlockCount / 4))
$InodeSize = 128
$InodeTableBlocks = [int][Math]::Ceiling(($InodeCount * $InodeSize) / $BlockSize)
$BlockBitmap = 2
$InodeBitmap = 3
$InodeTable = 4
$FirstDataBlock = $InodeTable + $InodeTableBlocks
$FullPath = [IO.Path]::GetFullPath($Path)
$Parent = [IO.Path]::GetDirectoryName($FullPath)
if (-not (Test-Path -LiteralPath $Parent)) { New-Item -ItemType Directory -Force -Path $Parent | Out-Null }
if (Test-Path -LiteralPath $FullPath) {
    $Existing = [IO.File]::OpenRead($FullPath)
    try {
        $S = [byte[]]::new(1024)
        if ($Existing.Length -ge 2048) { $Existing.Position = 1024; [void]$Existing.Read($S, 0, 1024) }
        if ([BitConverter]::ToUInt16($S, 56) -eq 0xef53 -and [BitConverter]::ToUInt32($S, 20) -eq 0 -and
            [BitConverter]::ToUInt32($S, 24) -eq 2 -and ([BitConverter]::ToUInt32($S, 96) -band 2) -ne 0) {
            Write-Host "Preserving existing ext2 disk image: $FullPath"; return
        }
        $HasExt2Signature = [BitConverter]::ToUInt16($S, 56) -eq 0xef53
        $IsFat = $Existing.Length -ge (2049 * 512)
        if ($IsFat) {
            $Existing.Position = 2048 * 512
            $Boot = [byte[]]::new(512); [void]$Existing.Read($Boot, 0, 512)
            $IsFat = [Text.Encoding]::ASCII.GetString($Boot, 82, 5) -eq "FAT32"
        }
    } finally { $Existing.Dispose() }
    if ($HasExt2Signature) {
        $Recovery = Join-Path $Parent "aetheros-data-ext2-recovery.img"
        if (-not (Test-Path -LiteralPath $Recovery)) { Copy-Item -LiteralPath $FullPath -Destination $Recovery }
        Write-Warning "The old ext2 image has invalid geometry. Preserved it at $Recovery before rebuilding."
    }
    if ($IsFat) {
        $Legacy = Join-Path $Parent "aetheros-data-fat32.img"
        if (-not (Test-Path -LiteralPath $Legacy)) { Copy-Item -LiteralPath $FullPath -Destination $Legacy }
        else { Write-Warning "Existing FAT32 image is preserved at $Legacy; retaining that backup." }
        Write-Host "Preserved the previous FAT32 disk at $Legacy before replacing the default image."
    }
}
$Stream = [IO.File]::Open($FullPath, [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    $Stream.SetLength([long]$BlockCount * $BlockSize)
    $Super = [byte[]]::new(1024)
    [BitConverter]::GetBytes([uint32]$InodeCount).CopyTo($Super, 0)
    [BitConverter]::GetBytes([uint32]$BlockCount).CopyTo($Super, 4)
    [BitConverter]::GetBytes([uint32]($BlockCount - $FirstDataBlock - 1)).CopyTo($Super, 12)
    [BitConverter]::GetBytes([uint32]($InodeCount - 10)).CopyTo($Super, 16)
    [BitConverter]::GetBytes([uint32]0).CopyTo($Super, 20)
    [BitConverter]::GetBytes([uint32]2).CopyTo($Super, 24)
    [BitConverter]::GetBytes([uint32]2).CopyTo($Super, 28)
    [BitConverter]::GetBytes([uint32]$BlockCount).CopyTo($Super, 32)
    [BitConverter]::GetBytes([uint32]$BlockCount).CopyTo($Super, 36)
    [BitConverter]::GetBytes([uint32]$InodeCount).CopyTo($Super, 40)
    [BitConverter]::GetBytes([uint16]0xef53).CopyTo($Super, 56)
    [BitConverter]::GetBytes([uint16]1).CopyTo($Super, 58)
    [BitConverter]::GetBytes([uint16]1).CopyTo($Super, 60)
    [BitConverter]::GetBytes([uint16]0xffff).CopyTo($Super, 54)
    [BitConverter]::GetBytes([uint32]1).CopyTo($Super, 76)
    [BitConverter]::GetBytes([uint32]11).CopyTo($Super, 84)
    [BitConverter]::GetBytes([uint16]$InodeSize).CopyTo($Super, 88)
    [BitConverter]::GetBytes([uint32]2).CopyTo($Super, 96)
    [BitConverter]::GetBytes([uint32]0).CopyTo($Super, 100)
    [BitConverter]::GetBytes([uint32]0).CopyTo($Super, 104)
    [BitConverter]::GetBytes([uint32]0).CopyTo($Super, 108)
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes("AetherOS"), 0, $Super, 120, 8)
    $Stream.Position = 1024; $Stream.Write($Super, 0, $Super.Length)
    $Group = [byte[]]::new($BlockSize)
    [BitConverter]::GetBytes([uint32]$BlockBitmap).CopyTo($Group, 0)
    [BitConverter]::GetBytes([uint32]$InodeBitmap).CopyTo($Group, 4)
    [BitConverter]::GetBytes([uint32]$InodeTable).CopyTo($Group, 8)
    [BitConverter]::GetBytes([uint16]($BlockCount - $FirstDataBlock - 1)).CopyTo($Group, 12)
    [BitConverter]::GetBytes([uint16]($InodeCount - 10)).CopyTo($Group, 14)
    [BitConverter]::GetBytes([uint16]1).CopyTo($Group, 16)
    $Stream.Position = [long]$BlockSize; $Stream.Write($Group, 0, $Group.Length)
    $Bitmap = [byte[]]::new($BlockSize)
    for ($i = 0; $i -le $FirstDataBlock; $i++) { $byteIndex = $i -shr 3; $Bitmap[$byteIndex] = $Bitmap[$byteIndex] -bor [byte](1 -shl ($i % 8)) }
    $Stream.Position = [long]$BlockBitmap * $BlockSize; $Stream.Write($Bitmap, 0, $Bitmap.Length)
    $IBitmap = [byte[]]::new($BlockSize)
    for ($i = 0; $i -lt 10; $i++) { $byteIndex = $i -shr 3; $IBitmap[$byteIndex] = $IBitmap[$byteIndex] -bor [byte](1 -shl ($i % 8)) }
    for ($i = $InodeCount; $i -lt ($BlockSize * 8); $i++) { $byteIndex = $i -shr 3; $IBitmap[$byteIndex] = $IBitmap[$byteIndex] -bor [byte](1 -shl ($i % 8)) }
    $Stream.Position = [long]$InodeBitmap * $BlockSize; $Stream.Write($IBitmap, 0, $IBitmap.Length)
    $InodeBlock = [byte[]]::new($BlockSize)
    $Now = [uint32][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    [BitConverter]::GetBytes([uint16]0x41ed).CopyTo($InodeBlock, 128)
    [BitConverter]::GetBytes([uint32]$BlockSize).CopyTo($InodeBlock, 132)
    [BitConverter]::GetBytes([uint32]8).CopyTo($InodeBlock, 156)
    [BitConverter]::GetBytes([uint32]$FirstDataBlock).CopyTo($InodeBlock, 168)
    [BitConverter]::GetBytes([uint16]2).CopyTo($InodeBlock, 154)
    [BitConverter]::GetBytes([uint32]$Now).CopyTo($InodeBlock, 136)
    [BitConverter]::GetBytes([uint32]$Now).CopyTo($InodeBlock, 140)
    [BitConverter]::GetBytes([uint32]$Now).CopyTo($InodeBlock, 144)
    $Stream.Position = [long]$InodeTable * $BlockSize; $Stream.Write($InodeBlock, 0, $InodeBlock.Length)
    $Root = [byte[]]::new($BlockSize)
    [BitConverter]::GetBytes([uint32]2).CopyTo($Root, 0); [BitConverter]::GetBytes([uint16]12).CopyTo($Root, 4); $Root[6] = 1; $Root[7] = 2; $Root[8] = 46
    [BitConverter]::GetBytes([uint32]2).CopyTo($Root, 12); [BitConverter]::GetBytes([uint16]($BlockSize - 12)).CopyTo($Root, 16); $Root[18] = 2; $Root[19] = 2; $Root[20] = 46; $Root[21] = 46
    $Stream.Position = [long]$FirstDataBlock * $BlockSize; $Stream.Write($Root, 0, $Root.Length)
} finally { $Stream.Dispose() }
Write-Host "Created ext2 data image: $FullPath ($SizeMiB MiB, 4 KiB blocks)"
