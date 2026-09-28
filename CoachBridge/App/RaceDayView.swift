import SwiftUI

/// Race day on one page: effort for each leg and the fuelling timeline. Also sent to the Watch
/// the day before and on race morning.
struct RaceDayView: View {
    let plan: RaceDayPlan
    var projection: RaceProjection? = nil

    var body: some View {
        List {
            if let projection {
                Section {
                    ForEach(projection.legs) { leg in
                        HStack(alignment: .firstTextBaseline) {
                            Label(leg.label, systemImage: leg.sport.symbol).foregroundStyle(Palette.color(for: leg.sport))
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(RaceProjection.clock(leg.seconds)).font(.subheadline.monospacedDigit().weight(.semibold))
                                Text(leg.basis.text).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                            }
                        }
                    }
                    if projection.transitions > 0 {
                        LabeledContent("Transitions", value: RaceProjection.clock(projection.transitions))
                    }
                    LabeledContent("Finish") {
                        Text("\(RaceProjection.clock(projection.total))  (\(RaceProjection.clock(projection.range.lowerBound))–\(RaceProjection.clock(projection.range.upperBound)))")
                            .monospacedDigit().bold()
                    }
                } header: {
                    Text("Projected times")
                } footer: {
                    Text("From your last eight weeks of workouts: median swim pace, your quicker rides, and your best run carried to race distance (Riegel's formula), slowed for running off the bike. It moves as you train.")
                }
            }

            Section {
                ForEach(plan.legs) { leg in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label(leg.label, systemImage: leg.sport.symbol)
                                .font(.headline)
                                .foregroundStyle(Palette.color(for: leg.sport))
                            Spacer()
                            Text("~\(Fmt.hours(leg.minutes))").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Text(leg.target).font(.subheadline.weight(.semibold))
                        Text(leg.cue).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Pacing")
            }

            Section {
                ForEach(plan.fuel) { step in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(Self.clock(step.at))
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .frame(width: 64, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.text).font(.subheadline)
                            Text(step.leg).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Fuelling · \(plan.carbsPerHour) g carbs an hour on the bike")
            } footer: {
                Text("The Coach Bridge Watch app can tap you when each one is due: open Race day on your Watch and start the fuel timer at the gun.")
            }

            Section("Notes") {
                ForEach(plan.notes, id: \.self) { Text($0).font(.subheadline) }
            }
        }
        .navigationTitle(plan.raceName)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// "−3:00", "0:20", "5:40" from minutes relative to the gun.
    static func clock(_ minutes: Int) -> String {
        let sign = minutes < 0 ? "−" : ""
        let m = abs(minutes)
        return "\(sign)\(m / 60):" + String(format: "%02d", m % 60)
    }
}
