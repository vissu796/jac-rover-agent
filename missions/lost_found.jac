"""Phase 1 lost-and-found agent.

The public endpoint constructs this walker. The walker persists a mission,
collects missing details, traverses to the rover, and triggers only one safe
camera-centering command in simulation. Later phases extend the same traversal
with scan, vision, movement, verification, and reporting abilities.
"""

import from .models {
    CommandReceipt,
    Mission,
    MissionEvent,
    Robot,
    RobotCommand,
    TargetProfile,
    now_iso
}
import from robot.contracts {
    SafetyLimits,
    SensorSnapshot,
    new_command
}
import from robot.simulator { execute_simulated_command }


def add_event(mission: Mission, state: str, message: str) -> MissionEvent {
    return mission ++> MissionEvent(
        at=now_iso(),
        state=state,
        message=message
    );
}


def get_or_create_robot -> Robot {
    robots = [root -->[?:Robot]];
    if robots {
        return robots[0];
    }
    return root ++> Robot(
        name="rover-1",
        online=True,
        simulated=True,
        last_seen=now_iso()
    );
}


def trigger_mission_rover(mission: Mission, robot: Robot) -> bool {
    mission.state = "PRECHECK";
    add_event(mission, mission.state, "Triggering rover through the simulation transport.");

    limits = SafetyLimits();
    snapshot = SensorSnapshot(
        front_distance_cm=100.0,
        bumper_pressed=False,
        undervoltage=False,
        camera_angle=limits.camera_center,
        at=now_iso()
    );
    command = new_command(
        mission_id=jid(mission),
        sequence=1,
        action="SET_CAMERA_ANGLE",
        angle=limits.camera_center,
        ttl_ms=limits.command_ttl_ms
    );
    mission ++> RobotCommand(
        command_id=command.command_id,
        sequence=command.sequence,
        action=command.action,
        speed_percent=command.speed_percent,
        duration_ms=command.duration_ms,
        angle=command.angle,
        issued_at=command.issued_at,
        expires_at=command.expires_at
    );

    result = execute_simulated_command(command, limits, snapshot);
    mission ++> CommandReceipt(
        command_id=result.command_id,
        accepted=result.accepted,
        status=result.status,
        stopped_by=result.stopped_by,
        detail=result.detail,
        at=now_iso()
    );
    robot.last_seen = now_iso();

    if result.accepted {
        mission.state = "READY";
        add_event(
            mission,
            mission.state,
            "Rover triggered successfully; camera centered and ready for Phase 2 scanning."
        );
        return True;
    }

    mission.state = "CANCELLED";
    mission.outcome = "BLOCKED";
    mission.stop_reason = result.stopped_by;
    mission.finished_at = now_iso();
    add_event(mission, mission.state, result.detail);
    return False;
}


walker LostFoundAgent {
    has goal_text: str,
        category: str = "",
        primary_color: str = "",
        size: str = "",
        markings: str = "",
        last_seen_area: str = "",
        mission: Mission | None = None,
        reports: list[Mission] = [];

    can create_mission with Root entry {
        clean_goal = self.goal_text.strip();
        mission = here ++> Mission(
            kind="LOST_OBJECT",
            goal_text=clean_goal,
            state="COLLECTING_DETAILS",
            outcome="PENDING",
            created_at=now_iso()
        );
        self.mission = mission;
        mission ++> TargetProfile(
            category=self.category.strip(),
            primary_color=self.primary_color.strip(),
            size=self.size.strip(),
            markings=self.markings.strip(),
            last_seen_area=self.last_seen_area.strip(),
            is_living=False
        );
        add_event(mission, mission.state, "Lost-object request received.");

        if not clean_goal {
            mission.pending_question = "What object should I look for?";
            skip;
        }
        if not self.category.strip() {
            mission.pending_question = "What kind of object is missing?";
            skip;
        }
        if not self.primary_color.strip() {
            mission.pending_question = "What is the object's main color?";
            skip;
        }
        if not self.last_seen_area.strip() {
            mission.pending_question = "Where was the object last seen?";
            skip;
        }

        mission.state = "PLANNED";
        mission.pending_question = "";
        add_event(mission, mission.state, "Required search details are complete.");
        visit get_or_create_robot();
    }

    can trigger_rover with Robot entry {
        mission = self.mission;
        if mission is None {
            disengage;
        }
        trigger_mission_rover(mission, here);
    }

    can finish with Root exit {
        if self.mission is not None {
            report self.mission;
        }
    }
}


walker PreparedMissionTrigger {
    """Traverse from a prepared mission to the rover after user confirmation."""
    has mission_id: str,
        mission: Mission | None = None,
        reports: list[Mission] = [];

    can locate with Root entry {
        target = jobj(self.mission_id);
        if isinstance(target, Mission) {
            self.mission = target;
            visit [target];
        }
    }

    can validate with Mission entry {
        if here.state != "AWAITING_CONFIRMATION" and here.state != "PLANNED" {
            disengage;
        }
        visit get_or_create_robot();
    }

    can trigger with Robot entry {
        if self.mission is not None {
            trigger_mission_rover(self.mission, here);
        }
    }

    can finish with Root exit {
        if self.mission is not None {
            report self.mission;
        }
    }
}
