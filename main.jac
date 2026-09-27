"""Interactive lost-and-found rover agent entry point."""

import from endpoints {
    StartLostObjectMission,
    ListLostObjectMissions,
    GetMissionTimeline
}
import from missions.chat {
    SendChatMessage,
    ConfirmLostObjectMission,
    GetChatHistory
}

import "./assets/main.css";
import from .frontend { ChatShell }


def:pub app -> JsxElement {
    <ChatShell/>
}
