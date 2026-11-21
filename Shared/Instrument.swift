import SwiftUI

/// The "Instrument" look: near-black, graphite panels, amber accent, IBM Plex type.
/// Shared by the iPhone app, the AutoFill extension and the Mac app.
enum Ink {
    static let bg = Color(red: 0.043, green: 0.047, blue: 0.055)        // #0B0C0E
    static let panel = Color(red: 0.071, green: 0.078, blue: 0.094)     // #121418
    static let panelHi = Color(red: 0.106, green: 0.118, blue: 0.137)   // #1B1E23
    static let line = Color(red: 0.165, green: 0.176, blue: 0.2)        // #2A2D33
    static let text = Color(red: 0.91, green: 0.902, blue: 0.882)       // #E8E6E1
    static let mid = Color(red: 0.659, green: 0.647, blue: 0.62)        // #A8A59E
    static let muted = Color(red: 0.557, green: 0.545, blue: 0.518)     // #8E8B84
    static let amber = Color(red: 0.949, green: 0.647, blue: 0.255)     // #F2A541
    static let amberFill = Color(red: 0.118, green: 0.09, blue: 0.051)  // #1E170D
    static let amberLine = Color(red: 0.361, green: 0.263, blue: 0.125) // #5C4320
    static let red = Color(red: 1, green: 0.541, blue: 0.478)           // #FF8A7A
}

extension Font {
    static func plex(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom("IBMPlexSans-Regular", size: size, relativeTo: style).weight(weight)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(weight == .regular ? "IBMPlexMono-Regular" : "IBMPlexMono-Medium", size: size, relativeTo: style)
    }
}

/// Small mono caps label: "USERNAME", "RECENT".
struct Eyebrow: View {
    let text: String
    var color: Color = Ink.muted
    init(_ text: String, color: Color = Ink.muted) { self.text = text; self.color = color }
    var body: some View {
        Text(text.uppercased()).font(.mono(11, .medium, relativeTo: .caption2)).tracking(1.2).foregroundStyle(color)
    }
}

/// Bordered graphite panel.
struct Panel<Content: View>: View {
    var fill: Color = Ink.panel
    var stroke: Color = Ink.line
    @ViewBuilder var content: Content
    var body: some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(stroke, lineWidth: 1))
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Ink.line).frame(height: 1) }
}

/// Square-cornered switch from the design.
struct InkToggle: View {
    @Binding var isOn: Bool
    let label: String
    var detail: String?
    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.plex(16)).foregroundStyle(Ink.text)
                    if let detail { Text(detail).font(.plex(13)).foregroundStyle(Ink.muted) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ZStack(alignment: isOn ? .trailing : .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(isOn ? Ink.amber : Ink.panel)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(isOn ? Ink.amber : Ink.line))
                    RoundedRectangle(cornerRadius: 2).fill(isOn ? Ink.bg : Ink.muted).frame(width: 22, height: 22).padding(3)
                }
                .frame(width: 50, height: 30)
                .animation(.easeOut(duration: 0.15), value: isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
    }
}

/// Amber primary / outlined secondary buttons.
struct InkButtonStyle: ButtonStyle {
    enum Kind { case primary, accentOutline, secondary, destructive }
    var kind: Kind = .secondary
    var height: CGFloat = 48

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.plex(16, kind == .primary ? .semibold : .medium))
            .frame(maxWidth: .infinity).frame(height: height)
            .foregroundStyle(fg)
            .background(bg, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(stroke, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }

    private var fg: Color {
        switch kind { case .primary: return Ink.bg; case .accentOutline: return Ink.amber; case .secondary: return Ink.text; case .destructive: return Ink.red }
    }
    private var bg: Color {
        switch kind { case .primary: return Ink.amber; case .accentOutline: return Ink.amberFill; case .secondary: return Ink.panel; case .destructive: return .clear }
    }
    private var stroke: Color {
        switch kind { case .primary, .accentOutline: return Ink.amber; default: return Ink.line }
    }
}

/// "2FA" / "REUSED" tags in rows.
struct Tag: View {
    let text: String
    var solid = true
    var body: some View {
        Text(text).font(.mono(11, .medium, relativeTo: .caption2))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .foregroundStyle(solid ? Ink.bg : Ink.amber)
            .background(solid ? Ink.amber : .clear, in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(solid ? .clear : Ink.amberLine))
    }
}

/// 30 segments that drain as the one-time code ages.
struct CodeTicks: View {
    let left: Int
    let period: Int
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<period, id: \.self) { i in
                Rectangle().fill(i < left ? Ink.amber : Ink.line).frame(height: 8)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Mono caps text button: COPY, SHOW, EDIT.
struct CapsButton: View {
    let title: String
    var color: Color = Ink.amber
    let action: () -> Void
    init(_ title: String, color: Color = Ink.amber, action: @escaping () -> Void) { self.title = title; self.color = color; self.action = action }
    var body: some View {
        Button(action: action) {
            Text(title.uppercased()).font(.mono(12, .medium)).tracking(1).foregroundStyle(color)
                .padding(.horizontal, 10).frame(minHeight: 44)
        }
        .buttonStyle(.plain)
    }
}

