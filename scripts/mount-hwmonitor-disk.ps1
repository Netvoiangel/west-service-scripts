param(
    [string]$HostName = "192.168.1.1",
    [string]$User = "root",
    [string]$ConfigPath = "/opt/mnt2/configurator/conf/HWMONITOR.json",
    [string]$ServiceName = "mnt-hwmonitor.service",
    [int]$MinDiskSizeGb = 1000,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptRoot
$LogDir = Join-Path $RepoRoot "logs"
$BackupDir = Join-Path $RepoRoot "backups"
$RunStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$LogPath = Join-Path $LogDir "mount-hwmonitor-disk-$RunStamp.log"
$BackupPath = Join-Path $BackupDir "HWMONITOR-$RunStamp.json"

New-Item -ItemType Directory -Force -Path $LogDir, $BackupDir | Out-Null

Import-Module (Join-Path $ScriptRoot "MountHwmonitorDisk.psm1") -Force

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "OK")]
        [string]$Level = "INFO"
    )

    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Host $line
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
}

function Confirm-Action {
    param([string]$Question)

    while ($true) {
        $answer = Read-Host "$Question [y/n]"
        switch ($answer.ToLowerInvariant()) {
            "y" { return $true }
            "yes" { return $true }
            "n" { return $false }
            "no" { return $false }
            default { Write-Host "Введите y или n." }
        }
    }
}

function Invoke-Remote {
    param(
        [string]$Command,
        [switch]$AllowFailure
    )

    $target = "$User@$HostName"
    $output = & ssh -o BatchMode=yes -o ConnectTimeout=10 $target $Command 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "SSH команда завершилась с ошибкой ($exitCode): $Command`n$output"
    }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output = ($output -join "`n")
    }
}

try {
    $script:MountPointToCreate = $null
    Write-Log "Старт. Цель: $User@$HostName, конфиг: $ConfigPath"

    $sshCheck = Invoke-Remote -Command "echo ok"
    if ($sshCheck.Output.Trim() -ne "ok") {
        throw "SSH подключение работает нестандартно: $($sshCheck.Output)"
    }
    Write-Log "SSH подключение проверено." "OK"

    $rootInfoCommand = 'root_source=$(findmnt -n -o SOURCE /); root_real=$(readlink -f "$root_source" 2>/dev/null || printf "%s" "$root_source"); root_parent=$(lsblk -no PKNAME "$root_real" 2>/dev/null | head -n 1); if [ -n "$root_parent" ]; then printf "%s|%s" "$root_source" "$root_parent"; else printf "%s|%s" "$root_source" "$(basename "$root_real")"; fi'
    $rootInfo = (Invoke-Remote -Command $rootInfoCommand).Output.Trim()
    $rootParts = $rootInfo -split "\|", 2
    $rootSource = $rootParts[0]
    $systemDiskName = if ($rootParts.Count -gt 1) { $rootParts[1] } else { $null }

    if (-not $rootSource -or -not $systemDiskName) {
        throw "Не удалось определить устройство корневой файловой системы."
    }

    Write-Log "Системный диск определен как /dev/$systemDiskName через root=$rootSource."

    $lsblkJson = (Invoke-Remote -Command "lsblk -b -J -o NAME,KNAME,PATH,TYPE,UUID,MOUNTPOINT,SIZE,FSTYPE,PKNAME,MODEL,SERIAL").Output
    $lsblk = $lsblkJson | ConvertFrom-Json
    $devices = ConvertTo-FlatDeviceList -Devices @($lsblk.blockdevices)
    $liveUuids = @($devices | Where-Object { $_.uuid } | ForEach-Object { [string]$_.uuid })

    Write-Log "Найдено UUID на устройстве: $($liveUuids.Count)."

    $configRaw = (Invoke-Remote -Command "cat '$ConfigPath'").Output
    $configRaw | Set-Content -Path $BackupPath -Encoding UTF8
    Write-Log "Локальный бэкап конфига сохранен: $BackupPath" "OK"

    $config = $configRaw | ConvertFrom-Json
    if (-not $config.mount) {
        throw "В конфиге нет массива mount."
    }

    $configUuids = @($config.mount | Where-Object { $_.uuid } | ForEach-Object { [string]$_.uuid })
    $targetResolution = Resolve-ArchiveMountTarget -Config $config -LiveUuids $liveUuids
    $targetMount = $null

    if ($targetResolution.Action -eq "Update") {
        $targetMount = $targetResolution.Mount
        Write-Log "Выбран mount-point с отсутствующим UUID: $($targetMount.mp)"
    } elseif ($targetResolution.Action -eq "Choose") {
        Write-Log "Найдено несколько archive mount-point с отсутствующим UUID." "WARN"
        for ($i = 0; $i -lt $targetResolution.Options.Count; $i++) {
            Write-Log ("{0}) {1} uuid={2}" -f ($i + 1), $targetResolution.Options[$i].mp, $targetResolution.Options[$i].uuid)
        }

        while ($true) {
            $choice = Read-Host "Выберите номер mount-point для обновления"
            $index = 0
            if ([int]::TryParse($choice, [ref]$index) -and $index -ge 1 -and $index -le $targetResolution.Options.Count) {
                $targetMount = $targetResolution.Options[$index - 1]
                break
            }
            Write-Host "Введите номер из списка."
        }
    } elseif ($targetResolution.Action -eq "Create") {
        $script:MountPointToCreate = $targetResolution.MountPoint
        Write-Log "Отсутствующего UUID в archive mount-point нет, будет создан блок $script:MountPointToCreate."
    } else {
        throw "Неизвестное действие выбора mount-point: $($targetResolution.Action)"
    }

    $minBytes = [int64]$MinDiskSizeGb * 1GB
    $candidates = @(Get-NewDiskCandidates `
        -Devices $devices `
        -SystemDiskName $systemDiskName `
        -ConfigUuids $configUuids `
        -MinDiskSizeBytes $minBytes)

    if ($candidates.Count -eq 0) {
        Write-Log "Подходящих новых дисков не найдено." "WARN"
        Write-Log "Порог размера: $MinDiskSizeGb GB. Системный диск /dev/$systemDiskName исключен."
        exit 1
    }

    Write-Log "Кандидаты на подключение:"
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $disk = $candidates[$i]
        $diskLine = "{0}) {1} size={2} uuid={3} fstype={4} model={5} serial={6}" -f `
            ($i + 1),
            $disk.path,
            (Format-Size $disk.size),
            $(if ($disk.uuid) { $disk.uuid } else { "<empty>" }),
            $(if ($disk.fstype) { $disk.fstype } else { "<empty>" }),
            $(if ($disk.model) { $disk.model } else { "<empty>" }),
            $(if ($disk.serial) { $disk.serial } else { "<empty>" })
        Write-Log $diskLine
    }

    $selected = if ($candidates.Count -eq 1) {
        $candidates[0]
    } else {
        while ($true) {
            $choice = Read-Host "Выберите номер нового диска"
            $index = 0
            if ([int]::TryParse($choice, [ref]$index) -and $index -ge 1 -and $index -le $candidates.Count) {
                $candidates[$index - 1]
                break
            }
            Write-Host "Введите номер из списка."
        }
    }

    Write-Log "Выбран диск: $($selected.path), размер $(Format-Size $selected.size)."

    $newUuid = $selected.uuid
    if (-not $newUuid) {
        Write-Log "У выбранного диска нет UUID. Нужно форматирование ext4." "WARN"
        Write-Log "ДАННЫЕ НА $($selected.path) БУДУТ УДАЛЕНЫ." "WARN"

        if (-not (Confirm-Action "Форматировать $($selected.path) в ext4?")) {
            Write-Log "Пользователь отменил форматирование." "WARN"
            exit 1
        }

        if ($DryRun) {
            Write-Log "DryRun: форматирование пропущено."
            $newUuid = "DRY-RUN-UUID"
        } else {
            $null = Invoke-Remote -Command "mkfs -t ext4 '$($selected.path)'"
            Write-Log "Форматирование завершено." "OK"

            $newUuid = (Invoke-Remote -Command "lsblk -n -o UUID '$($selected.path)'").Output.Trim()
            if (-not $newUuid) {
                throw "После форматирования не удалось получить UUID для $($selected.path)."
            }
            Write-Log "Новый UUID: $newUuid" "OK"
        }
    } else {
        Write-Log "У выбранного диска уже есть UUID: $newUuid"
    }

    if ($targetMount) {
        $oldUuid = $targetMount.uuid
        Write-Log "Будет обновлен $($targetMount.mp): $oldUuid -> $newUuid"
        if (-not (Confirm-Action "Записать новый UUID в $($targetMount.mp)?")) {
            Write-Log "Пользователь отменил запись в конфиг." "WARN"
            exit 1
        }
        $targetMount.uuid = $newUuid
    } else {
        if (-not $script:MountPointToCreate) {
            throw "Не определен mount-point для нового archive блока."
        }
        Write-Log "Будет создан новый блок $script:MountPointToCreate с UUID $newUuid"
        if (-not (Confirm-Action "Добавить блок $script:MountPointToCreate в конфиг?")) {
            Write-Log "Пользователь отменил создание нового archive блока." "WARN"
            exit 1
        }
        Add-ArchiveMount -Config $config -MountPoint $script:MountPointToCreate -Uuid $newUuid
    }

    $updatedJson = $config | ConvertTo-Json -Depth 50
    $null = $updatedJson | ConvertFrom-Json

    if ($DryRun) {
        Write-Log "DryRun: запись конфига и перезапуск сервиса пропущены." "WARN"
        Write-Log "Лог сохранен: $LogPath"
        exit 0
    }

    $writeCommand = "cat > '$ConfigPath'"
    $target = "$User@$HostName"
    $updatedJson | & ssh -o BatchMode=yes -o ConnectTimeout=10 $target $writeCommand
    if ($LASTEXITCODE -ne 0) {
        throw "Не удалось записать обновленный конфиг на устройство."
    }
    Write-Log "Конфиг обновлен на устройстве." "OK"

    $null = Invoke-Remote -Command "systemctl restart '$ServiceName'"
    Write-Log "Сервис $ServiceName перезапущен." "OK"

    $serviceState = (Invoke-Remote -Command "systemctl is-active '$ServiceName'" -AllowFailure).Output.Trim()
    Write-Log "Состояние сервиса: $serviceState"
    Write-Log "Готово. Лог сохранен: $LogPath" "OK"
} catch {
    Write-Log $_.Exception.Message "ERROR"
    Write-Log "Аварийное завершение. Лог сохранен: $LogPath" "ERROR"
    exit 1
}
