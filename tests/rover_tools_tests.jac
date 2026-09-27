"""Safety and semantic-tool tests for the two-motor rover contract."""

import from missions.engine { SearchEngine }
import from robot.contracts {
    SafetyLimits,
    SensorSnapshot,
    new_command,
    scan_angles,
    validate_motion
}
import from robot.transport { SimulatedTransport }


test "camera sweep stays inside conservative servo range" {
    limits = SafetyLimits();
    assert scan_angles(limits, 5) == [45, 67, 90, 112, 135];

    engine = SearchEngine(
        transport=SimulatedTransport(),
        limits=limits,
        mission_id="camera-test"
    );
    left = engine.set_camera_angle(0);
    right = engine.set_camera_angle(180);
    assert left.accepted and left.snapshot.camera_angle == 45;
    assert right.accepted and right.snapshot.camera_angle == 135;
}


test "physical driving is rejected without local safety input" {
    limits = SafetyLimits();
    command = new_command(
        mission_id="interlock-test",
        sequence=1,
        action="MOVE_FORWARD",
        speed_percent=100,
        duration_ms=5000
    );
    checked = validate_motion(
        command,
        limits,
        SensorSnapshot(
            front_distance_cm=999.0,
            bumper_pressed=False,
            undervoltage=False,
            drive_safety_ready=False
        )
    );
    assert not checked.ok;
    assert checked.reason == "DRIVE_INTERLOCK";
}


test "semantic turns map to the two motor rover without raw pwm" {
    transport = SimulatedTransport();
    engine = SearchEngine(
        transport=transport,
        limits=SafetyLimits(),
        mission_id="turn-test"
    );
    left = engine.turn_left(35);
    assert left.accepted;
    assert transport.heading == -35;
    right = engine.turn_right(20);
    assert right.accepted;
    assert transport.heading == -15;
}


test "simulated sweep captures frames and incidental objects" {
    engine = SearchEngine(
        transport=SimulatedTransport(),
        limits=SafetyLimits(),
        mission_id="sweep-test"
    );
    frames = engine.sweep(1);
    labels: list[str] = [];
    for frame in frames {
        labels = labels + frame.observed_labels;
    }
    assert len(frames) == 5;
    assert "chair" in labels;
    assert "shoe" in labels;
    assert "cardboard box" in labels;
}
