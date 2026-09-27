"""Transports that carry validated commands to a rover.

Both transports implement the same contract, so the mission engine cannot tell
them apart. That is what keeps the demo alive when the venue Wi-Fi or the
hardware does not cooperate: swap the transport, keep the mission.

`SimulatedTransport` models a rover in a lane with a target at a known bearing.
`PiTransport` posts to the edge runtime over the local network.
"""

import from .contracts {
    CommandResult,
    MotionCommand,
    SafetyLimits,
    SensorSnapshot,
    is_expired,
    validate_motion
}
import from datetime { datetime }
import json;
import urllib.request as urlreq;
import from pathlib { Path }


obj Transport {
    """Base contract. Subclasses override `send` and `read_sensors`."""
    has name: str = "base",
        seen_commands: list[str] = [];

    def read_sensors -> SensorSnapshot {
        return SensorSnapshot(at=datetime.now().isoformat());
    }

    def deliver(command: MotionCommand) -> CommandResult {
        return CommandResult(
            command_id=command.command_id,
            accepted=False,
            status="rejected",
            stopped_by="TRANSPORT_ERROR",
            detail="base transport cannot move a rover"
        );
    }

    def send(command: MotionCommand, limits: SafetyLimits) -> CommandResult {
        if command.command_id in self.seen_commands {
            return CommandResult(
                command_id=command.command_id,
                accepted=False,
                status="rejected",
                stopped_by="REJECTED",
                detail="duplicate command id",
                snapshot=self.read_sensors()
            );
        }
        if is_expired(command) {
            return CommandResult(
                command_id=command.command_id,
                accepted=False,
                status="rejected",
                stopped_by="EXPIRED",
                detail="command expired before dispatch",
                snapshot=self.read_sensors()
            );
        }

        snapshot = self.read_sensors();
        outcome = validate_motion(command, limits, snapshot);
        if not outcome.ok {
            return CommandResult(
                command_id=command.command_id,
                accepted=False,
                status="rejected",
                stopped_by=outcome.reason,
                detail=f"refused by safety layer: {outcome.reason}",
                snapshot=snapshot
            );
        }

        self.seen_commands.append(command.command_id);
        return self.deliver(outcome.command);
    }
}


obj SimulatedTransport(Transport) {
    """A rover in a straight lane with one target at a fixed bearing."""
    has name: str = "simulated",
        heading: int = 0,
        distance_to_target_cm: float = 220.0,
        target_bearing: int = 30,
        camera_angle: int = 90,
        obstacle_at_cm: float = 25.0,
        bumper_pressed: bool = False;

    override def read_sensors -> SensorSnapshot {
        front = self.distance_to_target_cm;
        if self.obstacle_at_cm < front { front = self.obstacle_at_cm; }
        return SensorSnapshot(
            front_distance_cm=front,
            bumper_pressed=self.bumper_pressed,
            undervoltage=False,
            drive_safety_ready=True,
            camera_angle=self.camera_angle,
            at=datetime.now().isoformat()
        );
    }

    override def deliver(command: MotionCommand) -> CommandResult {
        stopped = "COMPLETED";
        detail = "";

        if command.action == "SET_CAMERA_ANGLE" {
            self.camera_angle = command.angle;
            detail = f"camera at {self.camera_angle} degrees";
        } elif command.action == "TURN_LEFT" {
            self.heading -= command.angle;
            detail = f"heading now {self.heading} degrees";
        } elif command.action == "TURN_RIGHT" {
            self.heading += command.angle;
            detail = f"heading now {self.heading} degrees";
        } elif command.action == "MOVE_FORWARD" {
            travelled = command.duration_ms * command.speed_percent / 1000.0;
            self.distance_to_target_cm -= travelled;
            if self.distance_to_target_cm < 5.0 { self.distance_to_target_cm = 5.0; }
            detail = f"advanced, {self.distance_to_target_cm:.0f} cm remaining";
        } elif command.action == "MOVE_BACKWARD" {
            self.distance_to_target_cm += command.duration_ms * command.speed_percent / 1000.0;
            detail = "reversed";
        } elif command.action == "STOP" {
            detail = "stopped";
        }

        return CommandResult(
            command_id=command.command_id,
            accepted=True,
            status="completed",
            stopped_by=stopped,
            elapsed_ms=command.duration_ms,
            detail=detail,
            snapshot=self.read_sensors()
        );
    }

    """True when a sweep frame at this angle would contain the target."""
    def target_visible_at(angle: int) -> bool {
        relative = angle - 90 - self.heading;
        delta = relative - self.target_bearing;
        if delta < 0 { delta = -delta; }
        return delta <= 25;
    }
}


obj PiTransport(Transport) {
    """Talks to the edge runtime on the rover over HTTP."""
    has name: str = "pi",
        base_url: str = "http://10.189.134.218:871",
        timeout_s: float = 4.0,
        frame_cache: Path = Path(".jac/frames");

    def _get(path: str) -> dict[str, any] {
        url = f"{self.base_url}{path}";
        try {
            with urlreq.urlopen(url, timeout=self.timeout_s) as response {
                raw: any = json.loads(response.read().decode("utf-8"));
                return raw;
            }
        } except Exception as err {
            return {"error": str(err)};
        }
    }

    def _post(path: str, payload: dict[str, any]) -> dict[str, any] {
        url = f"{self.base_url}{path}";
        body = json.dumps(payload).encode("utf-8");
        request = urlreq.Request(url, data=body, method="POST");
        request.add_header("Content-Type", "application/json");
        try {
            with urlreq.urlopen(request, timeout=self.timeout_s) as response {
                raw: any = json.loads(response.read().decode("utf-8"));
                return raw;
            }
        } except Exception as err {
            return {"error": str(err)};
        }
    }

    override def read_sensors -> SensorSnapshot {
        data = self._get("/sensors");
        if "error" in data {
            return SensorSnapshot(
                front_distance_cm=0.0,
                bumper_pressed=True,
                undervoltage=True,
                drive_safety_ready=False,
                at=datetime.now().isoformat()
            );
        }
        return SensorSnapshot(
            front_distance_cm=float(data.get("front_distance_cm", 999.0)),
            bumper_pressed=bool(data.get("bumper_pressed", False)),
            undervoltage=bool(data.get("undervoltage", False)),
            drive_safety_ready=bool(data.get("drive_safety_ready", False)),
            camera_angle=int(data.get("camera_angle", 90)),
            at=datetime.now().isoformat()
        );
    }

    override def deliver(command: MotionCommand) -> CommandResult {
        payload: dict[str, any] = {
            "command_id": command.command_id,
            "mission_id": command.mission_id,
            "sequence": command.sequence,
            "action": command.action,
            "speed_percent": command.speed_percent,
            "duration_ms": command.duration_ms,
            "angle": command.angle,
            "expires_at": command.expires_at
        };
        data = self._post("/command", payload);
        if "error" in data {
            return CommandResult(
                command_id=command.command_id,
                accepted=False,
                status="error",
                stopped_by="TRANSPORT_ERROR",
                detail=str(data.get("error", "unreachable")),
                snapshot=self.read_sensors()
            );
        }
        return CommandResult(
            command_id=command.command_id,
            accepted=bool(data.get("accepted", False)),
            status=str(data.get("status", "completed")),
            stopped_by=str(data.get("stopped_by", "COMPLETED")),
            elapsed_ms=int(data.get("elapsed_ms", 0)),
            detail=str(data.get("detail", "")),
            image_name=str(data.get("image", "")),
            snapshot=self.read_sensors()
        );
    }

    """Pull a captured frame off the rover and cache it locally.

    The vision model is a hosted API and cannot reach the rover's LAN address,
    so frames must travel to this machine as bytes before they can be analysed.
    Returns the local path, or an empty string when the fetch fails.
    """
    def fetch_image(name: str) -> str {
        if not name { return ""; }
        target = self.frame_cache / name;
        if target.exists() { return str(target); }
        try {
            self.frame_cache.mkdir(parents=True, exist_ok=True);
            url = f"{self.base_url}/image/{name}";
            with urlreq.urlopen(url, timeout=self.timeout_s) as response {
                target.write_bytes(response.read());
            }
            return str(target);
        } except Exception {
            return "";
        }
    }
}
