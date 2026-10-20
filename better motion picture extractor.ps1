
param(
    [string]$Root = (Get-Location).ProviderPath,
    [string]$Destination = 'Motion_Pictures',
    [int]$BatchSize = 500,
    [switch]$Flatten,       # Put all images directly in the destination
    [switch]$Move           # Actually move files; default is dry-run
)

$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath($Root)
$Destination = if ([IO.Path]::IsPathRooted($Destination)) {
    [IO.Path]::GetFullPath($Destination)
} else {
    [IO.Path]::GetFullPath((Join-Path $Root $Destination))
}

if ($BatchSize -lt 1) { throw 'BatchSize must be at least 1.' }
if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    throw "Source folder not found: $Root"
}
$ExifTool = Get-Command exiftool -CommandType Application -ErrorAction Stop |
    Select-Object -First 1

# Exclude the destination tree and gather JPEGs.
$DestPrefix = $Destination.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
$Files = @(
    Get-ChildItem -LiteralPath $Root -File -Recurse -ErrorAction Stop |
        Where-Object {
            $_.Extension -match '^\.(jpg|jpeg)$' -and
            -not $_.FullName.StartsWith($DestPrefix, [StringComparison]::OrdinalIgnoreCase) -and
            -not $_.FullName.Equals($Destination, [StringComparison]::OrdinalIgnoreCase)
        }
)

Write-Host "Scanning $($Files.Count) JPEG files. Move enabled: $($Move.IsPresent)"

$Pattern = '(?i)MotionPhoto|MicroVideo|Motion Photo|Live Photo|LivePhoto|Container:Directory'
$Counts = @{ Matched = 0; Moved = 0; Planned = 0; Skipped = 0; Errors = 0 }

# ExifTool processes batches to avoid launching a process for each image.
for ($i = 0; $i -lt $Files.Count; $i += $BatchSize) {
    $end = [Math]::Min($i + $BatchSize - 1, $Files.Count - 1)
    $batch = @($Files[$i..$end])
    $args = @('-json', '-G1', '-charset', 'filename=UTF8') +
        @($batch | ForEach-Object { $_.FullName })

    try {
        $output = @(& $ExifTool.Source @args 2>$null)
        if ($LASTEXITCODE -ne 0) { throw "ExifTool exit code: $LASTEXITCODE" }
        $records = @($output -join "`n" | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        Write-Warning "Batch starting at index $i failed: $_"
        $Counts.Errors += $batch.Count
        continue
    }

    foreach ($record in $records) {
        $source = [string]$record.SourceFile
        if (-not $source) { $Counts.Errors++; continue }

        # Match metadata keys and values, never the filename itself.
        $metadata = foreach ($p in $record.PSObject.Properties) {
            if ($p.Name -ne 'SourceFile') { "$($p.Name) $($p.Value)" }
        }
        if (($metadata -join "`n") -notmatch $Pattern) { continue }
        $Counts.Matched++

        # Preserve the path relative to Root unless -Flatten is specified.
        $relative = [IO.Path]::GetRelativePath($Root, $source)
        if ($Flatten) { $relative = [IO.Path]::GetFileName($source) }
        $target = Join-Path $Destination $relative

        if (Test-Path -LiteralPath $target) {
            Write-Warning "Skipped existing target: $target"
            $Counts.Skipped++
            continue
        }

        if (-not $Move) {
            Write-Host "[DRY RUN] $source -> $target"
            $Counts.Planned++
            continue
        }

        try {
            $parent = Split-Path -Parent $target
            New-Item -ItemType Directory -Path $parent -Force | Out-Null

            # Recheck for collisions immediately before moving.
            if (Test-Path -LiteralPath $target) {
                Write-Warning "Skipped existing target: $target"
                $Counts.Skipped++
                continue
            }

            Move-Item -LiteralPath $source -Destination $target -ErrorAction Stop
            $Counts.Moved++
        } catch {
            Write-Warning "Failed: $source — $_"
            $Counts.Errors++
        }
    }

    Write-Progress -Activity 'Scanning motion photos' `
        -Status "$([Math]::Min($i + $BatchSize, $Files.Count)) / $($Files.Count)" `
        -PercentComplete (100 * [Math]::Min($i + $BatchSize, $Files.Count) / [Math]::Max(1, $Files.Count))
}

Write-Progress -Activity 'Scanning motion photos' -Completed
Write-Host "`nMatched: $($Counts.Matched) | Moved: $($Counts.Moved) | Planned: $($Counts.Planned) | Skipped: $($Counts.Skipped) | Errors: $($Counts.Errors)"
