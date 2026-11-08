$ErrorActionPreference = "Stop"

$Repository = "renawayne/factoria_mods"
$Branch = "main"
$PackPath = "Death_train/mods"
$ApiUrl = "https://api.github.com/repos/$Repository/contents/${PackPath}?ref=$Branch"

$FactorioRoot = Join-Path $env:APPDATA "Factorio"
$ModsDir = Join-Path $FactorioRoot "mods"
$StateDir = Join-Path $FactorioRoot ".github-mod-sync"
$StateFile = Join-Path $StateDir "managed.tsv"
$TempDir = Join-Path $env:TEMP ("Factorio-Death_train-" + [guid]::NewGuid().ToString("N"))

function Write-Info($Message) {
    Write-Host "[Factorio Mod Sync] $Message" -ForegroundColor Cyan
}

function Get-ZipModName($ZipPath) {
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entry = $archive.Entries | Where-Object { $_.FullName -eq "info.json" } | Select-Object -First 1
        if (-not $entry) { throw "В архиве нет info.json в корне: $([IO.Path]::GetFileName($ZipPath))" }
        $reader = [System.IO.StreamReader]::new($entry.Open())
        try {
            $info = $reader.ReadToEnd() | ConvertFrom-Json
        } finally {
            $reader.Dispose()
        }
        if (-not $info.name -or $info.name -notmatch '^[A-Za-z0-9_-]+$') {
            throw "Некорректное поле name в info.json: $([IO.Path]::GetFileName($ZipPath))"
        }
        return [string]$info.name
    } finally {
        $archive.Dispose()
    }
}

try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    New-Item -ItemType Directory -Force -Path $ModsDir, $StateDir, $TempDir | Out-Null

    Write-Info "Получаю список модов из GitHub..."
    $headers = @{ "User-Agent" = "Factorio-Death-train-Mod-Sync"; "Accept" = "application/vnd.github+json" }
    $items = Invoke-RestMethod -Uri $ApiUrl -Headers $headers

    if ($items -isnot [System.Array]) {
        throw "GitHub API не вернул список файлов. Проверь путь $PackPath."
    }

    $zipItems = @($items | Where-Object { $_.type -eq "file" -and $_.name -match '\.zip$' })
    if ($zipItems.Count -eq 0) {
        Write-Info "В GitHub пока нет ZIP-модов. Локальные файлы не изменены."
        exit 0
    }

    $oldEntries = @()
    if (Test-Path $StateFile) {
        foreach ($line in Get-Content $StateFile) {
            $parts = $line -split "`t", 2
            if ($parts.Count -eq 2) {
                $oldEntries += [pscustomobject]@{ File = $parts[0]; Name = $parts[1] }
            }
        }
    }

    $newEntries = @()
    foreach ($item in $zipItems) {
        $destination = Join-Path $TempDir $item.name
        Write-Info "Скачиваю $($item.name)"
        Invoke-WebRequest -Uri $item.download_url -OutFile $destination
        $modName = Get-ZipModName $destination

        if ($newEntries.Name -contains $modName) {
            throw "Несколько ZIP-файлов содержат один и тот же мод: $modName"
        }

        $newEntries += [pscustomobject]@{ File = $item.name; Name = $modName; Temp = $destination }
    }

    foreach ($entry in $newEntries) {
        $target = Join-Path $ModsDir $entry.File
        $wasManaged = $oldEntries.File -contains $entry.File
        if ((Test-Path $target) -and -not $wasManaged) {
            $localHash = (Get-FileHash $target -Algorithm SHA256).Hash
            $newHash = (Get-FileHash $entry.Temp -Algorithm SHA256).Hash
            if ($localHash -ne $newHash) {
                throw "Файл $($entry.File) уже существует и не принадлежит синхронизатору. Конфликт не перезаписан."
            }
        }
    }

    # All downloads and ZIP checks completed before touching the active mod directory.
    foreach ($entry in $newEntries) {
        $target = Join-Path $ModsDir $entry.File
        $staged = "$target.new"
        Copy-Item -LiteralPath $entry.Temp -Destination $staged -Force
        Move-Item -LiteralPath $staged -Destination $target -Force
    }

    foreach ($old in $oldEntries) {
        if ($newEntries.File -notcontains $old.File) {
            $oldPath = Join-Path $ModsDir $old.File
            if (Test-Path $oldPath) { Remove-Item -LiteralPath $oldPath -Force }
        }
    }

    $modListPath = Join-Path $ModsDir "mod-list.json"
    if (Test-Path $modListPath) {
        $modList = Get-Content -Raw $modListPath | ConvertFrom-Json
    } else {
        $modList = [pscustomobject]@{ mods = @([pscustomobject]@{ name = "base"; enabled = $true }) }
    }

    if (-not $modList.mods) { $modList | Add-Member -NotePropertyName mods -NotePropertyValue @() -Force }
    $mods = @($modList.mods)

    foreach ($old in $oldEntries) {
        if ($newEntries.Name -notcontains $old.Name) {
            $mods = @($mods | Where-Object { $_.name -ne $old.Name })
        }
    }

    foreach ($entry in $newEntries) {
        $found = $false
        foreach ($mod in $mods) {
            if ($mod.name -eq $entry.Name) {
                $mod.enabled = $true
                $found = $true
            }
        }
        if (-not $found) {
            $mods += [pscustomobject]@{ name = $entry.Name; enabled = $true }
        }
    }

    $modList.mods = @($mods)
    $json = $modList | ConvertTo-Json -Depth 20
    $jsonTemp = "$modListPath.new"
    [System.IO.File]::WriteAllText($jsonTemp, $json, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $jsonTemp -Destination $modListPath -Force

    $stateLines = @($newEntries | ForEach-Object { "$($_.File)`t$($_.Name)" })
    [System.IO.File]::WriteAllLines($StateFile, $stateLines, [System.Text.UTF8Encoding]::new($false))

    Write-Info "Синхронизация завершена. Управляемых модов: $($newEntries.Count)."
    Write-Info "Остальные моды и настройки не изменялись."
    exit 0
}
catch {
    Write-Host "[ОШИБКА] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally {
    if (Test-Path $TempDir) {
        Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
