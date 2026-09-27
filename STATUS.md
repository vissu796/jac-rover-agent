# Project status — actively evolving

> **This is a work in progress, not a finished product.** It is being built
> during a hackathon and changes hour to hour. Anything below marked *in
> progress* or *not started* is exactly that — please read this file before
> judging what the code claims to do.

Last updated: 2026-09-27

---

## What this is

A Jac-native agent that gives a Raspberry Pi rover a body: a person describes
something they have lost, the agent turns that into a bounded physical search
mission, drives the rover's camera and wheels through validated tools, and
reports back with evidence it actually gathered.

The design rule the whole project is built around:

> **The model proposes; deterministic code decides.**
> An LLM never produces a motor value. It selects from a fixed menu of bounded
> tools, and every selection is clamped, expiry-checked and re-validated on the
> rover itself before a wheel turns.

---

## Working today

| Area | State | Notes |
|---|---|---|
| Graph model | Working | Missions, targets, scan cycles, observations, detections, safety events persisted as Jac nodes |
| Bounded command contracts | Working | Clamping, expiry, idempotency, drive interlock — `robot/contracts.jac` |
| Simulated rover | Working | Same contract as the real one, so the demo survives hardware failure |
| Rover tool layer | Working | `move_forward`, `turn_left/right`, `set_camera_angle`, `sweep`, `capture_image`, `stop_motion` |
| Agentic tool loop | Working | Model chooses tools via `by brain(tools=[...])` — `missions/agent.jac` |
| Conversational chat | Working | Separate from missions; no rover, no tools |
| Tests | 12 passing | `jac test` |
| Camera + servo on real hardware | Working | Verified end to end: Jac → contracts → HTTP → Pi → servo sweep + real captures |

## In progress

| Area | State |
|---|---|
| Vision on real frames | Wired (frames fetch to the host, Together VLM configured) — **not yet validated against real captures** |
| Agent loop driving real missions | The mission walker is still the scripted loop; `decide_next_step` is not yet wired into it |
| Two-motor drive | Both motors verified individually and together on the bench; **drive is disarmed in the edge runtime** pending a distance sensor |

## Not started

- **Voice** — ElevenLabs STT/TTS on the Pi, with a "My Dear" wake word. Planned to run on the rover so a spoken reply never round-trips to a laptop.
- **Porting the edge runtime to Jac** — currently Python (`gpiozero` / `picamera2`). Note that GPIO code *cannot* compile to Jac's native machine-code pathway, because Python imports force demotion; the honest claim is "hardware adapter written in Jac", not "native".
- **Wheel encoders / return-to-home** — deliberately excluded. Open-loop TT motors give no reliable pose estimate, so claiming autonomous return would be misleading.

---

## Known issues

- **The Pi resets intermittently while driving.** Seen three times. Logs do not
  survive, which points at abrupt power loss rather than a software fault.
  Suspected cause is motor brush noise / inrush with no suppression fitted.
  Mitigation (not yet applied): 0.1µF ceramics across each motor, bulk
  capacitor across each driver's VS/GND.
- **Camera aim is unverified.** Captures are real and correctly formatted, but
  the test frames came back featureless — the lens needs pointing at something
  before vision results mean anything.
- **Servo range is conservative.** Limited to 45–135° rather than the intended
  30–170° until the mechanical endpoints are calibrated. A stalled servo draws
  500mA+, which is a prime suspect for the resets above.
- **`jac install` is broken on the dev machine** — the bundled Python 3.14
  cannot create a venv (`_posixsubprocess` symbol error). Worked around by
  building `.jac/venv` by hand with cp314 wheels.

---

## Architecture

```
person (web chat or voice)
        │
        ▼
  conversation / mission walker        ← Jac, owns the graph
        │
        ▼
  typed `by llm` reasoning             ← returns obj, never node
        │
        ▼
  bounded tool selection               ← model picks from a fixed menu
        │
        ▼
  contracts: clamp · expire · validate ← deterministic, not model-controlled
        │
        ▼
  transport (simulated | real Pi)      ← identical contract either way
        │
        ▼
  edge runtime on the rover            ← re-validates everything, watchdog, interlock
        │
        ▼
  motors · servo · camera
```

### Models

Three providers, chosen per job rather than one model for everything:

| Job | Model | Why |
|---|---|---|
| Orchestration, chat, reports | OpenAI | Called a handful of times per mission |
| Frame analysis | Together (Qwen VL) | A sweep is 8–15 images per cycle; this runs ~50× more often, so cost dominates |
| Voice | ElevenLabs | Runs on the Pi itself, next to the mic and speaker |

---

## Running it

```bash
jac check          # type-check the whole workspace
jac test           # 12 tests, no API keys needed
jac run --dev main.jac
```

Simulation is the default, so none of the above requires a rover.

To drive real hardware you also need the edge runtime on the Pi and these in
your environment:

```
OPENAI_API_KEY=      # orchestration
TOGETHER_API_KEY=    # vision
```

---

## Safety notes for anyone running this

- Drive is **disarmed by default** in the edge runtime. Motor commands are
  refused with `DRIVE_INTERLOCK` until it is started with `--arm-drive`. That
  is a deliberate human action and the agent cannot request it.
- Raise the wheels before any powered test.
- There is no bumper or distance sensor fitted yet. Until there is, autonomous
  driving should stay disarmed.
