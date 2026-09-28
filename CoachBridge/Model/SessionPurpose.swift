import Foundation

/// Why a session is on the plan, in the coach's voice: what it does, and what that builds.
///
/// Written from the session's sport, effort and phase rather than asked of the model. Every
/// session on every day needs one, and a request per session would cost money on every screen;
/// this is free, instant, the same every time you look, and tested.
enum SessionPurpose {
    /// Two or three sentences: what it does, what it builds, and where it fits in this block.
    static func text(for s: PlanSession, phaseID: String) -> String {
        [what(s), phaseLine(phaseID, s)].compactMap { $0 }.joined(separator: " ")
    }

    // MARK: What this session does

    static func what(_ s: PlanSession) -> String {
        let title = s.title.lowercased()
        let detail = s.detail.lowercased()
        let sport = Prescriber.sport(of: s)
        let effort = Prescriber.effort(of: s, sport: sport)
        let minutes = s.rx?.durationMin ?? Prescriber.parseVolume(s.detail, fraction: 0.5, sport: sport).minutes ?? 0

        switch s.kind {
        case .rest:
            return "Rest is where the training turns into fitness. The work breaks you down a little; today your body rebuilds a little stronger, and it can only do that if you let it."
        case .golf:
            return "Time on your feet at an easy effort, and a break for the head. It counts as light aerobic work, not a key session."
        case .snow:
            return "Leg strength in disguise: the descents load your quads the way hills do, with plenty of rest on the lift."
        case .fun:
            return "Something outside the training structure. It counts for what it is: enjoy it, and keep the next day's session as planned unless it took more out of you than expected."
        default:
            break
        }

        let bonus = s.kind == .flex
            ? " It's optional: extra easy time if you feel good, and skipping it costs nothing."
            : ""

        if title.contains("brick") || detail.contains("run off") || detail.contains("off the bike") {
            return "A brick: running straight off the bike teaches your legs to switch from pedalling to running, so the first mile of the race run feels familiar instead of like wood."
        }
        if sport == .lift || effort == .strength {
            return "Strength work to make you harder to break. Stronger hips, glutes and core hold your form late in the run, when it usually falls apart, and cut the injury risk that comes with more volume."
        }
        switch effort {
        case .sweetSpot:
            return "Sweet spot, just under threshold. It raises your FTP, the ceiling your race effort sits under, for much less fatigue than going above it, so race pace becomes a smaller share of what you can do."
        case .imPace:
            return "Race-specific work at goal effort. We're rehearsing race pace until it feels automatic, and testing fuelling at the intensity you'll actually race, so neither is a surprise on the day."
        case .steady:
            return "A steady, firm effort held for a long time. It builds muscular endurance, the ability to keep pushing without fading, which is what the middle of a long race asks for."
        case .recovery:
            return "Easy on purpose. Gentle movement moves blood through tired legs and clears the last hard session faster than sitting still.\(bonus)"
        default:
            break
        }

        let long = title.contains("long") || (sport == .bike && minutes >= 120) || (sport == .run && minutes >= 80)
            || (sport == .swim && minutes >= 60)
        if long {
            switch sport {
            case .bike:
                return "The long ride. We're building endurance and teaching your gut to take in fuel while working, the two things that decide how the back half of the race goes.\(bonus)"
            case .run:
                return "The long run. It builds the durability in your legs and the aerobic reach to keep running late in the race, when everyone else starts walking.\(bonus)"
            case .swim:
                return "A long swim to build the endurance to hold form for the whole distance, so you come out of the water with energy left for the bike.\(bonus)"
            default:
                break
            }
        }

        switch sport {
        case .swim:
            return "Easy aerobic swimming with a focus on technique. Smooth, relaxed laps build the efficiency that makes the race swim cheaper, so you save your legs and lungs for later.\(bonus)"
        case .bike:
            return "Easy zone 2 riding builds the aerobic engine: more capillaries and mitochondria, and a body that burns fat well. That engine is what carries you through a long bike leg without burning matches.\(bonus)"
        case .run:
            return "Easy running builds durability. Tendons, bones and your aerobic system adapt to the miles without the injury cost of running hard. Keep it conversational.\(bonus)"
        default:
            return s.kind == .flex
                ? "Optional easy movement if you feel good. Skipping it costs nothing."
                : "Time moving at an easy effort, adding to your aerobic base without adding much fatigue."
        }
    }

    // MARK: Where it fits

    static func phaseLine(_ phaseID: String, _ s: PlanSession) -> String? {
        guard s.kind != .rest else { return nil }
        switch phaseID {
        case "rec":
            return "In the Recovery block the goal is to arrive at the real training fresh, so nothing here should feel hard."
        case "b1":
            return "In Base 1 we're laying the foundation: aerobic fitness and consistency that everything later stacks on."
        case "b2":
            return "In Base 2 the foundation gets longer and a little firmer, so Build has something solid to work from."
        case "build":
            return "In Build the work gets specific to race day: longer, closer to race effort, and fuelled like the race."
        case "taper":
            return "In the taper the job is to arrive fresh: keep the sharpness, shed the fatigue, and trust the work that's done."
        default:
            return nil
        }
    }
}
