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
        $entries = @($archive.Entries | Where-Object {
            $_.FullName -match '(^|[\\/])info\.json$'
        })

        if ($entries.Count -ne 1) {
            throw "В архиве должен быть ровно один info.json: $([IO.Path]::GetFileName($ZipPath))"
        }

        $reader = [System.IO.StreamReader]::new($entries[0].Open())
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

    Write-Info "Получаю список файлов из GitHub..."
    $headers = @{
        "User-Agent" = "Factorio-Death-train-Mod-Sync"
        "Accept" = "application/vnd.github+json"
    }
    $items = @(Invoke-RestMethod -Uri $ApiUrl -Headers $headers)

    $zipItems = @($items | Where-Object {
        $_.type -eq "file" -and $_.name -match '(?i)\.zip$'
    })

    if ($zipItems.Count -eq 0) {
        Write-Info "В GitHub нет ZIP-модов. Локальные файлы не изменены."
        exit 0
    }

    $oldEntries = @()
    if (Test-Path $StateFile) {
        foreach ($line in Get-Content $StateFile) {
            $parts = $line -split "`t", 2
            if ($parts.Count -eq 2 -and
                $parts[0] -match '^[A-Za-z0-9._-]+\.zip$' -and
                $parts[1] -match '^[A-Za-z0-9_-]+$') {
                $oldEntries += [pscustomobject]@{
                    File = $parts[0]
                    Name = $parts[1]
                }
            }
        }
    }

    # mod-list.json in GitHub is the source of truth for this pack.
    $remoteModList = $items | Where-Object {
        $_.type -eq "file" -and $_.name -eq "mod-list.json"
    } | Select-Object -First 1

    $modListPath = Join-Path $ModsDir "mod-list.json"
    $stagedModList = Join-Path $TempDir "mod-list.json"

    if ($remoteModList -and $remoteModList.download_url) {
        Invoke-WebRequest -Uri $remoteModList.download_url -OutFile $stagedModList
    } elseif (Test-Path $modListPath) {
        Copy-Item -LiteralPath $modListPath -Destination $stagedModList
        Write-Info "В GitHub нет mod-list.json; оставляю локальный список."
    } else {
        '{"mods":[{"name":"base","enabled":true}]}' |
            Set-Content -LiteralPath $stagedModList -Encoding utf8
    }

    $modList = Get-Content -Raw -LiteralPath $stagedModList | ConvertFrom-Json
    if (-not $modList.mods -or -not (@($modList.mods) | Where-Object { $_.name -eq "base" })) {
        throw "mod-list.json некорректен или в нём отсутствует мод base."
    }

    $newEntries = @()
    foreach ($item in $zipItems) {
        if ($item.name -notmatch '^[A-Za-z0-9._-]+\.zip$') {
            throw "Недопустимое имя ZIP-файла: $($item.name)"
        }
        if (-not $item.download_url) {
            throw "GitHub не предоставил ссылку для $($item.name)"
        }

        $destination = Join-Path $TempDir $item.name
        Write-Info "Скачиваю $($item.name)"
        Invoke-WebRequest -Uri $item.download_url -OutFile $destination
        $modName = Get-ZipModName $destination

        if ($newEntries.Name -contains $modName) {
            throw "Несколько ZIP-файлов содержат один и тот же мод: $modName"
        }

        $newEntries += [pscustomobject]@{
            File = $item.name
            Name = $modName
            Temp = $destination
        }
    }

    # Keep enabled/disabled values authored in GitHub. Add missing custom mods.
    $mods = @($modList.mods)
    foreach ($entry in $newEntries) {
        if (@($mods | Where-Object { $_.name -eq $entry.Name }).Count -eq 0) {
            $mods += [pscustomobject]@{
                name = $entry.Name
                enabled = $true
            }
        }
    }
    $modList.mods = @($mods)

    $json = $modList | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText(
        $stagedModList,
        $json,
        [System.Text.UTF8Encoding]::new($false)
    )

    # Never overwrite an unmanaged file with different contents.
    foreach ($entry in $newEntries) {
        $target = Join-Path $ModsDir $entry.File
        $wasManaged = @($oldEntries | Where-Object { $_.File -eq $entry.File }).Count -gt 0

        if ((Test-Path $target) -and -not $wasManaged) {
            $localHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
            $newHash = (Get-FileHash -LiteralPath $entry.Temp -Algorithm SHA256).Hash
            if ($localHash -ne $newHash) {
                throw "Файл $($entry.File) уже существует и не принадлежит синхронизатору. Конфликт не перезаписан."
            }
        }
    }

    $backupRoot = Join-Path $StateDir "backups"
    $backupDir = Join-Path $backupRoot (Get-Date -Format "yyyyMMdd-HHmmss")
    New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null

    $hasChanges = $false
    foreach ($entry in $newEntries) {
        $target = Join-Path $ModsDir $entry.File
        if (-not (Test-Path $target) -or
            (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne
            (Get-FileHash -LiteralPath $entry.Temp -Algorithm SHA256).Hash) {
            $hasChanges = $true
        }
    }
    foreach ($old in $oldEntries) {
        if ($newEntries.File -notcontains $old.File) { $hasChanges = $true }
    }
    if (-not (Test-Path $modListPath) -or
        (Get-FileHash -LiteralPath $stagedModList -Algorithm SHA256).Hash -ne
        (Get-FileHash -LiteralPath $modListPath -Algorithm SHA256).Hash) {
        $hasChanges = $true
    }

    if ($hasChanges) {
        New-Item -ItemType Directory -Force -Path (Join-Path $backupDir "mods") | Out-Null

        if (Test-Path $modListPath) {
            Copy-Item -LiteralPath $modListPath -Destination $backupDir
        }
        foreach ($old in $oldEntries) {
            $oldPath = Join-Path $ModsDir $old.File
            if (Test-Path $oldPath) {
                Copy-Item -LiteralPath $oldPath -Destination (Join-Path $backupDir "mods")
            }
        }

        foreach ($entry in $newEntries) {
            $target = Join-Path $ModsDir $entry.File
            $staged = "$target.new"
            Copy-Item -LiteralPath $entry.Temp -Destination $staged -Force
            Move-Item -LiteralPath $staged -Destination $target -Force
        }

        foreach ($old in $oldEntries) {
            if ($newEntries.File -notcontains $old.File) {
                $oldPath = Join-Path $ModsDir $old.File
                if (Test-Path $oldPath) {
                    Remove-Item -LiteralPath $oldPath -Force
                }
            }
        }

        $jsonTemp = "$modListPath.new"
        Copy-Item -LiteralPath $stagedModList -Destination $jsonTemp -Force
        Move-Item -LiteralPath $jsonTemp -Destination $modListPath -Force

        Write-Info "Изменения применены. Резервная копия: $backupDir"

        $oldBackups = @(Get-ChildItem -LiteralPath $backupRoot -Directory |
            Sort-Object Name -Descending)
        if ($oldBackups.Count -gt 3) {
            $oldBackups | Select-Object -Skip 3 | Remove-Item -Recurse -Force
        }
    } else {
        Write-Info "Изменений нет."
    }

    $stateLines = @($newEntries | ForEach-Object {
        "$($_.File)`t$($_.Name)"
    })
    [System.IO.File]::WriteAllLines(
        $StateFile,
        $stateLines,
        [System.Text.UTF8Encoding]::new($false)
    )

    Write-Info "Синхронизация завершена. ZIP-модов: $($newEntries.Count)."
    Write-Info "mod-list.json синхронизирован с GitHub."
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
