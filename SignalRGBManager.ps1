# SignalRGB Plugin Manager
# Developed by cryptofyre
# Version 1.0

using namespace System.Management.Automation.Host

function Test-AdminPrivileges {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Scheduler related functions
function Show-ScheduleTypeMenu {
    Clear-Host
    Write-Host "Select Schedule Type" -ForegroundColor Cyan
    Write-Host "1. Run at logon"
    Write-Host "2. Run every 12 hours"
    Write-Host "3. Cancel"
    
    while ($true) {
        $choice = Read-Host "`nEnter your choice"
        switch ($choice) {
            "1" { return "LogOn" }
            "2" { return "Periodic" }
            "3" { return $null }
            default { 
                Write-Host "Invalid choice. Please try again." -ForegroundColor Red
                continue 
            }
        }
    }
}

function New-CleanupTask {
    param(
        [string]$ConfigPath,
        [string]$ScheduleType
    )
    
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NonInteractive -NoLogo -NoProfile -File `"$PSScriptRoot\SignalRGBManager.ps1`" -RunScheduledCleanup `"$ConfigPath`""
    
    # Create trigger based on schedule type
    $trigger = switch ($ScheduleType) {
        "LogOn" {
            New-ScheduledTaskTrigger -AtLogOn
        }
        "Periodic" {
            $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Hours 12)
            # Ensure the task continues indefinitely
            $trigger.Repetition.Duration = ""
            $trigger
        }
    }
    
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden
    
    $taskName = "SignalRGB Plugin Cleanup"
    $description = "Automatically removes unwanted SignalRGB plugins when new versions are detected"
    
    # Remove existing task if it exists
    Unregister-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue -Confirm:$false
    
    # Create new task
    Register-ScheduledTask -TaskName $taskName `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Description $description `
        -RunLevel Highest

    $scheduleDescription = if ($ScheduleType -eq "LogOn") {
        "at logon"
    } else {
        "every 12 hours"
    }
    
    Write-Host "Scheduled task created successfully (Running $scheduleDescription)" -ForegroundColor Green
}

function Remove-CleanupTask {
    $taskName = "SignalRGB Plugin Cleanup"
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "Scheduled task removed successfully" -ForegroundColor Green
    } else {
        Write-Host "No scheduled task found" -ForegroundColor Yellow
    }
}

function Test-ScheduledTaskSetup {
    param(
        [string[]]$ManufacturersToRemove
    )
    
    $testDir = "$env:TEMP\SignalRGBTest"
    $testPluginsPath = "$testDir\app-999.999.999\Signal-x64\Plugins"
    
    # Create test directory structure
    New-Item -Path $testPluginsPath -ItemType Directory -Force | Out-Null
    
    # Create test manufacturer folders
    foreach ($manufacturer in $ManufacturersToRemove) {
        New-Item -Path "$testPluginsPath\$manufacturer" -ItemType Directory -Force | Out-Null
        # Add a dummy file to make it more realistic
        "Test file" | Out-File -FilePath "$testPluginsPath\$manufacturer\test.dll"
    }
    
    Write-Host "Test environment created at: $testDir" -ForegroundColor Cyan
    Write-Host "Running cleanup test..." -ForegroundColor Cyan
    
    # Run cleanup on test directory
    $script:override_basePath = $testDir
    Remove-UnwantedPlugins -ManufacturersToRemove $ManufacturersToRemove
    $script:override_basePath = $null
    
    # Verify cleanup
    $remainingFolders = Get-ChildItem $testPluginsPath -Directory
    if ($remainingFolders.Count -eq 0) {
        Write-Host "Test successful! All test folders were removed correctly." -ForegroundColor Green
    } else {
        Write-Host "Test failed! Some folders remained: $($remainingFolders.Name -join ', ')" -ForegroundColor Red
    }
    
    # Cleanup test directory
    Remove-Item -Path $testDir -Recurse -Force
}

function Get-LatestSignalRGBPath {
    $basePath = if ($script:override_basePath) { 
        $script:override_basePath 
    } else { 
        "$env:LOCALAPPDATA\VortxEngine" 
    }
    
    $latestVersion = Get-ChildItem $basePath -Directory |
        Where-Object { $_.Name -match 'app-\d+\.\d+\.\d+' } |
        Sort-Object { [version]($_.Name -replace 'app-', '') } |
        Select-Object -Last 1
    
    if (-not $latestVersion) {
        throw "No SignalRGB installation found"
    }
    
    return Join-Path $latestVersion.FullName "Signal-x64\Plugins"
}

function Show-MultiSelect {
    param(
        [string]$Title,
        [string[]]$Options
    )
    
    $selection = @()
    $currentSelection = 0
    $page = 0
    $pageSize = 20
    $totalPages = [math]::Ceiling($Options.Count / $pageSize)
    
    $host.UI.RawUI.CursorVisible = $false
    
    while ($true) {
        Clear-Host
        Write-Host $Title -ForegroundColor Cyan
        Write-Host "Page $($page + 1)/$totalPages - Use ← → arrows to change pages" -ForegroundColor Yellow
        Write-Host "Space to select, Enter to confirm, Esc to cancel" -ForegroundColor Yellow
        Write-Host

        $startIndex = $page * $pageSize
        $pageOptions = $Options[$startIndex..([Math]::Min($startIndex + $pageSize - 1, $Options.Count - 1))]
        
        for ($i = 0; $i -lt $pageOptions.Count; $i++) {
            $item = $pageOptions[$i]
            $selected = $selection -contains $item
            $isCurrent = $i -eq $currentSelection
            
            $prefix = if ($selected) { "[X] " } else { "[ ] " }
            if ($isCurrent) {
                Write-Host "$prefix$item" -ForegroundColor Green
            } else {
                Write-Host "$prefix$item"
            }
        }

        $key = $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

        switch ($key.VirtualKeyCode) {
            38 { # Up arrow
                $currentSelection = [Math]::Max(0, $currentSelection - 1)
            }
            40 { # Down arrow
                $currentSelection = [Math]::Min($pageOptions.Count - 1, $currentSelection + 1)
            }
            37 { # Left arrow
                if ($page -gt 0) {
                    $page--
                    $currentSelection = 0
                }
            }
            39 { # Right arrow
                if ($page -lt $totalPages - 1) {
                    $page++
                    $currentSelection = 0
                }
            }
            32 { # Spacebar
                $selectedItem = $pageOptions[$currentSelection]
                if ($selection -contains $selectedItem) {
                    $selection = $selection | Where-Object { $_ -ne $selectedItem }
                } else {
                    $selection += $selectedItem
                }
            }
            13 { # Enter
                return $selection
            }
            27 { # Escape
                return $null
            }
        }
    }
}

function Save-Configuration {
    param(
        [string[]]$SelectedManufacturers,
        [string]$ConfigPath = ".\signalrgb-config.json"
    )
    
    $config = @{
        Manufacturers = $SelectedManufacturers
        LastUpdated = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }
    
    $config | ConvertTo-Json | Out-File -FilePath $ConfigPath
    Write-Host "Configuration saved to $ConfigPath" -ForegroundColor Green
    return $ConfigPath
}

function Remove-UnwantedPlugins {
    param(
        [string[]]$ManufacturersToRemove
    )
    
    $pluginsPath = Get-LatestSignalRGBPath
    
    foreach ($manufacturer in $ManufacturersToRemove) {
        $manufacturerPath = Join-Path $pluginsPath $manufacturer
        if (Test-Path $manufacturerPath) {
            Remove-Item -Path $manufacturerPath -Recurse -Force
            Write-Host "Removed plugins for $manufacturer" -ForegroundColor Green
        }
    }
}

# Parse command line arguments for scheduled task execution
if ($args -contains "-RunScheduledCleanup") {
    $configPath = $args[$args.IndexOf("-RunScheduledCleanup") + 1]
    if (Test-Path $configPath) {
        $config = Get-Content $configPath | ConvertFrom-Json
        Remove-UnwantedPlugins -ManufacturersToRemove $config.Manufacturers
    }
    exit
}

# Main script
$manufacturers = @(
    "A4Tech", "Ajazz", "Alienware", "AMD", "Anne", "Aqua Computer", "AsRock", "Asus",
    "Colorful", "CoolerMaster", "Corsair", "Creative Labs", "Crucial", "EVGA", "Fnatic",
    "GigaByte", "Glorious", "HyperX", "Kingston", "Lenovo", "LG", "Lian Li", "Logitech",
    "Mountain", "Msi", "Nollie", "Nuvoton", "Nzxt", "Patriot", "PNY", "PrismRGB", "Rama",
    "Razer", "Roccat", "Royal Kludge", "Royuan", "Sony", "SpeedLink", "Steelseries",
    "Thermal Take", "Turtle Beach", "Wooting", "Xiaohua", "XPG", "Zalman"
)

$isAdmin = Test-AdminPrivileges

# Main menu loop
while ($true) {
    Clear-Host
    Write-Host "SignalRGB Plugin Manager" -ForegroundColor Cyan
    Write-Host "Developed by cryptofyre" -ForegroundColor Cyan
    if (-not $isAdmin) {
        Write-Host "Running without administrator privileges - some features unavailable" -ForegroundColor Yellow
    }
    Write-Host "1. Select manufacturers to remove"
    Write-Host "2. Load saved configuration and remove plugins"
    if ($isAdmin) {
        Write-Host "3. Create scheduled cleanup task"
        Write-Host "4. Remove scheduled cleanup task"
        Write-Host "5. Test scheduled task setup"
        Write-Host "6. Exit"
    } else {
        Write-Host "3. Create scheduled cleanup task [REQUIRES ADMIN]" -ForegroundColor DarkGray
        Write-Host "4. Remove scheduled cleanup task [REQUIRES ADMIN]" -ForegroundColor DarkGray
        Write-Host "5. Test scheduled task setup [REQUIRES ADMIN]" -ForegroundColor DarkGray
        Write-Host "6. Exit"
    }
    
    $choice = Read-Host "`nEnter your choice"
    
    switch ($choice) {
        "1" {
            $selected = Show-MultiSelect -Title "Select manufacturers to remove (Space to select, Enter to confirm)" -Options $manufacturers
            if ($null -ne $selected) {
                $configPath = Save-Configuration -SelectedManufacturers $selected
                $remove = Read-Host "Do you want to remove the selected plugins now? (Y/N)"
                if ($remove -eq 'Y') {
                    Remove-UnwantedPlugins -ManufacturersToRemove $selected
                }
            }
        }
        "2" {
            if (Test-Path ".\signalrgb-config.json") {
                $config = Get-Content ".\signalrgb-config.json" | ConvertFrom-Json
                Write-Host "Loading configuration from $(Get-Date $config.LastUpdated)`n"
                Write-Host "Manufacturers to remove:"
                $config.Manufacturers | ForEach-Object { Write-Host "- $_" }
                $confirm = Read-Host "`nProceed with removal? (Y/N)"
                if ($confirm -eq 'Y') {
                    Remove-UnwantedPlugins -ManufacturersToRemove $config.Manufacturers
                }
            } else {
                Write-Host "No saved configuration found!" -ForegroundColor Red
                Start-Sleep -Seconds 2
            }
        }
        "3" {
            if (-not $isAdmin) {
                Write-Host "This feature requires administrator privileges." -ForegroundColor Red
                Write-Host "Please restart the script as administrator." -ForegroundColor Yellow
                Start-Sleep -Seconds 2
                continue
            }
            if (-not (Test-Path ".\signalrgb-config.json")) {
                Write-Host "Please create a configuration first (Option 1)" -ForegroundColor Red
                Start-Sleep -Seconds 2
                continue
            }
            $configPath = Resolve-Path ".\signalrgb-config.json"
            $scheduleType = Show-ScheduleTypeMenu
            if ($scheduleType) {
                New-CleanupTask -ConfigPath $configPath -ScheduleType $scheduleType
            }
            Start-Sleep -Seconds 2
        }
        "4" {
            if (-not $isAdmin) {
                Write-Host "This feature requires administrator privileges." -ForegroundColor Red
                Write-Host "Please restart the script as administrator." -ForegroundColor Yellow
                Start-Sleep -Seconds 2
                continue
            }
            Remove-CleanupTask
            Start-Sleep -Seconds 2
        }
        "5" {
            if (-not $isAdmin) {
                Write-Host "This feature requires administrator privileges." -ForegroundColor Red
                Write-Host "Please restart the script as administrator." -ForegroundColor Yellow
                Start-Sleep -Seconds 2
                continue
            }
            if (Test-Path ".\signalrgb-config.json") {
                $config = Get-Content ".\signalrgb-config.json" | ConvertFrom-Json
                Test-ScheduledTaskSetup -ManufacturersToRemove $config.Manufacturers
            } else {
                Write-Host "No configuration found to test with!" -ForegroundColor Red
            }
            Write-Host "`nPress any key to continue..."
            $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
        }
        "6" {
            exit
        }
    }
}