"""Persistent graph model for rover missions.

Node types are the durable record of what the agent did and why. LLM-facing
types live in `ai.jac` as `obj` and are copied into these nodes after
validation, so the AI schema and the storage schema can evolve separately.
"""

import from datetime { datetime }


enum MissionKind {
    LOST_OBJECT,
    PET_CHECK,
    AREA_INSPECTION
}


enum MissionState {
    COLLECTING_DETAILS,
    PLANNED,
    AWAITING_CONFIRMATION,
    PRECHECK,
    READY,
    SCANNING,
    VERIFYING,
    APPROACHING,
    COMPLETE,
    CANCELLED
}


enum MissionOutcome {
    PENDING,
    FOUND,
    NOT_FOUND,
    BLOCKED,
    CANCELLED,
    ERROR
}


def now_iso -> str {
    return datetime.now().isoformat();
}


node Robot {
    """The rover itself. One per root, created on first use."""
    has name: str = "rover-1",
        online: bool = False,
        simulated: bool = True,
        last_seen: str = "";
}


node Mission {
    """One bounded search task from goal to outcome."""
    has kind: str = "LOST_OBJECT",
        goal_text: str = "",
        state: str = "COLLECTING_DETAILS",
        outcome: str = "PENDING",
        stop_reason: str = "",
        created_at: str = "",
        finished_at: str = "",
        cycles_used: int = 0,
        max_cycles: int = 3,
        max_seconds: int = 90,
        pending_question: str = "";
}


node TargetProfile {
    """What we are looking for, after detail collection."""
    has category: str = "",
        primary_color: str = "",
        secondary_color: str = "",
        size: str = "",
        shape: str = "",
        material: str = "",
        markings: str = "",
        last_seen_area: str = "",
        is_living: bool = False;

    def describe -> str {
        parts: list[str] = [];
        if self.primary_color { parts.append(self.primary_color); }
        if self.size { parts.append(self.size); }
        if self.category { parts.append(self.category); }
        if not parts { return "unspecified target"; }
        return " ".join(parts);
    }
}


node SearchCycle {
    """One scan-and-maybe-move iteration of the search loop."""
    has index: int = 0,
        started_at: str = "",
        note: str = "";
}


node Observation {
    """A single captured frame at a known camera angle."""
    has camera_angle: int = 90,
        cycle_index: int = 0,
        image_path: str = "",
        captured_at: str = "";
}


node Detection {
    """A validated candidate match copied from an LLM result."""
    has label: str = "",
        confidence: float = 0.0,
        camera_angle: int = 90,
        bearing: int = 0,
        rationale: str = "",
        verified: bool = False,
        is_target_match: bool = False,
        observed_at: str = "";
}


node SafetyEvent {
    """A deterministic local safety trigger. Never produced by the LLM."""
    has kind: str = "",
        detail: str = "",
        at: str = "";
}


node MissionEvent {
    """Human-readable timeline entry for the dashboard."""
    has at: str = "",
        state: str = "",
        message: str = "";
}


node ChatMessage {
    """One persisted turn in the user-agent conversation."""
    has role: str = "assistant",
        text: str = "",
        at: str = "";
}


node RobotCommand {
    """Auditable copy of a bounded command sent to the rover transport."""
    has command_id: str = "",
        sequence: int = 0,
        action: str = "STOP",
        speed_percent: int = 0,
        duration_ms: int = 0,
        angle: int = 90,
        issued_at: str = "",
        expires_at: str = "";
}


node CommandReceipt {
    """Persistent acknowledgement returned by the rover transport."""
    has command_id: str = "",
        accepted: bool = False,
        status: str = "",
        stopped_by: str = "",
        detail: str = "",
        at: str = "";
}
