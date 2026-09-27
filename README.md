# Pi Lost & Found Agent — Interactive Phase 2 Simulation

The app turns a natural-language conversation into a persistent lost-object
mission and runs the complete search loop against a simulated two-motor rover.
Real motor commands remain safety-locked until a local obstacle or bumper input
is connected.

## What works

1. The Jac client provides an interactive chat and live mission profile.
2. Gemini extracts structured target details through Jac `by llm` functions.
3. The conversation persists as `ChatMessage`, `Mission`, and `TargetProfile`
   nodes in the Jac graph.
4. Missing details produce one focused follow-up question.
5. An actionable mission requires explicit user confirmation before the agent
   traverses to the `Robot` node.
6. The confirmed mission runs bounded semantic tools: forward, left/right turn,
   stop, camera positioning, sensor snapshot, and image capture.
7. The servo sweep is limited to 45°–135°, centered at 90°.
8. Every incidental simulated object is persisted as a `Detection` under its
   `Observation`; target matches are marked separately.
9. Real wheel movement fails closed with `DRIVE_INTERLOCK` while the rover has
   no local obstacle/bumper safety input.

## Run it

```bash
jac check .
jac test
GOOGLE_API_KEY="your-key" jac run
```

Open `http://localhost:8000` for the chat interface. API documentation remains
available at `http://localhost:8001/docs` while the dev client is running.

Do not commit the API key or paste it into the chat UI. A local shell export is
also supported:

```bash
export GOOGLE_API_KEY="your-key"
jac run
```

When the target profile is complete, the mission enters
`AWAITING_CONFIRMATION`. Selecting **Run simulation** centers the camera and
runs the bounded simulated search. The dashboard receives a clear found,
not-found, or blocked result.

## Hardware boundary

`PiTransport` uses the same semantic command contract, but drive actions are
rejected unless the Pi reports `drive_safety_ready=true`. Before enabling that
flag, connect and test a local distance sensor or bumper, command expiry,
watchdog stop, undervoltage stop, and a physical emergency stop. Servo and
motor direction calibration also stay local to the Pi edge runtime.
