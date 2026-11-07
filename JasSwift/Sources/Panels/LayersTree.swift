/// The Layers panel's TREE, slice S1: the shell half of the tree
/// (spec_inputs/LAYERS-S1-interaction-spec.md). The yaml already says WHAT
/// each row action does (`actions.yaml`) and WHICH widget raises it
/// (`layers.yaml` `lp_tree`); this file is how a press, a key and a canvas
/// selection become those events: press routing (§2), focus (§3), the rows
/// to draw (§4) and the viewport's reveal rule (§5).
///
/// Every action runs through ``LayersPanel/dispatchYamlAction``; nothing here
/// restates an action's effects. The SwiftUI view that calls these entry
/// points is `LayersTreeView` (Interpreter/LayersTreeView.swift).
///
/// Later slices plug in here rather than around it: rename (F2 / Enter /
/// double-click on the name), isolation (double-click on a container row),
/// Delete, the context menu and drag all arrive as further events through the
/// same template lookup (``LayersPanel/pressAction``) and the same keyboard
/// table (``LayersPanel/treeKey``), gated today by ``LayersPanel/s1TreeKeys``
/// and the click-count check in ``LayersPanel/treePress``.

import AppKit
import Foundation

/// Which part of the app receives the keyboard (spec §1 `key_focus`).
public enum LayersTreeFocus: Equatable {
    case tree
    case elsewhere
}

/// A row's hit regions, left to right as the yaml `do:` template lays them out
/// (spec §2, DECISION S1-6: spacer first).
public enum LayersRowRegion: String, CaseIterable {
    case spacer
    case eye
    case lock
    case twirl
    /// The 16-wide gap a leaf has where a container has its twirl.
    case leafGap
    case preview
    case name
    case select

    /// The template widget id this region is, or nil for an anonymous spacer.
    /// A region whose widget declares no behaviour for the event is
    /// transparent and the press falls to the row (DECISION S1-2).
    public var widgetId: String? {
        switch self {
        case .eye: return "lp_eye"
        case .lock: return "lp_lock"
        case .twirl: return "lp_twirl"
        case .preview: return "lp_preview"
        case .name: return "lp_name"
        case .select: return "lp_select"
        case .spacer, .leafGap: return nil
        }
    }
}

/// The modifier state at a press, as the yaml's `event.*` reads it.
public struct LayersPressMods: Equatable {
    public var shift: Bool
    public var alt: Bool
    public var ctrl: Bool
    public var meta: Bool

    public init(shift: Bool = false, alt: Bool = false, ctrl: Bool = false, meta: Bool = false) {
        self.shift = shift; self.alt = alt; self.ctrl = ctrl; self.meta = meta
    }

    /// The Mac's command chord: Cmd is reported as both `ctrl` and `meta`
    /// (spec §2). The physical Control key is NOT mapped: on the Mac
    /// Control-click is the secondary click, which the context menu (a later
    /// slice) owns. See SYNTH-NOTES.md.
    public static let command = LayersPressMods(ctrl: true, meta: true)

    public static func from(_ flags: NSEvent.ModifierFlags) -> LayersPressMods {
        let cmd = flags.contains(.command)
        return LayersPressMods(shift: flags.contains(.shift), alt: flags.contains(.option),
                               ctrl: cmd, meta: cmd)
    }

    var eventDict: [String: Any] {
        ["shift": shift, "alt": alt, "ctrl": ctrl, "meta": meta]
    }
}

/// The shell's own state (spec §1): key focus and the first row drawn. Not
/// persisted. One per tree view.
public final class LayersTreeShell: ObservableObject {
    @Published public var keyFocus: LayersTreeFocus = .elsewhere
    /// `scroll_top`: the first row drawn (rows >= 0).
    @Published public var scrollTop: Int = 0
    /// The element selection the panel itself just made (the select square),
    /// so the change it causes does not reveal (spec §5: "A selection made
    /// from the select square does not scroll").
    var panelMadeSelection: [[Int]]? = nil
    /// The AppKit view that holds key focus for the tree, when one is mounted.
    weak var keyView: NSView?

    public init() {}

    /// A press anywhere in the tree takes the keyboard (DECISION S1-4).
    public func focusTree() {
        keyFocus = .tree
        if let v = keyView, let w = v.window, w.firstResponder !== v {
            w.makeFirstResponder(v)
        }
    }

    /// Note an element-selection change; true when it came from OUTSIDE the
    /// panel and so must be revealed (spec §5).
    public func takeSelectionChange(_ selection: [[Int]]) -> Bool {
        if let made = panelMadeSelection {
            panelMadeSelection = nil
            if made == selection { return false }
        }
        return !selection.isEmpty
    }
}

extension LayersPanel {
    static let panelContentId = "layers_panel_content"

    /// The nine preset layer colours, in cycle order (layers.yaml, "Layer
    /// Color Presets").
    public static let layerColorPresets: [String] = [
        "#4a90d9", "#d94a4a", "#4ad94a", "#4a4ad9", "#d9d94a",
        "#d94ad9", "#4ad9d9", "#b0b0b0", "#2a7a2a",
    ]

    /// The colour of the top-level layer at `index`. The document model holds
    /// no per-layer colour today, so the colour is the preset cycle's entry for
    /// the layer's position (ASSUMPTION, SYNTH-NOTES.md).
    public static func layerColor(topLevelIndex index: Int) -> String {
        layerColorPresets[((index % 9) + 9) % 9]
    }

    /// The S1 rows of `lp_tree`'s `keyboard:` table (spec §3). The other rows
    /// (Delete, Backspace, F2, Enter, Escape) belong to later slices and fall
    /// through to the application's normal key route until then.
    public static let s1TreeKeys: Set<String> = ["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Ctrl+A"]

    // MARK: - The spec's tree_view node

    private static func findNode(_ v: Any, id: String) -> [String: Any]? {
        if let d = v as? [String: Any] {
            if d["id"] as? String == id { return d }
            for c in d.values { if let hit = findNode(c, id: id) { return hit } }
        } else if let a = v as? [Any] {
            for c in a { if let hit = findNode(c, id: id) { return hit } }
        }
        return nil
    }

    /// `lp_tree`, the `tree_view` node of layers.yaml.
    static func treeSpec() -> [String: Any]? {
        guard let content = WorkspaceData.load()?.panelContent(panelContentId) else { return nil }
        return findNode(content, id: "lp_tree")
    }

    /// The row template (`lp_tree.do`).
    static func treeRowTemplate() -> [String: Any]? {
        treeSpec()?["do"] as? [String: Any]
    }

    /// One template child by id (`lp_eye`, `lp_lock`, ...).
    static func templateWidget(_ id: String, in template: [String: Any]) -> [String: Any]? {
        findNode(template["children"] ?? [Any](), id: id)
    }

    // MARK: - Store helpers

    /// A stored path in any of its runtime forms: a `__path__` marker, a list
    /// of numbers (R-2: paths compare by value, whatever carries them).
    static func treePathOf(_ entry: Any) -> [Int]? {
        let e = (entry as? [String: Any])?["__path__"] ?? entry
        if let ints = e as? [Int] { return ints }
        if let nums = e as? [NSNumber] { return nums.map { $0.intValue } }
        if let any = e as? [Any] {
            var out: [Int] = []
            for x in any {
                if let i = x as? Int { out.append(i) }
                else if let d = x as? Double { out.append(Int(d)) }
                else if let n = x as? NSNumber { out.append(n.intValue) }
                else { return nil }
            }
            return out
        }
        return nil
    }

    /// Seed the Layers panel's store scope from its declared defaults when no
    /// one has yet: a write to a missing scope is dropped by the store.
    static func ensureLayersScope(_ model: Model) {
        let store = model.stateStore
        guard !store.hasPanel(panelContentId) else { return }
        let defaults = WorkspaceData.load()?.panelStateDefaults(panelContentId) ?? [:]
        store.initPanel(panelContentId, defaults: defaults)
    }

    /// `collapsed_paths` in stored order.
    public static func treeCollapsedPaths(model: Model) -> [[Int]] {
        let raw = (model.stateStore.getPanel(panelContentId, "collapsed_paths") as? [Any]) ?? []
        return raw.compactMap(treePathOf)
    }

    /// Rewrite `collapsed_paths` as plain index lists, one entry per path, in
    /// stored order. The engine's `list_toggle` compares stored values by
    /// their runtime form, and the arrow keys toggle a row's plain-list path
    /// while other writers store `__path__` markers; without one form an
    /// ArrowRight on a container collapsed by a marker ADDS a second entry,
    /// which R-2 forbids. See SYNTH-NOTES.md.
    static func normalizeCollapsedPaths(_ model: Model) {
        let store = model.stateStore
        guard let raw = store.getPanel(panelContentId, "collapsed_paths") as? [Any] else { return }
        var seen: [[Int]] = []
        for entry in raw {
            guard let p = treePathOf(entry), !seen.contains(p) else { continue }
            seen.append(p)
        }
        let needs = seen.count != raw.count || raw.contains { ($0 as? [String: Any]) != nil }
        if needs { store.setPanel(panelContentId, "collapsed_paths", seen as [Any]) }
    }

    // MARK: - Rows (spec §2, §4)

    /// The rows to draw, top to bottom: `tree_visible_rows` over the document's
    /// `element_tree` and the panel's binds, TOPMOST FIRST (R-5), recomputed on
    /// every call (spec §4: never patched in place). Each row gains:
    ///   * `locked`: the EFFECTIVE lock, own flag or any ancestor's (spec §4);
    ///     the element's own flag moves to `own_locked` (R-11 is about the
    ///     document read, not the icon);
    ///   * `ancestor_layer_color`: the nearest ancestor layer's colour, which
    ///     fills the select square of an element-selected row.
    public static func treeRows(model: Model) -> [[String: Any]] {
        let all = elementTree(model.document)
        let rows = treeVisibleRows(all,
                                   collapsed: treeCollapsedPaths(model: model),
                                   panelSelection: layersPanelSelection(model: model),
                                   renaming: layersRenamingPath(model: model))
        let ownLocked = Set(all.compactMap { r -> [Int]? in
            (r["locked"] as? Bool == true) ? r["path"] as? [Int] : nil
        })
        return rows.map { row in
            var r = row
            let p = row["path"] as? [Int] ?? []
            r["own_locked"] = row["locked"] as? Bool ?? false
            r["locked"] = (1...max(p.count, 1)).contains { ownLocked.contains(Array(p.prefix($0))) }
            r["ancestor_layer_color"] = layerColor(topLevelIndex: p.first ?? 0)
            return r
        }
    }

    /// The scope the row template's expressions read: the action context's
    /// `panel` and `active_document`, so a condition or an icon sees the same
    /// values an action does.
    static func treeEvalContext(model: Model) -> [String: Any] {
        guard let ws = WorkspaceData.load() else { return [:] }
        return actionContext(model: model, ws: ws, panelSelection: [],
                             artboardsPanelSelection: [], params: [:])
    }

    // MARK: - Press routing (spec §2, DECISION S1-2)

    /// The first behaviour of `widget` for `event` whose condition holds and
    /// which names an action, with its params evaluated in `ctx` (a bare
    /// identifier that evaluates to nothing is the literal, as `modifier:
    /// "none"` is).
    private static func firstBehavior(_ widget: [String: Any], event: String,
                                      ctx: [String: Any]) -> (action: String, params: [String: Any])? {
        for entry in (widget["behavior"] as? [[String: Any]]) ?? [] {
            guard entry["event"] as? String == event else { continue }
            if let cond = entry["condition"] as? String, !cond.isEmpty,
               !evaluate(cond, context: ctx).toBool() { continue }
            guard let action = entry["action"] as? String, !action.isEmpty else { continue }
            var params: [String: Any] = [:]
            for (k, v) in (entry["params"] as? [String: Any]) ?? [:] {
                guard let expr = v as? String else { params[k] = v; continue }
                if let any = storedValue(evaluate(expr, context: ctx)) {
                    params[k] = any
                } else if isBareIdentifier(expr) {
                    params[k] = expr
                }
            }
            return (action, params)
        }
        return nil
    }

    private static func widgetVisible(_ widget: [String: Any], ctx: [String: Any]) -> Bool {
        guard let expr = (widget["bind"] as? [String: Any])?["visible"] as? String else { return true }
        return evaluate(expr, context: ctx).toBool()
    }

    /// Which action a press on `region` of the row `node` raises, read from
    /// the yaml's row template: the deepest widget under the pointer that
    /// declares a behaviour for the event and whose condition holds claims it;
    /// otherwise the press falls to the row's own behaviours. It never reaches
    /// two handlers. nil when nothing claims it.
    static func pressAction(region: LayersRowRegion, node: [String: Any], mods: LayersPressMods,
                            event: String = "click", model: Model) -> (action: String, params: [String: Any])? {
        guard let template = treeRowTemplate() else { return nil }
        var ctx = treeEvalContext(model: model)
        ctx["node"] = node
        var ev = mods.eventDict
        ev["target_id"] = region.widgetId.map { $0 as Any } ?? NSNull()
        ctx["event"] = ev
        if let wid = region.widgetId, let widget = templateWidget(wid, in: template),
           widgetVisible(widget, ctx: ctx),
           let hit = firstBehavior(widget, event: event, ctx: ctx) {
            return hit
        }
        return firstBehavior(template, event: event, ctx: ctx)
    }

    /// The action a press would raise, by name only (tests, diagnostics).
    public static func pressActionName(region: LayersRowRegion, path: [Int],
                                       mods: LayersPressMods = LayersPressMods(),
                                       model: Model) -> String? {
        guard let node = treeRows(model: model).first(where: { ($0["path"] as? [Int]) == path })
        else { return nil }
        return pressAction(region: region, node: node, mods: mods, model: model)?.action
    }

    /// Run one tree action through the app's yaml-action pipeline, then ask
    /// every view reading the panel store to redraw (spec §4).
    static func runTreeAction(_ action: String, params: [String: Any], model: Model) {
        ensureLayersScope(model)
        normalizeCollapsedPaths(model)
        dispatchYamlAction(action, model: model, params: params)
        model.panelStateVersion &+= 1
    }

    /// A press on `region` of the row at `path` (spec §2, §3). Takes the
    /// keyboard for the tree, then raises the one action the template routes
    /// the press to. A second press of a double-click raises nothing in S1
    /// (rename and isolation are later slices). Returns the action raised.
    @discardableResult
    public static func treePress(region: LayersRowRegion, path: [Int],
                                 mods: LayersPressMods = LayersPressMods(),
                                 clickCount: Int = 1,
                                 model: Model, shell: LayersTreeShell? = nil) -> String? {
        shell?.focusTree()
        guard clickCount <= 1 else { return nil }
        guard let node = treeRows(model: model).first(where: { ($0["path"] as? [Int]) == path }),
              let hit = pressAction(region: region, node: node, mods: mods, model: model)
        else { return nil }
        runTreeAction(hit.action, params: hit.params, model: model)
        if hit.action == "layers_element_select" {
            shell?.panelMadeSelection = model.document.selection.map(\.path)
        }
        return hit.action
    }

    /// A press below the last row: takes the keyboard, changes no selection
    /// (DECISION S1-3).
    public static func treePressBelowRows(shell: LayersTreeShell?) {
        shell?.focusTree()
    }

    /// The eye button's entry point: a click cycles the row's visibility, an
    /// Alt-click solos it among its siblings (the template's two `lp_eye`
    /// behaviours).
    @discardableResult
    public static func treeEyeClick(path: [Int], alt: Bool = false, model: Model,
                                    shell: LayersTreeShell? = nil) -> String? {
        treePress(region: .eye, path: path, mods: LayersPressMods(alt: alt), model: model, shell: shell)
    }

    // MARK: - Keys (spec §3)

    /// The tree's key handler, tried FIRST while the tree holds key focus.
    /// A key one of `lp_tree`'s S1 `keyboard:` rows matches runs its action and
    /// is consumed (true); any other key returns false and goes on to the
    /// application's normal route. The command chord is Cmd on the Mac (R-3):
    /// `mods.cmd` (or `mods.ctrl`, the scripts' spelling of it) is the chord's
    /// `Ctrl`.
    @discardableResult
    public static func treeKey(_ key: String, mods: KeyMods, model: Model) -> Bool {
        guard let tree = treeSpec(), let ws = WorkspaceData.load() else { return false }
        let rows = ((tree["keyboard"] as? [Any]) ?? []).filter { row in
            guard let k = (row as? [String: Any])?["key"] as? String else { return false }
            return s1TreeKeys.contains(k)
        }
        let chord = KeyChord(key: key, ctrl: mods.cmd || mods.ctrl, shift: mods.shift, alt: mods.alt)
        let ctx = actionContext(model: model, ws: ws, panelSelection: [],
                                artboardsPanelSelection: [], params: [:])
        guard let hit = resolvePanelKey(["keyboard": rows], chord: chord, context: ctx) else { return false }
        runTreeAction(hit.action, params: hit.params, model: model)
        return true
    }

    /// The keyboard focus row: the LAST panel-selected row (DECISION S1-1).
    public static func treeFocusRow(model: Model) -> [Int]? {
        layersPanelSelection(model: model).last
    }

    // MARK: - Viewport (spec §5)

    /// Reveal the element selection after it changed from outside the panel:
    /// the first selected element in document order has each collapsed
    /// ancestor removed from `collapsed_paths` (stored order otherwise kept).
    /// Returns that element's path, whose row the view then scrolls to; nil
    /// with nothing selected.
    @discardableResult
    public static func revealElementSelection(model: Model) -> [Int]? {
        let selected = model.document.selection.map(\.path)
            .sorted { $0.lexicographicallyPrecedes($1) }
        guard let first = selected.first else { return nil }
        let store = model.stateStore
        let raw = (store.getPanel(panelContentId, "collapsed_paths") as? [Any]) ?? []
        let kept = raw.filter { entry in
            guard let p = treePathOf(entry) else { return true }
            return !(p.count < first.count && Array(first.prefix(p.count)) == p)
        }
        if kept.count != raw.count {
            ensureLayersScope(model)
            store.setPanel(panelContentId, "collapsed_paths", kept)
            model.panelStateVersion &+= 1
        }
        return first
    }

    /// The new `scroll_top` that puts row `row` fully in view, moving the least
    /// distance (DECISION S1-5); unchanged when it is already in view.
    public static func revealScrollTop(row: Int, scrollTop: Int, viewportRows: Int) -> Int {
        let vp = max(viewportRows, 1)
        if row < scrollTop { return row }
        if row >= scrollTop + vp { return row - vp + 1 }
        return scrollTop
    }
}
