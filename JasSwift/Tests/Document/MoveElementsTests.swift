import Testing
import Foundation
@testable import JasLib

/// `move_elements` (workspace/actions.yaml §move_elements; LAYERS-S2 §3): the
/// five validity rules refused by name, the move in document order with the
/// index read after removal, ONE undo step opened by the action's own
/// `snapshot`, and the remap of every path stored in the Layers panel's state.
@Suite struct MoveElementsTests {

    private static let pid = "layers_panel_content"

    private static func rect(_ x: Double) -> Element {
        .rect(Rect(x: x, y: 0, width: 10, height: 10))
    }

    /// L0 = [r0, r20, G[r40]], L1 = [r60].
    private static func doc() -> Document {
        Document(layers: [Layer(name: "Layer 1", children: [rect(0), rect(20), .group(Group(children: [rect(40)]))]),
                          Layer(name: "Layer 2", children: [rect(60)])])
    }

    /// nested_groups.svg's shape: L0 = [Outer[Inner[r20], r140]].
    private static func nested() -> Document {
        let inner = Element.group(Group(children: [rect(20)]))
        let outer = Element.group(Group(children: [inner, rect(140)]))
        return Document(layers: [Layer(name: "Layer 1", children: [outer])])
    }

    private static func model(_ d: Document = doc()) -> Model {
        let m = Model(document: d)
        LayersPanel.ensureLayersScope(m)
        return m
    }

    private static func setSelection(_ m: Model, _ paths: [[Int]]) {
        m.stateStore.setPanel(pid, "layers_panel_selection", paths.map { ["__path__": $0] as [String: Any] })
    }

    private static func check(_ d: Document, _ paths: [[Int]], _ parent: [Int],
                              filter: Bool = false, iso: [Int]? = nil) -> MoveElementsRefusal? {
        MoveElements.check(d, paths: paths, targetParent: parent, filterActive: filter, isolationRoot: iso)
    }

    // MARK: - Paths

    @Test func movedRootsDropDuplicatesAndDescendantsInDocumentOrder() {
        #expect(MoveElements.movedRoots([[0, 2, 0], [1, 0], [0, 2], [0, 0], [1, 0]])
                == [[0, 0], [0, 2], [1, 0]])
    }

    @Test func remapShiftsLaterSiblingsOnRemovalAndInsertion() {
        // [0,0] leaves layer 0 and lands at index 1 under layer 1.
        let f = { (p: [Int]) in MoveElements.remap(p, moved: [[0, 0]], parentAfter: [1], index: 1) }
        #expect(f([0, 0]) == [1, 1], "the moved element")
        #expect(f([0, 2, 0]) == [0, 1, 0], "a later sibling's descendant shifts down")
        #expect(f([1, 0]) == [1, 0], "below the insertion point: unchanged")
        #expect(f([1]) == [1])
        let g = { (p: [Int]) in MoveElements.remap(p, moved: [[1, 0]], parentAfter: [0], index: 1) }
        #expect(g([0, 1]) == [0, 2], "at or above the insertion point: shifts up")
        #expect(g([0, 0]) == [0, 0])
    }

    // MARK: - The five rules, refused by name

    @Test func theRefusalNamesAreTheSpecsInTheRulesOrder() {
        #expect(MoveElementsRefusal.allCases.map(\.rawValue)
                == ["into_itself_or_descendant", "locked_parent", "wrong_parent_kind",
                    "filter_active", "outside_isolation"])
    }

    @Test func rule1IntoItselfAndIntoItsDescendants() {
        #expect(Self.check(Self.doc(), [[0, 2]], [0, 2]) == .intoItselfOrDescendant)
        #expect(Self.check(Self.nested(), [[0, 0]], [0, 0, 0]) == .intoItselfOrDescendant,
                "G8: the descendant half")
    }

    @Test func rule2ALockedParentByItsOwnFlagOrAnAncestors() {
        let own = Self.doc().togglingElementLock(at: [1])
        #expect(Self.check(own, [[0, 0]], [1]) == .lockedParent)
        let inherited = Self.doc().togglingElementLock(at: [0])
        #expect(Self.check(inherited, [[1, 0]], [0, 2]) == .lockedParent)
        let lockedMover = Self.doc().togglingElementLock(at: [0, 0])
        #expect(Self.check(lockedMover, [[0, 0]], [1]) == nil, "a locked element may move")
    }

    @Test func rule3LayersToRootOrLayersEverythingElseIntoContainers() {
        #expect(Self.check(Self.doc(), [[1]], [0, 2]) == .wrongParentKind, "a layer into a group")
        #expect(Self.check(Self.doc(), [[1]], [0]) == nil, "a layer into a layer")
        #expect(Self.check(Self.doc(), [[1]], []) == nil, "a layer to the root")
        #expect(Self.check(Self.doc(), [[0, 1]], []) == .wrongParentKind, "a leaf to the root")
        #expect(Self.check(Self.doc(), [[0, 2]], [1]) == nil, "a group into a layer")
        #expect(Self.check(Self.doc(), [[0, 0]], [0, 2]) == nil, "a leaf into a group")
        #expect(Self.check(Self.doc(), [[0, 0]], [0, 1]) == .wrongParentKind, "a parent that is no container")
        #expect(Self.check(Self.doc(), [[1]], [0, 1]) == .wrongParentKind)
    }

    // MARK: - The first failure, in the rules' order

    @Test func rule1IsCheckedForEveryElementBeforeRule3ForAny() {
        // L0 = [r0], L1 = [G[r20]]. In document order the layer [0] fails rule 3
        // (a layer into a group) BEFORE [1,0] fails rule 1 (into itself); the
        // rules run in their order, so rule 1 is the first failure.
        let d = Document(layers: [Layer(name: "A", children: [Self.rect(0)]),
                                  Layer(name: "B", children: [.group(Group(children: [Self.rect(20)]))])])
        #expect(Self.check(d, [[0], [1, 0]], [1, 0]) == .intoItselfOrDescendant)
    }

    @Test func rule1BeforeRule2() {
        let d = Self.doc().togglingElementLock(at: [0, 2])
        #expect(Self.check(d, [[0, 2]], [0, 2]) == .intoItselfOrDescendant)
    }

    @Test func rule2BeforeRule3() {
        let d = Self.doc().togglingElementLock(at: [0, 2])
        #expect(Self.check(d, [[1]], [0, 2]) == .lockedParent, "a layer into a LOCKED group")
    }

    @Test func rule3BeforeRule4() {
        #expect(Self.check(Self.doc(), [[0, 1]], [], filter: true) == .wrongParentKind)
    }

    @Test func rule4BeforeRule5() {
        #expect(Self.check(Self.doc(), [[0, 0]], [1], filter: true, iso: [0]) == .filterActive)
    }

    @Test func anEmptyMoveFailsNoRule() {
        #expect(Self.check(Self.doc(), [], [0], filter: true, iso: [1]) == nil)
    }

    @Test func rule4NoMoveWhileFiltering() {
        #expect(Self.check(Self.doc(), [[0, 0]], [1], filter: true) == .filterActive)
        let m = Self.model()
        m.stateStore.setPanel(Self.pid, "search_query", "r")
        #expect(MoveElements.check(model: m, paths: [[0, 0]], targetParent: [1]) == .filterActive)
        m.stateStore.setPanel(Self.pid, "search_query", "")
        m.stateStore.setPanel(Self.pid, "type_filter", ["path"] as [Any])
        #expect(MoveElements.check(model: m, paths: [[0, 0]], targetParent: [1]) == .filterActive)
    }

    @Test func rule5InIsolationTheParentStaysInside() {
        #expect(Self.check(Self.doc(), [[0, 0]], [1], iso: [0]) == .outsideIsolation)
        #expect(Self.check(Self.doc(), [[0, 0]], [0, 2], iso: [0]) == nil, "inside it")
        #expect(Self.check(Self.doc(), [[0, 2, 0]], [0], iso: [0]) == nil, "the isolated container itself")
        let m = Self.model()
        m.layersIsolationStack = [[0]]
        #expect(MoveElements.check(model: m, paths: [[0, 0]], targetParent: [1]) == .outsideIsolation)
    }

    @Test func oneInvalidElementRefusesTheWholeMove() {
        #expect(Self.check(Self.doc(), [[0, 0], [1]], [0, 2]) == .wrongParentKind)
    }

    // MARK: - Errors, refusals and no-ops

    @Test func missingTargetsAreErrorsNotRefusals() {
        #expect(MoveElements.missingTarget(Self.doc(), paths: [[5]], targetParent: [0]) == .missingElement)
        #expect(MoveElements.missingTarget(Self.doc(), paths: [[]], targetParent: [0]) == .missingElement,
                "the root is no element to move")
        #expect(MoveElements.missingTarget(Self.doc(), paths: [[0, 0]], targetParent: [7]) == .missingParent)
        #expect(MoveElements.missingTarget(Self.doc(), paths: [[0, 0]], targetParent: []) == nil)
        #expect(Self.failure(MoveElements.apply(Self.doc(), paths: [[5]], targetParent: [0], index: 0))
                == .missingElement)
        #expect(Self.failure(MoveElements.apply(Self.doc(), paths: [[0, 0]], targetParent: [7], index: 0))
                == .missingParent)
    }

    @Test func aRefusalIsAnUnchangedSuccessCarryingTheRulesName() {
        let r = MoveElements.apply(Self.doc(), paths: [[1]], targetParent: [0, 2], index: 0)
        guard case .success(.refused(let why)) = r else { Issue.record("expected a refusal, got \(r)"); return }
        #expect(why == .wrongParentKind)
    }

    @Test func anEmptyMoveIsNothingToMove() {
        let r = MoveElements.apply(Self.doc(), paths: [], targetParent: [0], index: 0)
        guard case .success(.nothingToMove) = r else { Issue.record("expected a no-op, got \(r)"); return }
    }

    // MARK: - The move

    private static func moved(_ r: Result<MoveElementsEffect, MoveElementsError>) throws -> MoveElements.Outcome {
        guard case .success(.moved(let out)) = r else {
            Issue.record("expected a move, got \(r)")
            throw MoveElementsError.badIndex
        }
        return out
    }

    private static func failure(_ r: Result<MoveElementsEffect, MoveElementsError>) -> MoveElementsError? {
        if case .failure(let e) = r { return e }
        return nil
    }

    @Test func insertsInDocumentOrderAtTheIndexReadAfterRemoval() throws {
        let out = try Self.moved(MoveElements.apply(Self.doc(), paths: [[0, 1], [0, 0]], targetParent: [1], index: 0))
        #expect(out.document.layers[1].children == [Self.rect(0), Self.rect(20), Self.rect(60)])
        #expect(out.document.layers[0].children.count == 1)
        #expect(out.movedPaths == [[1, 0], [1, 1]])
    }

    @Test func theParentPathIsReadBeforeTheMove() throws {
        // [0,0] leaves layer 0, so the group [0,2] becomes [0,1]; into it, topmost.
        let out = try Self.moved(MoveElements.apply(Self.doc(), paths: [[0, 0]], targetParent: [0, 2], index: 1))
        #expect(out.document.getElement([0, 1, 1]) == Self.rect(0))
        #expect(out.movedPaths == [[0, 1, 1]])
    }

    @Test func anIndexPastTheChildrenIsAnError() {
        #expect(Self.failure(MoveElements.apply(Self.doc(), paths: [[0, 0]], targetParent: [1], index: 3))
                == .badIndex)
        #expect(Self.failure(MoveElements.apply(Self.doc(), paths: [[0, 0]], targetParent: [1], index: -1))
                == .badIndex)
    }

    @Test func layersMoveAtTheRootAndTheTargetLayerFollows() throws {
        let d = Self.doc().replacing(selectedLayer: 1)
        let out = try Self.moved(MoveElements.apply(d, paths: [[1]], targetParent: [], index: 0))
        #expect(out.document.layers.map(\.name) == ["Layer 2", "Layer 1"])
        #expect(out.document.selectedLayer == 0)
    }

    @Test func theElementSelectionFollowsItsElements() throws {
        let d = Self.doc().replacing(selection: [.all([0, 2, 0]), .all([0, 0])])
        let out = try Self.moved(MoveElements.apply(d, paths: [[0, 0]], targetParent: [1], index: 1))
        #expect(out.document.selection.map(\.path) == [[0, 1, 0], [1, 1]])
    }

    // MARK: - The op, through the dispatcher and the action

    @Test func theOpIsRegisteredByName() {
        let m = Self.model()
        let err = opApply(m, Controller(model: m),
                          ["op": "move_elements", "paths": [[0, 0]], "target_parent": [1], "index": 1])
        #expect(err == nil)
        #expect(m.document.layers[1].children == [Self.rect(60), Self.rect(0)])
    }

    @Test func aRefusedOpSucceedsChangesNothingAndJournalsNothing() {
        for (paths, parent) in [([[1]], [0, 2]),       // wrong_parent_kind
                                ([[0, 2]], [0, 2]),    // into_itself_or_descendant
                                ([[0, 1]], [Int]())] { // wrong_parent_kind (a leaf to the root)
            let m = Self.model()
            let before = m.document
            m.beginTxn()
            let err = opApply(m, Controller(model: m),
                              ["op": "move_elements", "paths": paths, "target_parent": parent, "index": 0])
            m.commitTxn()
            #expect(err == nil, "a refusal is no error: \(paths) → \(parent)")
            #expect(m.document == before)
            #expect(m.journal.isEmpty, "nothing journaled")
            #expect(!m.canUndo, "no undo step")
        }
    }

    @Test func aRefusedOpWithAnOutOfRangeIndexIsStillOnlyARefusal() {
        // The index is read after removal, i.e. only for a move the rules allow.
        let m = Self.model()
        let err = opApply(m, Controller(model: m),
                          ["op": "move_elements", "paths": [[1]], "target_parent": [0, 2], "index": 99])
        #expect(err == nil)
        #expect(m.document.layers == Self.doc().layers)
    }

    @Test func anEmptyOpIsANoOp() {
        let m = Self.model()
        m.beginTxn()
        let err = opApply(m, Controller(model: m),
                          ["op": "move_elements", "paths": [[Int]](), "target_parent": [0], "index": 0])
        m.commitTxn()
        #expect(err == nil)
        #expect(m.document.layers == Self.doc().layers)
        #expect(m.journal.isEmpty)
    }

    @Test func badParametersAndMissingTargetsStayErrors() {
        func run(_ paths: [[Int]], _ parent: [Int], _ index: Int) -> String? {
            let m = Self.model()
            let err = opApply(m, Controller(model: m),
                              ["op": "move_elements", "paths": paths, "target_parent": parent, "index": index])
            #expect(m.document.layers == Self.doc().layers, "an error changes nothing")
            return err?.className
        }
        #expect(run([[5]], [0], 0) == "MissingTarget", "a missing element")
        #expect(run([[0, 0]], [7], 0) == "MissingTarget", "a missing parent")
        #expect(run([[0, 0]], [1], 3) == "BadParamType", "an index out of range")
        #expect(run([[0, 0]], [1], -1) == "BadParamType", "a negative index")
    }

    @Test func theOpTakesNoSnapshotOfItsOwn() {
        let m = Self.model()
        m.beginTxn()
        opApply(m, Controller(model: m),
                ["op": "move_elements", "paths": [[0, 0]], "target_parent": [1], "index": 1])
        #expect(m.journal.isEmpty, "it joined the open step and committed nothing")
        m.commitTxn()
        #expect(m.journal.count == 1)
    }

    @Test func theActionIsOneUndoStep() {
        let m = Self.model()
        Self.setSelection(m, [[0, 0], [0, 1]])
        let before = m.document.layers
        LayersPanel.dispatchYamlAction("move_elements", model: m,
                                       params: ["target_parent": [1], "index": 1])
        #expect(m.document.layers[1].children == [Self.rect(60), Self.rect(0), Self.rect(20)])
        #expect(m.journal.count == 1)
        #expect(layersPanelSelection(model: m) == [[1, 1], [1, 2]], "the moved elements' new paths")
        m.undo()
        #expect(m.document.layers == before)
    }

    @Test func aRefusedActionLeavesNoUndoStep() {
        let m = Self.model()
        Self.setSelection(m, [[0, 1]])
        LayersPanel.dispatchYamlAction("move_elements", model: m, params: ["target_parent": [Int](), "index": 0])
        #expect(m.journal.isEmpty)
        #expect(m.document.layers == Self.doc().layers)
    }

    // MARK: - ERRATUM 3: the dragged set is reduced to its roots (S2-15)

    @Test func aNonRootIsNeverChecked() {
        // The layer [1] may go to the root; its child [1,0], a leaf, would fail
        // rule 3 there on its own. It is not a root, so it is never checked.
        #expect(Self.check(Self.doc(), [[1, 0], [1]], []) == nil)
        // The group [0,2] into layer 1 is valid; so is its child, but the
        // reduction is what keeps the child inside the group (below).
        #expect(Self.check(Self.doc(), [[0, 2, 0], [0, 2]], [1]) == nil)
    }

    @Test func theRootsAreCheckedAndTheFirstFailureNamed() {
        // Roots [0,0] (leaf) and [1] (layer) into the group [0,2]: the layer
        // fails rule 3; its own child [1,0] adds nothing to the check.
        #expect(Self.check(Self.doc(), [[1, 0], [0, 0], [1]], [0, 2]) == .wrongParentKind)
    }

    @Test func aDescendantTravelsInsideItsAncestorNeverPlacedOnItsOwn() throws {
        let out = try Self.moved(MoveElements.apply(Self.doc(), paths: [[0, 2, 0], [0, 2]],
                                                    targetParent: [1], index: 0))
        #expect(out.document.layers[1].children
                == [.group(Group(children: [Self.rect(40)])), Self.rect(60)],
                "the child stays inside the group, at its path within it")
        #expect(out.document.layers[0].children == [Self.rect(0), Self.rect(20)])
        #expect(out.moved == [[0, 2]], "only the root moves")
        #expect(out.movedPaths == [[1, 0]])
        #expect(out.remap([0, 2, 0]) == [1, 0, 0], "the descendant's path follows its root")
    }

    @Test func aLayerWithItsChildMovesAtTheRoot() throws {
        let out = try Self.moved(MoveElements.apply(Self.doc(), paths: [[1, 0], [1]], targetParent: [], index: 0))
        #expect(out.document.layers.map(\.name) == ["Layer 2", "Layer 1"])
        #expect(out.document.layers[0].children == [Self.rect(60)])
    }

    @Test func theIndexCountsOnlyTheParentsNonMovedChildren() {
        // L0 keeps r0 and r20 once the group leaves: 0...2 are in range, 3 is not.
        // The group's child is no child of L0 and is not counted either way.
        for i in 0...2 {
            if case .failure = MoveElements.apply(Self.doc(), paths: [[0, 2], [0, 2, 0]],
                                                  targetParent: [0], index: i) {
                Issue.record("index \(i) should be in range")
            }
        }
        #expect(Self.failure(MoveElements.apply(Self.doc(), paths: [[0, 2], [0, 2, 0]],
                                                targetParent: [0], index: 3)) == .badIndex)
    }

    @Test func theSelectionBecomesEverySelectedElementsNewPath() {
        let m = Self.model()
        Self.setSelection(m, [[0, 2, 0], [0, 2]])
        LayersPanel.dispatchYamlAction("move_elements", model: m,
                                       params: ["target_parent": [1], "index": 1])
        #expect(m.document.layers[1].children == [Self.rect(60), .group(Group(children: [Self.rect(40)]))])
        #expect(m.journal.count == 1)
        #expect(Set(layersPanelSelection(model: m)) == Set([[1, 1], [1, 1, 0]]),
                "the root and the descendant that travelled inside it, each by identity")
    }

    @Test func everyStoredPanelPathIsRemapped() {
        let m = Self.model()
        Self.setSelection(m, [[0, 0]])
        m.stateStore.setPanel(Self.pid, "collapsed_paths", [[0, 2], [1]] as [Any])
        m.stateStore.setPanel(Self.pid, "renaming_element", [0, 2, 0] as [Any])
        m.stateStore.setPanel(Self.pid, "solo_path", ["__path__": [0, 1]] as [String: Any])
        m.stateStore.setPanel(Self.pid, "solo_saved",
                              [[["__path__": [0, 2]] as [String: Any], "outline"] as [Any]] as [Any])
        m.layersIsolationStack = [[0, 2]]
        // Into the isolated group itself (rule 5 holds); the removal of [0,0]
        // shifts the group, and with it every path stored under it.
        LayersPanel.dispatchYamlAction("move_elements", model: m,
                                       params: ["target_parent": [0, 2], "index": 1])
        #expect(m.document.getElement([0, 1, 1]) == Self.rect(0))
        #expect(layersPanelSelection(model: m) == [[0, 1, 1]])
        #expect(LayersPanel.treeCollapsedPaths(model: m) == [[0, 1], [1]])
        #expect(layersRenamingPath(model: m) == [0, 1, 0])
        #expect(MoveElements.plainPath(m.stateStore.getPanel(Self.pid, "solo_path") as Any) == [0, 0])
        let saved = m.stateStore.getPanel(Self.pid, "solo_saved") as? [Any] ?? []
        #expect(MoveElements.plainPath((saved.first as? [Any])?.first as Any) == [0, 1])
        #expect((saved.first as? [Any])?.last as? String == "outline")
        #expect(m.layersIsolationStack == [[0, 1]])
    }
}
