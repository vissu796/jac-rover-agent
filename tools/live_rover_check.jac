"""Drive the REAL rover through the Jac tool layer.

Proves the whole chain end to end:

    SearchEngine tool  ->  contracts validation  ->  PiTransport HTTP
                       ->  rover_server.py on the Pi  ->  servo / camera

Nothing here is simulated. Run it with the rover powered and
`rover-agent.service` up:

    jac tools/live_rover_check.jac

Drive commands are expected to be REFUSED while the edge runtime is disarmed.
That refusal is the point: it shows the interlock works before any wheel turns.
"""

import from missions.engine { SearchEngine }
import from robot.contracts { SafetyLimits }
import from robot.transport { PiTransport }


with entry:__main__ {
    engine = SearchEngine(
        transport=PiTransport(),
        limits=SafetyLimits(),
        mission_id="live-check"
    );

    print("=== 1. sensors ===");
    snapshot = engine.get_sensor_snapshot();
    print(f"  camera_angle       : {snapshot.camera_angle}");
    print(f"  front_distance_cm  : {snapshot.front_distance_cm}");
    print(f"  undervoltage       : {snapshot.undervoltage}");
    print(f"  drive_safety_ready : {snapshot.drive_safety_ready}");

    print("\n=== 2. precheck ===");
    blocker = engine.precheck();
    print(f"  {'clear' if not blocker else blocker}");

    print("\n=== 3. camera tools (servo should physically move) ===");
    for angle in [45, 90, 135] {
        moved = engine.set_camera_angle(angle);
        print(f"  set_camera_angle({angle}) -> {moved.stopped_by}: {moved.detail}");
    }

    print("\n=== 4. clamping is enforced on the rover too ===");
    low = engine.set_camera_angle(-30);
    high = engine.set_camera_angle(999);
    print(f"  asked -30  -> camera now {low.snapshot.camera_angle}");
    print(f"  asked 999  -> camera now {high.snapshot.camera_angle}");

    print("\n=== 5. drive must be REFUSED while disarmed ===");
    forward = engine.move_forward(600);
    turn = engine.turn_left(30);
    print(f"  move_forward -> accepted={forward.accepted} {forward.stopped_by}");
    print(f"  turn_left    -> accepted={turn.accepted} {turn.stopped_by}");

    print("\n=== 6. full camera sweep with real capture ===");
    frames = engine.sweep(1);
    print(f"  captured {len(frames)} frames");
    for frame in frames {
        print(f"    {frame.camera_angle:>3} deg  incidental={frame.observed_labels}");

    }
    engine.park();
    print("\n=== done: camera centred, motors untouched ===");
}
