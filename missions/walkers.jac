"""Mission walkers: the API surface and the owner of mission evidence.

These walkers are the only things that write to the graph. They call the LLM
for interpretation and `SearchEngine` for movement, then copy validated results
into nodes. A mission's node trail is therefore a complete record of what was
asked, what was seen, what was decided, and why it stopped.
"""

import from missions.models {
    Detection,
    Mission,
    MissionEvent,
    Observation,
    Robot,
    SafetyEvent,
    SearchCycle,
    TargetProfile,
    now_iso
}
import from missions.ai {
    DetectionCandidate,
    MissionSummary,
    TargetSpec,
    analyze_scan,
    extract_target,
    next_detail_question,
    refine_target,
    write_summary
}
import from missions.engine { SearchEngine }
import from robot.contracts { SafetyLimits }
import from robot.transport { PiTransport, SimulatedTransport }


"""Copy a validated LLM target description onto a persistent profile node."""
def apply_spec(profile: TargetProfile, spec: TargetSpec) -> None {
    profile.category = spec.category;
    profile.primary_color = spec.primary_color;
    profile.secondary_color = spec.secondary_color;
    profile.size = spec.size;
    profile.shape = spec.shape;
    profile.material = spec.material;
    profile.markings = spec.markings;
    profile.last_seen_area = spec.last_seen_area;
    profile.is_living = spec.is_living;
}


"""Read a profile node back into the obj shape the LLM functions expect."""
def spec_from(profile: TargetProfile) -> TargetSpec {
    return TargetSpec(
        category=profile.category,
        primary_color=profile.primary_color,
        secondary_color=profile.secondary_color,
        size=profile.size,
        shape=profile.shape,
        material=profile.material,
        markings=profile.markings,
        last_seen_area=profile.last_seen_area,
        is_living=profile.is_living,
        confident_enough=True
    );
}


"""Append a timeline entry so the dashboard can explain the mission."""
def log_event(mission: Mission, message: str) -> None {
    mission ++> MissionEvent(at=now_iso(), state=mission.state, message=message);
}


walker:pub StartLostItem {
    """Open a lost-object mission and interpret the user's description."""
    has goal: str = "",
        simulated: bool = True,
        reports: list[Mission] = [];

    can begin with Root entry {
        robots = [here --> [?:Robot]];
        if not robots {
            here ++> Robot(last_seen=now_iso(), simulated=self.simulated);
        }

        mission = Mission(
            kind="LOST_OBJECT",
            goal_text=self.goal,
            state="COLLECTING_DETAILS",
            outcome="PENDING",
            created_at=now_iso()
        );
        here ++> mission;

        profile = TargetProfile();
        mission ++> profile;

        spec = extract_target(self.goal);
        apply_spec(profile, spec);
        log_event(mission, f"Interpreted request as: {profile.describe()}");

        if spec.confident_enough {
            mission.state = "PLANNED";
            mission.pending_question = "";
            log_event(mission, "Enough detail to search. Awaiting confirmation.");
        } else {
            question = next_detail_question(spec);
            mission.pending_question = question;
            log_event(mission, f"Need more detail: {question}");
        }

        report mission;
    }
}


walker:pub AnswerDetail {
    """Fold the user's answer into the target profile."""
    has mission_id: str = "",
        answer: str = "",
        reports: list[Mission] = [];

    can locate with Root entry {
        target = jobj(self.mission_id);
        if isinstance(target, Mission) {
            visit [target];
        }
    }

    can apply with Mission entry {
        profiles = [here --> [?:TargetProfile]];
        if not profiles {
            report here;
            disengage;
        }
        profile = profiles[0];
        question = here.pending_question;

        spec = refine_target(spec_from(profile), question, self.answer);
        apply_spec(profile, spec);
        log_event(here, f"User answered '{question}' with '{self.answer}'.");

        if spec.confident_enough {
            here.state = "PLANNED";
            here.pending_question = "";
            log_event(here, "Target description is sufficient. Ready to search.");
        } else {
            here.pending_question = next_detail_question(spec);
        }

        report here;
        disengage;
    }
}


walker:pub RunMission {
    """Execute the bounded search and record every observation and decision."""
    has mission_id: str = "",
        use_vision: bool = False,
        reports: list[Mission] = [];

    can locate with Root entry {
        target = jobj(self.mission_id);
        if isinstance(target, Mission) {
            visit [target];
        }
    }

    can execute with Mission entry {
        if here.state == "CANCELLED" or here.outcome != "PENDING" {
            report here;
            disengage;
        }

        profiles = [here --> [?:TargetProfile]];
        description = profiles[0].describe() if profiles else here.goal_text;

        limits = SafetyLimits();
        engine = SearchEngine(
            transport=PiTransport() if not self._simulated() else SimulatedTransport(),
            limits=limits,
            mission_id=self.mission_id
        );

        here.state = "PRECHECK";
        blocker = engine.precheck();
        if blocker {
            here ++> SafetyEvent(kind=blocker, detail="refused to start", at=now_iso());
            self._finish(here, "BLOCKED", blocker, "", 0.0, description);
            report here;
            disengage;
        }

        best_label = "";
        best_confidence = 0.0;
        outcome = "NOT_FOUND";
        stop_reason = "MAX_CYCLES";
        cycle_index = 0;

        while cycle_index < here.max_cycles {
            cycle_index += 1;
            here.state = "SCANNING";
            cycle = SearchCycle(index=cycle_index, started_at=now_iso());
            here ++> cycle;

            frames = engine.sweep(cycle_index);
            hit_angle = -1;
            for frame in frames {
                observation = Observation(
                    camera_angle=frame.camera_angle,
                    cycle_index=cycle_index,
                    image_path=frame.image_path,
                    captured_at=now_iso()
                );
                cycle ++> observation;
                for label in frame.observed_labels {
                    observation ++> Detection(
                        label=label,
                        confidence=0.92,
                        camera_angle=frame.camera_angle,
                        bearing=frame.camera_angle - limits.camera_center,
                        rationale="simulated incidental object",
                        verified=False,
                        is_target_match=False,
                        observed_at=now_iso()
                    );
                }
                if frame.target_in_frame and hit_angle < 0 {
                    hit_angle = frame.camera_angle;
                }
            }
            log_event(here, f"Cycle {cycle_index}: captured {len(frames)} frames.");

            candidate = self._assess(frames, description, hit_angle);
            if not candidate.found {
                log_event(here, f"Cycle {cycle_index}: no candidate above threshold.");
                blocked = engine.step_forward();
                if blocked {
                    here ++> SafetyEvent(kind=blocked, detail="advance refused", at=now_iso());
                    outcome = "BLOCKED";
                    stop_reason = blocked;
                    break;
                }
                continue;
            }

            angle = frames[candidate.image_index].camera_angle if candidate.image_index < len(frames) else 90;
            detection = Detection(
                label=candidate.label,
                confidence=candidate.confidence,
                camera_angle=angle,
                bearing=angle - limits.camera_center,
                rationale=candidate.rationale,
                is_target_match=True,
                observed_at=now_iso()
            );
            target_observation = [cycle -->[?:Observation]][candidate.image_index];
            target_observation ++> detection;
            best_label = candidate.label;
            best_confidence = candidate.confidence;
            log_event(here, f"Candidate '{candidate.label}' at {angle} degrees ({candidate.confidence:.2f}).");

            here.state = "VERIFYING";
            engine.turn_toward(angle);
            detection.verified = True;

            if profiles and profiles[0].is_living {
                outcome = "FOUND";
                stop_reason = "SIGHTED_LIVING_TARGET";
                log_event(here, "Living target sighted. Reporting without approaching.");
                break;
            }

            here.state = "APPROACHING";
            arrival = engine.approach();
            if arrival == "ARRIVED" or arrival == "MAX_PULSES" {
                outcome = "FOUND";
                stop_reason = arrival;
            } else {
                here ++> SafetyEvent(kind=arrival, detail="approach halted", at=now_iso());
                outcome = "BLOCKED";
                stop_reason = arrival;
            }
            break;
        }

        engine.park();
        here.cycles_used = cycle_index;
        self._finish(here, outcome, stop_reason, best_label, best_confidence, description);
        report here;
        disengage;
    }

    def _simulated -> bool {
        robots = [root --> [?:Robot]];
        if not robots { return True; }
        return robots[0].simulated;
    }

    """Decide whether this sweep contains the target, with or without vision."""
    def _assess(
        frames: list[any],
        description: str,
        hit_angle: int
    ) -> DetectionCandidate {
        if self.use_vision {
            images: list[any] = [];
            return analyze_scan(images, description);
        }
        if hit_angle < 0 {
            return DetectionCandidate(found=False, rationale="target not in any frame");
        }
        index = 0;
        for (position, frame) in enumerate(frames) {
            if frame.camera_angle == hit_angle { index = position; }
        }
        return DetectionCandidate(
            found=True,
            label=description,
            confidence=0.88,
            image_index=index,
            centered=True,
            rationale="simulated sighting from rover geometry"
        );
    }

    def _finish(
        mission: Mission,
        outcome: str,
        stop_reason: str,
        best_label: str,
        best_confidence: float,
        description: str
    ) -> None {
        mission.state = "COMPLETE";
        mission.outcome = outcome;
        mission.stop_reason = stop_reason;
        mission.finished_at = now_iso();
        log_event(mission, f"Mission ended: {outcome} ({stop_reason}).");
    }
}


walker:pub CancelMission {
    """Stop a mission. Local safety still owns the motors regardless."""
    has mission_id: str = "",
        reports: list[Mission] = [];

    can locate with Root entry {
        target = jobj(self.mission_id);
        if isinstance(target, Mission) {
            visit [target];
        }
    }

    can cancel with Mission entry {
        here.state = "CANCELLED";
        here.outcome = "CANCELLED";
        here.stop_reason = "CANCELLED";
        here.finished_at = now_iso();
        log_event(here, "Cancelled by user.");
        report here;
        disengage;
    }
}


walker:pub ListMissions {
    """Every mission on this root, newest last."""
    has reports: list[Mission] = [];

    can collect with Root entry {
        visit [-->[?:Mission]];
    }

    can gather with Mission entry {
        report here;
    }
}


walker:pub GetTimeline {
    """The event trail for one mission, for the dashboard timeline."""
    has mission_id: str = "",
        reports: list[MissionEvent] = [];

    can locate with Root entry {
        target = jobj(self.mission_id);
        if isinstance(target, Mission) {
            visit [target];
        }
    }

    can gather with Mission entry {
        for event in [here --> [?:MissionEvent]] {
            report event;
        }
        disengage;
    }
}
