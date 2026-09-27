"""The tools the model is allowed to call must stay bounded and honest.

These run without an API key: they exercise the tool surface directly, which
is the part that actually touches the rover. Whether the model picks the right
tool is a prompt question; whether a picked tool can do something unsafe is
this file's question.
"""

import from missions.agent {
    bind_engine,
    check_surroundings,
    drive_forward_briefly,
    halt,
    look_around,
    turn_towards
}
import from missions.engine { SearchEngine }
import from robot.contracts { SafetyLimits }
import from robot.transport { SimulatedTransport }


def fresh_engine(drive_ready: bool = True) -> SearchEngine {
    transport = SimulatedTransport();
    if not drive_ready {
        # a pressed bumper is the simplest way to make every drive unsafe
        transport.bumper_pressed = True;
    }
    return SearchEngine(
        transport=transport,
        limits=SafetyLimits(),
        mission_id="tool-test"
    );
}


test "tools refuse to invent a rover when none is attached" {
    bind_engine(None);
    assert "not connected" in look_around();
    assert "not connected" in check_surroundings();
    assert "not connected" in drive_forward_briefly();
    assert "not connected" in turn_towards(30);
}


test "look_around reports what it saw with the angle it saw it at" {
    bind_engine(fresh_engine());
    seen = look_around();
    assert "Swept" in seen;
    assert "chair" in seen;
    assert "degrees" in seen;
}


test "check_surroundings surfaces the sensor facts the model needs" {
    bind_engine(fresh_engine());
    reading = check_surroundings();
    assert "camera at" in reading;
    assert "obstacle" in reading;
}


test "a blocked rover refuses to drive and says why" {
    bind_engine(fresh_engine(drive_ready=False));
    answer = drive_forward_briefly();
    assert "Refused" in answer;
    assert "BUMPER" in answer;
}


test "turning maps sign to direction and stays bounded" {
    sim = SimulatedTransport();
    engine = SearchEngine(transport=sim, limits=SafetyLimits(), mission_id="turn-test");
    bind_engine(engine);

    left = turn_towards(-40);
    assert "Refused" not in left;
    assert sim.heading == -40;

    right = turn_towards(25);
    assert "Refused" not in right;
    assert sim.heading == -15;

    assert turn_towards(0) == "No turn needed.";
}


test "halt always stops, even mid-approach" {
    engine = fresh_engine();
    bind_engine(engine);
    engine.move_forward(600);
    assert halt() == "Rover stopped.";
}
