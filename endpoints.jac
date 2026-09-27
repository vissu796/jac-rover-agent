"""Public API for Phase 1 of the lost-and-found rover agent."""

import from missions.lost_found { LostFoundAgent }
import from missions.models { Mission, MissionEvent }


def:pub StartLostObjectMission(
    goal_text: str,
    category: str = "",
    primary_color: str = "",
    size: str = "",
    markings: str = "",
    last_seen_area: str = ""
) -> Mission {
    result = root spawn LostFoundAgent(
        goal_text=goal_text,
        category=category,
        primary_color=primary_color,
        size=size,
        markings=markings,
        last_seen_area=last_seen_area
    );
    return result.reports[0];
}


def:pub ListLostObjectMissions -> list[Mission] {
    return [root -->[?:Mission]];
}


def:pub GetMissionTimeline(mission_id: str) -> list[MissionEvent] {
    for mission in [root -->[?:Mission]] {
        if jid(mission) == mission_id {
            return [mission -->[?:MissionEvent]];
        }
    }
    return [];
}
