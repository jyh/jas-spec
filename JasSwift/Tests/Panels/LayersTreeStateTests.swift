import Testing
import Foundation
@testable import JasLib

/// The Layers tree, slice S1 (spec_inputs/LAYERS-S1-interaction-spec.md):
/// press routing, the eye cycle and solo, the inherited lock, twirl, element
/// versus panel selection, the arrow keys and Cmd+A, focus, and the reveal
/// rule. Every gesture goes through the tree's own entry points
/// (`LayersPanel.treePress` / `treeEyeClick` / `treeKey`), which raise the
/// yaml actions through `dispatchYamlAction`.
///
/// The fixture is the spec's S1 shape: two layers; layer 0 holds two leaves
/// and a group with one leaf, layer 1 one leaf. Drawn TOPMOST FIRST (R-5):
/// [1] [1,0] [0] [0,2] [0,2,0] [0,1] [0,0].
@Suite struct LayersTreeStateTests {

    private static func rect(_ x: Double) -> Element {
        .rect(Rect(x: x, y: 0, width: 10, height: 10))
    }

    private static func fixture(selection: [[Int]] = []) -> Model {
        let group = Element.group(Group(children: [rect(40)]))
        let doc = Document(
            layers: [Layer(name: "Layer 1", children: [rect(0), rect(20), group]),
                     Layer(name: "Layer 2", children: [rect(60)])],
            selection: selection.map { ElementSelection.all($0) })
        return Model(document: doc)
    }

    private static func paths(_ m: Model) -> [[Int]] {
        LayersPanel.treeRows(model: m).compactMap { $0["path"] as? [Int] }
    }

    private static func row(_ m: Model, _ p: [Int]) -> [String: Any]? {
        LayersPanel.treeRows(model: m).first { ($0["path"] as? [Int]) == p }
    }

    private static func panelSel(_ m: Model) -> [[Int]] { layersPanelSelection(model: m) }

    private static func clickName(_ m: Model, _ p: [Int], _ mods: LayersPressMods = LayersPressMods()) {
        LayersPanel.treePress(region: .name, path: p, mods: mods, model: m)
    }

    private static let cmd = KeyMods(cmd: true)

    // MARK: - Rows

    @Test func rowsAreDrawnTopmostFirst() {
        let m = Self.fixture()
        #expect(Self.paths(m) == [[1], [1, 0], [0], [0, 2], [0, 2, 0], [0, 1], [0, 0]])
    }

    @Test func selectSquareColourIsTheTopLevelLayersPreset() {
        let m = Self.fixture()
        #expect(Self.row(m, [0, 2, 0])?["ancestor_layer_color"] as? String == "#4a90d9")
        #expect(Self.row(m, [1, 0])?["ancestor_layer_color"] as? String == "#d94a4a")
    }

    // MARK: - Press routing (DECISION S1-2)

    @Test func eachRegionRaisesExactlyItsAction() {
        let m = Self.fixture()
        let name = { (r: LayersRowRegion, p: [Int], mods: LayersPressMods) in
            LayersPanel.pressActionName(region: r, path: p, mods: mods, model: m)
        }
        let none = LayersPressMods()
        for r in [LayersRowRegion.spacer, .leafGap, .preview, .name] {
            #expect(name(r, [0, 1], none) == "layers_panel_select", "\(r) falls to the row")
        }
        #expect(name(.eye, [0, 1], none) == "cycle_element_visibility")
        #expect(name(.eye, [0, 1], LayersPressMods(alt: true)) == "solo_element_visibility")
        #expect(name(.lock, [0, 1], none) == "toggle_element_lock")
        #expect(name(.twirl, [0, 2], none) == "toggle_element_twirl")
        #expect(name(.select, [0, 1], LayersPressMods(shift: true)) == "layers_element_select",
                "the square passes modifiers through and stays a plain select (S1-9)")
        #expect(name(.select, [0, 1], .command) == "layers_element_select")
        // A leaf has no twirl: the region is transparent and falls to the row.
        #expect(name(.twirl, [0, 1], none) == "layers_panel_select")
    }

    @Test func eyeLockTwirlAndSquareNeverPanelSelect() {
        let m = Self.fixture()
        LayersPanel.treeEyeClick(path: [0, 1], model: m)
        LayersPanel.treePress(region: .lock, path: [0, 1], model: m)
        LayersPanel.treePress(region: .twirl, path: [0, 2], model: m)
        LayersPanel.treePress(region: .select, path: [0, 1], model: m)
        #expect(Self.panelSel(m).isEmpty)
    }

    // MARK: - Panel selection

    @Test func plainClickSelectsTheRowAlone() {
        let m = Self.fixture()
        Self.clickName(m, [0, 1])
        #expect(Self.panelSel(m) == [[0, 1]])
        LayersPanel.treePress(region: .spacer, path: [1], model: m)
        #expect(Self.panelSel(m) == [[1]])
        #expect(m.document.selection.isEmpty, "panel selection never touches the element selection")
    }

    @Test func commandClickTogglesAndAppends() {
        let m = Self.fixture()
        Self.clickName(m, [0])
        Self.clickName(m, [1], .command)
        #expect(Self.panelSel(m) == [[0], [1]], "R-10: appended at the end")
        Self.clickName(m, [0], .command)
        #expect(Self.panelSel(m) == [[1]])
    }

    @Test func shiftClickRangesInDrawnOrderBothWays() {
        let m = Self.fixture()
        Self.clickName(m, [0])
        Self.clickName(m, [0, 1], LayersPressMods(shift: true))
        #expect(Self.panelSel(m) == [[0], [0, 2], [0, 2, 0], [0, 1]])

        let up = Self.fixture()
        Self.clickName(up, [0, 1])
        Self.clickName(up, [1, 0], LayersPressMods(shift: true))
        #expect(Self.panelSel(up) == [[1, 0], [0], [0, 2], [0, 2, 0], [0, 1]], "R-4/R-6: listed top to bottom")
    }

    @Test func shiftRangeAcrossACollapsedGroupBringsItsDescendants() {
        let m = Self.fixture()
        LayersPanel.treePress(region: .twirl, path: [0, 2], model: m)
        Self.clickName(m, [0])
        Self.clickName(m, [0, 1], LayersPressMods(shift: true))
        #expect(Self.panelSel(m) == [[0], [0, 2], [0, 2, 0], [0, 1]], "R-7: right after the group's row")
    }

    @Test func secondPressOfADoubleClickDoesNothing() {
        let m = Self.fixture()
        Self.clickName(m, [0])
        let raised = LayersPanel.treePress(region: .name, path: [1], mods: .command, clickCount: 2, model: m)
        #expect(raised == nil)
        #expect(Self.panelSel(m) == [[0]])
    }

    // MARK: - Element selection

    @Test func selectSquareElementSelectsAndLeavesPanelSelection() {
        let m = Self.fixture()
        Self.clickName(m, [1])
        LayersPanel.treePress(region: .select, path: [0, 1], model: m)
        #expect(m.document.selection.map(\.path) == [[0, 1]])
        #expect(Self.panelSel(m) == [[1]])
        #expect(Self.row(m, [0, 1])?["element_selected"] as? Bool == true)
    }

    // MARK: - Eye

    @Test func eyeCyclesPreviewOutlineInvisible() {
        let m = Self.fixture()
        var seen: [String] = []
        for _ in 0..<3 {
            LayersPanel.treeEyeClick(path: [0, 1], model: m)
            seen.append(Self.row(m, [0, 1])?["visibility"] as? String ?? "?")
        }
        #expect(seen == ["outline", "invisible", "preview"])
    }

    @Test func containerEyeWritesTheContainerOnly() {
        let m = Self.fixture()
        LayersPanel.treeEyeClick(path: [0], model: m)
        #expect(m.document.layers[0].visibility == .outline)
        #expect(m.document.getElement([0, 1]).visibility == .preview, "R-9: descendants keep their own")
    }

    @Test func altClickSolosThenRestores() {
        let m = Self.fixture()
        LayersPanel.treeEyeClick(path: [0, 0], model: m)   // [0,0] -> outline
        LayersPanel.treeEyeClick(path: [0, 1], alt: true, model: m)
        #expect(m.document.getElement([0, 0]).visibility == .invisible)
        #expect(m.document.getElement([0, 2]).visibility == .invisible)
        #expect(m.document.getElement([0, 1]).visibility == .preview)
        LayersPanel.treeEyeClick(path: [0, 1], alt: true, model: m)
        #expect(m.document.getElement([0, 0]).visibility == .outline, "an Outline sibling comes back Outline")
        #expect(m.document.getElement([0, 2]).visibility == .preview)
    }

    @Test func undoAfterAnEyeClickRedrawsTheRow() {
        let m = Self.fixture()
        LayersPanel.treeEyeClick(path: [0], model: m)
        #expect(Self.row(m, [0])?["visibility"] as? String == "outline")
        m.undo()
        #expect(Self.row(m, [0])?["visibility"] as? String == "preview")
    }

    // MARK: - Lock (inherited, R-8)

    @Test func lockIsInheritedAndAChildFlipsOnlyItsOwnFlag() {
        let m = Self.fixture()
        LayersPanel.treePress(region: .lock, path: [0], model: m)
        #expect(m.document.layers[0].locked)
        #expect(Self.row(m, [0, 2, 0])?["locked"] as? Bool == true, "the icon is the effective lock")
        #expect(Self.row(m, [0, 2, 0])?["own_locked"] as? Bool == false, "nothing written on the contents")
        #expect(Self.row(m, [1, 0])?["locked"] as? Bool == false)

        LayersPanel.treePress(region: .lock, path: [0, 1], model: m)
        #expect(m.document.getElement([0, 1]).isLocked, "R-8: the child's own flag flips")
        #expect(Self.row(m, [0, 1])?["locked"] as? Bool == true)

        LayersPanel.treePress(region: .lock, path: [0], model: m)
        #expect(Self.row(m, [0, 0])?["locked"] as? Bool == false)
        #expect(Self.row(m, [0, 1])?["locked"] as? Bool == true, "reads its own flag once the layer opens")
    }

    // MARK: - Twirl

    @Test func twirlCollapsesAndExpands() {
        let m = Self.fixture()
        LayersPanel.treePress(region: .twirl, path: [0, 2], model: m)
        #expect(Self.paths(m) == [[1], [1, 0], [0], [0, 2], [0, 1], [0, 0]])
        #expect(Self.row(m, [0, 2])?["collapsed"] as? Bool == true)
        LayersPanel.treePress(region: .twirl, path: [0, 2], model: m)
        #expect(Self.paths(m).count == 7)
        #expect(LayersPanel.treeCollapsedPaths(model: m).isEmpty)
    }

    // MARK: - Focus (DECISION S1-4)

    @Test func aPressAnywhereInTheTreeTakesTheKeyboard() {
        let m = Self.fixture()
        let shell = LayersTreeShell()
        #expect(shell.keyFocus == .elsewhere)
        LayersPanel.treeEyeClick(path: [0], model: m, shell: shell)
        #expect(shell.keyFocus == .tree)
        shell.keyFocus = .elsewhere
        LayersPanel.treePressBelowRows(shell: shell)
        #expect(shell.keyFocus == .tree)
        #expect(Self.panelSel(m).isEmpty, "S1-3: below the rows selects nothing")
    }

    // MARK: - Keys

    @Test func upAndDownWithAndWithoutASelection() {
        let down = Self.fixture()
        #expect(LayersPanel.treeKey("ArrowDown", mods: KeyMods(), model: down))
        #expect(Self.panelSel(down) == [[1]], "nothing selected: Down takes the first row")
        LayersPanel.treeKey("ArrowDown", mods: KeyMods(), model: down)
        #expect(Self.panelSel(down) == [[1, 0]])

        let up = Self.fixture()
        LayersPanel.treeKey("ArrowUp", mods: KeyMods(), model: up)
        #expect(Self.panelSel(up) == [[0, 0]], "nothing selected: Up takes the last row")
        LayersPanel.treeKey("ArrowUp", mods: KeyMods(), model: up)
        #expect(Self.panelSel(up) == [[0, 1]])
        #expect(LayersPanel.treeFocusRow(model: up) == [0, 1], "S1-1: the focus is the last entry")
    }

    @Test func leftCollapsesThenClimbs() {
        let m = Self.fixture()
        Self.clickName(m, [0, 2, 0])
        LayersPanel.treeKey("ArrowLeft", mods: KeyMods(), model: m)
        #expect(Self.panelSel(m) == [[0, 2]], "a leaf moves to its parent")
        LayersPanel.treeKey("ArrowLeft", mods: KeyMods(), model: m)
        #expect(LayersPanel.treeCollapsedPaths(model: m) == [[0, 2]], "an expanded container collapses")
        #expect(Self.panelSel(m) == [[0, 2]])
        LayersPanel.treeKey("ArrowLeft", mods: KeyMods(), model: m)
        #expect(Self.panelSel(m) == [[0]], "a collapsed container moves to its parent")
        LayersPanel.treeKey("ArrowLeft", mods: KeyMods(), model: m)
        #expect(LayersPanel.treeCollapsedPaths(model: m) == [[0, 2], [0]],
                "an EXPANDED top-level layer collapses first")
        LayersPanel.treeKey("ArrowLeft", mods: KeyMods(), model: m)
        #expect(Self.panelSel(m) == [[0]], "a collapsed top-level layer is a no-op")
        #expect(LayersPanel.treeCollapsedPaths(model: m) == [[0, 2], [0]])
    }

    @Test func rightExpandsThenEntersAndNeverDuplicates() {
        let m = Self.fixture()
        LayersPanel.treePress(region: .twirl, path: [0, 2], model: m)
        Self.clickName(m, [0, 2])
        LayersPanel.treeKey("ArrowRight", mods: KeyMods(), model: m)
        #expect(LayersPanel.treeCollapsedPaths(model: m).isEmpty, "R-2: expands, never adds a second entry")
        #expect(Self.panelSel(m) == [[0, 2]], "expanding does not move the selection")
        LayersPanel.treeKey("ArrowRight", mods: KeyMods(), model: m)
        #expect(Self.panelSel(m) == [[0, 2, 0]], "an expanded container moves to its first child")
        LayersPanel.treeKey("ArrowRight", mods: KeyMods(), model: m)
        #expect(Self.panelSel(m) == [[0, 2, 0]], "a leaf is a no-op")
    }

    @Test func rightOnAnEmptyContainerDoesNothing() {
        let doc = Document(layers: [Layer(name: "Layer 1", children: [.group(Group(children: []))])])
        let m = Model(document: doc)
        Self.clickName(m, [0, 0])
        LayersPanel.treeKey("ArrowRight", mods: KeyMods(), model: m)
        #expect(Self.panelSel(m) == [[0, 0]])
        #expect(LayersPanel.treeCollapsedPaths(model: m).isEmpty)
    }

    @Test func commandASelectsEveryDrawnRow() {
        let m = Self.fixture()
        LayersPanel.treePress(region: .twirl, path: [0, 2], model: m)
        #expect(LayersPanel.treeKey("a", mods: Self.cmd, model: m), "R-3: Cmd+A is the tree's Ctrl+A row")
        #expect(Self.panelSel(m) == [[1], [1, 0], [0], [0, 2], [0, 1], [0, 0]])
        #expect(m.document.selection.isEmpty, "never the canvas's select-all")
    }

    @Test func keysNoS1RowMatchesFallThrough() {
        let m = Self.fixture()
        Self.clickName(m, [0])
        #expect(!LayersPanel.treeKey("v", mods: KeyMods(), model: m))
        #expect(!LayersPanel.treeKey("Delete", mods: KeyMods(), model: m), "Delete is a later slice")
        #expect(!LayersPanel.treeKey("ArrowUp", mods: KeyMods(shift: true), model: m))
        #expect(!LayersPanel.treeKey("a", mods: KeyMods(), model: m))
        #expect(Self.panelSel(m) == [[0]])
        #expect(m.document.layers.count == 2)
    }

    // MARK: - Viewport (spec §5)

    @Test func canvasSelectionRevealsThroughCollapsedAncestors() {
        let m = Self.fixture(selection: [[0, 2, 0]])
        LayersPanel.ensureLayersScope(m)
        m.stateStore.setPanel("layers_panel_content", "collapsed_paths", [[1], [0, 2]] as [Any])
        #expect(LayersPanel.revealElementSelection(model: m) == [0, 2, 0])
        #expect(LayersPanel.treeCollapsedPaths(model: m) == [[1]], "only the ancestors open, order kept")
        #expect(Self.paths(m).contains([0, 2, 0]))
    }

    @Test func revealPicksTheFirstSelectedInDocumentOrder() {
        let m = Self.fixture(selection: [[1, 0], [0, 1]])
        #expect(LayersPanel.revealElementSelection(model: m) == [0, 1])
        #expect(LayersPanel.revealElementSelection(model: Self.fixture()) == nil)
    }

    @Test func selectSquareSelectionDoesNotRevealButACanvasOneDoes() {
        let m = Self.fixture()
        let shell = LayersTreeShell()
        LayersPanel.treePress(region: .select, path: [0, 1], model: m, shell: shell)
        #expect(!shell.takeSelectionChange(m.document.selection.map(\.path)))
        #expect(shell.takeSelectionChange([[0, 2, 0]]))
        #expect(!shell.takeSelectionChange([]))
    }

    @Test func revealScrollsTheLeastDistance() {
        #expect(LayersPanel.revealScrollTop(row: 3, scrollTop: 0, viewportRows: 5) == 0, "already in view")
        #expect(LayersPanel.revealScrollTop(row: 9, scrollTop: 0, viewportRows: 5) == 5, "bottom-aligned")
        #expect(LayersPanel.revealScrollTop(row: 2, scrollTop: 6, viewportRows: 5) == 2, "top-aligned")
        #expect(LayersPanel.revealScrollTop(row: 10, scrollTop: 6, viewportRows: 5) == 6)
    }
}
