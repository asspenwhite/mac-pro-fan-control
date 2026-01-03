<#
.SYNOPSIS
    GPU Temperature and Fan Speed Sender for Mac Pro Rack Fan Control System

.DESCRIPTION
    Reads temperatures AND fan speeds from NVIDIA GPUs using nvidia-smi and sends them via UDP
    to the Linux host running the fan control daemon.

    Sends JSON payload:
    {
        "gpu0_temp": 65,
        "gpu1_temp": 67,
        "gpu0_fan": 45,
        "gpu1_fan": 48
    }

.PARAMETER TargetIP
    IP address of the Linux host running fan-controller.py
    Default: 192.168.1.188 (Mac Pro Rack Proxmox host)

.PARAMETER TargetPort
    UDP port to send temperature data to
    Default: 9999

.PARAMETER Interval
    Polling interval in seconds
    Default: 0.5 (matches Proxmox fan controller)

.PARAMETER Verbose
    Enable verbose output

.EXAMPLE
    .\gpu-temp-sender.ps1 -TargetIP "192.168.1.188" -Interval 0.5

.NOTES
    Requires nvidia-smi to be in PATH or NVIDIA drivers installed.
    Designed to run in Windows VM with GPU passthrough on Mac Pro Rack.
#>

param(
    [Parameter()]
    [string]$TargetIP = "192.168.1.188",

    [Parameter()]
    [int]$TargetPort = 9999,

    [Parameter()]
    [double]$Interval = 0.5,

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

function Get-GPUData {
    <#
    .SYNOPSIS
        Query nvidia-smi for GPU temperatures and fan speeds
    .OUTPUTS
        Hashtable with gpu0_temp, gpu1_temp, gpu0_fan, gpu1_fan (or $null on error)
    #>

    try {
        $output = & $Script:NvidiaSmi --query-gpu=index,temperature.gpu,fan.speed --format=csv,noheader,nounits 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-Log "nvidia-smi returned error code $LASTEXITCODE" -Level "ERROR"
            return $null
        }

        $data = @{}

        $lines = $output -split "`n" | Where-Object { $_.Trim() -ne "" }

        foreach ($line in $lines) {
            $parts = $line -split ",\s*"
            if ($parts.Count -ge 3) {
                $index = [int]$parts[0].Trim()
                $temp = [int]$parts[1].Trim()
                $fan = [int]$parts[2].Trim()
                $data["gpu${index}_temp"] = $temp
                $data["gpu${index}_fan"] = $fan
            }
        }

        # Ensure we have both GPUs
        if (-not $data.ContainsKey("gpu0_temp")) {
            Write-Log "GPU 0 data not found" -Level "WARN"
            $data["gpu0_temp"] = 60
            $data["gpu0_fan"] = 30
        }
        if (-not $data.ContainsKey("gpu1_temp")) {
            Write-Log "GPU 1 data not found" -Level "WARN"
            $data["gpu1_temp"] = 60
            $data["gpu1_fan"] = 30
        }

        return $data

    } catch {
        Write-Log "Failed to query GPU data: $_" -Level "ERROR"
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
    Write-Log "=========================================="
    Write-Log "GPU Temperature & Fan Speed Sender Starting"
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

    Write-Log "Starting temperature/fan monitoring loop..."
    Write-Log "Press Ctrl+C to stop"

    $lastData = @{}
    $sendCount = 0
    $errorCount = 0

    while ($Script:Running) {
        $loopStart = Get-Date

        $data = Get-GPUData

        if ($data) {
            $payload = @{
                gpu0_temp = $data["gpu0_temp"]
                gpu1_temp = $data["gpu1_temp"]
                gpu0_fan = $data["gpu0_fan"]
                gpu1_fan = $data["gpu1_fan"]
            } | ConvertTo-Json -Compress

            $sent = Send-UDPPacket -Data $payload -IP $TargetIP -Port $TargetPort

            if ($sent) {
                $sendCount++

                $changed = $false
                foreach ($key in $data.Keys) {
                    if (-not $lastData.ContainsKey($key) -or
                        [Math]::Abs($data[$key] - $lastData[$key]) -ge 2) {
                        $changed = $true
                        break
                    }
                }

                if ($changed -or ($sendCount % 60 -eq 0)) {
                    Write-Log "Sent: GPU0=$($data['gpu0_temp'])C/$($data['gpu0_fan'])%, GPU1=$($data['gpu1_temp'])C/$($data['gpu1_fan'])%"
                } else {
                    Write-Log "Sent: GPU0=$($data['gpu0_temp'])C/$($data['gpu0_fan'])%, GPU1=$($data['gpu1_temp'])C/$($data['gpu1_fan'])%" -Level "DEBUG"
                }

                $lastData = $data.Clone()
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

        $elapsed = ((Get-Date) - $loopStart).TotalSeconds
        $sleepTime = [Math]::Max(0, $Interval - $elapsed)
        if ($sleepTime -gt 0) {
            Start-Sleep -Milliseconds ($sleepTime * 1000)
        }
    }

    Write-Log "Temperature sender stopped"
    Write-Log "Total packets sent: $sendCount"
}

# =============================================================================
# Service Installation Functions
# =============================================================================

function Install-AsScheduledTask {
    $taskName = "GPU Temp Sender"
    $scriptPath = $MyInvocation.PSCommandPath

    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Write-Log "Task '$taskName' already exists. Removing..." -Level "WARN"
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }

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
        -Description "Sends GPU temperatures and fan speeds to Mac Pro Rack fan controller"

    Write-Log "Scheduled task '$taskName' created successfully"
    Write-Log "The task will start automatically at boot"
    Write-Log "To start now: Start-ScheduledTask -TaskName '$taskName'"
}

function Uninstall-ScheduledTask {
    $taskName = "GPU Temp Sender"

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

if ($args -contains "-Install") {
    Install-AsScheduledTask
    exit 0
}

if ($args -contains "-Uninstall") {
    Uninstall-ScheduledTask
    exit 0
}

Start-TempSender
