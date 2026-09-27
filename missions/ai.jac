"""Typed model-delegated reasoning for the lost-object agent.

Every LLM-visible description is a `sem` statement, not a docstring, because
`sem` is what actually reaches the prompt. These functions return `obj` values
only: the walker copies validated fields into graph nodes, so a model change
can never reshape stored mission evidence.

Nothing here may return a motor value. The model describes what it sees and
what it believes; `robot/contracts.jac` decides what the rover is allowed to do.
"""

import from jaclang.byllm.lib { Image, Model }


# --- model split -------------------------------------------------------
# Three providers, chosen per job rather than one model for everything:
#
#   brain   OpenAI      orchestration, conversation, tool selection.
#                       Called a handful of times per mission.
#   vision  Together    frame analysis. A 30-170 degree sweep is 8-15 images
#                       per cycle and several cycles per mission, so this runs
#                       50x more often than the brain and cost dominates.
#
# Voice (ElevenLabs) is not here: it runs on the Pi itself, next to the mic
# and speaker, so a spoken reply never makes a round trip to this machine.

glob brain: Model = Model(model_name="gpt-4o");
glob vision: Model = Model(model_name="together_ai/Qwen/Qwen2.5-VL-7B-Instruct");


obj TargetSpec {
    has category: str = "",
        primary_color: str = "",
        secondary_color: str = "",
        size: str = "",
        shape: str = "",
        material: str = "",
        markings: str = "",
        last_seen_area: str = "",
        is_living: bool = False,
        confident_enough: bool = False;
}

sem TargetSpec = "A structured description of a single object the user has lost.";
sem TargetSpec.category = "The kind of object, one or two words, lowercase. Example: 'water bottle', 'keys', 'glasses'.";
sem TargetSpec.primary_color = "The dominant colour as a single common word, lowercase. Empty string if unknown.";
sem TargetSpec.secondary_color = "A second notable colour, or empty string if there is none or it is unknown.";
sem TargetSpec.size = "Rough size: one of 'small', 'medium', 'large'. Empty string if unknown.";
sem TargetSpec.shape = "Basic geometry in one or two words, such as 'cylindrical' or 'flat rectangular'. Empty if unknown.";
sem TargetSpec.material = "Material if stated or strongly implied, such as 'metal', 'plastic', 'fabric'. Empty if unknown.";
sem TargetSpec.markings = "Distinctive markings, logos or patterns that separate this item from similar ones. Empty if unknown.";
sem TargetSpec.last_seen_area = "Where the user last saw it, such as 'living room'. Empty string if not mentioned.";
sem TargetSpec.is_living = "True only if the target is a person or an animal rather than an inanimate object.";
sem TargetSpec.confident_enough = "True when category plus at least one distinguishing feature are known, so a visual search could plausibly succeed.";


"""Turn the user's free-text request into a structured search target."""
def extract_target(description: str) -> TargetSpec by brain(temperature=0.1);

sem extract_target = "Extract a structured description of the lost item from the user's message. Infer only what the message supports; leave unknown fields as empty strings rather than guessing.";
sem extract_target.description = "What the user said they lost, in their own words.";


"""Ask at most one high-value follow-up question, or nothing if ready."""
def next_detail_question(spec: TargetSpec) -> str by brain(temperature=0.2);

sem next_detail_question = "Given what is already known about the lost item, return ONE short question that would most improve a camera search. Ask only about visually distinguishing features. Return an empty string if enough is known to start searching.";
sem next_detail_question.spec = "What is currently known about the lost item.";


"""Merge the user's answer into the existing target description."""
def refine_target(spec: TargetSpec, question: str, answer: str) -> TargetSpec by brain(temperature=0.1);

sem refine_target = "Update the known description of the lost item using the user's answer to the question. Preserve fields the answer does not touch.";
sem refine_target.spec = "What was already known before this answer.";
sem refine_target.question = "The question that was asked.";
sem refine_target.answer = "The user's reply.";


obj DetectionCandidate {
    has found: bool = False,
        label: str = "",
        confidence: float = 0.0,
        image_index: int = 0,
        centered: bool = False,
        rationale: str = "";
}

sem DetectionCandidate = "A single possible sighting of the target in one captured frame.";
sem DetectionCandidate.found = "True only if the target appears in one of the images.";
sem DetectionCandidate.label = "What the matching object actually is, in the image, in a few words.";
sem DetectionCandidate.confidence = "How certain the match is, from 0.0 to 1.0. Be conservative: use below 0.5 when the object is partly hidden, blurry, or merely similar.";
sem DetectionCandidate.image_index = "Zero-based index of the image containing the best match. 0 when nothing was found.";
sem DetectionCandidate.centered = "True if the match sits near the horizontal centre of its frame rather than at an edge.";
sem DetectionCandidate.rationale = "One sentence explaining what visual evidence supports or undermines the match.";


"""Look for the target across one camera sweep of frames."""
def analyze_scan(images: list[Image], target_description: str) -> DetectionCandidate by vision(temperature=0.1);

sem analyze_scan = "Examine the images, captured left-to-right in one camera sweep, and decide whether the described object appears in any of them. Report the single best match. If nothing matches, set found to false rather than offering the closest unrelated object.";
sem analyze_scan.images = "Frames from one camera sweep, ordered by increasing camera angle.";
sem analyze_scan.target_description = "The object being searched for.";


"""Confirm a candidate after the rover has turned to face it."""
def verify_candidate(image: Image, target_description: str) -> DetectionCandidate by vision(temperature=0.1);

sem verify_candidate = "The rover has turned toward a suspected match and captured one centred frame. Confirm whether the described object is really there. Treat this as a second opinion: disagree with the earlier guess if the evidence does not support it.";
sem verify_candidate.image = "A single centred frame captured after turning toward the candidate.";
sem verify_candidate.target_description = "The object being searched for.";


obj MissionSummary {
    has headline: str = "",
        detail: str = "";
}

sem MissionSummary = "A short, honest account of how the search ended, written for the person who asked.";
sem MissionSummary.headline = "One sentence stating the outcome plainly. No preamble.";
sem MissionSummary.detail = "Two or three sentences covering what the rover did, what it saw, and why it stopped. State uncertainty plainly; never imply the rover is more certain than the confidence supports.";


"""Write the closing report from the recorded mission facts."""
def write_summary(
    target_description: str,
    outcome: str,
    cycles_used: int,
    stop_reason: str,
    best_label: str,
    best_confidence: float
) -> MissionSummary by brain(temperature=0.3);

sem write_summary = "Write the final mission report using only the facts supplied. Do not invent observations the rover did not make.";
sem write_summary.target_description = "What the rover was looking for.";
sem write_summary.outcome = "One of FOUND, NOT_FOUND, BLOCKED, CANCELLED, ERROR.";
sem write_summary.cycles_used = "How many scan cycles the rover completed.";
sem write_summary.stop_reason = "The deterministic reason the mission ended, from the safety layer.";
sem write_summary.best_label = "What the best candidate was identified as, or empty if nothing was found.";
sem write_summary.best_confidence = "Confidence of the best candidate, 0.0 when nothing was found.";
