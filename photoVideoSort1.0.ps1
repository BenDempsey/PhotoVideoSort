$global:DedupeStrategy = '3'
# PhotoOrganizer.ps1
# Version: 10.0
# Menu-driven photo organiser:
# 1) Copy tree (Source -> Dest)
# 2) Prepend EXIF DateTaken (fallback LastWriteTime) to filenames
# 3) Merge external hash CSV (from Source) into Dest cache
# 4) Sort into Year\Month folders by DateTaken
# 5) Hash + dedupe with strategy selection
# 6) Run ALL (1-5 in order)

$ErrorActionPreference = "Stop"

# ---------- Prompt for source/destination ----------

$SourceRoot = Read-Host "Enter SOURCE folder "
$DestRoot   = Read-Host "Enter DESTINATION folder "

if (-not (Test-Path $SourceRoot)) {
    throw "Source path does not exist: $SourceRoot"
}

New-Item -ItemType Directory -Force -Path $DestRoot | Out-Null

# ---------- Global extension sets & filter ----------

$global:PhotoExt = @(".jpg",".jpeg",".tif",".tiff",".png",".heic",".webp",".bmp")
$global:VideoExt = @(".mp4",".mov",".avi",".mkv",".m4v",".3gp")
$global:OtherExt = @(".pdf",".doc",".docx",".txt",".zip")  # adjust as needed

Write-Host ""
Write-Host "Select file type filter for this session:"
Write-Host " 1) Photos only"
Write-Host " 2) Videos only"
Write-Host " 3) Photos + Videos (default)"
Write-Host " 4) Other (custom set)"
$filterChoice = Read-Host "Choice (default: 3)"
if ([string]::IsNullOrWhiteSpace($filterChoice)) { $filterChoice = '3' }

switch ($filterChoice) {
    '1' { $global:ActiveExt = $PhotoExt }
    '2' { $global:ActiveExt = $VideoExt }
    '3' { $global:ActiveExt = $PhotoExt + $VideoExt }
    '4' { $global:ActiveExt = $OtherExt }
    default { $global:ActiveExt = $PhotoExt + $VideoExt }
}

Write-Host ""
Write-Host "Select DEFAULT dedupe strategy for this session:"
Write-Host " 1) Hash only (strict)"
Write-Host " 2) Hash + time threshold"
Write-Host " 3) Hash + NormalizedName + DateTaken (safe default)"
$global:DedupeStrategy = Read-Host "Choice (default: 3)"
if ([string]::IsNullOrWhiteSpace($global:DedupeStrategy)) { $global:DedupeStrategy = '3' }

# ---------- Merge hash CSV (Source -> Dest) ----------

function Merge-HashCsv {
    $RootPath     = $DestRoot
    $externalPath = Join-Path $SourceRoot ".file_hashes.csv"
    $destCsv      = Join-Path $RootPath ".file_hashes.csv"
    $merged       = Join-Path $RootPath ".file_hashes_merged.csv"

    if (-not (Test-Path $externalPath)) {
        Write-Host "No external cache found at $externalPath, nothing to merge."
        return
    }

    if (-not (Test-Path $destCsv)) {
        Copy-Item $externalPath $destCsv -Force
        Write-Host "No existing .file_hashes.csv, copied from $externalPath."
        return
    }

    $all = @()
    $all += Import-Csv $externalPath
    $all += Import-Csv $destCsv

    if ($all.Count -eq 0) {
        Write-Host "No entries to merge."
        return
    }

    $deduped = $all |
        Sort-Object FullName -Descending |
        Group-Object FullName |
        ForEach-Object { $_.Group[0] }

    $existingOnly = $deduped | Where-Object {
        Test-Path $_.FullName
    }

    $existingOnly |
        Sort-Object FullName |
        Export-Csv -Path $merged -NoTypeInformation -Encoding UTF8

    Remove-Item $destCsv -Force
    Rename-Item $merged ".file_hashes.csv" -Force

    Write-Host ("Merged {0} rows down to {1} existing files." -f $all.Count, $existingOnly.Count)
}

# ---------- Common helpers ----------

function Get-UniquePath {
    param(
        [string]$Directory,
        [string]$BaseName,
        [string]$Extension
    )
    $target = Join-Path $Directory ($BaseName + $Extension)
    if (-not (Test-Path $target)) { return $target }

    $i = 1
    while ($true) {
        $candidate = Join-Path $Directory ("{0}({1}){2}" -f $BaseName, $i, $Extension)
        if (-not (Test-Path $candidate)) { return $candidate }
        $i++
    }
}

Add-Type -AssemblyName System.Drawing

function Get-DateTaken {
    param(
        [System.IO.FileInfo]$File
    )

    $ext = $File.Extension.ToLowerInvariant()
    $photoExt = @(".jpg",".jpeg",".tif",".tiff",".png",".heic",".webp",".bmp")

    if ($photoExt -notcontains $ext) {
        return $null
    }

    try {
        $img = New-Object System.Drawing.Bitmap($File.FullName)
        try {
            $propId = 36867
            if ($img.PropertyIdList -contains $propId) {
                $prop = $img.GetPropertyItem($propId)
                $str  = [System.Text.Encoding]::ASCII.GetString($prop.Value)
                $str  = $str.Trim([char]0)
                return [datetime]::ParseExact($str, "yyyy:MM:dd HH:mm:ss", $null)
            }
        }
        finally {
            $img.Dispose()
        }
    }
    catch { }

    return $null
}

function Get-EffectiveDateTaken {
    param(
        [System.IO.FileInfo]$File
    )

    $dt = Get-DateTaken -File $File
    if ($dt) { return $dt }

    return $File.LastWriteTime
}

function Get-NormalizedBaseName {
    param(
        [System.IO.FileInfo]$File
    )
    $base = [IO.Path]::GetFileNameWithoutExtension($File.Name)

    # Strip common copy suffixes: " (1)", "(1)", " - Copy", "_copy"
    $normalized = $base -replace '\s*\(\d+\)$','' -replace '\s*-\s*copy$','' -replace '_copy$',''
    return $normalized.ToLowerInvariant()
}

# ---------- PART 1: Copy tree ----------

function Copy-Tree {
    Write-Host "Copying all files and folders from $SourceRoot to $DestRoot ..."

    $destHasFiles = Get-ChildItem -Path $DestRoot -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($destHasFiles) {
        Write-Host ""
        Write-Host "WARNING: Destination already contains files."
        Write-Host "This copy step will AVOID overwriting by renaming duplicates in the destination."
        $resp = Read-Host "Continue with copy? (Y/N)"
        if ($resp.ToUpper() -ne 'Y') {
            Write-Host "Copy cancelled."
            return
        }
    }

    $allFiles = Get-ChildItem -Path $SourceRoot -Recurse -File |
        Where-Object { $global:ActiveExt -contains $_.Extension.ToLower() }

    $total = $allFiles.Count
    $idx = 0

    foreach ($file in $allFiles) {
        $idx++
        if ($total -gt 0) {
            $pct = [int](($idx / $total) * 100)
            Write-Progress -Activity "Copying files" -Status "$pct% ($idx of $total)" -PercentComplete $pct
        }

        $rel      = $file.FullName.Substring($SourceRoot.Length).TrimStart('\')
        $destPath = Join-Path $DestRoot $rel

        $destDir  = Split-Path $destPath -Parent
        New-Item -ItemType Directory -Force -Path $destDir | Out-Null

        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($destPath)
        $ext      = [System.IO.Path]::GetExtension($destPath)

        $finalDest = Get-UniquePath -Directory $destDir -BaseName $baseName -Extension $ext

        try {
            Copy-Item -LiteralPath $file.FullName -Destination $finalDest -ErrorAction Stop
        }
        catch {
           Write-Host "Skipping missing source file: $($file.FullName)" -ForegroundColor Yellow
    }
}

    Write-Host "Copy complete."
}

# ---------- PART 2: Prepend DateTaken to filenames ----------

function Prepend-DateTakenToName {
    param(
        [string]$RootPath
    )

    $cachePath = Join-Path $RootPath ".file_hashes.csv"
    $hashCache = @{}

    if (Test-Path $cachePath) {
        Write-Host "Loading cache for DateTaken reuse..."
        Import-Csv -Path $cachePath | ForEach-Object {
            $hashCache[$_.FullName] = $_
        }
    }

    $files = Get-ChildItem -Path $RootPath -Recurse -File | Where-Object {
        $_.Name -notlike ".file_*" -and
        $global:ActiveExt -contains $_.Extension.ToLower()
    }

    $total = $files.Count
    $idx   = 0
    $cacheHits = 0

    foreach ($file in $files) {
        $idx++
        if ($total -gt 0) {
            $pct = [int](($idx / $total) * 100)
            Write-Progress -Activity "Prepending DateTaken" -Status "$pct% ($idx of $total)" -PercentComplete $pct
        }

        if ($file.BaseName -match '^[0-9]{4}-[0-9]{2}-[0-9]{2}_') {
            continue
        }

        $dt = $null
        $key = $file.FullName
        $len = $file.Length
        $lw = $file.LastWriteTime

        if ($hashCache.ContainsKey($key) -and
            [int64]$hashCache[$key].Length -eq $len -and
            [datetime]$hashCache[$key].LastWriteTime -eq $lw -and
            $hashCache[$key].DateTaken) {

            $dt = [datetime]::Parse($hashCache[$key].DateTaken)
            $cacheHits++
        }
        else {
            $dt = Get-EffectiveDateTaken -File $file
        }

        $dateStr = $dt.ToString("yyyy-MM-dd")
        $nameNoExt = $file.BaseName
        $ext       = $file.Extension

        $newBase = "{0}_{1}" -f $dateStr, $nameNoExt
        $newPath = Get-UniquePath -Directory $file.DirectoryName -BaseName $newBase -Extension $ext

        Rename-Item -LiteralPath $file.FullName -NewName ([System.IO.Path]::GetFileName($newPath))
    }

    $cacheHitRate = if ($total -gt 0) { [math]::Round(($cacheHits / $total) * 100, 1) } else { 0 }
    Write-Host "Cache reuse: $cacheHits of $total files ($cacheHitRate%)"
}

function Run-Prepend-DateTaken {
    Write-Host "Prepending DateTaken under $DestRoot ..."
    Prepend-DateTakenToName -RootPath $DestRoot
    Write-Host "Prepend DateTaken complete."
}

# ---------- PART 3: Sort into Year\Month by DateTaken ----------

function Sort-ByYearMonth-DateTaken {
    param(
        [string]$RootPath
    )

    $cachePath = Join-Path $RootPath ".file_hashes.csv"
    $hashCache = @{}

    if (Test-Path $cachePath) {
        Write-Host "Loading cache for DateTaken reuse..."
        Import-Csv -Path $cachePath | ForEach-Object {
            $hashCache[$_.FullName] = $_
        }
    }

    $files = Get-ChildItem -Path $RootPath -Recurse -File | Where-Object {
        ($_.Name -notlike ".file_*") -and
        ($_.DirectoryName -notmatch '\\[0-9]{4}\\[0-9]{2}$') -and
        $global:ActiveExt -contains $_.Extension.ToLower()
    }

    Write-Host "Found $($files.Count) files to sort (already-sorted files skipped)"

    $total = $files.Count
    $idx   = 0
    $cacheHits = 0

    foreach ($file in $files) {
        $idx++
        if ($total -gt 0) {
            $pct = [int](($idx / $total) * 100)
            Write-Progress -Activity "Sorting into Year\Month by DateTaken" -Status "$pct% ($idx of $total)" -PercentComplete $pct
        }

        $dt = $null
        $key = $file.FullName
        $len = $file.Length
        $lw = $file.LastWriteTime

        if ($hashCache.ContainsKey($key) -and
            [int64]$hashCache[$key].Length -eq $len -and
            [datetime]$hashCache[$key].LastWriteTime -eq $lw -and
            $hashCache[$key].DateTaken) {

            $dt = [datetime]::Parse($hashCache[$key].DateTaken)
            $cacheHits++
        }
        else {
            $dt = Get-EffectiveDateTaken -File $file
        }

        $year  = $dt.ToString("yyyy")
        $month = $dt.ToString("MM")

        $targetDir = Join-Path $RootPath (Join-Path $year $month)
        New-Item -ItemType Directory -Force -Path $targetDir | Out-Null

        $base      = $file.Name
        $nameNoExt = [IO.Path]::GetFileNameWithoutExtension($base)
        $ext       = [IO.Path]::GetExtension($base)

        $targetPath = Get-UniquePath -Directory $targetDir -BaseName $nameNoExt -Extension $ext

        if ($file.FullName -ne $targetPath) {
            Move-Item -LiteralPath $file.FullName -Destination $targetPath
        }
    }

    $cacheHitRate = if ($total -gt 0) { [math]::Round(($cacheHits / $total) * 100, 1) } else { 0 }
    Write-Host "Cache reuse: $cacheHits of $total files ($cacheHitRate%)"
}

function Run-Sort-ByYearMonth {
    Write-Host "Sorting files into Year\Month folders under $DestRoot ..."
    Sort-ByYearMonth-DateTaken -RootPath $DestRoot
    Write-Host "Sorting complete."
}

# ---------- PART 4: Hash + dedupe (with strategy selection) ----------

function Hash-And-Dedupe {
    $RootPath = $DestRoot

    $strategy = $global:DedupeStrategy
    Write-Host ""
    Write-Host "Using deduplication strategy: $strategy" -ForegroundColor Cyan

    $dayThreshold = 365
    if ($strategy -eq '2') {
        $input = Read-Host "Keep duplicates if saved more than X days apart (default: 365)"
        if (-not [string]::IsNullOrWhiteSpace($input)) { $dayThreshold = [int]$input }
        Write-Host "Using time threshold: $dayThreshold days"
    }

    Write-Host "Hashing files in $RootPath and removing duplicates..." -ForegroundColor Cyan

    $cachePath = Join-Path $RootPath ".file_hashes.csv"
    $hashCache = @{}

    if (Test-Path $cachePath) {
        Write-Host "Loading existing hash cache: $cachePath"
        Import-Csv -Path $cachePath | ForEach-Object {
            $hashCache[$_.FullName] = $_
        }
    }

    $files = Get-ChildItem -Path $RootPath -Recurse -File | Where-Object {
        $_.Name -notlike ".file_*" -and
        $global:ActiveExt -contains $_.Extension.ToLower()
    }

    $total         = $files.Count
    $idx           = 0
    $cacheOutput   = New-Object System.Collections.Generic.List[object]
    $deletedCount  = 0
    $keptDupeCount = 0
    $cacheHits     = 0
    $seenTable     = @{}

    foreach ($file in $files) {
        $idx++
        if ($total -gt 0) {
            $pct = [int](($idx / $total) * 100)
            Write-Progress -Activity "Hashing and de-duplicating" -Status "$pct% ($idx of $total)" -PercentComplete $pct
        }

        $len = $file.Length
        $lw  = $file.LastWriteTime
        $key = $file.FullName

        $hash = $null
        $dt   = $null
        $cacheMatch = $false

        if ($hashCache.ContainsKey($key) -and
            [int64]$hashCache[$key].Length -eq $len) {

            $cachedLwString = $hashCache[$key].LastWriteTime
            $formats = @(
                'dd/MM/yyyy h:mm:ss tt',
                'dd/MM/yyyy HH:mm:ss',
                'yyyy-MM-dd HH:mm:ss',
                'o'
            )

            $cachedLw = $null
            foreach ($fmt in $formats) {
                try {
                    $cachedLw = [datetime]::ParseExact(
                        $cachedLwString,
                        $fmt,
                        [System.Globalization.CultureInfo]::InvariantCulture
                    )
                    break
                }
                catch { }
            }

            if ($cachedLw -and $cachedLw -eq $lw) {
                $cacheMatch = $true
            }
        }

        if ($cacheMatch) {
            $hash = $hashCache[$key].Hash
            if ($hashCache[$key].DateTaken) {
                $dt = [datetime]::Parse($hashCache[$key].DateTaken)
            }
            $cacheHits++
        }
        else {
            $hashObj = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
            $hash = $hashObj.Hash
        }

        if (-not $dt) {
            $dt = Get-EffectiveDateTaken -File $file
        }

        $dtKey = $dt.ToString("yyyy-MM-dd HH:mm:ss")

        $cacheOutput.Add([pscustomobject]@{
            FullName      = $key
            Hash          = $hash
            Length        = $len
            LastWriteTime = $lw
            DateTaken     = $dtKey
        })

        $shouldDelete = $false
        $dupeKey      = $null

        switch ($strategy) {
            '1' {
                $dupeKey = $hash
                if ($seenTable.ContainsKey($dupeKey)) {
                    $shouldDelete = $true
                    Write-Host "Duplicate (hash match), deleting: $($file.FullName)" -ForegroundColor Yellow
                }
            }
            '2' {
                if ($seenTable.ContainsKey($hash)) {
                    $firstFile = $seenTable[$hash]
                    $timeDiff  = [Math]::Abs(($lw - $firstFile.LastWriteTime).TotalDays)

                    if ($timeDiff -le $dayThreshold) {
                        $shouldDelete = $true
                        Write-Host "Duplicate (hash, <= $dayThreshold days apart), deleting: $($file.FullName)" -ForegroundColor Yellow
                    }
                    else {
                        $keptDupeCount++
                        Write-Host "Same photo but different instance ($([int]$timeDiff) days apart), keeping: $($file.FullName)" -ForegroundColor Cyan
                    }
                }
            }
            '3' {
                $normalizedBase = Get-NormalizedBaseName -File $file
                $dupeKey = "{0}|{1}|{2}" -f $hash, $normalizedBase, $dt.ToString('yyyy-MM-dd')
                if ($seenTable.ContainsKey($dupeKey)) {
                    $shouldDelete = $true
                    Write-Host "Duplicate (hash + normalized name + date match), deleting: $($file.FullName)" -ForegroundColor Yellow
                }
            }
            default {
                $normalizedBase = Get-NormalizedBaseName -File $file
                $dupeKey = "{0}|{1}|{2}" -f $hash, $normalizedBase, $dt.ToString('yyyy-MM-dd')
                if ($seenTable.ContainsKey($dupeKey)) {
                    $shouldDelete = $true
                    Write-Host "Duplicate (hash + normalized name + date match), deleting: $($file.FullName)" -ForegroundColor Yellow
                }
            }
        }

        if ($shouldDelete) {
            Remove-Item -LiteralPath $file.FullName -Force
            $deletedCount++
        }
        else {
            if ($strategy -eq '2') {
                if (-not $seenTable.ContainsKey($hash)) {
                    $seenTable[$hash] = $file
                }
            }
            else {
                $seenTable[$dupeKey] = $file
            }
        }
    }

    $cacheOutput |
        Sort-Object FullName |
        Export-Csv -Path $cachePath -NoTypeInformation -Encoding UTF8

    $cacheHitRate = if ($total -gt 0) { [math]::Round(($cacheHits / $total) * 100, 1) } else { 0 }
    Write-Host ""
    Write-Host "Deduplication complete using strategy $strategy."
    Write-Host "Files deleted: $deletedCount"
    if ($strategy -eq '2' -and $keptDupeCount -gt 0) {
        Write-Host "Duplicate photos kept (different instances): $keptDupeCount"
    }
    Write-Host "Cache reuse: $cacheHits of $total files ($cacheHitRate%)"
    Write-Host "Cache saved to $cachePath."
}
# ---------- Defaults ----------
#$global:DedupeStrategy = '3'


# ---------- Menu ----------

function Show-Menu {
    Write-Host ""
    Write-Host "Source:      $SourceRoot"
    Write-Host "Destination: $DestRoot"
    Write-Host "Filter:      $($global:ActiveExt -join ', ')"
    Write-Host "Strategy:    $global:DedupeStrategy"
    Write-Host ""
    Write-Host "Select operation:"
    Write-Host " 1) Copy tree (Source -> Dest)"
    Write-Host " 2) Prepend DateTaken to filenames"
    Write-Host " 3) Merge external hash CSV into Dest cache"
    Write-Host " 4) Sort into Year\Month by DateTaken"
    Write-Host " 5) Hash + dedupe"
    Write-Host " 6) Run ALL (1-5 in order: copy, prepend, merge, sort, dedupe)"
    Write-Host " 7) Reset session (change Source/Dest/filter/strategy)"
    Write-Host " Q) Quit"
    $choice = Read-Host "Choice"
    return $choice
}

do {
    $c = Show-Menu
    switch ($c.ToUpper()) {
        '1' { Copy-Tree }
        '2' { Run-Prepend-DateTaken }
        '3' { Merge-HashCsv }
        '4' { Run-Sort-ByYearMonth }
        '5' { Hash-And-Dedupe }
        '6' {
            Copy-Tree
            Run-Prepend-DateTaken
            Merge-HashCsv
            Run-Sort-ByYearMonth
            Hash-And-Dedupe
        }
        '7' {
            $SourceRoot = Read-Host "Enter SOURCE folder "
            $DestRoot   = Read-Host "Enter DESTINATION folder "

            if (-not (Test-Path $SourceRoot)) {
                Write-Host "Source path does not exist: $SourceRoot" -ForegroundColor Red
            }
            else {
                New-Item -ItemType Directory -Force -Path $DestRoot | Out-Null

                Write-Host ""
                Write-Host "Select file type filter for this session:"
                Write-Host " 1) Photos only"
                Write-Host " 2) Videos only"
                Write-Host " 3) Photos + Videos (default)"
                Write-Host " 4) Other (custom set)"
                $filterChoice = Read-Host "Choice (default: 3)"
                if ([string]::IsNullOrWhiteSpace($filterChoice)) { $filterChoice = '3' }

                switch ($filterChoice) {
                    '1' { $global:ActiveExt = $PhotoExt }
                    '2' { $global:ActiveExt = $VideoExt }
                    '3' { $global:ActiveExt = $PhotoExt + $VideoExt }
                    '4' { $global:ActiveExt = $OtherExt }
                    default { $global:ActiveExt = $PhotoExt + $VideoExt }
                }

                Write-Host ""
                Write-Host "Select DEFAULT dedupe strategy for this session:"
                Write-Host " 1) Hash only (strict)"
                Write-Host " 2) Hash + time threshold"
                Write-Host " 3) Hash + NormalizedName + DateTaken (safe default)"
                $global:DedupeStrategy = Read-Host "Choice (default: 3)"
                if ([string]::IsNullOrWhiteSpace($global:DedupeStrategy)) { $global:DedupeStrategy = '3' }
            }
        }
        'Q' { break }
        default { Write-Host "Invalid choice." }
    }
} while ($true)

