$dest = Join-Path (Get-Location) "Motion_Pictures"
New-Item -ItemType Directory -Path $dest -Force | Out-Null

Get-ChildItem -File -Recurse -Include *.jpg,*.jpeg |
    Where-Object { $_.DirectoryName -ne $dest -and
                   $_.DirectoryName -notlike "$dest\*" } |
    ForEach-Object {
        $file = $_
        $metadata = & exiftool -s -G1 $file.FullName

        if ($metadata -match 'MotionPhoto|MicroVideo|Motion Photo|Container:Directory') {
            Move-Item -LiteralPath $file.FullName -Destination $dest
            Write-Host "Moved: $($file.Name)"
        }
    }