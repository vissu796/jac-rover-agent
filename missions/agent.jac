"""The agentic layer: the model chooses what the rover does next.

Everything else in this project is a scripted loop — good engineering, but the
sequence is fixed by us. Here the model is handed the rover's tools and decides
which to call and in what order, reasoning over what it actually saw.

The safety story is unchanged, and that is the point. These tools are the same
bounded `SearchEngine` methods: every one still goes through `validate_motion`,
still carries an expiry, and is still refused by the edge runtime when the
rover is unsafe. The model gets to pick from the menu; it never writes the menu.

Two separate concerns live here:
  * `decide_next_step`  - the mission agent, using rover tools
  * `converse`          - ordinary friendly chat, no tools, no rover
"""

import from missions.ai { brain }
import from robot.contracts { SafetyLimits }


# ---------------------------------------------------------------------
# Tool surface offered to the model.
#
# These are module-level so `tools=[...]` can reference them. Each one is a
# thin, side-effect-bounded wrapper that reports back in words the model can
# reason about, rather than returning raw objects it might misread.
#
# `bind_engine` is how a live mission attaches its engine before the agent
# runs. Without it the tools report that the rover is unavailable, which is
# the honest answer rather than a crash.
# ---------------------------------------------------------------------

glob _engine: any = None;


"""Attach the running mission's engine so the tools have a rover to drive."""
def bind_engine(engine: any) -> None {
    # A bare assignment rebinds the module-level glob directly - Jac has no
    # `global` statement and does not need one.
    _engine = engine;
}


def look_around -> str {
    if _engine is None { return "The rover is not connected."; }
    frames = _engine.sweep(1);
    if not frames { return "The camera sweep returned no frames."; }
    seen: list[str] = [];
    for frame in frames {
        for label in frame.observed_labels {
            seen.append(f"{label} at {frame.camera_angle} degrees");
        }
    }
    if not seen {
        return f"Swept {len(frames)} angles and recognised nothing of note.";
    }
    return f"Swept {len(frames)} angles. Saw: " + "; ".join(seen);
}
sem look_around = "Sweep the camera across its full safe range and report every object recognised, with the angle each was seen at. Use this first when you need to know what is around the rover.";


def check_surroundings -> str {
    if _engine is None { return "The rover is not connected."; }
    snap = _engine.get_sensor_snapshot();
    parts = [
        f"camera at {snap.camera_angle} degrees",
        f"nearest obstacle {snap.front_distance_cm:.0f} cm ahead"
    ];
    if snap.bumper_pressed { parts.append("BUMPER IS PRESSED"); }
    if snap.undervoltage { parts.append("POWER IS LOW"); }
    if not snap.drive_safety_ready { parts.append("driving is disabled right now"); }
    return "; ".join(parts);
}
sem check_surroundings = "Read the rover's sensors: where the camera points, how far the nearest obstacle is, and whether driving is currently permitted. Check this before asking the rover to move.";


def drive_forward_briefly -> str {
    if _engine is None { return "The rover is not connected."; }
    result = _engine.move_forward(600);
    if not result.accepted {
        return f"Refused: {result.stopped_by}. {result.detail}";
    }
    return f"Moved forward briefly. {result.detail}";
}
sem drive_forward_briefly = "Move the rover forward one short, bounded step of roughly half a second. Refused automatically if the path is blocked or driving is disabled. Never assume it succeeded - read the reply.";


def turn_towards(angle_degrees: int) -> str {
    if _engine is None { return "The rover is not connected."; }
    if angle_degrees < 0 { result = _engine.turn_left(abs(angle_degrees)); }
    elif angle_degrees > 0 { result = _engine.turn_right(angle_degrees); }
    else { return "No turn needed."; }
    if not result.accepted {
        return f"Refused: {result.stopped_by}. {result.detail}";
    }
    return f"Turned {angle_degrees} degrees. {result.detail}";
}
sem turn_towards = "Rotate the rover's body. Negative degrees turn left, positive turn right. Use the angle an object was seen at, minus 90, to face it.";
sem turn_towards.angle_degrees = "How far to rotate. Negative is left, positive is right. Keep it under 180.";


def halt -> str {
    if _engine is None { return "The rover is not connected."; }
    _engine.stop_motion();
    return "Rover stopped.";
}
sem halt = "Stop the rover immediately. Use this the moment anything looks wrong or the task is finished.";


# ---------------------------------------------------------------------
# The two model-delegated entry points
# ---------------------------------------------------------------------

obj AgentStep {
    has spoken_reply: str = "",
        action_taken: str = "",
        target_found: bool = False,
        should_continue: bool = True;
}

sem AgentStep = "What the agent did on this turn and what it wants to say about it.";
sem AgentStep.spoken_reply = "What to say to the person, in one or two plain sentences. This is read aloud, so avoid lists, symbols and jargon.";
sem AgentStep.action_taken = "A short phrase naming what the rover physically did, or 'nothing' if no tool was used.";
sem AgentStep.target_found = "True only if the object being searched for was actually identified.";
sem AgentStep.should_continue = "True if the agent should keep searching on the next turn, false when finished, blocked, or the target is found.";


"""Let the model decide the rover's next move and narrate it."""
def decide_next_step(goal: str, situation: str) -> AgentStep by brain(
    tools=[look_around, check_surroundings, drive_forward_briefly, turn_towards, halt],
    max_react_iterations=6,
    temperature=0.2
);

sem decide_next_step = "You control a small indoor rover looking for something a person has lost. Check the surroundings before moving. Sweep the camera to see what is around you. If you spot the target, turn towards the angle it was seen at and approach in short steps. Stop as soon as you find it, or if anything is refused or blocked. Be honest when you have not found it - never claim a sighting you cannot support.";
sem decide_next_step.goal = "What the person asked the rover to find.";
sem decide_next_step.situation = "What has happened in the search so far.";


"""Ordinary conversation. No rover, no tools, no mission."""
def converse(message: str, history: str) -> str by brain(temperature=0.7);

sem converse = "You are a small home rover with a warm, easy manner. Chat naturally with the person. Keep replies to a sentence or two, because they are read aloud. You can move around and look for lost things, so offer that if it fits - but do not force it into every reply. Never claim to see or do something you have not actually done.";
sem converse.message = "What the person just said.";
sem converse.history = "The recent conversation, oldest first, for context.";
