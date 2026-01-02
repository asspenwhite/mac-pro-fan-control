<#
.SYNOPSIS
    GPU Temperature Sender for Mac Pro Rack Fan Control System

.DESCRIPTION
    Reads temperatures from NVIDIA GPUs using nvidia-smi and sends them via UDP
    to the Linux host running the fan control daemon.

    Sends JSON payload:
    {
        "gpu0_temp": 65,
        "gpu1_temp": 67
    }

.PARAMETER TargetIP
    IP address of the Linux host running fan-controller.py
    Default: 192.168.137.2 (Mac Pro Rack Proxmox host)

.PARAMETER TargetPort
    UDP port to send temperature data to
    Default: 9999

.PARAMETER Interval
    Polling interval in seconds
    Default: 2

.PARAMETER Verbose
    Enable verbose output

.EXAMPLE
    .\gpu-temp-sender.ps1 -TargetIP "192.168.1.100" -Interval 2

.NOTES
    Requires nvidia-smi to be in PATH or NVIDIA drivers installed.
    Designed to run in Windows VM with GPU passthrough on Mac Pro Rack.
#>

param(
    [Parameter()]
    [string]$TargetIP = "192.168.137.2",

    [Parameter()]
    [int]$TargetPort = 9999,

    [Parameter()]
    [int]$Interval = 2,

    [Parameter()]
    [switch]$VerboseOutput
)

# =============================================================================
# Configuration
# =============================================================================

$ErrorActionPreference = "Continue"
$Script:Running = $true

# nvidia-smi path (auto-detect or set explicitly)
$NvidiaSmiPaths = @(
    "nvidia-smi",
    "C:\Windows\System32\nvidia-smi.exe",
    "C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe",
    "${env:ProgramFiles}\NVIDIA Corporation\NVSMI\nvidia-smi.exe"
)

$Script:NvidiaSmi = $null
foreach ($path in $NvidiaSmiPaths) {
    if (Get-Command $path -ErrorAction SilentlyContinue) {
        $Script:NvidiaSmi = $path
        break
    }
}

if (-not $Script:NvidiaSmi) {
    Write-Error "nvidia-smi not found! Please ensure NVIDIA drivers are installed."
    exit 1
}

# =============================================================================
# Functions
# =============================================================================

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] [$Level] $Message"

    switch ($Level) {
        "ERROR" { Write-Host $logLine -ForegroundColor Red }
        "WARN"  { Write-Host $logLine -ForegroundColor Yellow }
        "DEBUG" { if ($VerboseOutput) { Write-Host $logLine -ForegroundColor Gray } }
        default { Write-Host $logLine }
    }
}

function Get-GPUTemperatures {
    <#
    .SYNOPSIS
        Query nvidia-smi for GPU temperatures
    .OUTPUTS
        Hashtable with gpu0_temp and gpu1_temp (or $null on error)
    #>

    try {
        # Query temperature for all GPUs
        # Format: index, temperature.gpu (just the number)
        $output = & $Script:NvidiaSmi --query-gpu=index,temperature.gpu --format=csv,noheader,nounits 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-Log "nvidia-smi returned error code $LASTEXITCODE" -Level "ERROR"
            return $null
        }

        $temps = @{}

        # Parse each line: "0, 65" or "1, 67"
        $lines = $output -split "`n" | Where-Object { $_.Trim() -ne "" }

        foreach ($line in $lines) {
            $parts = $line -split ",\s*"
            if ($parts.Count -ge 2) {
                $index = [int]$parts[0].Trim()
                $temp = [int]$parts[1].Trim()
                $temps["gpu${index}_temp"] = $temp
            }
        }

        # Ensure we have both GPUs
        if (-not $temps.ContainsKey("gpu0_temp")) {
            Write-Log "GPU 0 temperature not found" -Level "WARN"
            $temps["gpu0_temp"] = 60  # Default safe value
        }
        if (-not $temps.ContainsKey("gpu1_temp")) {
            Write-Log "GPU 1 temperature not found" -Level "WARN"
            $temps["gpu1_temp"] = 60  # Default safe value
        }

        return $temps

    } catch {
        Write-Log "Failed to query GPU temperatures: $_" -Level "ERROR"
        return $null
    }
}

function Send-UDPPacket {
    param(
        [string]$Data,
        [string]$IP,
        [int]$Port
    )

    try {
        $udpClient = New-Object System.Net.Sockets.UdpClient
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Data)
        $udpClient.Send($bytes, $bytes.Length, $IP, $Port) | Out-Null
        $udpClient.Close()
        return $true
    } catch {
        Write-Log "Failed to send UDP packet: $_" -Level "ERROR"
        return $false
    }
}

function Start-TempSender {
    <#
    .SYNOPSIS
        Main loop to read and send GPU temperatures
    #>

    Write-Log "=========================================="
    Write-Log "GPU Temperature Sender Starting"
    Write-Log "=========================================="
    Write-Log "Target: ${TargetIP}:${TargetPort}"
    Write-Log "Interval: ${Interval}s"
    Write-Log "nvidia-smi: $Script:NvidiaSmi"

    # Get initial GPU info
    try {
        $gpuInfo = & $Script:NvidiaSmi --query-gpu=index,name,pci.bus_id --format=csv,noheader 2>&1
        Write-Log "Detected GPUs:"
        foreach ($line in ($gpuInfo -split "`n" | Where-Object { $_.Trim() -ne "" })) {
            Write-Log "  $line"
        }
    } catch {
        Write-Log "Could not query GPU info: $_" -Level "WARN"
    }

    Write-Log "Starting temperature monitoring loop..."
    Write-Log "Press Ctrl+C to stop"

    # Register Ctrl+C handler
    $null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
        $Script:Running = $false
    }

    try {
        [Console]::TreatControlCAsInput = $false
    } catch {
        # May not work in all environments
    }

    $lastTemps = @{}
    $sendCount = 0
    $errorCount = 0

    while ($Script:Running) {
        $loopStart = Get-Date

        # Read temperatures
        $temps = Get-GPUTemperatures

        if ($temps) {
            # Create JSON payload
            $payload = @{
                gpu0_temp = $temps["gpu0_temp"]
                gpu1_temp = $temps["gpu1_temp"]
            } | ConvertTo-Json -Compress

            # Send via UDP
            $sent = Send-UDPPacket -Data $payload -IP $TargetIP -Port $TargetPort

            if ($sent) {
                $sendCount++

                # Log if temperatures changed significantly
                $changed = $false
                foreach ($key in $temps.Keys) {
                    if (-not $lastTemps.ContainsKey($key) -or
                        [Math]::Abs($temps[$key] - $lastTemps[$key]) -ge 2) {
                        $changed = $true
                        break
                    }
                }

                if ($changed -or ($sendCount % 30 -eq 0)) {
                    Write-Log "Sent: GPU0=$($temps['gpu0_temp'])C, GPU1=$($temps['gpu1_temp'])C"
                } else {
                    Write-Log "Sent: GPU0=$($temps['gpu0_temp'])C, GPU1=$($temps['gpu1_temp'])C" -Level "DEBUG"
                }

                $lastTemps = $temps.Clone()
                $errorCount = 0
            } else {
                $errorCount++
                if ($errorCount -ge 5) {
                    Write-Log "Multiple send failures, check network connectivity" -Level "WARN"
                }
            }
        } else {
            $errorCount++
            if ($errorCount -ge 3) {
                Write-Log "Persistent GPU read failures" -Level "WARN"
            }
        }

        # Sleep for remaining interval
        $elapsed = ((Get-Date) - $loopStart).TotalSeconds
        $sleepTime = [Math]::Max(0, $Interval - $elapsed)
        if ($sleepTime -gt 0) {
            Start-Sleep -Milliseconds ($sleepTime * 1000)
        }

        # Check for Ctrl+C (only works with interactive console)
        try {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq "C" -and $key.Modifiers -eq "Control") {
                    Write-Log "Ctrl+C detected, stopping..."
                    $Script:Running = $false
                }
            }
        } catch {
            # Ignore - console not available when running as scheduled task or in background
        }
    }

    Write-Log "Temperature sender stopped"
    Write-Log "Total packets sent: $sendCount"
}

# =============================================================================
# Service Installation Functions
# =============================================================================

function Install-AsScheduledTask {
    <#
    .SYNOPSIS
        Install this script as a scheduled task that runs at startup
    #>

    $taskName = "GPUTempSender"
    $scriptPath = $MyInvocation.PSCommandPath

    # Check if already installed
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Write-Log "Task '$taskName' already exists. Removing..." -Level "WARN"
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }

    # Create the task
    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -TargetIP `"$TargetIP`" -TargetPort $TargetPort -Interval $Interval"

    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1)

    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description "Sends GPU temperatures to Mac Pro Rack fan controller"

    Write-Log "Scheduled task '$taskName' created successfully"
    Write-Log "The task will start automatically at boot"
    Write-Log "To start now: Start-ScheduledTask -TaskName '$taskName'"
}

function Uninstall-ScheduledTask {
    <#
    .SYNOPSIS
        Remove the scheduled task
    #>

    $taskName = "GPUTempSender"

    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Log "Scheduled task '$taskName' removed"
    } else {
        Write-Log "Scheduled task '$taskName' not found" -Level "WARN"
    }
}

# =============================================================================
# Main Entry Point
# =============================================================================

# Handle special commands
if ($args -contains "-Install") {
    Install-AsScheduledTask
    exit 0
}

if ($args -contains "-Uninstall") {
    Uninstall-ScheduledTask
    exit 0
}

# Normal operation
Start-TempSender
