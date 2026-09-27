"""Conversational interface between the user, Gemini, and the rover mission graph."""

import from .ai { TargetSpec, extract_target, refine_target }
import from .lost_found { PreparedMissionTrigger, add_event }
import from .models { ChatMessage, Mission, TargetProfile, now_iso }
import from .walkers { RunMission }


obj ChatResponse {
    has mission_id: str = "",
        assistant_message: str = "",
        state: str = "IDLE",
        category: str = "",
        primary_color: str = "",
        size: str = "",
        markings: str = "",
        last_seen_area: str = "",
        can_trigger: bool = False,
        rover_triggered: bool = False,
        error: str = "";
}


def apply_chat_spec(profile: TargetProfile, spec: TargetSpec) {
    profile.category = spec.category;
    profile.primary_color = spec.primary_color;
    profile.secondary_color = spec.secondary_color;
    profile.size = spec.size;
    profile.shape = spec.shape;
    profile.material = spec.material;
    profile.markings = spec.markings;
    profile.last_seen_area = spec.last_seen_area;
    profile.is_living = spec.is_living;
}


def chat_spec_from(profile: TargetProfile) -> TargetSpec {
    return TargetSpec(
        category=profile.category,
        primary_color=profile.primary_color,
        secondary_color=profile.secondary_color,
        size=profile.size,
        shape=profile.shape,
        material=profile.material,
        markings=profile.markings,
        last_seen_area=profile.last_seen_area,
        is_living=profile.is_living,
        confident_enough=False
    );
}


def next_required_question(profile: TargetProfile) -> str {
    if not profile.category {
        return "What kind of object should I look for?";
    }
    if not profile.primary_color and not profile.markings {
        return "What color or distinctive marking should I look for?";
    }
    if not profile.last_seen_area {
        return "Where did you last see it?";
    }
    return "";
}


def ready_summary(profile: TargetProfile) -> str {
    place = f" near {profile.last_seen_area}" if profile.last_seen_area else "";
    return f"I have enough to begin: {profile.describe()}{place}. Review the target profile, then wake the rover when you're ready.";
}


def response_for(
    mission: Mission,
    profile: TargetProfile,
    assistant_message: str,
    error: str = ""
) -> ChatResponse {
    return ChatResponse(
        mission_id=jid(mission),
        assistant_message=assistant_message,
        state=mission.state,
        category=profile.category,
        primary_color=profile.primary_color,
        size=profile.size,
        markings=profile.markings,
        last_seen_area=profile.last_seen_area,
        can_trigger=mission.state == "AWAITING_CONFIRMATION",
        rover_triggered=mission.state in ["READY", "SCANNING", "VERIFYING", "APPROACHING", "COMPLETE"],
        error=error
    );
}


def find_mission(mission_id: str) -> Mission | None {
    target = jobj(mission_id);
    return target if isinstance(target, Mission) else None;
}


def:pub SendChatMessage(message: str, mission_id: str = "") -> ChatResponse {
    clean = message.strip();
    if not clean {
        return ChatResponse(error="Write a message before sending.");
    }

    mission = find_mission(mission_id) if mission_id else None;
    if mission is None {
        mission = root ++> Mission(
            kind="LOST_OBJECT",
            goal_text=clean,
            state="COLLECTING_DETAILS",
            outcome="PENDING",
            created_at=now_iso()
        );
        profile = mission ++> TargetProfile();
        mission ++> ChatMessage(role="user", text=clean, at=now_iso());
        add_event(mission, mission.state, "Conversation started.");
        try {
            apply_chat_spec(profile, extract_target(clean));
        } except Exception {
            reply = "Gemini is not connected yet. Add GOOGLE_API_KEY to the server environment, then send your request again.";
            mission ++> ChatMessage(role="assistant", text=reply, at=now_iso());
            return response_for(mission, profile, reply, "Gemini connection unavailable.");
        }
    } else {
        profiles = [mission -->[?:TargetProfile]];
        if not profiles {
            profile = mission ++> TargetProfile();
        } else {
            profile = profiles[0];
        }
        mission ++> ChatMessage(role="user", text=clean, at=now_iso());
        try {
            spec = refine_target(chat_spec_from(profile), mission.pending_question, clean);
            apply_chat_spec(profile, spec);
        } except Exception {
            reply = "I couldn't reach Gemini for that update. Check the model connection and try again.";
            mission ++> ChatMessage(role="assistant", text=reply, at=now_iso());
            return response_for(mission, profile, reply, "Gemini connection unavailable.");
        }
    }

    question = next_required_question(profile);
    if question {
        mission.state = "COLLECTING_DETAILS";
        mission.pending_question = question;
        reply = question;
    } else {
        mission.state = "AWAITING_CONFIRMATION";
        mission.pending_question = "";
        reply = ready_summary(profile);
    }
    mission ++> ChatMessage(role="assistant", text=reply, at=now_iso());
    add_event(mission, mission.state, reply);
    return response_for(mission, profile, reply);
}


def:pub ConfirmLostObjectMission(mission_id: str) -> ChatResponse {
    mission = find_mission(mission_id);
    if mission is None {
        return ChatResponse(error="Mission not found. Start a new conversation.");
    }
    profiles = [mission -->[?:TargetProfile]];
    if not profiles {
        return ChatResponse(mission_id=mission_id, error="The mission has no target profile.");
    }
    profile = profiles[0];
    if mission.state != "AWAITING_CONFIRMATION" {
        return response_for(mission, profile, "The rover cannot start until the target details are complete.");
    }

    result = root spawn PreparedMissionTrigger(mission_id=mission_id);
    if not result.reports {
        return response_for(mission, profile, "The rover did not accept the mission.", "No rover acknowledgement received.");
    }
    mission = result.reports[0];
    if mission.state == "READY" {
        search = root spawn RunMission(mission_id=mission_id, use_vision=False);
        if search.reports {
            mission = search.reports[0];
        }
    }
    if mission.outcome == "FOUND" {
        reply = f"Simulation complete: I found the target after {mission.cycles_used} scan cycle(s). All incidental objects were stored with their frame and camera angle.";
    } elif mission.outcome == "NOT_FOUND" {
        reply = f"Simulation complete: the target was not found after {mission.cycles_used} bounded scan cycle(s). The observations are stored for review.";
    } elif mission.outcome == "BLOCKED" {
        reply = f"The search stopped safely: {mission.stop_reason}.";
    } else {
        reply = "The rover stopped during its safety precheck.";
    }
    mission ++> ChatMessage(role="assistant", text=reply, at=now_iso());
    return response_for(mission, profile, reply);
}


def:pub GetChatHistory(mission_id: str) -> list[ChatMessage] {
    mission = find_mission(mission_id);
    return [mission -->[?:ChatMessage]] if mission is not None else [];
}
