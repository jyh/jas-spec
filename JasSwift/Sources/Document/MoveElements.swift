import Foundation

/// `move_elements` (workspace/actions.yaml §move_elements; LAYERS-S2 spec §3):
/// the one engine op that moves elements between parents.
///
/// Move the given elements, as ONE undo step, to position `index` under
/// `target_parent`. The elements leave their places and are inserted in their
/// original DOCUMENT order. `index` counts the parent's children in document
/// (z) order, 0 = the bottom child, AFTER the moved elements are removed
/// (DECISION S2-14). `target_parent` is a path in the document as it stands
/// BEFORE the move (the drop point resolves to elements before anything moves,
/// DECISION S2-12); `[]` is the document root.
///
/// THE ONE AUTHORITY FOR VALIDITY (spec §3, ERRATUM 1).
/// ``MoveElements/check(_:paths:targetParent:filterActive:isolationRoot:)``
/// states the five rules once, runs them IN THE ORDER LISTED (rule 1 for every
/// dragged ROOT in document order, then rule 2, then rule 3 for every root,
/// then 4, then 5) and returns the FIRST failure's name. The op
///
/// THE DRAGGED SET IS FIRST REDUCED TO ITS ROOTS (ERRATUM 3, decision S2-15;
/// ``movedRoots(_:)``): a path whose proper ancestor is also given is dropped;
/// that element travels inside its ancestor at its unchanged path within it,
/// and is never checked or placed under the target on its own. `index` counts
/// the target parent's children that are not being moved.
/// refuses through it, and the Layers tree's `drop_valid` (the indicator and
/// the "not allowed" pointer) is computed by calling it
/// (``MoveElements/check(model:paths:targetParent:)``), never by a second copy.
///
/// A REFUSED MOVE SUCCEEDS WITH NOTHING CHANGED: no error, no change, nothing
/// journaled, no undo step. An empty `paths` is a no-op too (not a refusal).
/// What stays an ERROR is a bad parameter or a missing target: an element or
/// a parent that does not exist, and an `index` out of range.
///
/// The op takes NO undo snapshot of its own: the `move_elements` action opens
/// the step with its `snapshot` effect, and the op's write joins it
/// (``Model/editDocument(_:)``). A refusal writes nothing, so the action's
/// transaction commits as a no-op and no undo step is left behind.
///
/// After the move every path stored in the Layers panel's state is remapped
/// through it (DECISION S2-10, widened by G17): the panel selection becomes the
/// moved elements' new paths, and `collapsed_paths` (every entry: later
/// siblings and their descendants shift too), the isolation stack, `solo_path`,
/// `solo_saved` and `renaming_element` follow their elements. The document's
/// element selection and target layer are remapped the same way.

/// Which validity rule refused a move, by the spec's name (§3, ERRATUM 1).
/// The cases are declared in the rules' order. A refusal is NOT an error: the
/// op succeeds with nothing changed.
public enum MoveElementsRefusal: String, Equatable, CaseIterable {
    /// Rule 1: the parent is a moved element or inside one.
    case intoItselfOrDescendant = "into_itself_or_descendant"
    /// Rule 2: the parent is locked, by its own flag or an ancestor's.
    case lockedParent = "locked_parent"
    /// Rule 3 (both halves): a layer goes to the root or into a layer; anything
    /// else goes into a layer or a group, never the root. A parent that is no
    /// container at all fails both halves.
    case wrongParentKind = "wrong_parent_kind"
    /// Rule 4: a search query or a type filter is active.
    case filterActive = "filter_active"
    /// Rule 5: in isolation, the parent is outside the isolated container.
    case outsideIsolation = "outside_isolation"
}

/// A move that is not a move at all: a bad parameter or a missing target.
/// These stay ERRORS (spec §3, ERRATUM 1).
public enum MoveElementsError: String, Error, Equatable, CaseIterable {
    /// A moved path names no element.
    case missingElement = "missing_element"
    /// `target_parent` names no element.
    case missingParent = "missing_parent"
    /// `index` is outside the parent's children after removal.
    case badIndex = "bad_index"
}

/// What a well-formed `move_elements` did.
public enum MoveElementsEffect {
    /// The elements moved.
    case moved(MoveElements.Outcome)
    /// A validity rule refused the move; nothing changed.
    case refused(MoveElementsRefusal)
    /// `paths` was empty; nothing changed.
    case nothingToMove
}

public enum MoveElements {

    /// The Layers panel's store scope (layers.yaml `id`).
    static let panelId = "layers_panel_content"

    // MARK: - Paths

    /// The elements that actually travel: the given paths, de-duplicated, with
    /// every path that lies inside another given path dropped (it travels
    /// inside its ancestor), in DOCUMENT order. A Shift range across a
    /// collapsed group lists the group and its descendants; moving them
    /// separately would pull the descendants out of the group.
    public static func movedRoots(_ paths: [ElementPath]) -> [ElementPath] {
        var unique: [ElementPath] = []
        for p in paths where !unique.contains(p) { unique.append(p) }
        let roots = unique.filter { p in
            !unique.contains { q in q != p && q.count < p.count && Array(p.prefix(q.count)) == q }
        }
        return roots.sorted { $0.lexicographicallyPrecedes($1) }
    }

    /// Where `p` sits once `moved` (document-ordered roots, none inside
    /// another) are removed; nil when `p` is a moved element or inside one.
    public static func pathAfterRemoval(_ p: ElementPath, moved: [ElementPath]) -> ElementPath? {
        if moved.contains(where: { p.starts(with: $0) }) { return nil }
        var out = p
        for level in 0..<p.count {
            let prefix = Array(p.prefix(level))
            let shift = moved.filter { m in
                m.count == level + 1 && Array(m.prefix(level)) == prefix && m[level] < p[level]
            }.count
            out[level] -= shift
        }
        return out
    }

    /// The path `p` (a path in the document BEFORE the move) has AFTER the
    /// move of `moved` (document-ordered roots) to `index` under the parent
    /// whose post-removal path is `parentAfter`. Every stored path goes
    /// through this one function.
    public static func remap(_ p: ElementPath, moved: [ElementPath],
                             parentAfter: ElementPath, index: Int) -> ElementPath {
        if let j = moved.firstIndex(where: { p.starts(with: $0) }) {
            return parentAfter + [index + j] + Array(p.dropFirst(moved[j].count))
        }
        guard var q = pathAfterRemoval(p, moved: moved) else { return p }
        let d = parentAfter.count
        if q.count > d, Array(q.prefix(d)) == parentAfter, q[d] >= index {
            q[d] += moved.count
        }
        return q
    }

    // MARK: - Validity (the one authority)

    /// The missing targets, which are ERRORS and not refusals: the parent
    /// first, then each moved element in document order. nil when every path
    /// names an element (`[]` as the parent is the root; `[]` as a moved path
    /// names nothing, since the root cannot move).
    public static func missingTarget(_ doc: Document, paths: [ElementPath],
                                     targetParent: ElementPath) -> MoveElementsError? {
        if !targetParent.isEmpty, doc.tryGetElement(targetParent) == nil { return .missingParent }
        for p in movedRoots(paths) where p.isEmpty || doc.tryGetElement(p) == nil {
            return .missingElement
        }
        return nil
    }

    /// The five rules of `valid(sel, parent, index)` (spec §3, ERRATUM 1), run
    /// IN THE ORDER LISTED, each for the dragged elements in DOCUMENT order;
    /// the FIRST failure's name, or nil when no rule fails. Locked MOVED
    /// elements are allowed (lock protects content, not position).
    ///
    /// An empty `paths` fails no rule (the op treats it as a no-op). A missing
    /// element or parent is not a rule's business (``missingTarget(_:paths:targetParent:)``
    /// reports it, and the op checks it first); a rule that needs the kind of
    /// a missing element or parent passes it over.
    public static func check(_ doc: Document, paths: [ElementPath], targetParent: ElementPath,
                             filterActive: Bool, isolationRoot: ElementPath?) -> MoveElementsRefusal? {
        let moved = movedRoots(paths)
        if moved.isEmpty { return nil }
        // Rule 1: `parent` is not `e` and not a descendant of `e`.
        for p in moved where !p.isEmpty && targetParent.starts(with: p) {
            return .intoItselfOrDescendant
        }
        // Rule 2: `parent` is not locked, by its own flag or any ancestor's.
        if doc.effectiveLocked(targetParent) { return .lockedParent }
        // Rule 3: `e` is a layer ⇒ `parent` is the root or a layer; `e` is not
        // a layer ⇒ `parent` is a layer or a group (never the root).
        enum ParentKind { case root, layer, group, other, missing }
        let kind: ParentKind
        if targetParent.isEmpty {
            kind = .root
        } else {
            switch doc.tryGetElement(targetParent) {
            case .none: kind = .missing
            case .some(.layer): kind = .layer
            case .some(.group): kind = .group
            case .some: kind = .other
            }
        }
        if kind != .missing {
            for p in moved where !p.isEmpty {
                guard let e = doc.tryGetElement(p) else { continue }
                let ok: Bool
                if case .layer = e {
                    ok = kind == .root || kind == .layer
                } else {
                    ok = kind == .layer || kind == .group
                }
                if !ok { return .wrongParentKind }
            }
        }
        // Rule 4: no search query or type filter is active.
        if filterActive { return .filterActive }
        // Rule 5: in isolation, `parent` is the isolated container or inside it.
        if let iso = isolationRoot, !targetParent.starts(with: iso) { return .outsideIsolation }
        return nil
    }

    /// `search_query` or `type_filter` is non-empty in the Layers panel's store.
    public static func filterActive(model: Model) -> Bool {
        let store = model.stateStore
        let query = (store.getPanel(panelId, "search_query") as? String) ?? ""
        let types = (store.getPanel(panelId, "type_filter") as? [Any]) ?? []
        return !query.isEmpty || !types.isEmpty
    }

    /// The isolated container: the top of the isolation stack, or nil.
    public static func isolationRoot(model: Model) -> ElementPath? {
        model.layersIsolationStack.last
    }

    /// ``check(_:paths:targetParent:filterActive:isolationRoot:)`` against the
    /// model's document and the Layers panel's state: what the op itself
    /// checks, and what the tree's `drop_valid` calls.
    public static func check(model: Model, paths: [ElementPath],
                             targetParent: ElementPath) -> MoveElementsRefusal? {
        check(model.document, paths: paths, targetParent: targetParent,
              filterActive: filterActive(model: model), isolationRoot: isolationRoot(model: model))
    }

    // MARK: - The move (pure)

    /// The result of a valid move: the new document and the path remap.
    public struct Outcome {
        public let document: Document
        public let moved: [ElementPath]
        public let parentAfter: ElementPath
        public let index: Int

        /// Where a path from before the move is after it.
        public func remap(_ p: ElementPath) -> ElementPath {
            MoveElements.remap(p, moved: moved, parentAfter: parentAfter, index: index)
        }

        /// The moved elements' new paths, in document order.
        public var movedPaths: [ElementPath] {
            moved.indices.map { parentAfter + [index + $0] }
        }
    }

    /// Move the elements at `paths` to `index` under `targetParent` in `doc`.
    /// Pure: the caller decides where the document goes. In order: an empty
    /// `paths` is ``MoveElementsEffect/nothingToMove``; a missing parent or
    /// element is an error; a rule's failure is ``MoveElementsEffect/refused(_:)``
    /// (the index is then never read); an `index` out of range after removal
    /// is an error; otherwise ``MoveElementsEffect/moved(_:)``.
    public static func apply(_ doc: Document, paths: [ElementPath], targetParent: ElementPath,
                             index: Int, filterActive: Bool = false,
                             isolationRoot: ElementPath? = nil) -> Result<MoveElementsEffect, MoveElementsError> {
        let moved = movedRoots(paths)
        if moved.isEmpty { return .success(.nothingToMove) }
        if let missing = missingTarget(doc, paths: moved, targetParent: targetParent) {
            return .failure(missing)
        }
        if let refusal = check(doc, paths: moved, targetParent: targetParent,
                               filterActive: filterActive, isolationRoot: isolationRoot) {
            return .success(.refused(refusal))
        }
        let elements = moved.map { doc.getElement($0) }
        guard let parentAfter = pathAfterRemoval(targetParent, moved: moved) else {
            // Unreachable: rule 1 refuses a parent inside a moved element.
            return .success(.refused(.intoItselfOrDescendant))
        }
        // Remove, later siblings first, so every earlier path stays valid.
        var d = doc
        for p in moved.reversed() { d = d.deleteElement(p) }
        var children = childrenOfPath(d, parentAfter)
        guard index >= 0, index <= children.count else { return .failure(.badIndex) }
        children.insert(contentsOf: elements, at: index)
        d = setChildrenOfPath(d, parentAfter, children)
        let outcome = Outcome(document: d, moved: moved, parentAfter: parentAfter, index: index)
        // The document's own paths follow their elements: the element
        // selection, and the target layer (`selectedLayer`) when a layer moved.
        let selection = doc.selection.map { ElementSelection(path: outcome.remap($0.path), kind: $0.kind) }
        var selectedLayer = d.selectedLayer
        if doc.selectedLayer >= 0, doc.selectedLayer < doc.layers.count {
            let p = outcome.remap([doc.selectedLayer])
            if p.count == 1 { selectedLayer = p[0] }
        }
        let finished = d.replacing(selectedLayer: selectedLayer, selection: selection)
        return .success(.moved(Outcome(document: finished, moved: moved, parentAfter: parentAfter, index: index)))
    }

    // MARK: - Panel state remap

    /// One stored path in the form it was stored: a `__path__` marker stays a
    /// marker, a plain list stays a plain list; anything else is untouched.
    static func remapStored(_ entry: Any, _ f: (ElementPath) -> ElementPath) -> Any {
        if let marker = entry as? [String: Any], let inner = marker["__path__"],
           let p = plainPath(inner) {
            var m = marker
            m["__path__"] = f(p)
            return m
        }
        if let p = plainPath(entry) { return f(p) }
        return entry
    }

    /// A path in any runtime form: `[Int]`, a list of numbers, a `__path__`
    /// marker or an evaluated `Value.path` / `AnyJSON`.
    static func plainPath(_ v: Any) -> ElementPath? {
        if let j = v as? AnyJSON { return plainPath(j.value) }
        if let val = v as? Value {
            switch val {
            case .path(let p): return p
            case .list(let items): return plainPath(items.map { $0.value })
            default: return nil
            }
        }
        if let marker = v as? [String: Any], let inner = marker["__path__"] { return plainPath(inner) }
        if let ints = v as? [Int] { return ints }
        if let arr = v as? [Any] {
            var out: ElementPath = []
            for x in arr {
                if let n = x as? NSNumber, !n.isBool { out.append(n.intValue) }
                else if let i = x as? Int { out.append(i) }
                else if let dbl = x as? Double { out.append(Int(dbl)) }
                else { return nil }
            }
            return out
        }
        return nil
    }

    /// Rewrite every path stored in the Layers panel's state through the move.
    /// The panel selection becomes the moved elements' new paths (every entry
    /// remapped: an entry inside a moved element moves with it).
    static func remapPanelState(model: Model, _ outcome: Outcome) {
        let f: (ElementPath) -> ElementPath = { outcome.remap($0) }
        model.layersIsolationStack = model.layersIsolationStack.map(f)
        let store = model.stateStore
        guard store.hasPanel(panelId) else {
            model.panelStateVersion &+= 1
            return
        }
        for key in ["layers_panel_selection", "collapsed_paths"] {
            if let list = store.getPanel(panelId, key) as? [Any] {
                store.setPanel(panelId, key, list.map { remapStored($0, f) })
            }
        }
        for key in ["solo_path", "renaming_element"] {
            if let v = store.getPanel(panelId, key), !(v is NSNull) {
                store.setPanel(panelId, key, remapStored(v, f))
            }
        }
        // `solo_saved`: [path, visibility] pairs.
        if let pairs = store.getPanel(panelId, "solo_saved") as? [Any] {
            store.setPanel(panelId, "solo_saved", pairs.map { pair -> Any in
                guard var two = pair as? [Any], !two.isEmpty else { return pair }
                two[0] = remapStored(two[0], f)
                return two
            })
        }
        model.panelStateVersion &+= 1
    }

    // MARK: - The op arm

    /// What the op arm did, for the dispatcher.
    enum OpResult: Equatable {
        /// A bad parameter or a missing target: an error, nothing journaled.
        case failed(OpApplyError)
        /// Refused by a rule, or nothing to move: success with nothing
        /// changed, so the dispatcher returns before `recordOp` and nothing is
        /// journaled.
        case unchanged
        /// The elements moved; the dispatcher journals the op.
        case moved
    }

    /// The `move_elements` arm of ``opApply(_:_:_:)``: `{op: move_elements,
    /// paths, target_parent, index}`. A refused or empty move is
    /// ``OpResult/unchanged``; a moved one writes the document through
    /// ``Model/editDocument(_:)`` (joining the action's transaction; no
    /// snapshot of its own) and remaps the Layers panel's stored paths.
    static func applyOp(_ model: Model, _ op: [String: Any]) -> OpResult {
        guard let rawPaths = op["paths"] as? [Any] else {
            return .failed(op["paths"] == nil ? .missingParam(name: "paths") : .badParamType(name: "paths"))
        }
        var paths: [ElementPath] = []
        for entry in rawPaths {
            guard let p = plainPath(entry) else { return .failed(.badParamType(name: "paths")) }
            paths.append(p)
        }
        guard let rawParent = op["target_parent"] else { return .failed(.missingParam(name: "target_parent")) }
        guard let parent = plainPath(rawParent) else { return .failed(.badParamType(name: "target_parent")) }
        guard let rawIndex = op["index"] else { return .failed(.missingParam(name: "index")) }
        let index: Int
        if let n = rawIndex as? NSNumber, !n.isBool { index = n.intValue }
        else if let i = rawIndex as? Int { index = i }
        else { return .failed(.badParamType(name: "index")) }

        switch apply(model.document, paths: paths, targetParent: parent, index: index,
                     filterActive: filterActive(model: model),
                     isolationRoot: isolationRoot(model: model)) {
        case .failure(let error):
            switch error {
            case .missingElement, .missingParent:
                return .failed(.missingTarget(id: "move_elements: \(error.rawValue)"))
            case .badIndex:
                return .failed(.badParamType(name: "move_elements: \(error.rawValue)"))
            }
        case .success(.nothingToMove), .success(.refused):
            return .unchanged
        case .success(.moved(let outcome)):
            model.editDocument(outcome.document)
            remapPanelState(model: model, outcome)
            return .moved
        }
    }
}
