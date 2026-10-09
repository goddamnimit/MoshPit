import SwiftUI

// MARK: - "?" hint system (central)

/// Everything that can carry a hint. Copy lives in Labels.
enum HintKey: Hashable {
    case param(ParameterID)
    case mode(MoshMode)
    case panel(AppModel.Panel)
    case group(Labels.Group)

    var entry: LabelEntry {
        switch self {
        case .param(let id): return Labels.param(id)
        case .mode(let m): return Labels.mode(m)
        case .panel(let p): return Labels.panel(p)
        case .group(let g): return Labels.group(g)
        }
    }
}

/// Single source of truth for which hint is open: only one at a time, and
/// opening another closes the first. Kept off AppModel so toggling a hint
/// never invalidates the main view tree.
final class HintCenter: ObservableObject {
    static let shared = HintCenter()
    @Published var open: HintKey?

    func toggle(_ key: HintKey) { open = (open == key) ? nil : key }
    func close(_ key: HintKey) { if open == key { open = nil } }
}

/// Small "?" with a 44pt hit area and a 20pt visual. Tap opens a popover card;
/// tap elsewhere dismisses. Renders nothing when the entry has no hint, so
/// ParamRow shows it automatically wherever copy exists.
struct HintButton: View {
    let key: HintKey
    @ObservedObject private var center = HintCenter.shared

    var body: some View {
        if !key.entry.hint.isEmpty {
            Button {
                Theme.haptic()
                center.toggle(key)
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: Theme.g3 - Theme.gHalf, height: Theme.g3 - Theme.gHalf)
                    // 44pt hit area, ~20pt visual: no layout change.
                    .contentShape(Rectangle().inset(by: -(Theme.tapTarget - (Theme.g3 - Theme.gHalf)) / 2))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("What does \(key.entry.title) do?")
            .accessibilityHint("Shows a short explanation")
            .popover(isPresented: Binding(
                get: { center.open == key },
                set: { if !$0 { center.close(key) } })) {
                HintCard(entry: key.entry)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }
}

/// The popover card, in Theme style.
struct HintCard: View {
    let entry: LabelEntry

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.g1) {
            Text(entry.title)
                .font(Theme.label.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            if let original = entry.original, original != entry.title {
                Text("Also called: \(original)")
                    .font(Theme.labelSmall)
                    .foregroundStyle(Theme.textSecondary)
            }
            Text(entry.hint)
                .font(Theme.label)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.g2)
        .frame(width: 280, alignment: .leading)
        .background(Theme.scrimBase)
        .preferredColorScheme(.dark)
    }
}

/// Section header with the friendly title, optional original, and a "?".
struct HintHeader: View {
    let key: HintKey

    var body: some View {
        HStack(spacing: Theme.gHalf) {
            Text(key.entry.title)
            if let original = key.entry.original, original != key.entry.title {
                Text(original).font(Theme.labelSmall).foregroundStyle(Theme.textSecondary)
            }
            HintButton(key: key)
            Spacer(minLength: 0)
        }
        .textCase(nil)
    }
}

/// A Toggle bound to a ParameterID, titled from Labels, with a "?".
struct ParamToggle: View {
    @EnvironmentObject var params: ParameterStore
    let id: ParameterID
    /// Runs after the value is written (e.g. the flicker warning).
    var after: ((Bool) -> Void)? = nil

    var body: some View {
        Toggle(isOn: Binding(
            get: { params.bool(id) },
            set: { on in
                params.set(id, on ? 1 : 0, origin: .ui)
                after?(on)
            })) {
            HStack(spacing: Theme.gHalf) {
                Text(Labels.param(id).title)
                HintButton(key: .param(id))
            }
        }
    }
}

/// `Section` whose header is a HintHeader (title, original name, "?").
struct HintSection<Content: View>: View {
    let key: HintKey
    @ViewBuilder var content: () -> Content

    var body: some View {
        Section { content() } header: { HintHeader(key: key) }
    }
}
