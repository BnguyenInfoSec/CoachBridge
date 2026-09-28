import SwiftUI
import UIKit

// MARK: - How did it feel?

/// The question the coach asks after every recorded session. Two taps to answer: pick a face,
/// drag the effort slider. The note is there for the times it matters, and empty the rest.
struct FeelSheet: View {
    let workout: WorkoutSummary
    /// What's already saved, when they're changing an earlier answer.
    var existing: WorkoutFeel?
    let onSave: (WorkoutFeel) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var rpe: Double = 5
    @State private var mood: WorkoutFeel.Mood = .good
    @State private var note = ""
    @State private var loaded = false

    private let tap = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: workout.icon)
                            .font(.title2).foregroundStyle(Palette.color(for: workout.sport))
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(workout.name).font(.headline)
                            Text("\(Int((workout.duration / 60).rounded())) min · \(workout.start.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    HStack(spacing: 0) {
                        ForEach(WorkoutFeel.Mood.allCases) { m in
                            Button {
                                tap.impactOccurred()
                                tap.prepare()
                                withAnimation(.snappy(duration: 0.2)) { mood = m }
                            } label: {
                                VStack(spacing: 5) {
                                    Image(systemName: m.symbol)
                                        .font(.title2)
                                        .symbolVariant(mood == m ? .fill : .none)
                                    Text(m.label)
                                        .font(.caption2)
                                        .multilineTextAlignment(.center)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity)
                                .foregroundStyle(mood == m ? Palette.color(for: workout.sport) : Color.secondary)
                                .scaleEffect(mood == m ? 1.06 : 1)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(m.label)
                            .accessibilityAddTraits(mood == m ? [.isSelected] : [])
                        }
                    }
                    .padding(.vertical, 6)
                } header: {
                    Text("How did it feel?")
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Effort").font(.subheadline)
                            Spacer()
                            Text("\(Int(rpe)) / 10")
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(Palette.color(for: workout.sport))
                        }
                        Slider(value: $rpe, in: 1...10, step: 1) { editing in
                            if !editing { tap.impactOccurred(); tap.prepare() }
                        }
                        Text(WorkoutFeel.rpeLabel(Int(rpe)))
                            .font(.caption).foregroundStyle(.secondary)
                            .animation(.none, value: rpe)
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("Perceived effort")
                } footer: {
                    Text("How hard it felt to you, not what your watch says. This is the part the numbers can't see — an easy ride that felt like an 8 is worth knowing about.")
                }

                Section {
                    TextField("Legs were flat, wind on the way back, nailed the fuelling…",
                              text: $note, axis: .vertical)
                        .lineLimit(2...6)
                } header: {
                    Text("Anything to add (optional)")
                }
            }
            .screenBackground(Palette.color(for: workout.sport))
            .navigationTitle("Log how it went")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(WorkoutFeel(rpe: Int(rpe), mood: mood,
                                           note: note.trimmingCharacters(in: .whitespacesAndNewlines)))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                guard !loaded else { return }
                if let e = existing {
                    rpe = Double(e.rpe)
                    mood = e.mood
                    note = e.note
                }
                tap.prepare()
                loaded = true
            }
        }
    }
}

// MARK: - The prompt

/// Sits under an unanswered workout: the coach asking, rather than a setting the athlete has to
/// go and find.
struct FeelPromptCard: View {
    let sport: Sport
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .font(.title3).foregroundStyle(Palette.color(for: sport))
                VStack(alignment: .leading, spacing: 2) {
                    Text("How did that feel?").font(.subheadline.weight(.semibold))
                    Text("Tell the coach and they'll write back.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The saved answer, once given.
struct FeelRow: View {
    let feel: WorkoutFeel
    let sport: Sport
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: feel.mood.symbol).symbolVariant(.fill)
                    .foregroundStyle(Palette.color(for: sport))
                Text(feel.mood.label).font(.subheadline.weight(.semibold))
                Spacer()
                Text("RPE \(feel.rpe)/10").font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Change", action: onEdit).font(.caption)
            }
            if !feel.note.isEmpty {
                Text(feel.note).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Planned versus actual

struct CompareRows: View {
    let compare: SessionCompare

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(compare.lines) { line in
                HStack(alignment: .firstTextBaseline) {
                    Text(line.label).font(.subheadline)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(line.actual).font(.subheadline.monospacedDigit().weight(.semibold))
                            Image(systemName: symbol(line.status))
                                .font(.caption).foregroundStyle(color(line.status))
                        }
                        Text(line.delta.isEmpty ? "planned \(line.planned)" : "\(line.delta) · planned \(line.planned)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func symbol(_ s: SessionCompare.Status) -> String {
        switch s {
        case .onTarget: return "checkmark.circle.fill"
        case .under: return "arrow.down.circle.fill"
        case .over: return "arrow.up.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private func color(_ s: SessionCompare.Status) -> Color {
        switch s {
        case .onTarget: return .green
        case .under, .over: return .orange
        case .unknown: return .secondary
        }
    }
}

// MARK: - The coach's note

struct CoachNoteCard: View {
    let note: CoachNote
    let sport: Sport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(note.headline)
                .font(.headline)
                .foregroundStyle(Palette.color(for: sport))
            Text(note.body)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if let goal = note.towardGoal {
                Divider()
                Label {
                    Text(goal).font(.footnote).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "target").font(.footnote)
                }
                .foregroundStyle(.secondary)
            }
            if let watch = note.watchFor {
                Label {
                    Text(watch).font(.footnote).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").font(.footnote)
                }
                .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}
