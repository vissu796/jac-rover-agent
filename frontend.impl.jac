"""Client handlers for the conversational rover console."""

impl ChatShell.apply_response(response: ChatResponse) -> None {
    if response.mission_id { mission_id = response.mission_id; }
    mission_state = response.state;
    category = response.category;
    primary_color = response.primary_color;
    size = response.size;
    markings = response.markings;
    last_seen_area = response.last_seen_area;
    can_trigger = response.can_trigger;
    rover_triggered = response.rover_triggered;
    error = response.error;
    if response.assistant_message {
        messages = messages + [UiMessage(role="assistant", text=response.assistant_message)];
    }
}


impl ChatShell.send_message(e: FormEvent) -> None {
    e.preventDefault();
    clean = input_text.strip();
    if not clean or busy { return; }

    messages = messages + [UiMessage(role="user", text=clean)];
    input_text = "";
    busy = True;
    error = "";
    try {
        response = await SendChatMessage(clean, mission_id);
        apply_response(response);
    } except Exception as err {
        error = "The agent service could not process that message. " + str(err);
    } finally {
        busy = False;
    }
}


impl ChatShell.wake_rover -> None {
    if not can_trigger or busy or not mission_id { return; }
    busy = True;
    error = "";
    try {
        response = await ConfirmLostObjectMission(mission_id);
        apply_response(response);
    } except Exception as err {
        error = "The rover precheck did not complete. " + str(err);
    } finally {
        busy = False;
    }
}
