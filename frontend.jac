"""Conversational command console for the lost-and-found rover."""

import from missions.chat {
    ChatResponse,
    ConfirmLostObjectMission,
    SendChatMessage
}


obj UiMessage {
    has role: str,
        text: str;
}


def:pub RoverGlyph -> JsxElement {
    <svg viewBox="0 0 48 48" aria-hidden="true" className="rover-glyph">
        <path d="M16 15h16l4 9v8H12v-8l4-9Z" fill="none" stroke="currentColor" strokeWidth="2"/>
        <circle cx="18" cy="34" r="4" fill="none" stroke="currentColor" strokeWidth="2"/>
        <circle cx="30" cy="34" r="4" fill="none" stroke="currentColor" strokeWidth="2"/>
        <path d="M24 15V9m-4 0h8M17 24h2m10 0h2" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
    </svg>
}


def:pub MessageBubble(message: UiMessage) -> JsxElement {
    bubble_class = "message message-user" if message.role == "user" else "message message-agent";
    <div className={bubble_class}>
        <span className="message-role">{"You" if message.role == "user" else "Rover agent"}</span>
        <p>{message.text}</p>
    </div>
}


def:pub TargetFact(label: str, value: str) -> JsxElement {
    <div className="target-fact">
        <span>{label}</span>
        <strong>{value if value else "Not known"}</strong>
    </div>
}


def:pub ChatShell -> JsxElement {
    has messages: list[UiMessage] = [
            UiMessage(
                role="assistant",
                text="Tell me what you lost. I’ll gather the visual details and prepare a safe rover mission."
            )
        ],
        input_text: str = "",
        mission_id: str = "",
        mission_state: str = "IDLE",
        category: str = "",
        primary_color: str = "",
        size: str = "",
        markings: str = "",
        last_seen_area: str = "",
        can_trigger: bool = False,
        rover_triggered: bool = False,
        busy: bool = False,
        error: str = "";

    async def send_message(e: FormEvent) -> None;
    async def wake_rover -> None;
    def apply_response(response: ChatResponse) -> None;

    state_class = "status-dot status-live" if mission_state == "READY" else "status-dot";

    <main className="command-center">
        <header className="topbar">
            <div className="brand-lockup">
                <div className="mark"><RoverGlyph/></div>
                <div>
                    <h1>Lost & Found</h1>
                    <p>Jac rover command console</p>
                </div>
            </div>
            <div className="system-status" aria-live="polite">
                <span className={state_class}></span>
                <span>{mission_state.replace("_", " ")}</span>
            </div>
        </header>

        <section className="workspace">
            <div className="chat-panel">
                <div className="chat-heading">
                    <div>
                        <h2>Describe the missing object</h2>
                        <p>The agent will ask only for details that improve the visual search.</p>
                    </div>
                    <span className="phase-tag">Simulation mode</span>
                </div>

                <div className="message-list" aria-live="polite">
                    {[<MessageBubble key={idx} message={item}/> for (idx, item) in enumerate(messages)]}
                    {<div className="thinking"><span></span><span></span><span></span></div> if busy else None}
                </div>

                {<div className="error-banner" role="alert">{error}</div> if error else None}

                <form className="composer" onSubmit={send_message}>
                    <label htmlFor="agent-message">Message the agent</label>
                    <div className="composer-row">
                        <textarea
                            id="agent-message"
                            value={input_text}
                            onChange={lambda (e: ChangeEvent) { input_text = e.target.value; }}
                            placeholder="I lost my red water bottle in the kitchen..."
                            rows={2}
                            disabled={busy or rover_triggered}
                        />
                        <button type="submit" disabled={busy or not input_text.strip() or rover_triggered}>
                            <span>Send</span>
                            <svg viewBox="0 0 20 20" aria-hidden="true"><path d="m4 10 11-6-3 12-2-5-6-1Z" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinejoin="round"/></svg>
                        </button>
                    </div>
                </form>
            </div>

            <aside className="mission-panel">
                <div className="mission-heading">
                    <span>Mission profile</span>
                    <strong>{mission_state.replace("_", " ")}</strong>
                </div>
                <div className="target-visual">
                    <div className="scan-reticle"><span></span></div>
                    <p>{category if category else "Awaiting target"}</p>
                </div>
                <div className="target-grid">
                    <TargetFact label="Object" value={category}/>
                    <TargetFact label="Color" value={primary_color}/>
                    <TargetFact label="Size" value={size}/>
                    <TargetFact label="Last seen" value={last_seen_area}/>
                    <div className="target-fact target-wide">
                        <span>Distinctive markings</span>
                        <strong>{markings if markings else "Not known"}</strong>
                    </div>
                </div>
                <div className="safety-note">
                    <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3 4.5 6v5.5c0 4.4 3 7.7 7.5 9.5 4.5-1.8 7.5-5.1 7.5-9.5V6L12 3Z" fill="none" stroke="currentColor" strokeWidth="1.6"/><path d="m9 12 2 2 4-5" fill="none" stroke="currentColor" strokeWidth="1.6"/></svg>
                    <p><strong>Simulation only.</strong> The full search loop runs against a virtual two-motor rover. Real wheel commands stay locked until a local obstacle or bumper input is connected.</p>
                </div>
                <button className="wake-button" onClick={wake_rover} disabled={not can_trigger or busy or rover_triggered}>
                    <RoverGlyph/>
                    <span>{"Search complete" if mission_state == "COMPLETE" else ("Rover active" if rover_triggered else "Run simulation")}</span>
                </button>
            </aside>
        </section>
    </main>
}
