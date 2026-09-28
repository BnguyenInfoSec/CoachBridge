import SwiftUI

/// The privacy policy, bundled with the app (docs/coach-bridge-privacy-policy.md), so it's always
/// the version that describes this build and it reads offline.
struct PrivacyPolicyView: View {
    private let blocks = PolicyDocument.blocks(PolicyDocument.bundledText)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .heading(let level, let text):
                        Text(PolicyDocument.inline(text))
                            .font(level == 1 ? .title.bold() : .title3.bold())
                            .padding(.top, level == 1 ? 0 : 8)
                            .accessibilityAddTraits(.isHeader)
                    case .paragraph(let text):
                        Text(PolicyDocument.inline(text)).font(.body)
                    case .bullet(let text):
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•")
                            Text(PolicyDocument.inline(text))
                        }
                    case .row(let cells, let header):
                        VStack(alignment: .leading, spacing: 3) {
                            Text(PolicyDocument.inline(cells.first ?? "")).font(.headline)
                            ForEach(Array(zip(header.dropFirst(), cells.dropFirst())), id: \.0) { h, c in
                                (Text(h + ": ").bold() + Text(PolicyDocument.inline(c))).font(.subheadline)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Privacy policy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Just enough Markdown for the policy: headings, paragraphs, bullets and one table.
enum PolicyDocument {
    enum Block: Equatable {
        case heading(Int, String)
        case paragraph(String)
        case bullet(String)
        case row([String], header: [String])
    }

    static var bundledText: String {
        Bundle.main.url(forResource: "coach-bridge-privacy-policy", withExtension: "md")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? "The privacy policy couldn't be loaded."
    }

    static func blocks(_ markdown: String) -> [Block] {
        var out: [Block] = []
        var para: [String] = []
        var header: [String] = []
        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))); para = [] }
        }
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("#") {
                flush()
                let level = line.prefix { $0 == "#" }.count
                out.append(.heading(level, line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("|") {
                flush()
                let cells = line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast()
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { continue }      // the |---| line
                if header.isEmpty { header = cells.map { $0.replacingOccurrences(of: "**", with: "") } }
                else { out.append(.row(cells, header: header)) }
            } else if line.hasPrefix("- ") {
                flush()
                out.append(.bullet(String(line.dropFirst(2))))
            } else if !para.isEmpty, out.last.map({ if case .bullet = $0 { return true } else { return false } }) == true, raw.hasPrefix("  ") {
                para.append(line)
            } else if raw.hasPrefix("  "), case .bullet(let b)? = out.last {
                out[out.count - 1] = .bullet(b + " " + line)                                  // wrapped bullet
            } else {
                para.append(line)
            }
        }
        flush()
        return out
    }

    /// Bold, italics, code and links, as SwiftUI renders them.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
