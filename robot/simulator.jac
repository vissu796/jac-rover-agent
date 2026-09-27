"""Deterministic rover simulator used by Phase 1.

The real Raspberry Pi adapter will implement this same input/output contract.
Keeping simulation behind the contract lets us test the agent before motors,
sensors, networking, or GPIO are involved.
"""

import from .contracts {
    CommandResult,
    MotionCommand,
    SafetyLimits,
    SensorSnapshot,
    is_expired,
    validate_motion
}


def execute_simulated_command(
    command: MotionCommand,
    limits: SafetyLimits,
    snapshot: SensorSnapshot
) -> CommandResult {
    if is_expired(command) {
        return CommandResult(
            command_id=command.command_id,
            accepted=False,
            status="rejected",
            stopped_by="EXPIRED",
            detail="Command expired before the simulated rover received it.",
            snapshot=snapshot
        );
    }

    checked = validate_motion(command, limits, snapshot);
    if not checked.ok {
        return CommandResult(
            command_id=command.command_id,
            accepted=False,
            status="rejected",
            stopped_by=checked.reason,
            detail="Local safety policy rejected the command.",
            snapshot=snapshot
        );
    }

    safe = checked.command;
    if safe.action == "SET_CAMERA_ANGLE" {
        snapshot.camera_angle = safe.angle;
    }

    return CommandResult(
        command_id=safe.command_id,
        accepted=True,
        status="completed",
        stopped_by="COMPLETED",
        elapsed_ms=safe.duration_ms,
        detail=f"Simulation accepted bounded action {safe.action}.",
        snapshot=snapshot
    );
}
