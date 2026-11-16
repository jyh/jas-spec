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
/// Slice S2 (spec_inputs/LAYERS-S2-interaction-spec.md) extends it in place:
/// rename (double-click on the name, F2, Enter, and the field's own events),
/// the search / type-filter rows (``LayersPanel/treeRows(model:)``), and
/// drag-and-drop, whose drop runs the `move_elements` action
/// (Document/MoveElements.swift holds the op and its one validity check).
///
/// Later slices plug in here rather than around it: isolation (double-click
/// on a container row), Delete and the context menu arrive as further events
/// through the same template lookup (``LayersPanel/pressAction``) and the same
/// keyboard table (``LayersPanel/treeKey``), gated today by
/// ``LayersPanel/s1TreeKeys`` + ``LayersPanel/s2TreeKeys`` and
/// ``LayersPanel/s2DoubleClickActions``.

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
    /// S2: the drag in progress (from `drag_start` to `drag_end`), or nil.
    @Published public var drag: LayersDragState? = nil
    /// The view's pointer gesture is in progress (its first move tried to
    /// start a drag), whether or not a drag started.
    var dragGestureOpen: Bool = false

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

    /// Any widget of the Layers panel's `content:` by id (`lp_search_input`,
    /// `lp_filter_button`), for routing its events as the panel body does.
    static func panelWidget(_ id: String) -> [String: Any]? {
        guard let content = WorkspaceData.load()?.panelContent(panelContentId) else { return nil }
        return findNode(content, id: id)
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
    ///   * `search_ancestor_only` (S2 §2): shown only because a descendant is a
    ///     search / type-filter hit; the row template dims it.
    ///
    /// S2: while `search_query` or `type_filter` is non-empty only the SHOWN
    /// rows are drawn (a hit, or an ancestor of one), and a container with a
    /// hit beneath it is drawn expanded whatever `collapsed_paths` says, which
    /// is NOT written (DECISION S2-4). In isolation only the isolated
    /// container's proper descendants are candidates.
    public static func treeRows(model: Model) -> [[String: Any]] {
        let doc = model.document
        let all = elementTree(doc)
        let pathOf = { (r: [String: Any]) -> [Int] in r["path"] as? [Int] ?? [] }
        var candidates = all
        if let iso = MoveElements.isolationRoot(model: model) {
            candidates = all.filter { r in
                let p = pathOf(r)
                return p.count > iso.count && p.starts(with: iso)
            }
        }
        let collapsed = treeCollapsedPaths(model: model)
        let selection = layersPanelSelection(model: model)
        let renaming = layersRenamingPath(model: model)
        let filtering = treeFilterActive(model: model)
        var hits: Set<[Int]> = []
        let rows: [[String: Any]]
        if filtering {
            let query = treeSearchQuery(model: model).lowercased()
            let types = Set(treeTypeFilter(model: model))
            for r in candidates where treeRowHit(r, query: query, types: types, doc: doc) {
                hits.insert(pathOf(r))
            }
            // Containers with a hit strictly beneath them: drawn expanded.
            var openAbove: Set<[Int]> = []
            for h in hits where h.count > 1 {
                for n in 1..<h.count { openAbove.insert(Array(h.prefix(n))) }
            }
            let shown = hits.union(openAbove)
            rows = treeVisibleRows(candidates.filter { shown.contains(pathOf($0)) },
                                   collapsed: collapsed.filter { !openAbove.contains($0) },
                                   panelSelection: selection, renaming: renaming)
        } else {
            rows = treeVisibleRows(candidates, collapsed: collapsed,
                                   panelSelection: selection, renaming: renaming)
        }
        let ownLocked = Set(all.compactMap { r -> [Int]? in
            (r["locked"] as? Bool == true) ? r["path"] as? [Int] : nil
        })
        return rows.map { row in
            var r = row
            let p = row["path"] as? [Int] ?? []
            r["own_locked"] = row["locked"] as? Bool ?? false
            r["locked"] = (1...max(p.count, 1)).contains { ownLocked.contains(Array(p.prefix($0))) }
            r["ancestor_layer_color"] = layerColor(topLevelIndex: p.first ?? 0)
            r["search_ancestor_only"] = filtering && !hits.contains(p)
            return r
        }
    }

    // MARK: - Search and type filter (S2 §2)

    /// `panel.search_query`.
    public static func treeSearchQuery(model: Model) -> String {
        (model.stateStore.getPanel(panelContentId, "search_query") as? String) ?? ""
    }

    /// `panel.type_filter`, the CHECKED type tokens, in stored order.
    public static func treeTypeFilter(model: Model) -> [String] {
        ((model.stateStore.getPanel(panelContentId, "type_filter") as? [Any]) ?? []).compactMap { $0 as? String }
    }

    /// A search query or a type filter is active (the one definition the rows
    /// and the drop's validity rule 4 share: ``MoveElements/filterActive(model:)``).
    public static func treeFilterActive(model: Model) -> Bool {
        MoveElements.filterActive(model: model)
    }

    /// The label a search matches: the name, or `<Type>` for an unnamed element.
    static func treeRowLabel(_ row: [String: Any]) -> String {
        let name = row["name"] as? String ?? ""
        return name.isEmpty ? "<" + (row["type_label"] as? String ?? "") + ">" : name
    }

    /// `hit(e)` = `match_q(e) ∧ match_t(e)`. `query` is already lowercased.
    /// The type token is the app's one classification, ``layersTypeValue(_:)``.
    static func treeRowHit(_ row: [String: Any], query: String, types: Set<String>, doc: Document) -> Bool {
        if !query.isEmpty, !treeRowLabel(row).lowercased().contains(query) { return false }
        if !types.isEmpty {
            guard let p = row["path"] as? [Int], let e = doc.tryGetElement(p),
                  types.contains(layersTypeValue(e)) else { return false }
        }
        return true
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

    /// The `double_click` actions this slice raises: the name's rename (S2 §1).
    /// The row's own double-click (`enter_isolation_mode`) is the isolation
    /// slice's; it plugs in by joining this set.
    public static let s2DoubleClickActions: Set<String> = ["rename_element"]

    /// Whether `action`'s declared `enabled_when` holds in the action context
    /// (true when it declares none).
    static func actionEnabled(_ action: String, model: Model) -> Bool {
        guard let ws = WorkspaceData.load(),
              let def = (ws.data["actions"] as? [String: Any])?[action] as? [String: Any],
              let cond = def["enabled_when"] as? String, !cond.isEmpty else { return true }
        let ctx = actionContext(model: model, ws: ws, panelSelection: [],
                                artboardsPanelSelection: [], params: [:])
        return evaluate(cond, context: ctx).toBool()
    }

    /// A press on `region` of the row at `path` (spec §2, §3). Takes the
    /// keyboard for the tree, then raises the one action the template routes
    /// the press to. The second press of a double-click (`clickCount` 2)
    /// raises the template's `double_click` route, limited to
    /// ``s2DoubleClickActions``: a double-click on the name opens the rename
    /// field (DECISION S2-3, S2-11: its first press already panel-selected
    /// the row). Returns the action raised.
    @discardableResult
    public static func treePress(region: LayersRowRegion, path: [Int],
                                 mods: LayersPressMods = LayersPressMods(),
                                 clickCount: Int = 1,
                                 model: Model, shell: LayersTreeShell? = nil) -> String? {
        shell?.focusTree()
        guard let node = treeRows(model: model).first(where: { ($0["path"] as? [Int]) == path })
        else { return nil }
        if clickCount >= 2 {
            guard let hit = pressAction(region: region, node: node, mods: mods,
                                        event: "double_click", model: model),
                  s2DoubleClickActions.contains(hit.action),
                  actionEnabled(hit.action, model: model)
            else { return nil }
            runTreeAction(hit.action, params: hit.params, model: model)
            return hit.action
        }
        guard let hit = pressAction(region: region, node: node, mods: mods, model: model)
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
    ///
    /// S2: F2 and Enter join (rename, `keyboard:` rows; Enter's own
    /// `enabled_when` asks for exactly one selected row, and F2 honours
    /// `rename_element`'s). While a rename is open the FIELD has the keyboard
    /// and this table is not consulted at all (DECISION S2-1). Under a search
    /// or type filter the arrow keys reach only SHOWN rows (S2 §2), as the
    /// plain row selection a nav move is (``treeFilteredNav(_:model:)``).
    @discardableResult
    public static func treeKey(_ key: String, mods: KeyMods, model: Model) -> Bool {
        if layersRenamingPath(model: model) != nil { return false }
        guard let tree = treeSpec(), let ws = WorkspaceData.load() else { return false }
        let keys = s1TreeKeys.union(s2TreeKeys)
        let rows = ((tree["keyboard"] as? [Any]) ?? []).filter { row in
            guard let k = (row as? [String: Any])?["key"] as? String else { return false }
            return keys.contains(k)
        }
        let chord = KeyChord(key: key, ctrl: mods.cmd || mods.ctrl, shift: mods.shift, alt: mods.alt)
        let ctx = actionContext(model: model, ws: ws, panelSelection: [],
                                artboardsPanelSelection: [], params: [:])
        guard let hit = resolvePanelKey(["keyboard": rows], chord: chord, context: ctx) else { return false }
        if hit.action.hasPrefix("layers_nav_"), treeFilterActive(model: model) {
            return treeFilteredNav(key, model: model)
        }
        if hit.action == "rename_element", !actionEnabled(hit.action, model: model) { return false }
        runTreeAction(hit.action, params: hit.params, model: model)
        return true
    }

    /// The S2 rows of `lp_tree`'s `keyboard:` table: rename. (Delete,
    /// Backspace and Escape-for-isolation stay with the later slice.)
    public static let s2TreeKeys: Set<String> = ["F2", "Enter"]

    /// An arrow key under a search or type filter: the nav actions walk
    /// `tree_visible_rows`, which knows no filter, so the shell moves over the
    /// SHOWN rows and raises the move a nav move is, a plain row selection
    /// (`layers_panel_select`). Up / Down: the previous / next shown row (the
    /// first / last with no focus). Left: the parent row. Right: the first
    /// shown child. `collapsed_paths` is not written while filtering (S2-4).
    static func treeFilteredNav(_ key: String, model: Model) -> Bool {
        let paths = treeRows(model: model).compactMap { $0["path"] as? [Int] }
        guard !paths.isEmpty else { return true }
        let focus = treeFocusRow(model: model)
        let idx = focus.flatMap { paths.firstIndex(of: $0) }
        var target: [Int]? = nil
        switch key {
        case "ArrowDown":
            if let i = idx { target = i + 1 < paths.count ? paths[i + 1] : nil } else { target = paths.first }
        case "ArrowUp":
            if let i = idx { target = i > 0 ? paths[i - 1] : nil } else { target = paths.last }
        case "ArrowLeft":
            if let f = focus, f.count > 1, paths.contains(Array(f.dropLast())) { target = Array(f.dropLast()) }
        case "ArrowRight":
            if let i = idx, let f = focus, i + 1 < paths.count,
               paths[i + 1].count == f.count + 1, paths[i + 1].starts(with: f) { target = paths[i + 1] }
        default:
            break
        }
        if let t = target {
            runTreeAction("layers_panel_select", params: ["path": t, "modifier": "none"], model: model)
        }
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

// MARK: - S2: inline rename (spec_inputs/LAYERS-S2-interaction-spec.md §1)

extension LayersPanel {

    /// The row being renamed (`panel.renaming_element`), or nil.
    public static func treeRenamingPath(model: Model) -> [Int]? {
        layersRenamingPath(model: model)
    }

    /// The text the rename field opens with (DECISION S2-2): the element's
    /// CURRENT name, empty for an unnamed element (never its `<Type>` label).
    /// The view selects all of it.
    public static func renameFieldInitialText(model: Model) -> String {
        guard let p = layersRenamingPath(model: model), let e = model.document.tryGetElement(p)
        else { return "" }
        return e.name ?? ""
    }

    /// The node a field event is evaluated against: the renamed row.
    private static func renamingNode(model: Model) -> [String: Any]? {
        guard let p = layersRenamingPath(model: model) else { return nil }
        return treeRows(model: model).first { ($0["path"] as? [Int]) == p }
            ?? elementTree(model.document).first { ($0["path"] as? [Int]) == p }
            ?? ["path": p]
    }

    /// Deliver one `lp_name_edit` event (`keydown` / `blur`) with `event.value`
    /// the field's text, and run the behaviour the template declares for it.
    private static func renameFieldEvent(_ event: String, _ ev: [String: Any], model: Model) -> String? {
        guard let node = renamingNode(model: model),
              let template = treeRowTemplate(),
              let widget = templateWidget("lp_name_edit", in: template) else { return nil }
        var ctx = treeEvalContext(model: model)
        ctx["node"] = node
        var e = LayersPressMods().eventDict
        for (k, v) in ev { e[k] = v }
        e["target_id"] = "lp_name_edit"
        ctx["event"] = e
        guard let hit = firstBehavior(widget, event: event, ctx: ctx) else { return nil }
        runTreeAction(hit.action, params: hit.params, model: model)
        return hit.action
    }

    /// A key in the rename field: Enter confirms with the field's text, Escape
    /// cancels (the field consumes Escape: it never exits isolation, S2-1).
    /// Any other key is the field's own (caret, deletion) and raises nothing.
    /// After Enter or Escape the keyboard returns to the tree. Returns the
    /// action raised.
    @discardableResult
    public static func renameFieldKey(_ key: String, text: String, model: Model,
                                      shell: LayersTreeShell? = nil) -> String? {
        let raised = renameFieldEvent("keydown", ["key": key, "value": text], model: model)
        if raised != nil { shell?.focusTree() }
        return raised
    }

    /// The field lost focus (a press outside it, a panel switch): confirms
    /// with the field's text while the row is still being renamed; after
    /// Enter or Escape it finds nothing to do (the template's `blur`
    /// condition).
    @discardableResult
    public static func renameFieldBlur(text: String, model: Model) -> String? {
        renameFieldEvent("blur", ["value": text], model: model)
    }
}

// MARK: - S2: drag-and-drop (spec §3)

/// Where a drop lands relative to the row under the pointer (DECISION S2-9).
public enum LayersDropZone: String, CaseIterable {
    /// Above the row's element in z order (the tree draws topmost first).
    case before
    /// Below the row's element in z order.
    case after
    /// Into the row's container, as its topmost child (DECISION S2-14).
    case into
}

/// A drop point: the row under the pointer and the zone of it.
public struct LayersDropPoint: Equatable {
    public var row: [Int]
    public var zone: LayersDropZone
    public init(row: [Int], zone: LayersDropZone) { self.row = row; self.zone = zone }
}

/// The shell's state for one drag (spec §3), from `drag_start` to `drag_end`.
public struct LayersDragState: Equatable {
    /// The row the drag started on.
    public var pressed: [Int]
    /// Where it would drop now, or nil (off the rows).
    public var point: LayersDropPoint?
    /// `drop_valid` for `point`: the op's own check.
    public var valid: Bool
    /// The row the pointer has rested on since `hoverStartMs`.
    public var hoverRow: [Int]?
    public var hoverStartMs: Double
}

extension LayersPanel {

    /// A pointer move beyond this many points with the button down starts a
    /// drag (DECISION S2-7).
    public static let dragThreshold: Double = 4
    /// Resting on a collapsed container this long expands it (layers.yaml).
    public static let hoverExpandMs: Double = 500

    /// The zone of a row the pointer is over, from its vertical position in the
    /// row (0 = top, 1 = bottom): the top quarter is before, the bottom quarter
    /// after, the middle half into a container; a leaf has only before and
    /// after, split at the middle (DECISION S2-9).
    public static func dropZone(fraction: Double, isContainer: Bool) -> LayersDropZone {
        if fraction < 0.25 { return .before }
        if fraction >= 0.75 { return .after }
        if isContainer { return .into }
        return fraction < 0.5 ? .before : .after
    }

    /// The drop point converted to `move_elements`' parameters (spec §3): the
    /// target parent (a path before the move) and `index`, in DOCUMENT order,
    /// read AFTER the dragged elements (the panel selection) are removed.
    /// "into" is the parent's child count after removal (its topmost child);
    /// "before" a row is that row's index after removal + 1 (above it);
    /// "after" a row is that index (below it). A drop before or after a
    /// DRAGGED row lands where that row was. nil when the point names no
    /// element, or "into" a non-container.
    public static func dropTarget(_ point: LayersDropPoint, model: Model) -> (parent: [Int], index: Int)? {
        let doc = model.document
        let moved = MoveElements.movedRoots(layersPanelSelection(model: model))
        let r = point.row
        guard let last = r.last, let elem = doc.tryGetElement(r) else { return nil }
        switch point.zone {
        case .into:
            switch elem {
            case .layer, .group: break
            default: return nil
            }
            let leaving = moved.filter { $0.count == r.count + 1 && Array($0.dropLast()) == r }.count
            return (r, childrenOfPath(doc, r).count - leaving)
        case .before, .after:
            let parent = Array(r.dropLast())
            let below = moved.filter {
                $0.count == r.count && Array($0.dropLast()) == parent && ($0.last ?? 0) < last
            }.count
            let at = last - below
            if moved.contains(r) { return (parent, at) }
            return (parent, point.zone == .before ? at + 1 : at)
        }
    }

    /// `drop_valid`: the drop point resolves and `move_elements`' own check
    /// accepts it (the one authority; no second copy of the rules here).
    public static func dropValid(_ point: LayersDropPoint, model: Model) -> Bool {
        guard let t = dropTarget(point, model: model) else { return false }
        return MoveElements.check(model: model, paths: layersPanelSelection(model: model),
                                  targetParent: t.parent) == nil
    }

    /// Why the drop at `point` would be refused, by the op's name; nil when valid.
    public static func dropRefusal(_ point: LayersDropPoint, model: Model) -> MoveElementsRefusal? {
        guard let t = dropTarget(point, model: model) else { return .parentNotContainer }
        return MoveElements.check(model: model, paths: layersPanelSelection(model: model),
                                  targetParent: t.parent)
    }

    /// `panel.drag_active` (shell-bound state; no action writes it).
    public static func treeDragActive(model: Model) -> Bool {
        model.stateStore.getPanel(panelContentId, "drag_active") as? Bool ?? false
    }

    private static func setDragActive(_ on: Bool, model: Model) {
        ensureLayersScope(model)
        model.stateStore.setPanel(panelContentId, "drag_active", on)
        model.panelStateVersion &+= 1
    }

    /// The row template's own behaviour for a row event (`drag_start`,
    /// `drag_end`), evaluated for `node` with `event`.
    private static func rowBehavior(_ event: String, node: [String: Any], ev: [String: Any],
                                    model: Model) -> (action: String, params: [String: Any])? {
        guard let template = treeRowTemplate() else { return nil }
        var ctx = treeEvalContext(model: model)
        ctx["node"] = node
        var e = LayersPressMods().eventDict
        for (k, v) in ev { e[k] = v }
        ctx["event"] = e
        return firstBehavior(template, event: event, ctx: ctx)
    }

    /// A drag starts on `region` of the row at `path` (the pointer moved past
    /// ``dragThreshold`` with the button down). Only a region that
    /// panel-selects starts one (S1 §2). DECISION S2-8: a row already
    /// panel-selected keeps the whole selection, which is what is dragged;
    /// otherwise the row's `drag_start` behaviour (`layers_panel_select`)
    /// makes it the selection first. `drag_active` is true until the end.
    /// Returns whether a drag started.
    @discardableResult
    public static func treeDragStart(region: LayersRowRegion, path: [Int], model: Model,
                                     shell: LayersTreeShell, nowMs: Double = 0) -> Bool {
        shell.focusTree()
        guard let node = treeRows(model: model).first(where: { ($0["path"] as? [Int]) == path }),
              pressAction(region: region, node: node, mods: LayersPressMods(), model: model)?.action
                == "layers_panel_select"
        else { return false }
        if !layersPanelSelection(model: model).contains(path),
           let hit = rowBehavior("drag_start", node: node, ev: [:], model: model) {
            runTreeAction(hit.action, params: hit.params, model: model)
        }
        setDragActive(true, model: model)
        shell.drag = LayersDragState(pressed: path, point: nil, valid: false,
                                     hoverRow: nil, hoverStartMs: nowMs)
        return true
    }

    /// The pointer moved during a drag (`drag_move`): the drop point and its
    /// validity (the indicator, or "not allowed") are recomputed, and the
    /// hover clock restarts when the pointer enters another row.
    public static func treeDragMove(to point: LayersDropPoint?, nowMs: Double, model: Model,
                                    shell: LayersTreeShell) {
        guard var d = shell.drag else { return }
        if point?.row != d.hoverRow {
            d.hoverRow = point?.row
            d.hoverStartMs = nowMs
        }
        d.point = point
        d.valid = point.map { dropValid($0, model: model) } ?? false
        shell.drag = d
        treeDragHoverTick(nowMs: nowMs, model: model, shell: shell)
    }

    /// Time passes during a drag. Resting on a COLLAPSED container for
    /// ``hoverExpandMs`` expands it: a real write, by the twirl's own action
    /// (`toggle_element_twirl`). Not while filtering, where the tree draws
    /// containers expanded as a view and `collapsed_paths` is not written
    /// (DECISION S2-4). Returns whether it expanded one.
    @discardableResult
    public static func treeDragHoverTick(nowMs: Double, model: Model, shell: LayersTreeShell) -> Bool {
        guard var d = shell.drag, let row = d.hoverRow,
              nowMs - d.hoverStartMs >= hoverExpandMs,
              !treeFilterActive(model: model),
              treeCollapsedPaths(model: model).contains(row),
              let node = treeRows(model: model).first(where: { ($0["path"] as? [Int]) == row }),
              node["is_container"] as? Bool == true
        else { return false }
        runTreeAction("toggle_element_twirl", params: ["path": row], model: model)
        d.valid = d.point.map { dropValid($0, model: model) } ?? false
        shell.drag = d
        return true
    }

    /// The button is released (`drag_end`): the row's `drag_end` behaviour
    /// raises `move_elements(drop_parent, drop_index)` when `drop_valid`
    /// holds, through the action (one undo step, its own `snapshot`). Off the
    /// rows, or refused, nothing moves. `drag_active` ends. Returns the action
    /// raised.
    @discardableResult
    public static func treeDragEnd(model: Model, shell: LayersTreeShell) -> String? {
        guard let d = shell.drag else { return nil }
        shell.drag = nil
        defer { setDragActive(false, model: model) }
        guard let point = d.point, let target = dropTarget(point, model: model) else { return nil }
        let node = elementTree(model.document).first { ($0["path"] as? [Int]) == d.pressed }
            ?? ["path": d.pressed]
        let ev: [String: Any] = ["drop_valid": dropValid(point, model: model),
                                 "drop_parent": target.parent, "drop_index": target.index]
        guard let hit = rowBehavior("drag_end", node: node, ev: ev, model: model) else { return nil }
        runTreeAction(hit.action, params: hit.params, model: model)
        return hit.action
    }

    /// The drag is abandoned (Escape, the window lost the pointer): nothing moves.
    public static func treeDragCancel(model: Model, shell: LayersTreeShell) {
        guard shell.drag != nil else { return }
        shell.drag = nil
        setDragActive(false, model: model)
    }

    /// One whole gesture, as an input script states it: press `from`, drag to
    /// `point`, rest there `hoverMs`, release. Returns the action the release
    /// raised (nil when nothing moved).
    @discardableResult
    public static func treeDrag(from path: [Int], region: LayersRowRegion = .name,
                                to point: LayersDropPoint, hoverMs: Double = 0,
                                model: Model, shell: LayersTreeShell? = nil) -> String? {
        let sh = shell ?? LayersTreeShell()
        guard treeDragStart(region: region, path: path, model: model, shell: sh, nowMs: 0) else { return nil }
        treeDragMove(to: point, nowMs: 0, model: model, shell: sh)
        treeDragHoverTick(nowMs: hoverMs, model: model, shell: sh)
        return treeDragEnd(model: model, shell: sh)
    }
}
