$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ModulePath = Join-Path (Join-Path $RepoRoot "scripts") "MountHwmonitorDisk.psm1"

Import-Module $ModulePath -Force

$script:Failed = 0
$script:Passed = 0

function Assert-Equal {
    param(
        [object]$Actual,
        [object]$Expected,
        [string]$Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message Expected=[$Expected], Actual=[$Actual]"
    }
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Test-Case {
    param(
        [string]$Name,
        [scriptblock]$Body
    )

    try {
        & $Body
        $script:Passed++
        Write-Host "[PASS] $Name"
    } catch {
        $script:Failed++
        Write-Host "[FAIL] $Name"
        Write-Host "       $($_.Exception.Message)"
    }
}

function New-Mount {
    param(
        [string]$MountPoint,
        [string]$Uuid,
        [bool]$LostNotified = $true
    )

    return [PSCustomObject]@{
        enabled          = $true
        is_lost_notified = $LostNotified
        mp               = $MountPoint
        uuid             = $Uuid
    }
}

function New-Config {
    param([object[]]$Mounts)

    return [PSCustomObject]@{
        mount = @($Mounts)
    }
}

function New-Disk {
    param(
        [string]$Name,
        [string]$Path,
        [int64]$SizeGb,
        [string]$Uuid = $null,
        [string]$MountPoint = $null,
        [object[]]$Children = @()
    )

    return [PSCustomObject]@{
        name       = $Name
        path       = $Path
        type       = "disk"
        uuid       = $Uuid
        mountpoint = $MountPoint
        size       = $SizeGb * 1GB
        children   = @($Children)
    }
}

Test-Case "ConvertTo-FlatDeviceList keeps child parent name" {
    $devices = @(
        [PSCustomObject]@{
            name       = "sdb"
            kname      = "sdb"
            path       = "/dev/sdb"
            type       = "disk"
            uuid       = $null
            mountpoint = $null
            size       = 100 * 1GB
            fstype     = $null
            pkname     = $null
            model      = "disk"
            serial     = "serial"
            children   = @(
                [PSCustomObject]@{
                    name       = "sdb1"
                    kname      = "sdb1"
                    path       = "/dev/sdb1"
                    type       = "part"
                    uuid       = "uuid-part"
                    mountpoint = "/"
                    size       = 50 * 1GB
                    fstype     = "ext4"
                    pkname     = "sdb"
                    model      = $null
                    serial     = $null
                    children   = @()
                }
            )
        }
    )

    $flat = @(ConvertTo-FlatDeviceList -Devices $devices)

    Assert-Equal $flat.Count 2 "Flat list should contain disk and partition."
    Assert-Equal $flat[1].parent "sdb" "Partition parent should be the disk name."
}

Test-Case "Resolve-ArchiveMountTarget updates single missing archive UUID" {
    $config = New-Config -Mounts @(
        (New-Mount -MountPoint "/opt/mt2/x86/basket" -Uuid "missing-basket"),
        (New-Mount -MountPoint "/opt/mt2/x86/basket2" -Uuid "live-basket2")
    )

    $result = Resolve-ArchiveMountTarget -Config $config -LiveUuids @("live-basket2")

    Assert-Equal $result.Action "Update" "Single missing UUID should be updated."
    Assert-Equal $result.Mount.mp "/opt/mt2/x86/basket" "basket should be selected."
}

Test-Case "Resolve-ArchiveMountTarget asks to choose when both archive UUIDs are missing" {
    $config = New-Config -Mounts @(
        (New-Mount -MountPoint "/opt/mt2/x86/basket" -Uuid "missing-basket"),
        (New-Mount -MountPoint "/opt/mt2/x86/basket2" -Uuid "missing-basket2")
    )

    $result = Resolve-ArchiveMountTarget -Config $config -LiveUuids @("system-uuid")

    Assert-Equal $result.Action "Choose" "Several missing UUIDs should require user choice."
    Assert-Equal $result.Options.Count 2 "Two archive options should be returned."
}

Test-Case "Resolve-ArchiveMountTarget creates basket2 when only basket exists and is live" {
    $config = New-Config -Mounts @(
        (New-Mount -MountPoint "/opt/mt2/x86/basket" -Uuid "live-basket")
    )

    $result = Resolve-ArchiveMountTarget -Config $config -LiveUuids @("live-basket")

    Assert-Equal $result.Action "Create" "Missing second archive block should be created."
    Assert-Equal $result.MountPoint "/opt/mt2/x86/basket2" "basket2 should be created."
}

Test-Case "Add-ArchiveMount adds expected mount block" {
    $config = New-Config -Mounts @(
        (New-Mount -MountPoint "/opt/mt2/x86/basket" -Uuid "live-basket")
    )

    Add-ArchiveMount -Config $config -MountPoint "/opt/mt2/x86/basket2" -Uuid "new-uuid"

    Assert-Equal $config.mount.Count 2 "Mount array should contain a new item."
    Assert-Equal $config.mount[1].mp "/opt/mt2/x86/basket2" "New mount point should be basket2."
    Assert-Equal $config.mount[1].uuid "new-uuid" "New UUID should be written."
    Assert-True $config.mount[1].enabled "New mount should be enabled."
    Assert-True $config.mount[1].is_lost_notified "New archive mount should use is_lost_notified=true."
}

Test-Case "Get-NewDiskCandidates filters unsafe disks" {
    $devices = @(
        (New-Disk -Name "sda" -Path "/dev/sda" -SizeGb 2000 -Uuid "system-uuid"),
        (New-Disk -Name "sdb" -Path "/dev/sdb" -SizeGb 2000 -Uuid "configured-uuid"),
        (New-Disk -Name "sdc" -Path "/dev/sdc" -SizeGb 2000 -MountPoint "/mnt/archive"),
        (New-Disk -Name "sdd" -Path "/dev/sdd" -SizeGb 2000 -Children @([PSCustomObject]@{ name = "sdd1" })),
        (New-Disk -Name "sde" -Path "/dev/sde" -SizeGb 500),
        (New-Disk -Name "sdf" -Path "/dev/sdf" -SizeGb 2000),
        (New-Disk -Name "sdg" -Path "/dev/sdg" -SizeGb 4000 -Uuid "new-uuid")
    )

    $candidates = @(Get-NewDiskCandidates `
        -Devices $devices `
        -SystemDiskName "sda" `
        -ConfigUuids @("configured-uuid") `
        -MinDiskSizeBytes (1000 * 1GB))

    Assert-Equal $candidates.Count 2 "Only safe new disks should remain."
    Assert-Equal $candidates[0].name "sdf" "Blank UUID large disk should be a candidate."
    Assert-Equal $candidates[1].name "sdg" "Unconfigured UUID large disk should be a candidate."
}

Write-Host ""
Write-Host "Tests passed: $script:Passed"
Write-Host "Tests failed: $script:Failed"

if ($script:Failed -gt 0) {
    exit 1
}
