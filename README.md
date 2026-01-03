# Mac Pro 2019 Per-Zone Fan Control

Advanced per-zone fan control system for Apple Mac Pro 2019 (Rack or Tower) running Linux/Proxmox with T2 kernel patches. Integrates GPU temperatures from Windows VMs via UDP for intelligent thermal management of multi-GPU setups.

## Features

- **Per-Zone Fan Control** - Independent control of each intake fan based on thermal zones
- **GPU Fan Follow Mode** - Chassis fans match GPU fan speeds for optimal cooling during benchmarks
- **GPU Temperature Integration** - Receives GPU temps and fan speeds from Windows/Linux VMs
- **Zone Bleed-Over** - Accounts for thermal cross-contamination between zones (e.g., NVLink heat sharing)
- **Configurable Fan Curves** - Linear interpolation between temperature/speed points
- **Hysteresis** - Prevents rapid fan speed oscillation
- **Emergency Override** - All fans to 100% if any temperature exceeds threshold
- **Safe Defaults** - Falls back to conservative speeds if sensor data is stale
- **Systemd Integration** - Runs as a managed service with automatic restart
- **Fast Response** - 0.5s poll interval for quick thermal response

## Architecture

```
                                 UDP:9999
    ┌─────────────────┐     ┌──────────────────┐     ┌─────────────────────────┐
    │   Windows VM    │────►│  fan-controller  │────►│     SMC via sysfs       │
    │ gpu-temp-sender │     │     (Python)     │     │                         │
    └─────────────────┘     └──────────────────┘     └─────────────────────────┘
           │                        │                           │
           │                        │                           ▼
    {"gpu0_temp": 65,        CPU temp from          ┌─────────────────────────┐
     "gpu1_temp": 67,         /sys/class/hwmon      │   Mac Pro Fan Zones     │
     "gpu0_fan": 45,                                │                         │
     "gpu1_fan": 50}                                │  [Fan 1] Rear Blower    │
                                                    │    └─ Apple Auto Mode   │
                                                    │                         │
                                                    │  [Fan 2] Right Front    │
                                                    │    └─ GPU0 Zone         │
                                                    │                         │
                                                    │  [Fan 3] Middle Front   │
                                                    │    └─ GPU1 Zone         │
                                                    │                         │
                                                    │  [Fan 4] Left Front     │
                                                    │    └─ CPU Zone          │
                                                    └─────────────────────────┘
```

### Fan Layout (Mac Pro Rack - Rear View, Verified 2026-01-02)

```
           REAR (exhaust)
    ┌─────────────────────────┐
    │    [Fan 1 - Blower]     │  ← Apple automatic mode
    │                         │
    │   GPU0        GPU1      │  ← PCIe slots (e.g., RTX 3090 NVLink)
    │                         │
    │  [Fan 4]  [Fan 3]  [Fan 2]  ← Intake fans (manual control)
    │   CPU     GPU1     GPU0  │
    └─────────────────────────┘
           FRONT (intake)
```

**Note:** Fan numbering in SMC doesn't match physical left-to-right order. Verified by physical testing.

### Zone Bleed-Over Weights

Hot air flows from front to back, and multi-GPU setups (especially with NVLink) share heat:

| Fan | Zone | Primary | Secondary | Tertiary |
|-----|------|---------|-----------|----------|
| Fan 2 | GPU0 (Right) | 70% GPU0 | 20% GPU1 | 10% CPU |
| Fan 3 | GPU1 (Middle) | 70% GPU1 | 20% GPU0 | 10% CPU |
| Fan 4 | CPU (Left) | 80% CPU | 20% max(GPU) | - |

## Requirements

### Linux Host (Proxmox/Debian/Ubuntu)

- **T2 Linux Kernel** - Provides Apple SMC fan control via sysfs
  - Proxmox: `apt install pve-edge-kernel-t2`
  - Other distros: See [t2linux.org](https://t2linux.org/)
- **Python 3.8+**
- **lm-sensors** (optional, for CPU temperature fallback)

### Windows VM (for GPU temperature sender)

- Windows 10/11 with GPU passthrough
- NVIDIA GPU with drivers installed (`nvidia-smi` available)
- PowerShell 5.1+

## Installation

### Linux Host

```bash
# Clone the repository
git clone https://github.com/asspenwhite/mac-pro-fan-control.git
cd mac-pro-fan-control

# Run installer (as root)
sudo ./install.sh
```

The installer will:
1. Copy `fan-controller.py` to `/opt/fan-control/`
2. Install systemd service
3. Create config directory at `/etc/fan-control/`
4. Enable the service (but not start it)

### Start the Service

```bash
# Configure firewall for UDP temperature data
sudo ufw allow 9999/udp

# Start the service
sudo systemctl start fan-controller

# View logs
sudo journalctl -u fan-controller -f
```

### Windows VM (GPU Temperature Sender)

1. Copy `gpu-temp-sender.ps1` to the Windows VM
2. Edit the target IP if needed (default: `192.168.137.2`)
3. Run manually or install as scheduled task:

```powershell
# Test run
.\gpu-temp-sender.ps1 -TargetIP "192.168.137.2"

# Install as startup task (requires admin)
powershell -ExecutionPolicy Bypass -File .\gpu-temp-sender.ps1 -Install
```

## Configuration

The daemon runs with sensible defaults. For customization, edit `/etc/fan-control/config.yaml`:

```yaml
# Temperature curves (temperature_celsius -> fan_percentage)
curves:
  cpu:
    - [30.0, 20.0]   # Idle
    - [50.0, 45.0]   # Moderate load
    - [65.0, 90.0]   # Heavy load
    - [80.0, 100.0]  # Thermal limit

  gpu:
    - [35.0, 20.0]   # Idle
    - [65.0, 50.0]   # Gaming
    - [83.0, 100.0]  # Thermal limit

# Safety settings
safety:
  emergency_temp: 85.0    # All fans to 100% above this
  min_fan_percent: 20.0   # Never go below this

# Hysteresis (prevents oscillation)
hysteresis:
  up: 2.0    # Temp must rise 2C before speeding up
  down: 2.0  # Temp must fall 2C before slowing down

# GPU Fan Follow Mode (default: enabled)
# When enabled, chassis fans match GPU fan speeds instead of using temp curves
system:
  gpu_fan_follow_mode: true
  poll_interval: 0.5  # Seconds between updates
```

### GPU Fan Follow Mode

When `gpu_fan_follow_mode: true` (default), the chassis fans directly follow the GPU fan speeds reported by nvidia-smi, with zone weights still applied. This provides better cooling correlation during GPU-intensive workloads like benchmarks or gaming, since the GPU's own fan controller knows best what cooling is needed.

The Windows sender now transmits both temperature AND fan speed:
```json
{"gpu0_temp": 65, "gpu1_temp": 67, "gpu0_fan": 45, "gpu1_fan": 50}
```

## Usage

### Service Management

```bash
# Check status
sudo systemctl status fan-controller

# View real-time logs
sudo journalctl -u fan-controller -f

# Restart after config changes
sudo systemctl restart fan-controller

# Stop and revert to Apple automatic
sudo systemctl stop fan-controller
```

### Test Mode

```bash
# Test fan control without running the full daemon
sudo python3 /opt/fan-control/fan-controller.py --test

# Verbose mode for debugging
sudo python3 /opt/fan-control/fan-controller.py -v
```

### Manual Fan Control

```bash
SMC=/sys/devices/LNXSYSTM:00/LNXSYBUS:00/PNP0A08:00/device:1f/APP0001:00

# Read current fan speeds
for i in 1 2 3 4; do echo "Fan $i: $(cat $SMC/fan${i}_input) RPM"; done

# Set fan to manual mode
echo 1 > $SMC/fan2_manual

# Set RPM (requires manual mode)
echo 1500 > $SMC/fan2_output

# Return to Apple automatic
echo 0 > $SMC/fan2_manual
```

## Troubleshooting

### SMC Path Not Found

If you see "SMC path not found" errors:

```bash
# Verify T2 modules are loaded
lsmod | grep apple

# Expected output:
# apple_bce       ...
# applesmc        ...

# If missing, load manually
sudo modprobe apple_bce applesmc
```

### GPU Temperatures Not Received

```bash
# Check UDP listener is active
ss -uln | grep 9999

# Check logs for GPU data
journalctl -u fan-controller | grep -i gpu

# From Windows VM, test connectivity
Test-NetConnection 192.168.137.2 -Port 9999
```

### Fans Running High at Idle

1. Check if GPU temperatures are being received (not showing "stale" in logs)
2. Verify Windows GPUTempSender task is running
3. Check firewall allows UDP port 9999

### Reverting to Apple Automatic Control

```bash
# Stop the service
sudo systemctl stop fan-controller

# Set all fans to automatic
SMC=/sys/devices/LNXSYSTM:00/LNXSYBUS:00/PNP0A08:00/device:1f/APP0001:00
for i in 1 2 3 4; do echo 0 > $SMC/fan${i}_manual; done
```

## Temperature Curves

### Default CPU Curve (Xeon W-3245)

| Temperature | Fan Speed |
|-------------|-----------|
| 30C | 20% |
| 40C | 30% |
| 50C | 45% |
| 60C | 80% |
| 65C | 90% |
| 80C | 100% |

### Default GPU Curve (RTX 3090)

| Temperature | Fan Speed |
|-------------|-----------|
| 35C | 20% |
| 50C | 30% |
| 65C | 50% |
| 75C | 75% |
| 83C | 100% |

Curves are linearly interpolated between points.

## File Structure

```
mac-pro-fan-control/
├── fan-controller.py      # Main daemon (810 lines)
├── gpu-temp-sender.ps1    # Windows GPU temp sender
├── fan-controller.service # Systemd unit file
├── fan-control.yaml       # Configuration template
├── install.sh             # Linux installer
├── uninstall.sh           # Linux uninstaller
├── LICENSE                # MIT License
└── README.md              # This file
```

## How It Works

1. **Temperature Collection**
   - CPU: Read from `/sys/class/hwmon/*/temp*_input` (coretemp)
   - GPU: Received via UDP JSON packets from Windows VM

2. **Fan Speed Calculation**
   - Each fan has a primary thermal zone and secondary influences
   - Temperature is mapped to percentage via configurable curves
   - Zone bleed-over weights combine multiple thermal sources

3. **Hysteresis Application**
   - Prevents fan speed from changing until temperature moves beyond threshold
   - Separate thresholds for increasing vs decreasing speed

4. **Fan Control**
   - Converts percentage to RPM based on fan's min/max range
   - Writes to SMC sysfs interface (`fan*_output`)

5. **Safety Features**
   - Emergency mode if any temp exceeds 85C
   - Default to 60C GPU temp if data stale (>10 seconds)
   - Set fans to 50% on daemon shutdown

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

### Development Notes

- Test changes with `--test` flag before deploying
- The daemon runs in simulation mode if SMC path doesn't exist
- GPU temp sender can run standalone for testing

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [t2linux](https://t2linux.org/) - T2 Linux kernel patches enabling SMC fan control
- [apple-bce](https://github.com/t2linux/apple-bce-drv) - Apple BCE driver
- The Mac Pro 2019 Proxmox community

## Related Projects

- [t2linux](https://wiki.t2linux.org/) - Linux on T2 Macs
- [Proxmox VE](https://www.proxmox.com/) - Enterprise virtualization platform

---

*Built for the Mac Pro 2019 running Proxmox with dual RTX 3090 NVLink passthrough.*
