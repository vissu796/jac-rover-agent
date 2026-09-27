"""The bounded search loop for a lost-object mission.

This is the deterministic half of the agent. The model decides *what it sees*;
this file decides *what the rover is allowed to do about it*. Every exit from
the loop sets an explicit stop reason, so a mission can never simply trail off.

The loop is a plain object rather than a walker because it does not traverse
the graph: the walker in `walkers.jac` owns the graph and calls into this.
"""

import from robot.contracts {
    CommandResult,
    SafetyLimits,
    SensorSnapshot,
    bearing_from_angle,
    new_command,
    scan_angles
}
import from robot.transport { PiTransport, SimulatedTransport, Transport }


obj FrameCapture {
    """One frame from a sweep, with the angle it was taken at."""
    has camera_angle: int = 90,
        image_path: str = "",
        target_in_frame: bool = False,
        observed_labels: list[str] = [];
}


obj CycleResult {
    """What one scan-and-approach cycle produced."""
    has cycle_index: int = 0,
        frames: list[FrameCapture] = [],
        found: bool = False,
        best_angle: int = 90,
        best_confidence: float = 0.0,
        best_label: str = "",
        rationale: str = "",
        stop_reason: str = "",
        halted: bool = False,
        notes: list[str] = [];
}


obj SearchOutcome {
    """The terminal result of the whole bounded search."""
    has outcome: str = "NOT_FOUND",
        stop_reason: str = "MAX_CYCLES",
        cycles_used: int = 0,
        best_label: str = "",
        best_confidence: float = 0.0,
        cycles: list[CycleResult] = [];
}


obj SearchEngine {
    """Runs the PRECHECK -> SCAN -> VERIFY -> APPROACH loop within hard limits."""
    has transport: Transport = SimulatedTransport(),
        limits: SafetyLimits = SafetyLimits(),
        confidence_threshold: float = 0.55,
        scan_steps: int = 5,
        sequence: int = 0,
        mission_id: str = "";

    def _next_sequence -> int {
        self.sequence += 1;
        return self.sequence;
    }

    """Run one bounded command through the safety layer and transport."""
    def _dispatch(
        action: str,
        speed_percent: int = 0,
        duration_ms: int = 0,
        angle: int = 90
    ) -> CommandResult {
        command = new_command(
            mission_id=self.mission_id,
            sequence=self._next_sequence(),
            action=action,
            speed_percent=speed_percent,
            duration_ms=duration_ms,
            angle=angle,
            ttl_ms=self.limits.command_ttl_ms
        );
        return self.transport.send(command, self.limits);
    }

    """Refuse to start when the rover is already unsafe."""
    def precheck -> str {
        snapshot = self.get_sensor_snapshot();
        if snapshot.bumper_pressed { return "BUMPER"; }
        if snapshot.undervoltage { return "UNDERVOLTAGE"; }
        if not snapshot.drive_safety_ready { return "DRIVE_INTERLOCK"; }
        if snapshot.front_distance_cm < self.limits.min_front_distance_cm {
            return "OBSTACLE";
        }
        return "";
    }

    """Semantic rover tools. The agent never sees GPIO pins or raw PWM."""
    def get_sensor_snapshot -> SensorSnapshot {
        return self.transport.read_sensors();
    }

    def move_forward(duration_ms: int = 600) -> CommandResult {
        return self._dispatch(
            "MOVE_FORWARD",
            speed_percent=self.limits.max_speed_percent,
            duration_ms=duration_ms
        );
    }

    def turn_left(angle_degrees: int) -> CommandResult {
        return self._dispatch(
            "TURN_LEFT",
            speed_percent=self.limits.max_speed_percent,
            angle=angle_degrees
        );
    }

    def turn_right(angle_degrees: int) -> CommandResult {
        return self._dispatch(
            "TURN_RIGHT",
            speed_percent=self.limits.max_speed_percent,
            angle=angle_degrees
        );
    }

    def stop_motion -> CommandResult {
        return self._dispatch("STOP");
    }

    def set_camera_angle(angle_degrees: int) -> CommandResult {
        return self._dispatch("SET_CAMERA_ANGLE", angle=angle_degrees);
    }

    def camera_left(step_degrees: int = 15) -> CommandResult {
        current = self.get_sensor_snapshot().camera_angle;
        return self.set_camera_angle(current - step_degrees);
    }

    def camera_right(step_degrees: int = 15) -> CommandResult {
        current = self.get_sensor_snapshot().camera_angle;
        return self.set_camera_angle(current + step_degrees);
    }

    def capture_image -> CommandResult {
        return self._dispatch("CAPTURE_IMAGE");
    }

    """Sweep the camera across its calibrated range, capturing one frame each stop.

    Against a real rover each frame is pulled back to this machine, because the
    hosted vision model cannot reach the rover's LAN address. Against the
    simulator the frames are fixtures, so tests and the offline demo stay
    deterministic and cost nothing.
    """
    def sweep(cycle_index: int) -> list[FrameCapture] {
        frames: list[FrameCapture] = [];

        for angle in scan_angles(self.limits, self.scan_steps) {
            moved = self.set_camera_angle(angle);
            if not moved.accepted { continue; }

            captured = self.capture_image();
            if not captured.accepted { continue; }

            visible = False;
            labels: list[str] = [];
            path = f"cycle{cycle_index}-angle{angle}.jpg";

            # isinstance must stay inline: the narrowed type is what lets the
            # checker see the subclass methods.
            rover = self.transport;
            if isinstance(rover, SimulatedTransport) {
                visible = rover.target_visible_at(angle);
                # deterministic fixtures: the simulator has no camera, so these
                # stand in for whatever the vision model would report.
                if angle == self.limits.camera_min_angle { labels = ["chair"]; }
                elif angle == self.limits.camera_center { labels = ["shoe"]; }
                elif angle == self.limits.camera_max_angle { labels = ["cardboard box"]; }
            } elif isinstance(rover, PiTransport) {
                local = rover.fetch_image(captured.image_name);
                if local { path = local; }
            }

            frames.append(
                FrameCapture(
                    camera_angle=angle,
                    image_path=path,
                    target_in_frame=visible,
                    observed_labels=labels
                )
            );
        }
        self.set_camera_angle(self.limits.camera_center);
        return frames;
    }

    """Turn the chassis toward a candidate's approximate bearing."""
    def turn_toward(camera_angle: int) -> CommandResult {
        bearing = bearing_from_angle(camera_angle, self.limits.camera_center);
        if bearing < 0 { return self.turn_left(abs(bearing)); }
        if bearing > 0 { return self.turn_right(bearing); }
        return self.stop_motion();
    }

    """Close on a verified static target in short, sensor-checked pulses."""
    def approach -> str {
        pulses = 0;
        while pulses < self.limits.max_approach_pulses {
            snapshot = self.get_sensor_snapshot();
            if snapshot.bumper_pressed { return "BUMPER"; }
            if snapshot.front_distance_cm <= self.limits.min_front_distance_cm {
                return "ARRIVED";
            }
            result = self.move_forward(600);
            if not result.accepted { return result.stopped_by; }
            pulses += 1;
        }
        return "MAX_PULSES";
    }

    """Advance a short segment before re-scanning from a new vantage point."""
    def step_forward -> str {
        result = self.move_forward(800);
        if not result.accepted { return result.stopped_by; }
        return "";
    }

    """Stop the rover and centre the camera. Safe to call from any state."""
    def park -> None {
        self.stop_motion();
        self.set_camera_angle(self.limits.camera_center);
    }
}
