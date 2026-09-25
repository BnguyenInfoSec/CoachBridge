import PhotosUI
import SwiftUI
import UIKit

/// What a place looks like: your photo if you've added one, otherwise the illustration that
/// ships with the app, otherwise a sport-colored gradient. One place decides, so the banner,
/// the list row and the editor can never disagree.
struct VenueArtwork: View {
    @EnvironmentObject private var venues: VenueStore
    @EnvironmentObject private var weather: WeatherModel
    let venue: Venue?
    let slot: String
    /// Symbol size relative to the view's height, for the gradient fallback.
    var symbolScale: CGFloat = 0.7
    var height: CGFloat = 150
    /// Override the time of day (the walkthrough uses this to show all four).
    var phase: TimeOfDay? = nil

    /// Real sunrise/sunset when the forecast has today's, clock hours otherwise.
    private var timeOfDay: TimeOfDay {
        phase ?? TimeOfDay.current(sunrise: weather.forecast?.today?.sunrise,
                                   sunset: weather.forecast?.today?.sunset)
    }

    /// `venue-la-jolla` + `night` → `venue-la-jolla-night`, falling back to the day version
    /// and then to nothing, so a missing asset degrades instead of rendering blank.
    static func asset(_ base: String, _ phase: TimeOfDay) -> String? {
        let key = "\(base)-\(phase.rawValue)"
        if let cached = resolved[key] { return cached }
        let found = ["\(base)-\(phase.rawValue)", "\(base)-day", base]
            .first { UIImage(named: $0) != nil }
        resolved[key] = found
        return found
    }

    /// Asset lookups are cheap but not free, and this runs on every redraw of a full-screen
    /// image. Resolved once per scene and time of day.
    nonisolated(unsafe) private static var resolved: [String: String?] = [:]

    var body: some View {
        if let v = venue, let img = venues.image(for: v) {
            Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
        } else if let art = venue?.art, let name = Self.asset(art, timeOfDay) {
            Image(name).resizable().aspectRatio(contentMode: .fill)
                .transition(.opacity)
        } else {
            let tint = Palette.color(for: VenueSlot.kind(slot))
            ZStack(alignment: .topTrailing) {
                LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.55)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: VenueSlot.symbol(slot))
                    .font(.system(size: height * symbolScale, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.18))
                    .padding(.trailing, -10).padding(.top, -6)
            }
        }
    }
}

/// The place, as the top third of the page. Full-strength photograph at the top, dissolving
/// into the wash at its lower edge — no card, no border, no seam. Pulling the page down opens
/// it to most of the screen. Falls back to the painted wash when the day has no venue.
struct VenueBackdrop: View {
    /// How far down the screen the image reaches at rest — the top third of the page.
    static let coverage: CGFloat = 0.34
    /// …and how far when pulled open: the whole screen, like Reachability showing the wallpaper.
    static let peekCoverage: CGFloat = 1.0

    @EnvironmentObject private var venues: VenueStore
    @EnvironmentObject private var plan: PlanModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// The day's main session, if it has a place.
    let session: PlanSession?
    let iso: String
    /// Used for the wash when there's no photo to show.
    var accent: Color = Palette.Tab.plan
    /// 0 = normal, 1 = pulled open. Scales how much of the screen the image covers and how
    /// much of the scrim is over it.
    var openness: CGFloat = 0
    /// Overrides the time of day while the athlete is looking through the four versions.
    var phase: TimeOfDay? = nil

    private var slot: String? { session.flatMap { VenueSlot.key(for: $0) } }

    private var venue: Venue? {
        guard let slot else { return nil }
        return VenuePicker.pick(venues.venues, slot: slot, iso: iso,
                                pinnedID: plan.settings.venueByKind?[slot])
    }

    var body: some View {
        ZStack {
            // The wash stays underneath: it fills the edges and it's the whole background when
            // there's no venue or the athlete has reduced transparency. Once the image covers
            // the screen it's invisible, so it isn't drawn at all.
            if openness < 0.95 || reduceTransparency || venue == nil {
                AppBackground(accent: slot.map { Palette.color(for: VenueSlot.kind($0)) } ?? accent)
            }

            if !reduceTransparency, let v = venue {
                GeometryReader { geo in
                    let h = geo.size.height * (Self.coverage + (Self.peekCoverage - Self.coverage) * openness)
                    VenueArtwork(venue: v, slot: v.slot, height: h, phase: phase)
                        .frame(width: geo.size.width, height: h)
                        .clipped()
                        // Untouched at the top — no blur, no veil, full saturation. The scrim
                        // only comes in over the lower half, where the cards and text are.
                        .overlay(
                            LinearGradient(stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .clear, location: 0.45 + 0.12 * openness),
                                .init(color: (scheme == .dark ? Color.black : Color.white).opacity(0.22), location: 0.75 + 0.05 * openness),
                                .init(color: (scheme == .dark ? Color.black : Color.white).opacity(0.50), location: 1),
                            ], startPoint: .top, endPoint: .bottom)
                        )
                        // …and dissolved into the wash over its bottom half, so there's no edge.
                        .mask(
                            LinearGradient(stops: [
                                .init(color: .black, location: 0.0),
                                .init(color: .black, location: 0.72 + 0.20 * openness),
                                .init(color: .clear, location: 1.0),
                            ], startPoint: .top, endPoint: .bottom)
                        )
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                .ignoresSafeArea()
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

extension View {
    /// Lays a screen over the day's place, falling back to the painted wash.
    func venueBackground(session: PlanSession?, iso: String, accent: Color = Palette.Tab.plan,
                         openness: CGFloat = 0, phase: TimeOfDay? = nil) -> some View {
        self.scrollContentBackground(.hidden)
            .background(VenueBackdrop(session: session, iso: iso, accent: accent,
                                      openness: openness, phase: phase))
    }

    /// List rows as glass, so a photo backdrop shows through instead of being covered by slabs.
    func glassRows(radius: CGFloat = 12) -> some View {
        self.listRowBackground(
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.ultraThinMaterial)
        )
    }
}

// MARK: - Places settings

/// Settings: the places you train, with your own photos.
struct VenueLibraryView: View {
    @EnvironmentObject private var venues: VenueStore
    @EnvironmentObject private var plan: PlanModel

    var body: some View {
        List {
            ForEach(VenueSlot.all, id: \.self) { slot in
                Section {
                    ForEach(venues.venues(for: slot)) { v in
                        NavigationLink(value: v) {
                            VenueRow(venue: v, pinned: plan.settings.venueByKind?[slot] == v.id.uuidString)
                        }
                    }
                    Button {
                        venues.save(Venue(slot: slot, name: "New place"))
                    } label: {
                        Label("Add a place", systemImage: "plus.circle")
                    }
                } header: {
                    Label(VenueSlot.label(slot), systemImage: VenueSlot.symbol(slot))
                } footer: {
                    if slot == VenueSlot.all.last {
                        Text("Photos stay on your phone: they're copied into the app's own storage and never uploaded, exported or sent to Claude.")
                    }
                }
            }
        }
        .screenBackground(Palette.Tab.plan)
        .navigationTitle("Places")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Venue.self) { v in VenueEditor(venueID: v.id) }
    }
}

private struct VenueRow: View {
    @EnvironmentObject private var venues: VenueStore
    let venue: Venue
    let pinned: Bool

    var body: some View {
        HStack(spacing: 12) {
            VenueArtwork(venue: venue, slot: venue.slot, symbolScale: 0.5, height: 40)
                .frame(width: 58, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(venue.name)
                if !venue.note.isEmpty {
                    Text(venue.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(Palette.series4) }
        }
    }
}

/// One place: name, note, photo, and whether it's the one this sport always shows.
struct VenueEditor: View {
    @EnvironmentObject private var venues: VenueStore
    @EnvironmentObject private var plan: PlanModel
    @Environment(\.dismiss) private var dismiss

    let venueID: UUID
    @State private var name = ""
    @State private var note = ""
    @State private var pick: PhotosPickerItem?
    @State private var loading = false

    private var venue: Venue? { venues.venue(id: venueID) }

    var body: some View {
        Form {
            if let v = venue {
                Section {
                    ZStack {
                        VenueArtwork(venue: v, slot: v.slot, height: 150)
                        if loading { ProgressView().tint(.white) }
                    }
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .listRowInsets(EdgeInsets())

                    PhotosPicker(selection: $pick, matching: .images, photoLibrary: .shared()) {
                        Label(v.hasPhoto ? "Change photo" : "Choose a photo", systemImage: "photo.on.rectangle")
                    }
                    if v.hasPhoto {
                        Button("Remove photo", role: .destructive) {
                            venues.forgetImage(v)
                            venues.removePhoto(v)
                        }
                    }
                } footer: {
                    if v.hasPhoto && v.art != nil {
                        Text("Removing your photo puts the app's illustration back.")
                    }
                }

                Section {
                    TextField("Name", text: $name)
                    TextField("Note — distance, lanes, what it's good for", text: $note)
                }

                Section {
                    Toggle("Always show this one", isOn: Binding(
                        get: { plan.settings.venueByKind?[v.slot] == v.id.uuidString },
                        set: { on in
                            var m = plan.settings.venueByKind ?? [:]
                            if on { m[v.slot] = v.id.uuidString } else if m[v.slot] == v.id.uuidString { m[v.slot] = nil }
                            plan.settings.venueByKind = m.isEmpty ? nil : m
                        }))
                } footer: {
                    Text("Off, the app rotates through your \(VenueSlot.label(v.slot).lowercased()) places — the same day always shows the same one.")
                }

                Section {
                    Button("Delete place", role: .destructive) {
                        var m = plan.settings.venueByKind ?? [:]
                        if m[v.slot] == v.id.uuidString {
                            m[v.slot] = nil
                            plan.settings.venueByKind = m.isEmpty ? nil : m
                        }
                        venues.delete(v)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(name.isEmpty ? "Place" : name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            name = venue?.name ?? ""
            note = venue?.note ?? ""
        }
        .onDisappear(perform: commit)
        .onChange(of: pick) { _, item in
            guard let item else { return }
            loading = true
            Task {
                defer { loading = false }
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let v = venue else { return }
                venues.forgetImage(v)
                venues.setPhoto(Self.shrink(data), for: v)
                pick = nil
            }
        }
    }

    private func commit() {
        guard var v = venue else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        v.name = trimmed.isEmpty ? v.name : trimmed
        v.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        venues.save(v)
    }

    /// Banner-sized JPEG, so a library full of 12 MP shots doesn't fill the phone.
    static func shrink(_ data: Data, maxEdge: CGFloat = 1600, quality: CGFloat = 0.8) -> Data {
        guard let img = UIImage(data: data) else { return data }
        let longest = max(img.size.width, img.size.height)
        guard longest > maxEdge else { return img.jpegData(compressionQuality: quality) ?? data }
        let scale = maxEdge / longest
        let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: quality) ?? data
    }
}
