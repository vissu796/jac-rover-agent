"""Bounded command contracts between the agent and the rover.

The safety boundary of the whole system lives here. The LLM never produces a
motor value: it selects an action from `RobotAction` and the numbers are
clamped by `validate_motion` before any transport sees them. Every command
carries an id, a sequence number and an expiry so the edge runtime can reject
duplicates and stale commands.
"""

import from datetime { datetime, timedelta, timezone }
import uuid;


enum RobotAction {
    MOVE_FORWARD,
    MOVE_BACKWARD,
    TURN_LEFT,
    TURN_RIGHT,
    STOP,
    SET_CAMERA_ANGLE,
    CAPTURE_IMAGE
}


enum StopReason {
    COMPLETED,
    BUMPER,
    OBSTACLE,
    EXPIRED,
    CANCELLED,
    UNDERVOLTAGE,
    REJECTED,
    TRANSPORT_ERROR,
    DRIVE_INTERLOCK
}


obj SafetyLimits {
    """Hard caps applied to every command. Config, never model output."""
    has max_forward_ms: int = 2000,
        max_turn_degrees: int = 180,
        max_speed_percent: int = 40,
        camera_min_angle: int = 45,
        camera_max_angle: int = 135,
        camera_center: int = 90,
        min_front_distance_cm: int = 20,
        command_ttl_ms: int = 3000,
        max_approach_pulses: int = 6;
}


obj SensorSnapshot {
    """Deterministic local sensor read. Ground truth for safety decisions."""
    has front_distance_cm: float = 999.0,
        bumper_pressed: bool = False,
        undervoltage: bool = False,
        drive_safety_ready: bool = False,
        camera_angle: int = 90,
        at: str = "";
}


obj MotionCommand {
    """One bounded, expiring, idempotent instruction for the rover."""
    has command_id: str = "",
        mission_id: str = "",
        sequence: int = 0,
        action: str = "STOP",
        speed_percent: int = 0,
        duration_ms: int = 0,
        angle: int = 90,
        issued_at: str = "",
        expires_at: str = "";
}


obj CommandResult {
    """What the rover reports back. `stopped_by` is always populated."""
    has command_id: str = "",
        accepted: bool = False,
        status: str = "completed",
        stopped_by: str = "COMPLETED",
        elapsed_ms: int = 0,
        detail: str = "",
        image_name: str = "",
        snapshot: SensorSnapshot = SensorSnapshot();
}


obj ValidationOutcome {
    """Result of clamping a requested command against the limits."""
    has ok: bool = True,
        reason: str = "",
        command: MotionCommand = MotionCommand();
}


def clamp(value: int, low: int, high: int) -> int {
    if value < low { return low; }
    if value > high { return high; }
    return value;
}


"""Build a command stamped with a fresh id and an expiry window."""
def new_command(
    mission_id: str,
    sequence: int,
    action: str,
    speed_percent: int = 0,
    duration_ms: int = 0,
    angle: int = 90,
    ttl_ms: int = 3000
) -> MotionCommand {
    # UTC, timezone-aware. A naive local timestamp is read as UTC by the edge
    # runtime, so every command from a non-UTC machine arrives "expired".
    issued = datetime.now(timezone.utc);
    expires = issued + timedelta(milliseconds=ttl_ms);
    return MotionCommand(
        command_id=str(uuid.uuid4()),
        mission_id=mission_id,
        sequence=sequence,
        action=action,
        speed_percent=speed_percent,
        duration_ms=duration_ms,
        angle=angle,
        issued_at=issued.isoformat(),
        expires_at=expires.isoformat()
    );
}


"""Clamp a command and refuse it outright when the rover is unsafe.

Runs before the transport. The edge runtime clamps again on arrival, so a bug
here cannot be the only thing standing between the agent and the motors.
"""
def validate_motion(
    command: MotionCommand,
    limits: SafetyLimits,
    snapshot: SensorSnapshot
) -> ValidationOutcome {
    if snapshot.bumper_pressed {
        return ValidationOutcome(ok=False, reason="BUMPER", command=command);
    }
    if snapshot.undervoltage {
        return ValidationOutcome(ok=False, reason="UNDERVOLTAGE", command=command);
    }

    drive_actions = ["MOVE_FORWARD", "MOVE_BACKWARD", "TURN_LEFT", "TURN_RIGHT"];
    if command.action in drive_actions and not snapshot.drive_safety_ready {
        return ValidationOutcome(ok=False, reason="DRIVE_INTERLOCK", command=command);
    }

    blocked = snapshot.front_distance_cm < limits.min_front_distance_cm;
    if command.action == "MOVE_FORWARD" and blocked {
        return ValidationOutcome(ok=False, reason="OBSTACLE", command=command);
    }

    safe_speed = clamp(command.speed_percent, 0, limits.max_speed_percent);
    safe_duration = clamp(command.duration_ms, 0, limits.max_forward_ms);
    safe_angle = command.angle;
    if command.action == "SET_CAMERA_ANGLE" {
        safe_speed = 0;
        safe_duration = 0;
        safe_angle = clamp(command.angle, limits.camera_min_angle, limits.camera_max_angle);
    } elif command.action == "TURN_LEFT" or command.action == "TURN_RIGHT" {
        safe_duration = 0;
        safe_angle = clamp(abs(command.angle), 0, limits.max_turn_degrees);
    } elif command.action == "STOP" or command.action == "CAPTURE_IMAGE" {
        safe_speed = 0;
        safe_duration = 0;
    }

    safe = MotionCommand(
        command_id=command.command_id,
        mission_id=command.mission_id,
        sequence=command.sequence,
        action=command.action,
        speed_percent=safe_speed,
        duration_ms=safe_duration,
        angle=safe_angle,
        issued_at=command.issued_at,
        expires_at=command.expires_at
    );
    return ValidationOutcome(ok=True, reason="", command=safe);
}


"""True when the command's TTL has passed. Checked again on the Pi."""
def is_expired(command: MotionCommand) -> bool {
    if not command.expires_at { return False; }
    deadline = datetime.fromisoformat(command.expires_at);
    if deadline.tzinfo is None {
        deadline = deadline.replace(tzinfo=timezone.utc);
    }
    return datetime.now(timezone.utc) > deadline;
}


"""Evenly spaced camera angles across the calibrated safe range."""
def scan_angles(limits: SafetyLimits, count: int = 5) -> list[int] {
    if count <= 1 { return [limits.camera_center]; }
    span = limits.camera_max_angle - limits.camera_min_angle;
    return [
        limits.camera_min_angle + ((span * i) // (count - 1))
        for i in range(count)
    ];
}


"""Approximate chassis bearing to a target seen at a camera angle."""
def bearing_from_angle(camera_angle: int, center: int = 90) -> int {
    return camera_angle - center;
}
