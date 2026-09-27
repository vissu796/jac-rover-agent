#!/usr/bin/env python3
"""Edge runtime for the Jac rover agent.

This is the other half of `PiTransport` in pi-agent/robot/transport.jac. The
Jac mission engine sends bounded, expiring commands here; this process is the
last thing between the agent and the motors, so it re-validates everything
rather than trusting the caller.

    GET  /health    liveness + current arming state
    GET  /sensors   SensorSnapshot  (front_distance_cm, bumper_pressed, ...)
    POST /command   MotionCommand -> CommandResult
    GET  /image/<name>  a captured frame

Safety model, in order of authority:

1. Drive is DISARMED by default. Every MOVE_/TURN_ command is refused with
   DRIVE_INTERLOCK until the process is started with --arm-drive. That is a
   deliberate human action, not something the agent can request, and it exists
   because no bumper or distance sensor is wired yet.
2. A watchdog thread stops the motors after duration_ms no matter what the
   request loop is doing. Motors are never left energised by a crash.
3. Speed and duration are clamped again here, using the same ceilings as the
   Jac layer, so a bug on the other side cannot exceed them.
4. Expired and duplicate command ids are rejected before any GPIO is touched.

Run on the Pi:
    python3 ~/hardware-tests/rover_server.py                 # camera only
    python3 ~/hardware-tests/rover_server.py --arm-drive     # motors live
"""

from __future__ import annotations

import argparse
import json
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# --- pin map (BCM) -----------------------------------------------------
# Verified on the bench: GPIO17/27 drive L298N IN3/IN4 -> OUT3/OUT4 with the
# ENB cap fitted. ENA/ENB are jumpered, so there is no PWM speed control:
# speed_percent only decides move / don't move.
RIGHT_FORWARD_PIN = 17      # physical 11 -> IN3
RIGHT_BACKWARD_PIN = 27     # physical 13 -> IN4
LEFT_FORWARD_PIN = 5        # physical 29 -> IN1   (second motor, optional)
LEFT_BACKWARD_PIN = 6       # physical 31 -> IN2
SERVO_PIN = 18              # physical 12 -> servo signal

# --- ceilings, mirroring robot/contracts.jac ---------------------------
MAX_FORWARD_MS = 2000
MAX_SPEED_PERCENT = 40
CAMERA_MIN_ANGLE = 45
CAMERA_MAX_ANGLE = 135
CAMERA_CENTER = 90
MAX_TURN_DEGREES = 180

# Timed turns are open loop; calibrate on the demo surface.
MS_PER_TURN_DEGREE = 6.0

# Absolute, NOT Path.home(): systemd runs this as root, so home-relative paths
# land in /root where the dashboard and the vissupi account cannot read them.
IMAGE_DIR = Path("/home/vissupi/hardware-tests/results/frames")
DRIVE_ACTIONS = {"MOVE_FORWARD", "MOVE_BACKWARD", "TURN_LEFT", "TURN_RIGHT"}


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


class Rover:
    """Owns every GPIO resource and guarantees the motors can always stop."""

    def __init__(self, arm_drive: bool, enable_left: bool, simulate: bool) -> None:
        self.arm_drive = arm_drive
        self.enable_left = enable_left
        self.simulate = simulate
        self.camera_angle = CAMERA_CENTER
        self.lock = threading.Lock()
        self.seen_commands: dict[str, dict] = {}
        self.order: list[str] = []
        self._stop_timer: threading.Timer | None = None

        self.right = None
        self.left = None
        self.servo = None
        self.camera = None

        if simulate:
            print("[rover] SIMULATE mode - no GPIO will be touched", flush=True)
            return

        from gpiozero import AngularServo, Motor

        self.right = Motor(forward=RIGHT_FORWARD_PIN, backward=RIGHT_BACKWARD_PIN, pwm=False)
        print(f"[rover] right motor on GPIO{RIGHT_FORWARD_PIN}/{RIGHT_BACKWARD_PIN}", flush=True)
        if enable_left:
            self.left = Motor(forward=LEFT_FORWARD_PIN, backward=LEFT_BACKWARD_PIN, pwm=False)
            print(f"[rover] left motor on GPIO{LEFT_FORWARD_PIN}/{LEFT_BACKWARD_PIN}", flush=True)
        else:
            print("[rover] left motor NOT configured - straight travel unavailable", flush=True)

        try:
            self.servo = AngularServo(
                SERVO_PIN, min_angle=0, max_angle=180,
                min_pulse_width=1.0 / 1000, max_pulse_width=2.0 / 1000,
            )
            self.servo.angle = None          # stay limp until asked to move
            print(f"[rover] servo on GPIO{SERVO_PIN}", flush=True)
        except Exception as exc:                                  # noqa: BLE001
            print(f"[rover] servo unavailable: {exc}", flush=True)

    # -- sensors --------------------------------------------------------

    def undervoltage(self) -> bool:
        """Ask the Pi itself, not a sensor we do not have."""
        try:
            import subprocess
            out = subprocess.run(
                ["vcgencmd", "get_throttled"], capture_output=True, text=True, timeout=2
            ).stdout.strip()
            value = int(out.split("=")[1], 16)
            return bool(value & 0x1)          # bit 0 = under-voltage NOW
        except Exception:                                         # noqa: BLE001
            return False

    def sensors(self) -> dict:
        # No distance sensor or bumper is wired yet. Report the honest thing:
        # unknown distance, bumper clear, and drive_safety_ready gated on the
        # explicit arming flag so the Jac layer refuses to drive blind.
        return {
            "front_distance_cm": 999.0,
            "bumper_pressed": False,
            "undervoltage": self.undervoltage(),
            "drive_safety_ready": self.arm_drive and (self.left is not None or self.simulate),
            "camera_angle": self.camera_angle,
            "at": now_iso(),
        }

    # -- motion ---------------------------------------------------------

    def _cancel_watchdog(self) -> None:
        if self._stop_timer is not None:
            self._stop_timer.cancel()
            self._stop_timer = None

    def stop(self) -> None:
        self._cancel_watchdog()
        for motor in (self.right, self.left):
            if motor is not None:
                motor.stop()

    def _arm_watchdog(self, duration_ms: int) -> None:
        """Force a stop even if this thread dies mid-command."""
        self._cancel_watchdog()
        timer = threading.Timer(duration_ms / 1000.0 + 0.25, self.stop)
        timer.daemon = True
        timer.start()
        self._stop_timer = timer

    def drive(self, action: str, duration_ms: int) -> str:
        if self.simulate:
            time.sleep(min(duration_ms, MAX_FORWARD_MS) / 1000.0)
            return f"simulated {action} for {duration_ms}ms"

        self._arm_watchdog(duration_ms)
        try:
            if action == "MOVE_FORWARD":
                if self.left is not None:
                    self.left.forward()
                self.right.forward()
            elif action == "MOVE_BACKWARD":
                if self.left is not None:
                    self.left.backward()
                self.right.backward()
            elif action == "TURN_LEFT":
                # differential: right wheel forward, left reversed for a tight turn
                if self.left is not None:
                    self.left.backward()
                self.right.forward()
            elif action == "TURN_RIGHT":
                if self.left is not None:
                    self.left.forward()
                self.right.backward()
            time.sleep(duration_ms / 1000.0)
        finally:
            self.stop()
        return f"{action} for {duration_ms}ms"

    def set_camera(self, angle: int) -> str:
        angle = int(clamp(angle, CAMERA_MIN_ANGLE, CAMERA_MAX_ANGLE))
        if self.servo is not None:
            # ease rather than jump: a step keeps the current spike down
            start = self.camera_angle
            steps = max(1, abs(angle - start) // 5)
            for i in range(1, steps + 1):
                self.servo.angle = start + (angle - start) * i / steps
                time.sleep(0.02)
            time.sleep(0.25)
            self.servo.angle = None           # release so it does not buzz
        self.camera_angle = angle
        return f"camera at {angle} degrees"

    def capture(self, command_id: str) -> tuple[str, str]:
        IMAGE_DIR.mkdir(parents=True, exist_ok=True)
        name = f"{int(time.time())}-{self.camera_angle}deg-{command_id[:8]}.jpg"
        path = IMAGE_DIR / name
        if self.simulate or self.camera is None:
            try:
                from picamera2 import Picamera2
                if self.camera is None:
                    self.camera = Picamera2()
                    self.camera.configure(self.camera.create_still_configuration())
                    self.camera.start()
                    time.sleep(0.4)
                self.camera.capture_file(str(path))
                return name, f"captured {name}"
            except Exception as exc:                              # noqa: BLE001
                return "", f"camera unavailable: {exc}"
        self.camera.capture_file(str(path))
        return name, f"captured {name}"

    # -- command handling -----------------------------------------------

    def execute(self, payload: dict) -> dict:
        command_id = str(payload.get("command_id", ""))
        action = str(payload.get("action", "STOP"))
        snapshot = self.sensors()

        def result(accepted: bool, stopped_by: str, detail: str, elapsed: int = 0) -> dict:
            return {
                "command_id": command_id,
                "accepted": accepted,
                "status": "completed" if accepted else "rejected",
                "stopped_by": stopped_by,
                "elapsed_ms": elapsed,
                "detail": detail,
                "snapshot": self.sensors(),
            }

        if not command_id:
            return result(False, "REJECTED", "missing command_id")

        # idempotency: replay the original answer, never re-run the motion
        if command_id in self.seen_commands:
            return self.seen_commands[command_id]

        expires_at = str(payload.get("expires_at", ""))
        if expires_at:
            try:
                deadline = datetime.fromisoformat(expires_at)
                if deadline.tzinfo is None:
                    deadline = deadline.replace(tzinfo=timezone.utc)
                if datetime.now(timezone.utc) > deadline:
                    return result(False, "EXPIRED", "command expired before arrival")
            except ValueError:
                return result(False, "REJECTED", "unparseable expires_at")

        if snapshot["undervoltage"]:
            return result(False, "UNDERVOLTAGE", "Pi reports undervoltage; refusing")

        if action in DRIVE_ACTIONS and not snapshot["drive_safety_ready"]:
            return result(
                False, "DRIVE_INTERLOCK",
                "drive disarmed: start with --arm-drive and a second motor wired",
            )

        speed = int(clamp(float(payload.get("speed_percent", 0)), 0, MAX_SPEED_PERCENT))
        duration = int(clamp(float(payload.get("duration_ms", 0)), 0, MAX_FORWARD_MS))
        angle = int(payload.get("angle", CAMERA_CENTER))

        started = time.time()
        with self.lock:
            try:
                if action in {"MOVE_FORWARD", "MOVE_BACKWARD"}:
                    if speed <= 0 or duration <= 0:
                        answer = result(False, "REJECTED", "zero speed or duration")
                    else:
                        answer = result(True, "COMPLETED", self.drive(action, duration),
                                        int((time.time() - started) * 1000))
                elif action in {"TURN_LEFT", "TURN_RIGHT"}:
                    degrees = int(clamp(abs(angle), 0, MAX_TURN_DEGREES))
                    turn_ms = int(clamp(degrees * MS_PER_TURN_DEGREE, 0, MAX_FORWARD_MS))
                    if turn_ms <= 0:
                        answer = result(False, "REJECTED", "zero turn angle")
                    else:
                        answer = result(True, "COMPLETED", self.drive(action, turn_ms),
                                        int((time.time() - started) * 1000))
                elif action == "SET_CAMERA_ANGLE":
                    answer = result(True, "COMPLETED", self.set_camera(angle),
                                    int((time.time() - started) * 1000))
                elif action == "CAPTURE_IMAGE":
                    name, detail = self.capture(command_id)
                    answer = result(bool(name), "COMPLETED" if name else "TRANSPORT_ERROR",
                                    detail, int((time.time() - started) * 1000))
                    answer["image"] = name
                elif action == "STOP":
                    self.stop()
                    answer = result(True, "COMPLETED", "stopped")
                else:
                    answer = result(False, "REJECTED", f"unknown action {action}")
            except Exception as exc:                              # noqa: BLE001
                self.stop()
                answer = result(False, "TRANSPORT_ERROR", f"{type(exc).__name__}: {exc}")

        # bounded replay cache
        self.seen_commands[command_id] = answer
        self.order.append(command_id)
        if len(self.order) > 256:
            self.seen_commands.pop(self.order.pop(0), None)
        return answer

    def shutdown(self) -> None:
        self.stop()
        for device in (self.right, self.left, self.servo):
            if device is not None:
                try:
                    device.close()
                except Exception:                                 # noqa: BLE001
                    pass
        if self.camera is not None:
            try:
                self.camera.stop()
            except Exception:                                     # noqa: BLE001
                pass


ROVER: Rover | None = None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:
        print(f"[http] {fmt % args}", flush=True)

    def _send(self, code: int, payload: dict | bytes, content_type: str = "application/json") -> None:
        body = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:                                     # noqa: N802
        assert ROVER is not None
        if self.path == "/health":
            self._send(200, {"status": "ok", "armed": ROVER.arm_drive,
                             "left_motor": ROVER.left is not None, "at": now_iso()})
        elif self.path == "/sensors":
            self._send(200, ROVER.sensors())
        elif self.path.startswith("/image/"):
            path = IMAGE_DIR / Path(self.path[len("/image/"):]).name
            if path.is_file():
                self._send(200, path.read_bytes(), "image/jpeg")
            else:
                self._send(404, {"error": "no such image"})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self) -> None:                                    # noqa: N802
        assert ROVER is not None
        if self.path != "/command":
            self._send(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
            payload = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, json.JSONDecodeError) as exc:
            self._send(400, {"error": f"bad json: {exc}"})
            return
        self._send(200, ROVER.execute(payload))


def main() -> int:
    global ROVER
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=871)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--arm-drive", action="store_true",
                        help="allow motor commands (default: camera only)")
    parser.add_argument("--left-motor", action="store_true",
                        help="a second motor is wired to IN1/IN2")
    parser.add_argument("--simulate", action="store_true",
                        help="no GPIO; useful for testing the contract off-rover")
    args = parser.parse_args()

    ROVER = Rover(arm_drive=args.arm_drive, enable_left=args.left_motor, simulate=args.simulate)
    if args.arm_drive:
        print("[rover] DRIVE ARMED - motors will move. Raise the wheels.", flush=True)
    else:
        print("[rover] drive disarmed - camera and sensors only", flush=True)

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"[rover] listening on http://{args.host}:{args.port}", flush=True)

    # systemd stops us with SIGTERM, which would otherwise skip the cleanup
    # below and leave a motor energised. Turn it into a normal shutdown.
    import signal

    def on_term(signum, frame) -> None:                           # noqa: ANN001
        print(f"[rover] signal {signum}: stopping motors", flush=True)
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGINT, on_term)

    try:
        server.serve_forever()
    finally:
        print("[rover] releasing GPIO", flush=True)
        ROVER.shutdown()
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
