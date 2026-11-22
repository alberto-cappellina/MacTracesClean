import SwiftUI
import AppKit

extension ShapeStyle where Self == Color {
    /// Card surface that sits above the window background in both themes.
    static var cardSurface: Color { Color(nsColor: .controlBackgroundColor) }
}

struct SeverityPill: View {
    let sensitivity: Sensitivity
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(sensitivity.color).frame(width: 7, height: 7)
            Text(sensitivity.label)
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(sensitivity.color.opacity(0.14), in: Capsule())
        .foregroundStyle(sensitivity.color)
    }
}

struct IconBadge: View {
    let system: String
    let tint: Color
    var body: some View {
        Image(systemName: system)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 34, height: 34)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.cardSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 1))
    }
}

struct StatTile: View {
    let value: String
    let label: String
    var tint: Color = .accentColor
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.cardSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
