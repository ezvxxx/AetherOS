param([Parameter(Mandatory = $true)][string]$Path)

$ErrorActionPreference = 'Stop'
$fullPath = [IO.Path]::GetFullPath($Path)
$stream = [IO.File]::Open($fullPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    $header = [byte[]]::new(64)
    if ($stream.Read($header, 0, $header.Length) -ne $header.Length) { throw 'Kernel ELF header is truncated.' }
    if ([Text.Encoding]::ASCII.GetString($header, 0, 4) -ne "ELF") { throw 'Kernel output is not an ELF file.' }

    $programOffset = [BitConverter]::ToUInt64($header, 32)
    $programEntrySize = [BitConverter]::ToUInt16($header, 54)
    $programCount = [BitConverter]::ToUInt16($header, 56)
    if ($programEntrySize -lt 56 -or $programCount -eq 0) { throw 'Kernel ELF has no valid program headers.' }
    if ($programOffset + [uint64]$programEntrySize * $programCount -gt [uint64]$stream.Length) { throw 'Kernel ELF program table is out of bounds.' }

    $maxFileEnd = [uint64]0
    $compactedBss = $false
    for ($i = 0; $i -lt $programCount; $i++) {
        $entryOffset = [long]($programOffset + [uint64]$i * $programEntrySize)
        $entry = [byte[]]::new($programEntrySize)
        $stream.Position = $entryOffset
        if ($stream.Read($entry, 0, $entry.Length) -ne $entry.Length) { throw 'Kernel ELF program table is truncated.' }
        $kind = [BitConverter]::ToUInt32($entry, 0)
        if ($kind -ne 1) { continue }

        $flags = [BitConverter]::ToUInt32($entry, 4)
        $fileOffset = [BitConverter]::ToUInt64($entry, 8)
        $fileSize = [BitConverter]::ToUInt64($entry, 32)
        $memorySize = [BitConverter]::ToUInt64($entry, 40)
        # The dedicated writable BSS load segment is pure zero-fill. Store its
        # memory size in ELF but remove the accidental zero-filled file payload.
        if ($flags -eq 6 -and $memorySize -gt 32MB -and $fileSize -eq $memorySize) {
            [Array]::Copy([BitConverter]::GetBytes([uint64]0), 0, $entry, 8, 8)
            [Array]::Copy([BitConverter]::GetBytes([uint64]0), 0, $entry, 32, 8)
            $stream.Position = $entryOffset
            $stream.Write($entry, 0, $entry.Length)
            $fileSize = 0
            $compactedBss = $true
        }
        if ($fileSize -gt 0) {
            $segmentEnd = $fileOffset + $fileSize
            if ($segmentEnd -gt [uint64]$stream.Length) { throw 'Kernel ELF load segment exceeds the file.' }
            if ($segmentEnd -gt $maxFileEnd) { $maxFileEnd = $segmentEnd }
        }
    }
    if (-not $compactedBss) { throw 'Could not find the large zero-fill BSS segment in the kernel ELF.' }

    # This stripped boot ELF uses only program headers. Discard the stale
    # section-name/symbol table that was placed after the former BSS payload.
    [Array]::Copy([BitConverter]::GetBytes([uint64]0), 0, $header, 40, 8)
    [Array]::Copy([BitConverter]::GetBytes([uint16]0), 0, $header, 58, 2)
    [Array]::Copy([BitConverter]::GetBytes([uint16]0), 0, $header, 60, 2)
    [Array]::Copy([BitConverter]::GetBytes([uint16]0), 0, $header, 62, 2)
    $stream.Position = 0
    $stream.Write($header, 0, $header.Length)
    if ($maxFileEnd -lt $stream.Length) { $stream.SetLength([long]$maxFileEnd) }
    Write-Host ("Compacted kernel ELF to {0:N1} MiB (BSS stays zero-filled in memory)." -f ($stream.Length / 1MB))
} finally {
    $stream.Dispose()
}
