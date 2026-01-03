#!/usr/bin/env python3
"""
Advanced Per-Zone Fan Control System for Mac Pro Rack 2019
============================================================

Hardware Configuration (verified 2026-01-02):
- Fan 1: Rear Blower (500-1200 RPM) - Exhaust, left in Apple automatic mode
- Fan 2: Right Front (500-2500 RPM) - GPU 0 Zone intake (3090 #1, PCI 0000:fb:00)
- Fan 3: Middle Front (500-2500 RPM) - GPU 1 Zone intake (3090 #2, PCI 0000:14:00)
- Fan 4: Left Front (500-2500 RPM) - CPU Zone intake

Thermal Dynamics:
- Front fans push cool air IN
- Rear blower pulls hot air OUT
- Hot air rises and flows toward rear
- NVLink bridge means GPUs share heat

Zone Bleed-Over Logic:
- Fan 1 (Blower): Apple automatic control (not managed by this script)
- Fan 2 (GPU0): 70% GPU0 curve + 20% GPU1 curve + 10% CPU curve
- Fan 3 (GPU1): 70% GPU1 curve + 20% GPU0 curve + 10% CPU curve
- Fan 4 (CPU): 80% CPU curve + 20% max(GPU curves)
"""

import json
import logging
import os
import signal
import socket
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Tuple

# =============================================================================
# Configuration
# =============================================================================

@dataclass
class FanConfig:
    """Configuration for a single fan."""
    name: str
    sysfs_id: int  # fan1, fan2, etc.
    min_rpm: int
    max_rpm: int
    min_percent: float = 20.0  # Minimum speed percentage

@dataclass
class ThermalCurve:
    """Temperature to fan percentage curve with interpolation."""
    points: List[Tuple[float, float]]  # (temp_celsius, percent)

    def get_percent(self, temp: float) -> float:
        """Get fan percentage for given temperature using linear interpolation."""
        if not self.points:
            return 100.0

        # Sort by temperature
        sorted_points = sorted(self.points, key=lambda x: x[0])

        # Below minimum temp
        if temp <= sorted_points[0][0]:
            return sorted_points[0][1]

        # Above maximum temp
        if temp >= sorted_points[-1][0]:
            return sorted_points[-1][1]

        # Linear interpolation between points
        for i in range(len(sorted_points) - 1):
            t1, p1 = sorted_points[i]
            t2, p2 = sorted_points[i + 1]
            if t1 <= temp <= t2:
                ratio = (temp - t1) / (t2 - t1)
                return p1 + ratio * (p2 - p1)

        return 100.0

@dataclass
class HysteresisState:
    """Track hysteresis state per fan."""
    last_temp: float = 0.0
    last_percent: float = 20.0
    last_update: float = 0.0

class Config:
    """System configuration."""

    # SMC sysfs base path
    SMC_BASE = "/sys/devices/LNXSYSTM:00/LNXSYBUS:00/PNP0A08:00/device:1f/APP0001:00"

    # UDP listener for GPU temps from Windows VM
    UDP_HOST = "0.0.0.0"
    UDP_PORT = 9999

    # GPU Fan Follow Mode - use GPU fan speed instead of temperature curves
    GPU_FAN_FOLLOW_MODE = True

    # Timing
    POLL_INTERVAL = 0.5  # seconds (faster response to GPU fan changes)
    GPU_STALE_TIMEOUT = 10.0  # seconds

    # Hysteresis
    HYSTERESIS_UP = 2.0  # degrees
    HYSTERESIS_DOWN = 2.0  # degrees

    # Safety thresholds
    EMERGENCY_TEMP = 85.0  # All fans to 100% if any temp exceeds this
    DEFAULT_CPU_TEMP = 50.0  # Assumed if read fails
    DEFAULT_GPU_TEMP = 60.0  # Assumed if data stale

    # Fan configurations (verified 2026-01-02)
    # Fan 1 (Rear Blower) is left in Apple automatic mode - not controlled here
    FANS = {
        2: FanConfig("Right Front (GPU0)", 2, 500, 2500, min_percent=20.0),
        3: FanConfig("Middle Front (GPU1)", 3, 500, 2500, min_percent=20.0),
        4: FanConfig("Left Front (CPU)", 4, 500, 2500, min_percent=20.0),
    }

    # Thermal curves (temperature -> percentage)
    # CPU curve adapted for Xeon W-3245
    CPU_CURVE = ThermalCurve([
        (30.0, 20.0),
        (40.0, 30.0),
        (50.0, 45.0),
        (60.0, 80.0),
        (65.0, 90.0),
        (80.0, 100.0),
    ])

    # GPU curve adapted for RTX 3090 (runs hotter than 5090)
    GPU_CURVE = ThermalCurve([
        (35.0, 20.0),   # Minimum 20% even at idle
        (50.0, 30.0),
        (65.0, 50.0),
        (75.0, 75.0),
        (83.0, 100.0),
    ])

    # Zone bleed-over weights (verified 2026-01-02)
    # Fan 1 (Rear Blower) uses Apple automatic control
    ZONE_WEIGHTS = {
        # Fan 2 (GPU0 Zone): 70% GPU0, 20% GPU1, 10% CPU
        2: {'gpu0': 0.70, 'gpu1': 0.20, 'cpu': 0.10},
        # Fan 3 (GPU1 Zone): 70% GPU1, 20% GPU0, 10% CPU
        3: {'gpu1': 0.70, 'gpu0': 0.20, 'cpu': 0.10},
        # Fan 4 (CPU Zone): 80% CPU, 20% max GPU
        4: {'cpu': 0.80, 'gpu_max': 0.20},
    }


# =============================================================================
# Temperature Sources
# =============================================================================

class CPUTempReader:
    """Read CPU temperature from local sensors."""

    HWMON_BASE = "/sys/class/hwmon"

    def __init__(self):
        self.hwmon_path = self._find_coretemp()
        self.logger = logging.getLogger("CPUTemp")

    def _find_coretemp(self) -> Optional[Path]:
        """Find the coretemp hwmon device."""
        hwmon_base = Path(self.HWMON_BASE)
        if not hwmon_base.exists():
            return None

        for hwmon_dir in hwmon_base.iterdir():
            name_file = hwmon_dir / "name"
            if name_file.exists():
                try:
                    name = name_file.read_text().strip()
                    if name in ("coretemp", "k10temp", "zenpower"):
                        return hwmon_dir
                except (IOError, OSError):
                    continue
        return None

    def read(self) -> Optional[float]:
        """Read CPU temperature. Returns package temp or max core temp."""
        temps = []

        # Try hwmon interface first
        if self.hwmon_path:
            try:
                for temp_file in self.hwmon_path.glob("temp*_input"):
                    try:
                        # Values are in millidegrees
                        temp = int(temp_file.read_text().strip()) / 1000.0
                        temps.append(temp)
                    except (ValueError, IOError):
                        continue
            except OSError:
                pass

        # Fallback to sensors command
        if not temps:
            try:
                result = subprocess.run(
                    ["sensors", "-j"],
                    capture_output=True,
                    text=True,
                    timeout=5
                )
                if result.returncode == 0:
                    data = json.loads(result.stdout)
                    for chip_name, chip_data in data.items():
                        if "coretemp" in chip_name.lower():
                            for key, value in chip_data.items():
                                if isinstance(value, dict):
                                    for metric, temp in value.items():
                                        if "input" in metric and isinstance(temp, (int, float)):
                                            temps.append(float(temp))
            except (subprocess.TimeoutExpired, json.JSONDecodeError, OSError):
                pass

        if temps:
            # Return maximum core temperature
            return max(temps)
        return None


class GPUTempReceiver:
    """Receive GPU temperatures and fan speeds via UDP from Windows VM."""

    def __init__(self, host: str, port: int, stale_timeout: float):
        self.host = host
        self.port = port
        self.stale_timeout = stale_timeout
        self.logger = logging.getLogger("GPUTemp")

        self._lock = threading.Lock()
        self._gpu0_temp: Optional[float] = None
        self._gpu1_temp: Optional[float] = None
        self._gpu0_fan: Optional[float] = None  # Fan speed percentage
        self._gpu1_fan: Optional[float] = None  # Fan speed percentage
        self._last_update: float = 0.0

        self._socket: Optional[socket.socket] = None
        self._running = False
        self._thread: Optional[threading.Thread] = None

    def start(self):
        """Start the UDP listener thread."""
        self._socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._socket.settimeout(1.0)
        self._socket.bind((self.host, self.port))

        self._running = True
        self._thread = threading.Thread(target=self._listener_loop, daemon=True)
        self._thread.start()
        self.logger.info(f"GPU temp receiver started on {self.host}:{self.port}")

    def stop(self):
        """Stop the UDP listener."""
        self._running = False
        if self._thread:
            self._thread.join(timeout=2.0)
        if self._socket:
            self._socket.close()
            self._socket = None

    def _listener_loop(self):
        """Background thread to receive UDP packets."""
        while self._running:
            try:
                data, addr = self._socket.recvfrom(1024)
                self._process_packet(data, addr)
            except socket.timeout:
                continue
            except Exception as e:
                if self._running:
                    self.logger.error(f"UDP receive error: {e}")

    def _process_packet(self, data: bytes, addr: tuple):
        """Process a received temperature and fan speed packet."""
        try:
            payload = json.loads(data.decode('utf-8'))

            with self._lock:
                if 'gpu0_temp' in payload:
                    self._gpu0_temp = float(payload['gpu0_temp'])
                if 'gpu1_temp' in payload:
                    self._gpu1_temp = float(payload['gpu1_temp'])
                if 'gpu0_fan' in payload:
                    self._gpu0_fan = float(payload['gpu0_fan'])
                if 'gpu1_fan' in payload:
                    self._gpu1_fan = float(payload['gpu1_fan'])
                self._last_update = time.time()

            self.logger.debug(f"Received from {addr}: GPU0={self._gpu0_temp}C/{self._gpu0_fan}%, GPU1={self._gpu1_temp}C/{self._gpu1_fan}%")

        except (json.JSONDecodeError, ValueError, KeyError) as e:
            self.logger.warning(f"Invalid packet from {addr}: {e}")

    def get_temps(self) -> Tuple[Optional[float], Optional[float], bool]:
        """
        Get GPU temperatures.
        Returns: (gpu0_temp, gpu1_temp, is_stale)
        """
        with self._lock:
            is_stale = (time.time() - self._last_update) > self.stale_timeout
            return self._gpu0_temp, self._gpu1_temp, is_stale

    def get_fan_speeds(self) -> Tuple[Optional[float], Optional[float], bool]:
        """
        Get GPU fan speeds.
        Returns: (gpu0_fan_pct, gpu1_fan_pct, is_stale)
        """
        with self._lock:
            is_stale = (time.time() - self._last_update) > self.stale_timeout
            return self._gpu0_fan, self._gpu1_fan, is_stale


# =============================================================================
# Fan Control
# =============================================================================

class FanController:
    """Control Mac Pro fans via SMC sysfs interface."""

    def __init__(self, smc_base: str, fans: Dict[int, FanConfig]):
        self.smc_base = Path(smc_base)
        self.fans = fans
        self.logger = logging.getLogger("FanControl")

        # Hysteresis state per fan
        self.hysteresis: Dict[int, HysteresisState] = {
            fan_id: HysteresisState() for fan_id in fans
        }

        # Verify SMC path exists
        if not self.smc_base.exists():
            self.logger.warning(f"SMC path not found: {self.smc_base}")
            self.logger.warning("Running in simulation mode")
            self._simulation_mode = True
        else:
            self._simulation_mode = False

    def _read_sysfs(self, filename: str) -> Optional[str]:
        """Read a value from sysfs."""
        if self._simulation_mode:
            return None
        try:
            path = self.smc_base / filename
            return path.read_text().strip()
        except (IOError, OSError) as e:
            self.logger.error(f"Failed to read {filename}: {e}")
            return None

    def _write_sysfs(self, filename: str, value: str) -> bool:
        """Write a value to sysfs."""
        if self._simulation_mode:
            self.logger.info(f"[SIM] Would write {value} to {filename}")
            return True
        try:
            path = self.smc_base / filename
            path.write_text(value)
            return True
        except (IOError, OSError) as e:
            self.logger.error(f"Failed to write {value} to {filename}: {e}")
            return False

    def get_current_rpm(self, fan_id: int) -> Optional[int]:
        """Read current RPM of a fan."""
        value = self._read_sysfs(f"fan{fan_id}_input")
        if value:
            try:
                return int(value)
            except ValueError:
                return None
        return None

    def is_manual_mode(self, fan_id: int) -> bool:
        """Check if fan is in manual mode."""
        value = self._read_sysfs(f"fan{fan_id}_manual")
        return value == "1" if value else False

    def set_manual_mode(self, fan_id: int, manual: bool) -> bool:
        """Set fan to manual or auto mode."""
        return self._write_sysfs(f"fan{fan_id}_manual", "1" if manual else "0")

    def percent_to_rpm(self, fan_id: int, percent: float) -> int:
        """Convert percentage to RPM for a specific fan."""
        fan = self.fans[fan_id]
        rpm_range = fan.max_rpm - fan.min_rpm
        rpm = fan.min_rpm + (percent / 100.0) * rpm_range
        return int(round(rpm))

    def rpm_to_percent(self, fan_id: int, rpm: int) -> float:
        """Convert RPM to percentage for a specific fan."""
        fan = self.fans[fan_id]
        rpm_range = fan.max_rpm - fan.min_rpm
        percent = ((rpm - fan.min_rpm) / rpm_range) * 100.0
        return max(0.0, min(100.0, percent))

    def set_fan_rpm(self, fan_id: int, rpm: int) -> bool:
        """Set fan to specific RPM."""
        fan = self.fans[fan_id]
        rpm = max(fan.min_rpm, min(fan.max_rpm, rpm))
        return self._write_sysfs(f"fan{fan_id}_output", str(rpm))

    def set_fan_percent(self, fan_id: int, percent: float) -> bool:
        """Set fan to percentage of its range."""
        fan = self.fans[fan_id]
        percent = max(fan.min_percent, min(100.0, percent))
        rpm = self.percent_to_rpm(fan_id, percent)
        return self.set_fan_rpm(fan_id, rpm)

    def apply_hysteresis(self, fan_id: int, temp: float, raw_percent: float,
                         hysteresis_up: float, hysteresis_down: float) -> float:
        """
        Apply hysteresis to prevent fan speed oscillation.

        Only allow speed INCREASE if temp has risen by hysteresis_up degrees.
        Only allow speed DECREASE if temp has fallen by hysteresis_down degrees.
        """
        state = self.hysteresis[fan_id]

        # First run - just set the values
        if state.last_update == 0:
            state.last_temp = temp
            state.last_percent = raw_percent
            state.last_update = time.time()
            return raw_percent

        # Determine direction of change
        temp_delta = temp - state.last_temp
        percent_delta = raw_percent - state.last_percent

        new_percent = state.last_percent

        if percent_delta > 0:
            # Want to speed up - require temp increase above threshold
            if temp_delta >= hysteresis_up:
                new_percent = raw_percent
                state.last_temp = temp
        elif percent_delta < 0:
            # Want to slow down - require temp decrease below threshold
            if temp_delta <= -hysteresis_down:
                new_percent = raw_percent
                state.last_temp = temp
        else:
            # No change in target
            pass

        state.last_percent = new_percent
        state.last_update = time.time()
        return new_percent


# =============================================================================
# Zone Controller
# =============================================================================

class ZoneController:
    """
    Manages thermal zones and calculates fan speeds.

    Zone assignments (verified 2026-01-02):
    - Fan 2 (GPU0 Zone): Primary GPU0, secondary GPU1, tertiary CPU
    - Fan 3 (GPU1 Zone): Primary GPU1, secondary GPU0, tertiary CPU
    - Fan 4 (CPU Zone): Primary CPU, secondary GPU max
    - Fan 1 (Blower): Apple automatic control
    """

    def __init__(self, config: Config, fan_controller: FanController,
                 cpu_reader: CPUTempReader, gpu_receiver: GPUTempReceiver):
        self.config = config
        self.fan_controller = fan_controller
        self.cpu_reader = cpu_reader
        self.gpu_receiver = gpu_receiver
        self.logger = logging.getLogger("ZoneCtrl")

        # Current state for logging
        self._last_state: Dict = {}

    def update(self) -> Dict:
        """
        Read all temperatures and update all fans.
        Returns current state dict for logging.
        """
        # Read temperatures
        cpu_temp = self.cpu_reader.read()
        if cpu_temp is None:
            cpu_temp = self.config.DEFAULT_CPU_TEMP
            self.logger.warning(f"CPU temp read failed, using default {cpu_temp}C")

        gpu0_temp, gpu1_temp, gpu_stale = self.gpu_receiver.get_temps()

        if gpu_stale or gpu0_temp is None:
            gpu0_temp = self.config.DEFAULT_GPU_TEMP
            self.logger.warning(f"GPU0 temp stale/missing, using default {gpu0_temp}C")
        if gpu_stale or gpu1_temp is None:
            gpu1_temp = self.config.DEFAULT_GPU_TEMP
            self.logger.warning(f"GPU1 temp stale/missing, using default {gpu1_temp}C")

        # Check emergency condition
        emergency = any(t >= self.config.EMERGENCY_TEMP
                       for t in [cpu_temp, gpu0_temp, gpu1_temp])

        if emergency:
            self.logger.critical(
                f"EMERGENCY: Temp exceeded {self.config.EMERGENCY_TEMP}C! "
                f"CPU={cpu_temp:.1f}, GPU0={gpu0_temp:.1f}, GPU1={gpu1_temp:.1f}"
            )

        # Get GPU fan speeds if in follow mode
        gpu0_fan_pct, gpu1_fan_pct, fan_stale = self.gpu_receiver.get_fan_speeds()

        # Calculate curve percentages (fallback if no fan data)
        cpu_pct = self.config.CPU_CURVE.get_percent(cpu_temp)

        if Config.GPU_FAN_FOLLOW_MODE and gpu0_fan_pct is not None and gpu1_fan_pct is not None and not fan_stale:
            # Use actual GPU fan speeds directly
            gpu0_pct = gpu0_fan_pct
            gpu1_pct = gpu1_fan_pct
            self.logger.debug(f"Following GPU fan speeds: GPU0={gpu0_pct:.0f}%, GPU1={gpu1_pct:.0f}%")
        else:
            # Fall back to temperature curves
            gpu0_pct = self.config.GPU_CURVE.get_percent(gpu0_temp)
            gpu1_pct = self.config.GPU_CURVE.get_percent(gpu1_temp)

        gpu_max_pct = max(gpu0_pct, gpu1_pct)

        # Calculate zone percentages with bleed-over (verified 2026-01-02)
        zone_percents = {}

        # Fan 2 (GPU0 Zone): 70% GPU0, 20% GPU1, 10% CPU
        zone_percents[2] = (0.70 * gpu0_pct) + (0.20 * gpu1_pct) + (0.10 * cpu_pct)

        # Fan 3 (GPU1 Zone): 70% GPU1, 20% GPU0, 10% CPU
        zone_percents[3] = (0.70 * gpu1_pct) + (0.20 * gpu0_pct) + (0.10 * cpu_pct)

        # Fan 4 (CPU Zone): 80% CPU, 20% max GPU
        zone_percents[4] = (0.80 * cpu_pct) + (0.20 * gpu_max_pct)

        # Fan 1 (Blower) is left in Apple automatic mode - not controlled here

        # Emergency override
        if emergency:
            for fan_id in zone_percents:
                zone_percents[fan_id] = 100.0

        # Apply minimum and hysteresis, then set fans
        state = {
            'timestamp': time.time(),
            'temps': {
                'cpu': cpu_temp,
                'gpu0': gpu0_temp,
                'gpu1': gpu1_temp,
                'gpu_stale': gpu_stale,
            },
            'curves': {
                'cpu_pct': cpu_pct,
                'gpu0_pct': gpu0_pct,
                'gpu1_pct': gpu1_pct,
            },
            'fans': {},
            'emergency': emergency,
        }

        for fan_id, raw_percent in zone_percents.items():
            fan = self.config.FANS[fan_id]

            # Ensure minimum
            percent = max(fan.min_percent, raw_percent)

            # Apply hysteresis (use cpu_temp as representative for hysteresis check)
            # In practice, we track the resulting percent, not the input temp
            final_percent = self.fan_controller.apply_hysteresis(
                fan_id,
                max(cpu_temp, gpu0_temp, gpu1_temp),  # Use max temp for hysteresis
                percent,
                self.config.HYSTERESIS_UP,
                self.config.HYSTERESIS_DOWN
            )

            # Set the fan
            rpm = self.fan_controller.percent_to_rpm(fan_id, final_percent)
            self.fan_controller.set_fan_percent(fan_id, final_percent)

            state['fans'][fan_id] = {
                'name': fan.name,
                'raw_percent': raw_percent,
                'final_percent': final_percent,
                'target_rpm': rpm,
                'actual_rpm': self.fan_controller.get_current_rpm(fan_id),
            }

        # Log state changes
        self._log_state_changes(state)
        self._last_state = state

        return state

    def _log_state_changes(self, new_state: Dict):
        """Log meaningful state changes."""
        if not self._last_state:
            # First run - log full state
            self.logger.info(
                f"Initial state: CPU={new_state['temps']['cpu']:.1f}C, "
                f"GPU0={new_state['temps']['gpu0']:.1f}C, "
                f"GPU1={new_state['temps']['gpu1']:.1f}C"
            )
            for fan_id, fan_state in new_state['fans'].items():
                self.logger.info(
                    f"  {fan_state['name']}: {fan_state['final_percent']:.0f}% "
                    f"({fan_state['target_rpm']} RPM)"
                )
            return

        # Check for significant changes
        old_temps = self._last_state.get('temps', {})
        new_temps = new_state['temps']

        temp_changed = (
            abs(new_temps['cpu'] - old_temps.get('cpu', 0)) >= 2.0 or
            abs(new_temps['gpu0'] - old_temps.get('gpu0', 0)) >= 2.0 or
            abs(new_temps['gpu1'] - old_temps.get('gpu1', 0)) >= 2.0
        )

        if temp_changed or new_state['emergency']:
            self.logger.info(
                f"Temps: CPU={new_temps['cpu']:.1f}C, "
                f"GPU0={new_temps['gpu0']:.1f}C, "
                f"GPU1={new_temps['gpu1']:.1f}C"
                f"{' [STALE]' if new_temps['gpu_stale'] else ''}"
            )

        # Log fan changes
        old_fans = self._last_state.get('fans', {})
        for fan_id, fan_state in new_state['fans'].items():
            old_percent = old_fans.get(fan_id, {}).get('final_percent', 0)
            if abs(fan_state['final_percent'] - old_percent) >= 5.0:
                self.logger.info(
                    f"Fan {fan_id} ({fan_state['name']}): "
                    f"{old_percent:.0f}% -> {fan_state['final_percent']:.0f}% "
                    f"({fan_state['target_rpm']} RPM)"
                )


# =============================================================================
# Main Application
# =============================================================================

class FanControlDaemon:
    """Main daemon that orchestrates the fan control system."""

    def __init__(self):
        self.logger = logging.getLogger("Daemon")
        self.running = False

        # Initialize components
        self.config = Config()
        self.cpu_reader = CPUTempReader()
        self.gpu_receiver = GPUTempReceiver(
            Config.UDP_HOST,
            Config.UDP_PORT,
            Config.GPU_STALE_TIMEOUT
        )
        self.fan_controller = FanController(Config.SMC_BASE, Config.FANS)
        self.zone_controller = ZoneController(
            self.config,
            self.fan_controller,
            self.cpu_reader,
            self.gpu_receiver
        )

    def setup_logging(self, verbose: bool = False):
        """Configure logging."""
        level = logging.DEBUG if verbose else logging.INFO

        # Console handler
        console = logging.StreamHandler()
        console.setLevel(level)
        console_fmt = logging.Formatter(
            '%(asctime)s [%(levelname)s] %(name)s: %(message)s',
            datefmt='%Y-%m-%d %H:%M:%S'
        )
        console.setFormatter(console_fmt)

        # Root logger
        root = logging.getLogger()
        root.setLevel(level)
        root.addHandler(console)

        # Optional file logging
        log_dir = Path("/var/log/fan-control")
        if log_dir.exists() or os.access(log_dir.parent, os.W_OK):
            try:
                log_dir.mkdir(exist_ok=True)
                file_handler = logging.FileHandler(log_dir / "fan-control.log")
                file_handler.setLevel(logging.DEBUG)
                file_fmt = logging.Formatter(
                    '%(asctime)s.%(msecs)03d [%(levelname)s] %(name)s: %(message)s',
                    datefmt='%Y-%m-%d %H:%M:%S'
                )
                file_handler.setFormatter(file_fmt)
                root.addHandler(file_handler)
            except (OSError, PermissionError):
                pass

    def signal_handler(self, signum, frame):
        """Handle shutdown signals."""
        self.logger.info(f"Received signal {signum}, shutting down...")
        self.running = False

    def ensure_manual_mode(self):
        """Ensure controlled fans are in manual mode, Fan 1 in auto."""
        # Set Fan 1 (blower) to Apple automatic mode
        if self.fan_controller._read_sysfs("fan1_manual") == "1":
            self.logger.info("Setting Fan 1 (Rear Blower) to Apple automatic mode")
            self.fan_controller._write_sysfs("fan1_manual", "0")

        # Set controlled fans to manual mode
        for fan_id in Config.FANS:
            if not self.fan_controller.is_manual_mode(fan_id):
                self.logger.info(f"Setting fan {fan_id} to manual mode")
                self.fan_controller.set_manual_mode(fan_id, True)

    def run(self, verbose: bool = False):
        """Main run loop."""
        self.setup_logging(verbose)

        # Register signal handlers
        signal.signal(signal.SIGTERM, self.signal_handler)
        signal.signal(signal.SIGINT, self.signal_handler)

        self.logger.info("=" * 60)
        self.logger.info("Mac Pro Rack Fan Control System Starting")
        self.logger.info("=" * 60)
        self.logger.info(f"SMC Path: {Config.SMC_BASE}")
        self.logger.info(f"UDP Port: {Config.UDP_PORT}")
        self.logger.info(f"Poll Interval: {Config.POLL_INTERVAL}s")
        self.logger.info(f"GPU Stale Timeout: {Config.GPU_STALE_TIMEOUT}s")
        self.logger.info(f"Emergency Threshold: {Config.EMERGENCY_TEMP}C")

        # Log fan configuration
        self.logger.info("Fan Configuration:")
        self.logger.info("  Fan 1: Rear Blower (Apple automatic mode)")
        for fan_id, fan in Config.FANS.items():
            self.logger.info(f"  Fan {fan_id}: {fan.name} ({fan.min_rpm}-{fan.max_rpm} RPM)")

        # Start GPU temp receiver
        self.gpu_receiver.start()

        # Ensure manual mode
        self.ensure_manual_mode()

        # Main loop
        self.running = True
        self.logger.info("Entering main control loop")

        try:
            while self.running:
                loop_start = time.time()

                try:
                    self.zone_controller.update()
                except Exception as e:
                    self.logger.error(f"Error in control loop: {e}", exc_info=True)
                    # On error, set fans to safe speed
                    for fan_id in Config.FANS:
                        self.fan_controller.set_fan_percent(fan_id, 50.0)

                # Sleep for remaining interval
                elapsed = time.time() - loop_start
                sleep_time = max(0, Config.POLL_INTERVAL - elapsed)
                if sleep_time > 0:
                    time.sleep(sleep_time)

        finally:
            self.logger.info("Shutting down...")
            self.gpu_receiver.stop()

            # Set fans to safe default on exit
            self.logger.info("Setting fans to 50% on shutdown")
            for fan_id in Config.FANS:
                self.fan_controller.set_fan_percent(fan_id, 50.0)

            self.logger.info("Shutdown complete")


def main():
    """Entry point."""
    import argparse

    parser = argparse.ArgumentParser(
        description="Mac Pro Rack Fan Control System",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s                    # Run with default settings
  %(prog)s -v                 # Run with verbose logging
  %(prog)s --test             # Test fan control (set 50%% for 5s)
        """
    )
    parser.add_argument('-v', '--verbose', action='store_true',
                       help='Enable verbose logging')
    parser.add_argument('--test', action='store_true',
                       help='Test mode: set fans to 50%% for 5 seconds')

    args = parser.parse_args()

    if args.test:
        # Test mode
        logging.basicConfig(level=logging.INFO,
                          format='%(asctime)s [%(levelname)s] %(message)s')
        logger = logging.getLogger("Test")

        logger.info("Testing fan control...")
        fan_ctrl = FanController(Config.SMC_BASE, Config.FANS)

        for fan_id, fan in Config.FANS.items():
            logger.info(f"Fan {fan_id} ({fan.name}):")
            logger.info(f"  Manual mode: {fan_ctrl.is_manual_mode(fan_id)}")
            logger.info(f"  Current RPM: {fan_ctrl.get_current_rpm(fan_id)}")
            logger.info(f"  Setting to 50%...")
            fan_ctrl.set_fan_percent(fan_id, 50.0)

        logger.info("Waiting 5 seconds...")
        time.sleep(5)

        for fan_id, fan in Config.FANS.items():
            rpm = fan_ctrl.get_current_rpm(fan_id)
            logger.info(f"Fan {fan_id}: {rpm} RPM")

        logger.info("Test complete")
        return

    # Normal operation
    daemon = FanControlDaemon()
    daemon.run(verbose=args.verbose)


if __name__ == "__main__":
    main()
