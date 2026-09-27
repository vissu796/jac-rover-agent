"""Phase 1 acceptance tests for mission intake and rover triggering."""

import from missions.lost_found { LostFoundAgent }
import from missions.models {
    CommandReceipt,
    MissionEvent,
    RobotCommand,
    TargetProfile
}


test "agent asks for missing object details" {
    result = root spawn LostFoundAgent(
        goal_text="Find my bottle",
        category="bottle"
    );
    mission = result.reports[0];
    assert mission.state == "COLLECTING_DETAILS";
    assert mission.pending_question == "What is the object's main color?";
    assert len([mission -->[?:TargetProfile]]) == 1;
    assert len([mission -->[?:RobotCommand]]) == 0;
}


test "complete request triggers bounded simulated rover command" {
    result = root spawn LostFoundAgent(
        goal_text="Find my red water bottle",
        category="water bottle",
        primary_color="red",
        size="medium",
        markings="white logo",
        last_seen_area="kitchen"
    );
    mission = result.reports[0];
    commands = [mission -->[?:RobotCommand]];
    receipts = [mission -->[?:CommandReceipt]];
    timeline = [mission -->[?:MissionEvent]];

    assert mission.state == "READY";
    assert mission.outcome == "PENDING";
    assert len(commands) == 1;
    assert commands[0].action == "SET_CAMERA_ANGLE";
    assert commands[0].speed_percent == 0;
    assert commands[0].duration_ms == 0;
    assert commands[0].angle == 90;
    assert len(receipts) == 1;
    assert receipts[0].accepted;
    assert receipts[0].stopped_by == "COMPLETED";
    assert len(timeline) == 4;
}
