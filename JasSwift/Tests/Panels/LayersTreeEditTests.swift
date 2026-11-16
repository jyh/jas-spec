import Testing
import Foundation
@testable import JasLib

/// The Layers tree, slice S2 (spec_inputs/LAYERS-S2-interaction-spec.md):
/// inline rename (§1), search and the type filter (§2), drag-and-drop with its
/// constraints (§3). Every gesture goes through the tree's own entry points
/// (`treePress`, `treeKey`, `renameFieldKey` / `renameFieldBlur`, `treeDrag`)
/// or the panel's widget route (`PanelWidgetEvents`), which raise the yaml
/// actions; a drop runs `move_elements` through its action.
///
/// The fixture is S1's: two layers; layer 0 holds two leaves and a group with
/// one leaf, layer 1 one leaf. Drawn TOPMOST FIRST:
/// [1] [1,0] [0] [0,2] [0,2,0] [0,1] [0,0].
@Suite struct LayersTreeEditTests {

    private static func rect(_ x: Double) -> Element {
        .rect(Rect(x: x, y: 0, width: 10, height: 10))
    }

    private static func fixture() -> Model {
        let group = Element.group(Group(children: [rect(40)]))
        let doc = Document(
            layers: [Layer(name: "Layer 1", children: [rect(0), rect(20), group]),
                     Layer(name: "Layer 2", children: [rect(60)])])
        let m = Model(document: doc)
        LayersPanel.ensureLayersScope(m)
        return m
    }

    private static func paths(_ m: Model) -> [[Int]] {
        LayersPanel.treeRows(model: m).compactMap { $0["path"] as? [Int] }
    }

    private static func row(_ m: Model, _ p: [Int]) -> [String: Any]? {
        LayersPanel.treeRows(model: m).first { ($0["path"] as? [Int]) == p }
    }

    private static func panelSel(_ m: Model) -> [[Int]] { layersPanelSelection(model: m) }

    private static func click(_ m: Model, _ p: [Int], _ mods: LayersPressMods = LayersPressMods()) {
        LayersPanel.treePress(region: .name, path: p, mods: mods, model: m)
    }

    /// A person's double-click on the name: one click, then the second press
    /// (DECISION S2-11).
    @discardableResult
    private static func doubleClickName(_ m: Model, _ p: [Int]) -> String? {
        click(m, p)
        return LayersPanel.treePress(region: .name, path: p, clickCount: 2, model: m)
    }

    private static func name(_ m: Model, _ p: [Int]) -> String? {
        m.document.getElement(p).name
    }

    private static func collapse(_ m: Model, _ p: [Int]) {
        LayersPanel.treePress(region: .twirl, path: p, model: m)
    }

    // The panel's own widget routes, as the panel body raises them.
    private static func search(_ m: Model, _ text: String) {
        let w = LayersPanel.panelWidget("lp_search_input") ?? [:]
        PanelWidgetEvents(model: m, panelId: "layers_panel_content")
            .textEntry(w, event: "input", text: text)
    }

    private static func pick(_ m: Model, _ value: String, alt: Bool = false) {
        let w = LayersPanel.panelWidget("lp_filter_button") ?? [:]
        PanelWidgetEvents(model: m, panelId: "layers_panel_content").pick(w, value: value, alt: alt)
    }

    private static func filter(_ m: Model) -> [String] { LayersPanel.treeTypeFilter(model: m) }

    @discardableResult
    private static func drag(_ m: Model, _ from: [Int], _ to: [Int], _ zone: LayersDropZone,
                             hoverMs: Double = 0) -> String? {
        LayersPanel.treeDrag(from: from, to: LayersDropPoint(row: to, zone: zone),
                             hoverMs: hoverMs, model: m)
    }

    // MARK: - Rename (§1)

    @Test func doubleClickOnTheNameOpensTheField() {
        let m = Self.fixture()
        #expect(Self.doubleClickName(m, [0, 1]) == "rename_element")
        #expect(LayersPanel.treeRenamingPath(model: m) == [0, 1])
        #expect(Self.row(m, [0, 1])?["renaming"] as? Bool == true)
        #expect(Self.panelSel(m) == [[0, 1]], "its first click panel-selected the row")
    }

    @Test func f2RenamesTheSelectedRow() {
        let m = Self.fixture()
        Self.click(m, [0, 2])
        #expect(LayersPanel.treeKey("F2", mods: KeyMods(), model: m))
        #expect(LayersPanel.treeRenamingPath(model: m) == [0, 2])
    }

    @Test func enterRenamesOnlyWithOneSelected() {
        let one = Self.fixture()
        Self.click(one, [1, 0])
        #expect(LayersPanel.treeKey("Enter", mods: KeyMods(), model: one))
        #expect(LayersPanel.treeRenamingPath(model: one) == [1, 0])

        let two = Self.fixture()
        Self.click(two, [1, 0])
        Self.click(two, [0, 1], .command)
        #expect(!LayersPanel.treeKey("Enter", mods: KeyMods(), model: two))
        #expect(LayersPanel.treeRenamingPath(model: two) == nil)
    }

    @Test func theFieldOpensWithTheCurrentNameNeverTheTypeLabel() {
        let m = Self.fixture()
        Self.doubleClickName(m, [0, 1])
        #expect(LayersPanel.renameFieldInitialText(model: m) == "", "S2-2: unnamed opens empty")
        LayersPanel.renameFieldKey("Escape", text: "", model: m)
        Self.doubleClickName(m, [0])
        #expect(LayersPanel.renameFieldInitialText(model: m) == "Layer 1")
    }

    @Test func enterInTheFieldConfirms() {
        let m = Self.fixture()
        Self.doubleClickName(m, [0, 1])
        #expect(LayersPanel.renameFieldKey("Enter", text: "Ring", model: m) == "confirm_rename")
        #expect(Self.name(m, [0, 1]) == "Ring")
        #expect(LayersPanel.treeRenamingPath(model: m) == nil)
        #expect(LayersPanel.renameFieldBlur(text: "Ring", model: m) == nil,
                "a blur after Enter finds the row no longer renaming")
    }

    @Test func escapeInTheFieldCancelsAndWritesNothing() {
        let m = Self.fixture()
        Self.doubleClickName(m, [0, 1])
        let undoBefore = m.journal.count
        #expect(LayersPanel.renameFieldKey("Escape", text: "Ring", model: m) == "cancel_rename")
        #expect(Self.name(m, [0, 1]) == nil)
        #expect(LayersPanel.treeRenamingPath(model: m) == nil)
        #expect(m.journal.count == undoBefore, "a cancel writes nothing")
    }

    @Test func otherKeysInTheFieldRaiseNothing() {
        let m = Self.fixture()
        Self.doubleClickName(m, [0, 1])
        #expect(LayersPanel.renameFieldKey("ArrowDown", text: "Ri", model: m) == nil)
        #expect(LayersPanel.treeRenamingPath(model: m) == [0, 1])
    }

    @Test func blurConfirms() {
        let m = Self.fixture()
        Self.doubleClickName(m, [0, 1])
        #expect(LayersPanel.renameFieldBlur(text: "Ring", model: m) == "confirm_rename")
        #expect(Self.name(m, [0, 1]) == "Ring")
        #expect(LayersPanel.treeRenamingPath(model: m) == nil)
    }

    @Test func anEmptyConfirmClearsTheName() {
        let m = Self.fixture()
        Self.doubleClickName(m, [0, 1])
        LayersPanel.renameFieldKey("Enter", text: "Ring", model: m)
        Self.doubleClickName(m, [0, 1])
        #expect(LayersPanel.renameFieldInitialText(model: m) == "Ring")
        LayersPanel.renameFieldKey("Enter", text: "", model: m)
        #expect(Self.name(m, [0, 1]) == nil)
        #expect(Self.row(m, [0, 1])?["name"] as? String == "", "the row shows <Type> again")
    }

    @Test func oneUndoStepPerConfirm() {
        let m = Self.fixture()
        Self.doubleClickName(m, [0, 1])
        LayersPanel.renameFieldKey("Enter", text: "Ring", model: m)
        m.undo()
        #expect(Self.name(m, [0, 1]) == nil)
    }

    @Test func aLockedElementCanBeRenamed() {
        let m = Self.fixture()
        LayersPanel.treePress(region: .lock, path: [0], model: m)
        Self.doubleClickName(m, [0, 1])
        LayersPanel.renameFieldKey("Enter", text: "Kept", model: m)
        #expect(Self.name(m, [0, 1]) == "Kept")
    }

    @Test func whileRenamingTheTreeTableIsNotConsulted() {
        let m = Self.fixture()
        Self.doubleClickName(m, [0, 1])
        #expect(!LayersPanel.treeKey("ArrowDown", mods: KeyMods(), model: m), "S2-1: the field has the keyboard")
        #expect(!LayersPanel.treeKey("Enter", mods: KeyMods(), model: m))
        #expect(Self.panelSel(m) == [[0, 1]])
        #expect(LayersPanel.treeRenamingPath(model: m) == [0, 1])
    }

    // MARK: - Search and type filter (§2)

    @Test func searchMatchingALeafInACollapsedGroupExpandsItAsAView() {
        let m = Self.fixture()
        Self.collapse(m, [0, 2])
        Self.search(m, "Rect")
        #expect(LayersPanel.treeSearchQuery(model: m) == "Rect")
        #expect(Self.paths(m) == [[1], [1, 0], [0], [0, 2], [0, 2, 0], [0, 1], [0, 0]])
        #expect(LayersPanel.treeCollapsedPaths(model: m) == [[0, 2]], "S2-4: not written")
        Self.search(m, "")
        #expect(Self.paths(m) == [[1], [1, 0], [0], [0, 2], [0, 1], [0, 0]], "the twirl state comes back")
    }

    @Test func ancestorOnlyRowsAreMarkedAndDimmed() {
        let m = Self.fixture()
        Self.search(m, "group")
        #expect(Self.paths(m) == [[0], [0, 2]])
        #expect(Self.row(m, [0])?["search_ancestor_only"] as? Bool == true)
        #expect(Self.row(m, [0, 2])?["search_ancestor_only"] as? Bool == false)
        let opacity = (LayersPanel.treeRowTemplate()?["bind"] as? [String: Any])?["opacity"] as? String ?? ""
        var ctx = LayersPanel.treeEvalContext(model: m)
        ctx["node"] = Self.row(m, [0]) ?? [:]
        if case .number(let n) = evaluate(opacity, context: ctx) {
            #expect(n == 0.5)
        } else {
            Issue.record("the row's opacity bind evaluates to a number")
        }
    }

    @Test func searchMatchesTheTypeLabelAndTheNameCaseInsensitively() {
        let m = Self.fixture()
        Self.search(m, "<rectangle>")
        #expect(Self.paths(m) == [[1], [1, 0], [0], [0, 2], [0, 2, 0], [0, 1], [0, 0]])
        Self.search(m, "LAYER 2")
        #expect(Self.paths(m) == [[1]])
    }

    @Test func filterToggleTwiceRestores() {
        let m = Self.fixture()
        Self.pick(m, "group")
        #expect(Self.filter(m) == ["group"])
        #expect(Self.paths(m) == [[0], [0, 2]])
        #expect(Self.row(m, [0])?["search_ancestor_only"] as? Bool == true)
        Self.pick(m, "group")
        #expect(Self.filter(m).isEmpty)
        #expect(Self.paths(m).count == 7)
    }

    @Test func altToggleSolosThenRestores() {
        let m = Self.fixture()
        Self.pick(m, "group")
        Self.pick(m, "rectangle", alt: true)
        #expect(Self.filter(m) == ["rectangle"])
        Self.pick(m, "rectangle", alt: true)
        #expect(Self.filter(m).isEmpty)
    }

    @Test func allClearsTheFilter() {
        let m = Self.fixture()
        Self.pick(m, "group")
        Self.pick(m, "layer")
        #expect(Self.filter(m) == ["group", "layer"])
        Self.pick(m, "__all__")
        #expect(Self.filter(m).isEmpty)
    }

    @Test func searchAndFilterCompose() {
        let m = Self.fixture()
        Self.pick(m, "rectangle")
        Self.search(m, "layer")
        #expect(Self.paths(m).isEmpty, "no rectangle is labelled 'layer'")
        Self.pick(m, "rectangle")
        Self.pick(m, "layer")
        #expect(Self.paths(m) == [[1], [0]])
    }

    @Test func aClickUnderAFilterReplacesTheSelectionWhichSurvivesTheClear() {
        let m = Self.fixture()
        Self.click(m, [0, 0])
        Self.click(m, [1, 0], .command)
        Self.search(m, "group")
        Self.click(m, [0, 2])
        #expect(Self.panelSel(m) == [[0, 2]], "S2-5: the action's plain click wins")
        Self.search(m, "")
        #expect(Self.panelSel(m) == [[0, 2]])
    }

    @Test func arrowKeysUnderAFilterReachOnlyShownRows() {
        let m = Self.fixture()
        Self.search(m, "group")
        LayersPanel.treeKey("ArrowDown", mods: KeyMods(), model: m)
        #expect(Self.panelSel(m) == [[0]])
        LayersPanel.treeKey("ArrowDown", mods: KeyMods(), model: m)
        #expect(Self.panelSel(m) == [[0, 2]])
        LayersPanel.treeKey("ArrowDown", mods: KeyMods(), model: m)
        #expect(Self.panelSel(m) == [[0, 2]], "the last shown row")
        LayersPanel.treeKey("ArrowLeft", mods: KeyMods(), model: m)
        #expect(Self.panelSel(m) == [[0]])
        #expect(LayersPanel.treeCollapsedPaths(model: m).isEmpty)
    }

    // MARK: - Drop zones and targets (§3)

    @Test func dropZonesByRowPosition() {
        #expect(LayersPanel.dropZone(fraction: 0.1, isContainer: true) == .before)
        #expect(LayersPanel.dropZone(fraction: 0.5, isContainer: true) == .into)
        #expect(LayersPanel.dropZone(fraction: 0.9, isContainer: true) == .after)
        #expect(LayersPanel.dropZone(fraction: 0.4, isContainer: false) == .before, "a leaf has no into")
        #expect(LayersPanel.dropZone(fraction: 0.6, isContainer: false) == .after)
    }

    @Test func dropTargetsCountInDocumentOrderAfterRemoval() {
        let m = Self.fixture()
        Self.click(m, [0, 0])
        let t = { (p: [Int], z: LayersDropZone) in
            LayersPanel.dropTarget(LayersDropPoint(row: p, zone: z), model: m).map { [$0.parent, [$0.index]] }
        }
        #expect(t([0, 2], .into) == [[0, 2], [1]], "into: the topmost child")
        #expect(t([0, 2], .before) == [[0], [2]], "before: above the row, its index after removal + 1")
        #expect(t([0, 2], .after) == [[0], [1]], "after: below the row")
        #expect(t([0, 0], .after) == [[0], [0]], "a dragged row: where it was")
        #expect(t([0, 1], .into) == nil, "a leaf takes nothing into it")
    }

    // MARK: - Drag-and-drop (§3)

    @Test func leafIntoGroupLandsAsItsTopmostChild() {
        let m = Self.fixture()
        #expect(Self.drag(m, [0, 0], [0, 2], .into) == "move_elements")
        #expect(m.document.layers[0].children.count == 2)
        #expect(m.document.getElement([0, 1, 1]) == Self.rect(0), "topmost = last in document order")
        #expect(Self.panelSel(m) == [[0, 1, 1]], "S2-10: the selection is the new path")
        #expect(!LayersPanel.treeDragActive(model: m))
    }

    @Test func leafBeforeAndAfterALeaf() {
        let before = Self.fixture()
        Self.drag(before, [0, 0], [0, 1], .before)
        #expect(before.document.layers[0].children[1] == Self.rect(0), "above [0,1] in z")
        let after = Self.fixture()
        Self.drag(after, [1, 0], [0, 1], .after)
        #expect(after.document.layers[0].children[1] == Self.rect(60), "below [0,1] in z")
        #expect(after.document.layers[0].children[2] == Self.rect(20))
        #expect(Self.panelSel(after) == [[0, 1]])
    }

    @Test func groupIntoLayer() {
        let m = Self.fixture()
        Self.drag(m, [0, 2], [1], .into)
        #expect(m.document.layers[0].children.count == 2)
        if case .group = m.document.getElement([1, 1]) {} else { Issue.record("the group moved into layer 2") }
    }

    @Test func layerToTheRoot() {
        let m = Self.fixture()
        Self.drag(m, [1], [0], .after)
        #expect(m.document.layers.map(\.name) == ["Layer 2", "Layer 1"])
        #expect(Self.panelSel(m) == [[0]])
    }

    @Test func refusedDropsChangeNothing() {
        for (from, to, zone) in [([1], [0, 2], LayersDropZone.into),     // a layer into a group
                                 ([0, 2], [0, 2, 0], .after),             // into itself
                                 ([0, 1], [0], .before)] {                // a leaf to the root
            let m = Self.fixture()
            let before = m.document.layers
            #expect(Self.drag(m, from, to, zone) == nil, "\(from) \(zone) \(to)")
            #expect(m.document.layers == before)
            #expect(m.journal.isEmpty, "no undo step for a refusal")
        }
    }

    @Test func intoALockedLayerIsRefused() {
        let m = Self.fixture()
        LayersPanel.treePress(region: .lock, path: [1], model: m)
        let before = m.document.layers
        #expect(Self.drag(m, [0, 0], [1], .into) == nil)
        #expect(m.document.layers == before)
        #expect(LayersPanel.dropRefusal(LayersDropPoint(row: [1], zone: .into), model: m) == .lockedParent)
    }

    @Test func aLockedElementCanBeDragged() {
        let m = Self.fixture()
        LayersPanel.treePress(region: .lock, path: [0, 0], model: m)
        #expect(Self.drag(m, [0, 0], [1], .into) == "move_elements")
        #expect(m.document.getElement([1, 1]).isLocked)
    }

    @Test func multiRowDragWithOneInvalidElementIsRefusedWhole() {
        let m = Self.fixture()
        Self.click(m, [0, 0])
        Self.click(m, [1], .command)
        let before = m.document.layers
        #expect(Self.drag(m, [0, 0], [0, 2], .into) == nil)
        #expect(Self.panelSel(m) == [[0, 0], [1]], "S2-8: a selected row keeps the selection")
        #expect(m.document.layers == before)
    }

    @Test func multiRowDragMovesTheSelectionInDocumentOrder() {
        let m = Self.fixture()
        Self.click(m, [0, 1])
        Self.click(m, [0, 0], .command)
        #expect(Self.drag(m, [0, 1], [1], .into) == "move_elements")
        #expect(m.document.layers[1].children == [Self.rect(60), Self.rect(0), Self.rect(20)])
        #expect(Self.panelSel(m) == [[1, 2], [1, 1]], "each entry follows its element")
    }

    @Test func dragFromAnUnselectedRowSelectsItFirst() {
        let m = Self.fixture()
        Self.click(m, [1, 0])
        Self.drag(m, [0, 0], [0, 2], .into)
        #expect(m.document.layers[1].children.count == 1, "only the pressed row moved")
    }

    @Test func dragWhileSearchingIsRefused() {
        let m = Self.fixture()
        Self.search(m, "rect")
        let before = m.document.layers
        #expect(Self.drag(m, [0, 0], [0, 2], .into) == nil)
        #expect(m.document.layers == before)
    }

    @Test func aDragStartsOnlyOnARegionThatPanelSelects() {
        let m = Self.fixture()
        let shell = LayersTreeShell()
        #expect(!LayersPanel.treeDragStart(region: .eye, path: [0, 0], model: m, shell: shell))
        #expect(LayersPanel.treeDragStart(region: .preview, path: [0, 0], model: m, shell: shell))
        #expect(LayersPanel.treeDragActive(model: m))
        LayersPanel.treeDragCancel(model: m, shell: shell)
        #expect(!LayersPanel.treeDragActive(model: m))
    }

    @Test func hoveringACollapsedContainerExpandsItAfter500ms() {
        let short = Self.fixture()
        Self.collapse(short, [0, 2])
        Self.drag(short, [0, 0], [0, 2], .after, hoverMs: 200)
        // Not expanded. The leaf left [0,0] (the group shifted to [0,1]) and
        // landed below the group (the group shifted back to [0,2]).
        #expect(short.document.layers[0].children[1] == Self.rect(0))
        #expect(LayersPanel.treeCollapsedPaths(model: short) == [[0, 2]])

        let long = Self.fixture()
        Self.collapse(long, [0, 2])
        Self.drag(long, [0, 0], [0, 2], .into, hoverMs: 600)
        #expect(LayersPanel.treeCollapsedPaths(model: long).isEmpty, "a real write")
    }

    @Test func aRemovalShiftsACollapsedSibling() {
        let m = Self.fixture()
        Self.collapse(m, [0, 2])
        Self.drag(m, [0, 0], [1], .into)
        #expect(LayersPanel.treeCollapsedPaths(model: m) == [[0, 1]])
        #expect(Self.row(m, [0, 1])?["collapsed"] as? Bool == true, "the same group stays collapsed")
    }

    @Test func anInsertionShiftsACollapsedSibling() {
        let m = Self.fixture()
        Self.collapse(m, [0, 2])
        Self.drag(m, [1, 0], [0, 2], .after)
        #expect(m.document.layers[0].children[2] == Self.rect(60))
        #expect(LayersPanel.treeCollapsedPaths(model: m) == [[0, 3]])
    }

    @Test func undoAfterADropRestoresTheDocument() {
        let m = Self.fixture()
        let before = m.document.layers
        Self.drag(m, [0, 0], [0, 2], .into)
        #expect(m.document.layers != before)
        #expect(m.journal.count == 1, "one undo step")
        m.undo()
        #expect(m.document.layers == before)
    }
}
