/// The native `tree_view` for the Layers panel (slice S1;
/// spec_inputs/LAYERS-S1-interaction-spec.md). Draws the rows the core
/// resolves (``LayersPanel/treeRows(model:)``) from layers.yaml's `lp_tree`
/// `do:` template — icons, name, background and the select square's fill are
/// the template's own expressions, evaluated per row — and routes every press
/// and key through the state machine in Panels/LayersTree.swift.

import SwiftUI
import AppKit

private let layersRowHeight: CGFloat = 24

private struct LayersTreeOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// A row's stable scroll id.
private func layersRowKey(_ path: [Int]) -> String {
    "lp_row_" + path.map(String.init).joined(separator: ".")
}

struct LayersTreeView: View {
    let element: [String: Any]
    let context: [String: Any]
    @ObservedObject var model: Model
    let theme: Theme?
    @StateObject private var shell = LayersTreeShell()

    var body: some View {
        // Read on every render: any document or panel-store change redraws
        // every row from scratch (spec §4).
        let _ = model.panelStateVersion
        let rows = LayersPanel.treeRows(model: model)
        let template = (element["do"] as? [String: Any]) ?? [:]
        let baseCtx = rowBaseContext()
        let selection = model.document.selection.map(\.path)
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, node in
                            let path = node["path"] as? [Int] ?? []
                            LayersTreeRow(node: node, template: template, baseCtx: baseCtx,
                                          theme: theme,
                                          onPress: { region in press(region, path) })
                                .id(layersRowKey(path))
                        }
                        // Below the last row: takes focus, selects nothing
                        // (DECISION S1-3).
                        SwiftUI.Color.clear
                            .frame(maxWidth: .infinity,
                                   minHeight: max(0, geo.size.height - CGFloat(rows.count) * layersRowHeight))
                            .contentShape(Rectangle())
                            .onTapGesture { LayersPanel.treePressBelowRows(shell: shell) }
                    }
                    .background(GeometryReader { g in
                        SwiftUI.Color.clear.preference(
                            key: LayersTreeOffsetKey.self,
                            value: -g.frame(in: .named("lp_tree_scroll")).minY)
                    })
                }
                .coordinateSpace(name: "lp_tree_scroll")
                .onPreferenceChange(LayersTreeOffsetKey.self) { off in
                    let top = max(0, Int((off / layersRowHeight - 0.001).rounded(.up)))
                    if top != shell.scrollTop { shell.scrollTop = top }
                }
                .background(LayersTreeKeyCatcher(shell: shell, onKey: { event in
                    handleKey(event, proxy: proxy, height: geo.size.height)
                }))
                .onChange(of: selection) { newSelection in
                    guard shell.takeSelectionChange(newSelection),
                          let path = LayersPanel.revealElementSelection(model: model) else { return }
                    reveal(path, proxy: proxy, height: geo.size.height)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// The renderer's scope with the action context's `panel` and
    /// `active_document` laid over it, so the template's expressions read the
    /// values the actions read.
    private func rowBaseContext() -> [String: Any] {
        var ctx = context
        let ac = LayersPanel.treeEvalContext(model: model)
        var panel = (context["panel"] as? [String: Any]) ?? [:]
        for (k, v) in (ac["panel"] as? [String: Any]) ?? [:] { panel[k] = v }
        ctx["panel"] = panel
        if let ad = ac["active_document"] { ctx["active_document"] = ad }
        return ctx
    }

    private func press(_ region: LayersRowRegion, _ path: [Int]) {
        var clicks = 1
        if let e = NSApp.currentEvent,
           [.leftMouseDown, .leftMouseUp].contains(e.type) {
            clicks = e.clickCount
        }
        LayersPanel.treePress(region: region, path: path,
                              mods: .from(NSEvent.modifierFlags),
                              clickCount: clicks, model: model, shell: shell)
    }

    private func handleKey(_ event: NSEvent, proxy: ScrollViewProxy, height: CGFloat) -> Bool {
        let key = canonicalKeyName(event)
        let flags = event.modifierFlags
        let mods = KeyMods(shift: flags.contains(.shift), ctrl: flags.contains(.control),
                           alt: flags.contains(.option), cmd: flags.contains(.command))
        guard LayersPanel.treeKey(key, mods: mods, model: model) else { return false }
        // Reveal on keyboard move (spec §5).
        if key.hasPrefix("Arrow"), let focus = LayersPanel.treeFocusRow(model: model) {
            reveal(focus, proxy: proxy, height: height)
        }
        return true
    }

    /// Scroll the least distance that puts the row at `path` fully in view
    /// (DECISION S1-5). Runs after the rows the change produced are drawn.
    private func reveal(_ path: [Int], proxy: ScrollViewProxy, height: CGFloat) {
        DispatchQueue.main.async {
            let rows = LayersPanel.treeRows(model: model)
            guard let idx = rows.firstIndex(where: { ($0["path"] as? [Int]) == path }) else { return }
            let viewport = Int(height / layersRowHeight)
            let top = LayersPanel.revealScrollTop(row: idx, scrollTop: shell.scrollTop,
                                                  viewportRows: viewport)
            guard top != shell.scrollTop, top >= 0, top < rows.count,
                  let topPath = rows[top]["path"] as? [Int] else { return }
            proxy.scrollTo(layersRowKey(topPath), anchor: .top)
            shell.scrollTop = top
        }
    }
}

/// One row, laid out as the template: spacer · eye · lock · twirl or leaf gap
/// · preview · name · select square.
private struct LayersTreeRow: View {
    let node: [String: Any]
    let template: [String: Any]
    let baseCtx: [String: Any]
    let theme: Theme?
    let onPress: (LayersRowRegion) -> Void

    private var ctx: [String: Any] {
        var c = baseCtx
        c["node"] = node
        return c
    }

    private func widget(_ id: String) -> [String: Any] {
        LayersPanel.templateWidget(id, in: template) ?? [:]
    }

    private func iconName(_ id: String) -> String {
        guard let raw = widget(id)["icon"] as? String else { return "" }
        return raw.contains("{{") ? evaluateText(raw, context: ctx) : raw
    }

    private var tint: NSColor { theme?.text ?? NSColor.labelColor }

    var body: some View {
        let depth = node["depth"] as? Int ?? 0
        let isContainer = node["is_container"] as? Bool ?? false
        HStack(spacing: 2) {
            SwiftUI.Color.clear
                .frame(width: CGFloat(depth * 16), height: layersRowHeight)
                .contentShape(Rectangle())
                .onTapGesture { onPress(.spacer) }
            iconButton(iconName("lp_eye"), id: "lp_eye", summary: "Visibility") { onPress(.eye) }
            iconButton(iconName("lp_lock"), id: "lp_lock", summary: "Lock") { onPress(.lock) }
            if isContainer {
                iconButton(iconName("lp_twirl"), id: "lp_twirl", summary: "Expand/Collapse") { onPress(.twirl) }
            } else {
                SwiftUI.Color.clear
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
                    .onTapGesture { onPress(.leafGap) }
            }
            // Best-effort thumbnail (spec §4): a white 24-square (DECISION S1-7).
            Rectangle()
                .fill(SwiftUI.Color.white)
                .overlay(Rectangle().stroke(SwiftUI.Color.gray.opacity(0.6), lineWidth: 1))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .onTapGesture { onPress(.preview) }
                .accessibilityIdentifier("lp_preview")
            SwiftUI.Text(nameText)
                .font(.system(size: 11))
                .foregroundColor(SwiftUI.Color(nsColor: tint))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { onPress(.name) }
                .accessibilityIdentifier("lp_name")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { onPress(.name) }
            Button(action: { onPress(.select) }) {
                Rectangle()
                    .fill(selectFill)
                    .overlay(Rectangle().stroke(SwiftUI.Color.gray, lineWidth: 1))
                    .frame(width: 12, height: 12)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("lp_select")
        }
        .padding(.horizontal, 4)
        .frame(height: layersRowHeight)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture { onPress(.spacer) }
        .accessibilityElement(children: .contain)
        .accessibilityValue((node["path"] as? [Int] ?? []).map(String.init).joined(separator: ","))
    }

    private var nameText: String {
        guard let raw = widget("lp_name")["content"] as? String else {
            return node["name"] as? String ?? ""
        }
        return evaluateText(raw, context: ctx)
    }

    private func color(_ s: String) -> SwiftUI.Color? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("#") else { return nil }
        return SwiftUI.Color(nsColor: NSColor(hex: t))
    }

    private var rowBackground: SwiftUI.Color {
        let selected = node["panel_selected"] as? Bool ?? false
        if let expr = (template["bind"] as? [String: Any])?["background"] as? String {
            switch evaluate(expr, context: ctx) {
            case .color(let c): if let col = color(c) { return col }
            case .string(let s): if let col = color(s) { return col }
            default: break
            }
        }
        return selected ? SwiftUI.Color(nsColor: .selectedContentBackgroundColor) : .clear
    }

    private var selectFill: SwiftUI.Color {
        let style = widget("lp_select")["style"] as? [String: Any] ?? [:]
        if let raw = style["background"] as? String {
            let s = raw.contains("{{") ? evaluateText(raw, context: ctx) : raw
            if let col = color(s) { return col }
            return .clear
        }
        if node["element_selected"] as? Bool == true,
           let c = node["ancestor_layer_color"] as? String, let col = color(c) {
            return col
        }
        return .clear
    }

    @ViewBuilder
    private func iconButton(_ name: String, id: String, summary: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if !name.isEmpty, WorkspaceIconCache.shared.lookup(name) != nil {
                WorkspaceIcon(name: name, size: 16, tint: tint)
            } else {
                Image(systemName: fallbackSymbol(name))
                    .font(.system(size: 11))
                    .foregroundColor(SwiftUI.Color(nsColor: tint))
                    .frame(width: 16, height: 16)
            }
        }
        .buttonStyle(.plain)
        .frame(width: 16, height: 16)
        .help(summary)
        .accessibilityIdentifier(id)
        .accessibilityValue(name)
    }

    private func fallbackSymbol(_ icon: String) -> String {
        switch icon {
        case "eye_preview": return "eye"
        case "eye_outline": return "eye.circle"
        case "eye_invisible": return "eye.slash"
        case "lock_locked": return "lock.fill"
        case "lock_unlocked": return "lock.open"
        case "twirl_open": return "chevron.down"
        case "twirl_closed": return "chevron.right"
        default: return "questionmark"
        }
    }
}

/// An invisible AppKit view that holds the tree's key focus (spec §3). A press
/// in the tree makes it first responder; a press on the canvas or another
/// panel takes first responder away, which is `key_focus = elsewhere`.
private struct LayersTreeKeyCatcher: NSViewRepresentable {
    let shell: LayersTreeShell
    let onKey: (NSEvent) -> Bool

    func makeNSView(context: Context) -> LayersTreeKeyNSView {
        let v = LayersTreeKeyNSView()
        v.onKey = onKey
        let owner = shell
        v.onFocus = { [weak owner] focused in
            DispatchQueue.main.async { owner?.keyFocus = focused ? .tree : .elsewhere }
        }
        shell.keyView = v
        return v
    }

    func updateNSView(_ nsView: LayersTreeKeyNSView, context: Context) {
        nsView.onKey = onKey
        shell.keyView = nsView
    }
}

final class LayersTreeKeyNSView: NSView {
    var onKey: ((NSEvent) -> Bool)?
    var onFocus: ((Bool) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        onFocus?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        onFocus?(false)
        return true
    }

    /// Transparent to the pointer: presses land on the rows above it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }

    /// Cmd+A reaches the views before the main menu's Select All, so the
    /// tree's `Ctrl+A` row wins while the tree holds the keyboard (R-3).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, event.type == .keyDown,
           event.modifierFlags.contains(.command), onKey?(event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
