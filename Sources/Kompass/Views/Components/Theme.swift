import SwiftUI

/// Bewegung nach Apples „Designing Fluid Interfaces“: Federn statt fester Dauern,
/// kritisch gedämpft als Standard, etwas Federung nur nach Gesten mit Schwung.
enum Motion {
    /// Standard – kein Überschwingen
    static let standard = Animation.spring(response: 0.35, dampingFraction: 1.0)
    static let snappy = Animation.spring(response: 0.25, dampingFraction: 1.0)
    /// Nach einem Drag/Flick – leichte Federung, weil die Geste Schwung hatte
    static let momentum = Animation.spring(response: 0.35, dampingFraction: 0.8)
    static let sheet = Animation.spring(response: 0.3, dampingFraction: 0.8)
    /// Bei „Bewegung reduzieren“: sanftes Überblenden statt Bewegung
    static let reduced = Animation.easeInOut(duration: 0.2)

    static func pick(_ reduce: Bool, _ a: Animation = standard) -> Animation { reduce ? reduced : a }
}

/// Feedback beim Drücken – sofort, nicht erst beim Loslassen.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(configuration.isPressed ? .easeOut(duration: 0.08) : Motion.snappy, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}

// MARK: - Flächen

struct CardModifier: ViewModifier {
    var padding: CGFloat = 16
    var radius: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
    }
}

extension View {
    func card(padding: CGFloat = 16, radius: CGFloat = 14) -> some View { modifier(CardModifier(padding: padding, radius: radius)) }
}

// MARK: - Typografie

/// Systemschrift mit fester Grundgröße, die auf dem iPhone mit der eingestellten Textgröße
/// mitwächst (Dynamic Type). Auf dem Mac und in Standardgröße identisch mit `.system(size:)`.
struct ScaledSystemFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: Self.textStyle(for: size))
        self.weight = weight
        self.design = design
    }

    /// Wächst so wie der Systemstil ähnlicher Größe.
    private static func textStyle(for size: CGFloat) -> Font.TextStyle {
        switch size {
        case 24...: return .title
        case 19..<24: return .title3
        case 15..<19: return .body
        case 12..<15: return .subheadline
        default: return .caption
        }
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}

extension View {
    func scaledFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(ScaledSystemFont(size: size, weight: weight, design: design))
    }
}

/// Große Titel mit negativem Tracking und enger Zeilenhöhe.
struct PageTitle: View {
    var title: String
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .scaledFont(size: 28, weight: .bold)
                .tracking(-0.6)
            if let subtitle {
                Text(subtitle)
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Seitenkopf: Titel links, Aktionen rechts – auf dem iPhone untereinander.
struct PageHeader<Trailing: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing
    @Environment(\.isCompactLayout) private var compact

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: 12) {
                PageTitle(title: title, subtitle: subtitle)
                HStack { trailing }
            }
        } else {
            HStack(alignment: .bottom) {
                PageTitle(title: title, subtitle: subtitle)
                Spacer()
                trailing
            }
        }
    }
}

/// Runder Abhak-Knopf (statt Checkbox) – gut mit Maus und Finger bedienbar.
struct CheckToggle: View {
    @Binding var isOn: Bool
    var tint: Color = .accentColor
    var body: some View {
        Button { withAnimation(Motion.momentum) { isOn.toggle() } } label: {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .scaledFont(size: 18)
                .foregroundStyle(isOn ? tint : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Nur Symbol (z. B. auf dem iPhone) oder Symbol mit Titel – derselbe Label bleibt für VoiceOver beschriftet.
struct AdaptiveIconLabelStyle: LabelStyle {
    var iconOnly: Bool
    func makeBody(configuration: Configuration) -> some View {
        if iconOnly { Label(configuration).labelStyle(.iconOnly) } else { Label(configuration).labelStyle(.titleAndIcon) }
    }
}

/// Horizontal auf breiten, vertikal auf schmalen Bildschirmen.
struct AdaptiveStack<Content: View>: View {
    var spacing: CGFloat = 20
    @ViewBuilder var content: Content
    @Environment(\.isCompactLayout) private var compact
    var body: some View {
        let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
                             : AnyLayout(HStackLayout(alignment: .top, spacing: spacing))
        layout { content }
    }
}

struct SectionLabel<Trailing: View>: View {
    var title: String
    var symbol: String?
    @ViewBuilder var trailing: Trailing

    init(_ title: String, symbol: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.symbol = symbol; self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(.secondary).scaledFont(size: 12, weight: .semibold)
                    .accessibilityHidden(true)
            }
            Text(title)
                .scaledFont(size: 15, weight: .semibold)
                .tracking(-0.2)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            trailing
        }
    }
}

extension SectionLabel where Trailing == EmptyView {
    init(_ title: String, symbol: String? = nil) { self.init(title, symbol: symbol) { EmptyView() } }
}

// MARK: - Bausteine

struct ProgressRing: View {
    var value: Double
    var color: Color = .accentColor
    var lineWidth: CGFloat = 5
    var size: CGFloat = 36
    var showLabel = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, value)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Motion.pick(reduce), value: value)
            if showLabel {
                Text("\(Int((value * 100).rounded()))")
                    .font(.system(size: size * 0.3, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("Fortschritt \(Int(value * 100)) Prozent")
    }
}

struct ModuleDot: View {
    var color: Color
    var size: CGFloat = 9
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

struct Pill: View {
    var text: String
    var color: Color = .secondary
    var symbol: String?
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).scaledFont(size: 9, weight: .bold) }
            Text(text).scaledFont(size: 11, weight: .semibold)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(color)
        .background(Capsule().fill(color.opacity(0.13)))
    }
}

struct BarMeter: View {
    var value: Double
    var color: Color
    var height: CGFloat = 6
    var marker: Double?
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.15))
                Capsule().fill(color).frame(width: max(height, geo.size.width * min(1, max(0, value))))
                    .opacity(value <= 0 ? 0 : 1)
                if let marker {
                    Rectangle().fill(Color.primary.opacity(0.5)).frame(width: 1.5, height: height + 4)
                        .offset(x: geo.size.width * min(1, max(0, marker)) - 0.75)
                }
            }
            .animation(Motion.pick(reduce), value: value)
        }
        .frame(height: height)
    }
}

/// Zeilen, die umbrechen (z. B. für Chips).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: min(width, maxX), height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

struct ToastView: View {
    var toast: Toast
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.symbol).foregroundStyle(toast.isError ? .orange : .green)
            Text(toast.text).scaledFont(size: 13, weight: .medium)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }
}

/// Kleine Kopfzeile in Sheets: Titel links, Aktionen rechts.
struct SheetHeader<Trailing: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).scaledFont(size: 19, weight: .bold).tracking(-0.3)
                if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer()
            trailing
        }
    }
}

extension Set {
    /// Mitgliedschaft als Wert – `$auswahl[contains: id]` ergibt ein Binding für Schalter.
    subscript(contains element: Element) -> Bool {
        get { contains(element) }
        set { if newValue { insert(element) } else { remove(element) } }
    }
}

extension Dictionary where Value: Hashable {
    /// Wie `[key, default:]`, aber als Key-Path nutzbar (`$ziele[id, or: standard]`).
    subscript(key: Key, or fallback: Value) -> Value {
        get { self[key] ?? fallback }
        set { self[key] = newValue }
    }
}

extension Color {
    static let subtleFill = Color.primary.opacity(0.045)
}

/// Stellt Minuten (seit Mitternacht) als Date-Binding für DatePicker bereit.
func minutesBinding(_ b: Binding<Int>) -> Binding<Date> {
    Binding(
        get: { Date().startOfDay.at(minutes: b.wrappedValue) },
        set: { b.wrappedValue = $0.minutesSinceMidnight }
    )
}
