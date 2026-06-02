function ConvertTo-FlatDeviceList {
    param([object[]]$Devices)

    $items = New-Object System.Collections.Generic.List[object]

    function Add-Device {
        param(
            [object]$Device,
            [string]$ParentName
        )

        $items.Add([PSCustomObject]@{
            name       = $Device.name
            kname      = $Device.kname
            path       = $Device.path
            type       = $Device.type
            uuid       = $Device.uuid
            mountpoint = $Device.mountpoint
            size       = [int64]($Device.size)
            fstype     = $Device.fstype
            pkname     = $Device.pkname
            model      = $Device.model
            serial     = $Device.serial
            parent     = $ParentName
            children   = @($Device.children)
        })

        foreach ($child in @($Device.children)) {
            Add-Device -Device $child -ParentName $Device.name
        }
    }

    foreach ($device in $Devices) {
        Add-Device -Device $device -ParentName $null
    }

    return $items
}

function Format-Size {
    param([int64]$Bytes)

    if ($Bytes -le 0) {
        return "unknown"
    }

    return "{0:N1} GB" -f ($Bytes / 1GB)
}

function Get-ArchiveMounts {
    param([object]$Config)

    return @($Config.mount | Where-Object {
        $_.mp -eq "/opt/mt2/x86/basket" -or $_.mp -eq "/opt/mt2/x86/basket2"
    })
}

function Resolve-ArchiveMountTarget {
    param(
        [object]$Config,
        [string[]]$LiveUuids
    )

    $archiveMounts = Get-ArchiveMounts -Config $Config
    $staleMounts = @($archiveMounts | Where-Object {
        $_.uuid -and ($LiveUuids -notcontains $_.uuid)
    })

    if ($staleMounts.Count -eq 1) {
        return [PSCustomObject]@{
            Action     = "Update"
            Mount      = $staleMounts[0]
            Options    = @()
            MountPoint = $staleMounts[0].mp
        }
    }

    if ($staleMounts.Count -gt 1) {
        return [PSCustomObject]@{
            Action     = "Choose"
            Mount      = $null
            Options    = $staleMounts
            MountPoint = $null
        }
    }

    $hasBasket = [bool](@($archiveMounts | Where-Object { $_.mp -eq "/opt/mt2/x86/basket" }).Count)
    $hasBasket2 = [bool](@($archiveMounts | Where-Object { $_.mp -eq "/opt/mt2/x86/basket2" }).Count)

    if ($hasBasket -and -not $hasBasket2) {
        return [PSCustomObject]@{
            Action     = "Create"
            Mount      = $null
            Options    = @()
            MountPoint = "/opt/mt2/x86/basket2"
        }
    }

    if ($hasBasket2 -and -not $hasBasket) {
        return [PSCustomObject]@{
            Action     = "Create"
            Mount      = $null
            Options    = @()
            MountPoint = "/opt/mt2/x86/basket"
        }
    }

    throw "Не найден archive mount-point с отсутствующим UUID, и создать новый archive блок нельзя: basket=$hasBasket, basket2=$hasBasket2."
}

function Add-ArchiveMount {
    param(
        [object]$Config,
        [string]$MountPoint,
        [string]$Uuid
    )

    $newMount = [PSCustomObject][ordered]@{
        enabled          = $true
        is_lost_notified = $true
        mp               = $MountPoint
        uuid             = $Uuid
    }

    $mounts = @($Config.mount)
    $Config.mount = @($mounts + $newMount)
}

function Get-NewDiskCandidates {
    param(
        [object[]]$Devices,
        [string]$SystemDiskName,
        [string[]]$ConfigUuids,
        [int64]$MinDiskSizeBytes
    )

    return @($Devices | Where-Object {
        $_.type -eq "disk" `
            -and $_.name -ne $SystemDiskName `
            -and $_.path `
            -and -not $_.mountpoint `
            -and @($_.children).Count -eq 0 `
            -and $_.size -ge $MinDiskSizeBytes `
            -and ((-not $_.uuid) -or ($ConfigUuids -notcontains $_.uuid))
    })
}

Export-ModuleMember -Function `
    ConvertTo-FlatDeviceList, `
    Format-Size, `
    Get-ArchiveMounts, `
    Resolve-ArchiveMountTarget, `
    Add-ArchiveMount, `
    Get-NewDiskCandidates
