<#
.SYNOPSIS
    Automatically sets up a Windows Developer Drive for improved build performance.

.DESCRIPTION
    This script identifies the best available storage option and creates or configures a trusted developer drive.
    Developer drives provide enhanced performance for development workloads by using ReFS with optimizations
    for common development scenarios like compilation and file I/O operations.

    The script will:
    1. Search for viable dev drive options in priority order:
       - Existing trusted dev drives (reuse without changes)
       - Existing untrusted dev drives (make trusted and reuse)
       - Unallocated disk space (create new dev drive)
       - Empty/reformattable partitions (convert to dev drive)
       - Resizable partitions (shrink and create new dev drive)

    2. For resizable partitions:
       - Ensures the existing partition keeps at least 100GB of free space
       - Allows user to specify the exact size for the dev drive (minimum 400GB)

    3. Automatically adds Windows Defender exclusions for the dev drive to improve performance

    Can be run without cloning the repo:
        irm https://raw.githubusercontent.com/YOUR_ORG/WindowsDevSetup/main/setup_dev_drive.ps1 | iex

.REQUIREMENTS
    - Windows 11 22H2 or later (for dev drive support)
    - Administrator privileges (will self-elevate if needed)
    - At least 400GB of available storage on a non-OS disk

.NOTES
    Created with assistance from GitHub Copilot
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'  # Suppress progress bars

# Self-elevate to admin if needed (before Set-StrictMode to avoid property access issues via iex)
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Write-Output "Administrator privileges required. Requesting elevation..."

    $scriptPath = try { $MyInvocation.MyCommand.Path } catch { $null }
    if ($scriptPath) {
        # Running from a file on disk - re-run with a flag so the elevated window pauses
        $argList = "-NoProfile -ExecutionPolicy Bypass -Command `"& { `$env:SETUP_DEV_DRIVE_ELEVATED = '1'; & '$scriptPath' }`""
    } else {
        # Running via iex/piped input - save to temp file for elevation
        $tempScript = Join-Path $env:TEMP "setup_dev_drive.ps1"
        try {
            $MyInvocation.MyCommand.ScriptBlock.ToString() | Set-Content -Path $tempScript -Encoding UTF8
        } catch {
            Write-Error "Failed to extract script for elevation. Please run this script as administrator."
            exit 1314
        }
        $argList = "-NoProfile -ExecutionPolicy Bypass -Command `"& { `$env:SETUP_DEV_DRIVE_ELEVATED = '1'; & '$tempScript' }`""
    }

    try {
        $process = Start-Process powershell -Verb RunAs -ArgumentList $argList -Wait -PassThru
        exit $process.ExitCode
    } catch {
        Write-Error "Failed to elevate to administrator. Please run this script as administrator."
        exit 1314  # ERROR_PRIVILEGE_NOT_HELD
    }
}

Set-StrictMode -Version Latest

$MINIMUM_DEV_DRIVE_SIZE = 400GB

function Test-IsTrustedDevDrive {
    param([string]$driveLetter)

    $result = fsutil devdrv query "${driveLetter}:" 2>$null
    return $result -match "This is a trusted developer volume"
}

function Test-IsUntrustedDevDrive {
    param([string]$driveLetter)

    $result = fsutil devdrv query "${driveLetter}:" 2>$null
    return $result -match "The volume is formatted as a developer volume but is not trusted on this machine"
}

function Set-DevDriveTrusted {
    param([string]$driveLetter)

    Write-Output "Setting dev drive $($driveLetter): as trusted..."
    try {
        fsutil devdrv trust "${driveLetter}:" | Out-Null
        Write-Output "Dev drive $($driveLetter): is now trusted"
        return $true
    } catch {
        Write-Warning "Failed to set dev drive $($driveLetter): as trusted: $($_.Exception.Message)"
        return $false
    }
}

function Dismount-AndRemountDisk {
    param([string]$driveLetter)

    Write-Output "Dismounting and remounting disk containing $($driveLetter): to ensure trust status is applied..."

    try {
        # Get the disk number for the drive
        $partition = Get-Partition -DriveLetter $driveLetter
        $diskNumber = $partition.DiskNumber

        # Dismount the disk
        Write-Output "Dismounting disk $diskNumber..."
        Set-Disk -Number $diskNumber -IsOffline $true

        # Wait for dismount to complete by checking disk status
        $maxWaitSeconds = 30
        $waitStart = Get-Date
        do {
            Start-Sleep -Milliseconds 500
            $disk = Get-Disk -Number $diskNumber
            $elapsed = (Get-Date) - $waitStart
            if ($elapsed.TotalSeconds -gt $maxWaitSeconds) {
                throw "Timeout waiting for disk $diskNumber to go offline"
            }
        } while (-not $disk.IsOffline)

        Write-Output "Disk $diskNumber is now offline"

        # Remount the disk
        Write-Output "Remounting disk $diskNumber..."
        Set-Disk -Number $diskNumber -IsOffline $false

        # Wait for remount to complete by checking disk status and volume accessibility
        $waitStart = Get-Date
        do {
            Start-Sleep -Milliseconds 500
            $disk = Get-Disk -Number $diskNumber
            $elapsed = (Get-Date) - $waitStart
            if ($elapsed.TotalSeconds -gt $maxWaitSeconds) {
                throw "Timeout waiting for disk $diskNumber to come online"
            }
        } while ($disk.IsOffline)

        # Additional check: Wait for the original drive letter to be accessible
        $waitStart = Get-Date
        do {
            Start-Sleep -Milliseconds 500
            $volumeAccessible = Test-Path "${driveLetter}:\"
            $elapsed = (Get-Date) - $waitStart
            if ($elapsed.TotalSeconds -gt $maxWaitSeconds) {
                throw "Timeout waiting for volume $($driveLetter): to become accessible"
            }
        } while (-not $volumeAccessible)

        Write-Output "Disk $diskNumber is now online and volume $($driveLetter): is accessible"
        return $true
    } catch {
        Write-Warning "Failed to dismount/remount disk: $($_.Exception.Message)"
        return $false
    }
}

function Confirm-UntrustedDevDriveChoice {
    param([PSCustomObject]$option, [PSCustomObject[]]$otherOptions)

    Write-Host ""
    Write-Host "Found untrusted dev drive at $($option.DriveLetter): ($(Format-SizeInGB $option.Size))"
    Write-Host ""
    Write-Host "To use this drive, it needs to be made trusted and followed by the its parent disk"
    Write-Host "being dismounted & remounted to make trust status change take effect."
    Write-Host ""
    Write-Warning "WARNING:"
    Write-Warning "  The dismount/remount operation will temporarily disconnect all volumes on"
    Write-Warning "  the same physical disk. Any open files on those volumes may be affected."
    Write-Host ""

    if ($otherOptions.Count -gt 0) {
        Write-Host "Alternative options are available if you prefer not to use this untrusted dev drive."
        Write-Host ""
    }

    $choice = Read-Host "Do you want to trust and use this dev drive? (y/N)"
    return ($choice -eq 'y' -or $choice -eq 'Y')
}

function Format-SizeInGB {
    param([long]$sizeInBytes)
    return "$([math]::Round($sizeInBytes / 1GB, 2)) GB"
}

function GetAvailableDriveLetter {
    # Get available drive letter (D-Z) that is not currently in use
    $availableLetters = @(68..90 | ForEach-Object { [char]$_ } | Where-Object {
        -not (Get-Volume -DriveLetter $_ -ErrorAction SilentlyContinue)
    })

    if (-not $availableLetters) {
        throw "No available drive letters for new partition"
    }

    return $availableLetters[0]
}

function Confirm-DevDriveOperation {
    param([PSCustomObject]$option)

    Write-Output ""
    switch ($option.OptionType) {
        'UntrustedDevDrive' {
            Write-Output "Found untrusted dev drive $($option.DriveLetter): ($(Format-SizeInGB $option.Size))"
            Write-Output "Will offer option to make this dev drive trusted and dismount/remount its disk to pick up the change."
        }
        'UnallocatedSpace' {
            Write-Output "Found unallocated space on disk $($option.DiskNumber) ($(Format-SizeInGB $option.Size))"
            Write-Output "A new dev drive will be created using this space."
        }
        'UnallocatedRawSpace' {
            Write-Output "Found uninitialized disk $($option.DiskNumber) ($(Format-SizeInGB $option.Size))"
            Write-Output "The disk will be initialized and a new dev drive will be created."
        }
        'ReformattablePartition' {
            Write-Output "Found reformattable partition $($option.DriveLetter): ($(Format-SizeInGB $option.Size))"
            Write-Output "This partition will be reformatted as a dev drive. ALL DATA WILL BE LOST."

            # Show contents of the partition
            $volumePath = "$($option.DriveLetter):\"
            $items = @(Get-ChildItem -Path $volumePath -Force -ErrorAction SilentlyContinue)
            if ($items.Count -eq 0) {
                Write-Output "Partition is empty."
            } else {
                Write-Output "Partition contains the following items:"
                $items | ForEach-Object { Write-Output "  $($_.Name)" }
            }
        }
        'ResizablePartition' {
            Write-Output "Found resizable partition $($option.DriveLetter): ($(Format-SizeInGB $option.Size))"
            Write-Output "This partition can be shrunk to make room while leaving at least $(Format-SizeInGB $option.MinimumToKeep)"
            Write-Output "free space in the current partition.`n"
            Write-Output "Up to $(Format-SizeInGB $option.MaxShrinkableSpace) is available for the dev drive."
            Write-Output "You will be able to specify the exact size for the dev drive if you continue."
        }
    }

    Write-Output ""
    $confirmation = Read-Host "Proceed with dev drive setup? (y/N)"
    if ($confirmation -ne 'y' -and $confirmation -ne 'Y') {
        Write-Output "Operation cancelled"
        exit 1
    }
    Write-Output ""
}

function Get-OSPartition {
    $osVolumes = @(Get-Volume | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter -eq $env:SystemDrive.Trim(':') })
    if ($osVolumes.Count -eq 0) {
        throw "Could not find OS volume for drive $($env:SystemDrive)"
    }
    if ($osVolumes.Count -gt 1) {
        throw "Multiple OS volumes found - this script does not handle this condition"
    }
    $osVolume = $osVolumes[0]
    $osPartition = Get-Partition -DriveLetter $osVolume.DriveLetter
    return $osPartition
}

function Get-ViableDevDriveOptions {
    $osPartition = Get-OSPartition
    $osDiskNumber = $osPartition.DiskNumber
    $options = @()

    Write-Debug "OS disk number: $osDiskNumber"
    Write-Debug "Required size: $(Format-SizeInGB $MINIMUM_DEV_DRIVE_SIZE)"

    $fixedVolumes = @(Get-Volume | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter })
    Write-Debug "Found $($fixedVolumes.Count) fixed volumes to evaluate"

    foreach ($volume in $fixedVolumes) {
        $partition = Get-Partition -DriveLetter $volume.DriveLetter

        if ($partition.DiskNumber -eq $osDiskNumber) {
            Write-Debug "Skipping volume $($volume.DriveLetter): - on OS disk"
            continue
        }

        if ($volume.Size -lt $MINIMUM_DEV_DRIVE_SIZE) {
            Write-Debug "Skipping volume $($volume.DriveLetter): - too small ($(Format-SizeInGB $volume.Size))"
            continue
        }

        # Priority 1: Pre-existing dev drive that is trusted (reuse without formatting)
        if (Test-IsTrustedDevDrive -driveLetter $volume.DriveLetter) {
            $options += [PSCustomObject]@{
                OptionType = 'ExistingDevDrive'
                DriveLetter = $volume.DriveLetter
                Size = $volume.Size
                Priority = 1
            }
            Write-Verbose "Found existing trusted dev drive: $($volume.DriveLetter): ($(Format-SizeInGB $volume.Size))"
            continue
        }

        # Priority 1.5: Pre-existing dev drive that is not trusted (prompt to make trusted)
        if (Test-IsUntrustedDevDrive -driveLetter $volume.DriveLetter) {
            $options += [PSCustomObject]@{
                OptionType = 'UntrustedDevDrive'
                DriveLetter = $volume.DriveLetter
                Size = $volume.Size
                Priority = 1.5
            }
            Write-Verbose "Found existing untrusted dev drive: $($volume.DriveLetter): ($(Format-SizeInGB $volume.Size))"
            continue
        } else {
            Write-Debug "Volume $($volume.DriveLetter): is not a dev drive"
        }

        $volumePath = "$($volume.DriveLetter):\"
        $items = @(Get-ChildItem -Path $volumePath -Force -ErrorAction SilentlyContinue)
        $onlySystemItems = $items.Count -eq 0 -or
            @($items | Where-Object { $_.Name -notin @('$Recycle.Bin', 'System Volume Information') }).Count -eq 0

        # Priority 3: Partition that can be reformatted without data loss
        if ($onlySystemItems) {
            $options += [PSCustomObject]@{
                OptionType = 'ReformattablePartition'
                DriveLetter = $volume.DriveLetter
                Size = $volume.Size
                Priority = 3
            }
            $itemsDescription = if ($items.Count -eq 0) { "empty" } else { "system files only" }
            Write-Verbose "Found reformattable partition: $($volume.DriveLetter): ($(Format-SizeInGB $volume.Size)) - $itemsDescription"
            continue
        }

        # Priority 4: Resizable partition to create enough room for a new dev drive partition
        $supportedSize = Get-PartitionSupportedSize -DriveLetter $volume.DriveLetter -ErrorAction SilentlyContinue
        if ($supportedSize) {
            $minimumToKeep = 100GB
            $maxShrinkableSpace = $volume.Size - $supportedSize.SizeMin - $minimumToKeep
            if ($maxShrinkableSpace -ge $MINIMUM_DEV_DRIVE_SIZE) {
                $options += [PSCustomObject]@{
                    OptionType = 'ResizablePartition'
                    DriveLetter = $volume.DriveLetter
                    Size = $volume.Size
                    MaxShrinkableSpace = $maxShrinkableSpace
                    MinimumToKeep = $minimumToKeep
                    Priority = 4
                }
                Write-Verbose "Found resizable partition: $($volume.DriveLetter): ($(Format-SizeInGB $volume.Size)) - can shrink by up to $(Format-SizeInGB $maxShrinkableSpace)"
            } else {
                Write-Debug "Skipping volume $($volume.DriveLetter): - insufficient shrinkable space after keeping 100GB ($(Format-SizeInGB $maxShrinkableSpace))"
            }
        } else {
            Write-Debug "Skipping volume $($volume.DriveLetter): - cannot determine shrinkable space"
        }
    }

    # Priority 2: Unallocated space (can be used without prompting)
    $nonOsDisks = @(Get-Disk | Where-Object { $_.Number -ne $osDiskNumber })
    Write-Debug "Found $($nonOsDisks.Count) non-OS disks to evaluate"

    foreach ($disk in $nonOsDisks) {
        if ($disk.PartitionStyle -eq 'RAW') {
            $availableSize = $disk.Size
        } else {
            $diskPartitions = @($disk | Get-Partition)
            if ($diskPartitions.Count -eq 0) {
                $availableSize = $disk.Size
            } else {
                $availableSize = $disk.Size - ($diskPartitions | Measure-Object -Property Size -Sum).Sum
            }
        }

        if ($disk.PartitionStyle -eq 'RAW') {
            $diskType = 'UnallocatedRawSpace'
        } else {
            $diskType = 'UnallocatedSpace'
        }

        if ($availableSize -ge $MINIMUM_DEV_DRIVE_SIZE) {
            $options += [PSCustomObject]@{
                OptionType = $diskType
                DiskNumber = $disk.Number
                Size = $availableSize
                Priority = 2
            }
            $typeDescription = if ($disk.PartitionStyle -eq 'RAW') { "RAW disk" } else { "unallocated space" }
            Write-Verbose "Found $typeDescription on disk $($disk.Number): $(Format-SizeInGB $availableSize)"
        } else {
            $typeDescription = if ($disk.PartitionStyle -eq 'RAW') { "RAW disk" } else { "unallocated space" }
            Write-Debug "Skipping disk $($disk.Number) - insufficient $typeDescription ($(Format-SizeInGB $availableSize))"
        }
    }

    Write-Debug "Found $($options.Count) total viable options"

    $options = @($options | Sort-Object -Property Priority)
    Write-Verbose "All viable options found:"
    for ($i = 0; $i -lt $options.Count; $i++) {
        $option = $options[$i]
        if ($option.OptionType -in @('ExistingDevDrive', 'UntrustedDevDrive', 'ReformattablePartition', 'ResizablePartition')) {
            Write-Verbose "  Option $($i): OptionType=$($option.OptionType), Priority=$($option.Priority), Drive=$($option.DriveLetter):, Size=$(Format-SizeInGB $option.Size)"
        } else {
            Write-Verbose "  Option $($i): OptionType=$($option.OptionType), Priority=$($option.Priority), Disk=$($option.DiskNumber), Size=$(Format-SizeInGB $option.Size)"
        }
    }

    return $options
}

function New-DevDriveFromUnallocated {
    param([PSCustomObject]$option)

    Write-Output "Creating dev drive on disk $($option.DiskNumber) using unallocated space..."

    # Initialize RAW disks if needed
    $disk = Get-Disk -Number $option.DiskNumber
    if ($disk.PartitionStyle -eq 'RAW') {
        Write-Output "Initializing RAW disk $($option.DiskNumber)..."
        Initialize-Disk -Number $option.DiskNumber -PartitionStyle GPT
    }

    $driveLetter = GetAvailableDriveLetter

    # Use UseMaximumSize to let PowerShell handle size calculation and avoid capacity issues
    New-Partition -DiskNumber $option.DiskNumber -UseMaximumSize -DriveLetter $driveLetter
    Format-Volume -DriveLetter $driveLetter -DevDrive -Confirm:$false

    Write-Output "Dev drive created successfully at ${driveLetter}:"

    # Add the DriveLetter property to the option object for later use
    $option | Add-Member -MemberType NoteProperty -Name DriveLetter -Value $driveLetter -Force
}

function ConvertTo-DevDrive {
    param([PSCustomObject]$option)

    Write-Output "Converting drive $($option.DriveLetter): to dev drive..."
    Format-Volume -DriveLetter $option.DriveLetter -DevDrive -Confirm:$false
    Write-Output "Drive $($option.DriveLetter): recreated as dev drive successfully"
}

function Invoke-ResizeAndCreateDevDrive {
    param([PSCustomObject]$option)

    $maxAvailable = $option.MaxShrinkableSpace

    Write-Output "Resizing partition $($option.DriveLetter): to make space for dev drive..."
    Write-Output ""
    Write-Output "Available space for dev drive: $(Format-SizeInGB $maxAvailable)"
    Write-Output "Minimum dev drive size: $(Format-SizeInGB $MINIMUM_DEV_DRIVE_SIZE)"
    Write-Output ""

    # Allow user to specify dev drive size
    do {
        $sizeInput = Read-Host "Enter dev drive size in GB (minimum $([math]::Round($MINIMUM_DEV_DRIVE_SIZE / 1GB)), maximum $([math]::Round($maxAvailable / 1GB)))"

        if ([double]::TryParse($sizeInput, [ref]$null)) {
            $requestedSizeGB = [double]$sizeInput
            $requestedSize = $requestedSizeGB * 1GB

            if ($requestedSize -ge $MINIMUM_DEV_DRIVE_SIZE -and $requestedSize -le $maxAvailable) {
                break
            } else {
                Write-Output "Size must be between $([math]::Round($MINIMUM_DEV_DRIVE_SIZE / 1GB)) GB and $([math]::Round($maxAvailable / 1GB)) GB"
            }
        } else {
            Write-Output "Please enter a valid number"
        }
    } while ($true)

    Write-Output ""
    Write-Output "Creating $(Format-SizeInGB $requestedSize) dev drive..."

    $newSize = $option.Size - $requestedSize
    Resize-Partition -DriveLetter $option.DriveLetter -Size $newSize

    $disk = Get-Partition -DriveLetter $option.DriveLetter | Get-Disk

    $driveLetter = GetAvailableDriveLetter

    # Create partition with the requested size
    New-Partition -DiskNumber $disk.Number -Size $requestedSize -DriveLetter $driveLetter
    Format-Volume -DriveLetter $driveLetter -DevDrive -Confirm:$false

    Write-Output "Dev drive created successfully at ${driveLetter}:"

    # Add the DriveLetter property to the option object for later use
    $option | Add-Member -MemberType NoteProperty -Name DriveLetter -Value $driveLetter -Force
}

function Main {
    Write-Output "Searching for dev drive options..."

    $options = @(Get-ViableDevDriveOptions)

    if ($options.Count -eq 0) {
        Write-Warning "No viable options found for creating a dev drive"
        Write-Output "Requirements: At least $(Format-SizeInGB $MINIMUM_DEV_DRIVE_SIZE) on a disk other than the OS disk"
        exit 1
    }

    # Handle the case where the first option is an untrusted dev drive
    if ($options[0].OptionType -eq 'UntrustedDevDrive') {
        $otherOptions = @($options | Select-Object -Skip 1)
        if (-not (Confirm-UntrustedDevDriveChoice -option $options[0] -otherOptions $otherOptions)) {
            Write-Output "Skipping untrusted dev drive, looking for alternative options..."
            if ($otherOptions.Count -eq 0) {
                Write-Warning "No other viable options found for creating a dev drive"
                Write-Output "Requirements: At least $(Format-SizeInGB $MINIMUM_DEV_DRIVE_SIZE) on a disk other than the OS disk"
                exit 1
            }
            $options = $otherOptions
        }
    }

    $selectedOption = $options[0]

    Write-Verbose "Selected option: OptionType=$($selectedOption.OptionType), Priority=$($selectedOption.Priority)"

    if (-not $selectedOption -or -not $selectedOption.OptionType) {
        Write-Error "Selected option is invalid or missing OptionType property"
        exit 1
    }

    # Handle existing dev drive without prompting
    if ($selectedOption.OptionType -eq 'ExistingDevDrive') {
        Write-Output ""
        Write-Output "Found existing trusted dev drive at $($selectedOption.DriveLetter): ($(Format-SizeInGB $selectedOption.Size))"
        Write-Output "This dev drive will be used without any changes."
    } elseif ($selectedOption.OptionType -eq 'UntrustedDevDrive') {
        Write-Output ""
        Write-Output "Processing untrusted dev drive at $($selectedOption.DriveLetter): ($(Format-SizeInGB $selectedOption.Size))"

        if (-not (Set-DevDriveTrusted -driveLetter $selectedOption.DriveLetter)) {
            Write-Error "Failed to make dev drive trusted. Cannot continue."
            exit 1
        }

        # Dismount and remount the disk
        if (-not (Dismount-AndRemountDisk -driveLetter $selectedOption.DriveLetter)) {
            Write-Warning "Failed to dismount/remount disk. Trust status may not be fully applied."
        }

        # Verify the drive is now trusted
        Write-Output "Verifying dev drive trust status..."
        if (-not (Test-IsTrustedDevDrive -driveLetter $selectedOption.DriveLetter)) {
            Write-Error "Dev drive is still not trusted after trust operation and remount. Cannot continue."
            exit 1
        }

        Write-Output "Dev drive $($selectedOption.DriveLetter): is now trusted and ready for use."
    } else {
        Confirm-DevDriveOperation -Option $selectedOption

        switch ($selectedOption.OptionType) {
            'UnallocatedSpace' {
                Write-Output "Creating dev drive from unallocated space on disk $($selectedOption.DiskNumber) ($(Format-SizeInGB $selectedOption.Size))"
                New-DevDriveFromUnallocated -Option $selectedOption
            }

            'UnallocatedRawSpace' {
                Write-Output "Creating dev drive from RAW disk $($selectedOption.DiskNumber) ($(Format-SizeInGB $selectedOption.Size))"
                New-DevDriveFromUnallocated -Option $selectedOption
            }

            'ReformattablePartition' {
                Write-Output "Converting partition $($selectedOption.DriveLetter): to dev drive ($(Format-SizeInGB $selectedOption.Size))"
                ConvertTo-DevDrive -Option $selectedOption
            }

            'ResizablePartition' {
                Write-Output "Resizing partition $($selectedOption.DriveLetter): and creating dev drive (up to $(Format-SizeInGB $selectedOption.MaxShrinkableSpace) available)"
                Invoke-ResizeAndCreateDevDrive -Option $selectedOption
            }
        }

        $volume = Get-Volume -DriveLetter $selectedOption.DriveLetter
        Write-Output ""
        Write-Output "Dev drive ready at $($selectedOption.DriveLetter): ($(Format-SizeInGB $volume.Size) total, $(Format-SizeInGB $volume.SizeRemaining) free)"
    }

    # Add Windows Defender exclusion for the dev drive (both existing and newly created)
    Write-Output ""
    Write-Output "Checking Windows Defender exclusions for dev drive..."
    try {
        $exclusionPath = "$($selectedOption.DriveLetter):\"
        $mpPreference = Get-MpPreference
        $existingExclusions = @($mpPreference.ExclusionPath)
        
        if ($existingExclusions -contains $exclusionPath) {
            Write-Output "Windows Defender exclusion already exists for $exclusionPath"
        } else {
            Write-Output "Adding Windows Defender exclusion for dev drive..."
            Add-MpPreference -ExclusionPath $exclusionPath
            Write-Output "Windows Defender exclusion added for $exclusionPath"
        }
    } catch {
        Write-Warning "Failed to check or add Windows Defender exclusion: $($_.Exception.Message)"
        Write-Output "You may need to manually add an exclusion for $($selectedOption.DriveLetter):\ in Windows Defender"
    }
}

# Execute main function
Main

# If we self-elevated into a new window, pause so the user can see the output
if ($env:SETUP_DEV_DRIVE_ELEVATED -eq '1') {
    Write-Output ""
    Read-Host "Press Enter to close this window"
}
