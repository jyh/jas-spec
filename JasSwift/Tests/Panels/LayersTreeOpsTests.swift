import Testing
import Foundation
@testable import JasLib

/// The Layers tree, slice S3 (spec_inputs/LAYERS-S3-interaction-spec.md): the
/// panel menu, the context menu, Escape's order, the delete routing,
/// isolation (row double-click, menus, breadcrumb, Escape) and the panel's
/// half of Options for Layer. Every gesture goes through the tree's own entry
/// points (`treePress`, `treeSecondaryPress`, `treeMenuChoose`, `treeKey`,
/// `treeEscape`, `treeBreadcrumbClick`), which raise the yaml actions.
///
/// The fixture is S1's: two layers; layer 0 holds two leaves and a group with
/// one leaf, layer 1 one leaf. Drawn TOPMOST FIRST:
/// [1] [1,0] [0] [0,2] [0,2,0] [0,1] [0,0].
@Suite struct LayersTreeOpsTests {

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

    private static func panelSel(_ m: Model) -> [[Int]] { layersPanelSelection(model: m) }

    private static func click(_ m: Model, _ p: [Int], _ region: LayersRowRegion = .name,
                              _ mods: LayersPressMods = LayersPressMods(), shell: LayersTreeShell? = nil) {
        LayersPanel.treePress(region: region, path: p, mods: mods, model: m, shell: shell)
    }

    /// A person's double-click on `region`: one click, then the second press
    /// (DECISION S2-11; S3 §1: the row is the sole selection when it arrives).
    @discardableResult
    private static func doubleClick(_ m: Model, _ p: [Int], _ region: LayersRowRegion = .preview,
                                    shell: LayersTreeShell? = nil) -> String? {
        click(m, p, region, shell: shell)
        return LayersPanel.treePress(region: region, path: p, clickCount: 2, model: m, shell: shell)
    }

    private static func children(_ m: Model, _ layer: Int) -> Int {
        m.document.layers[layer].children.count
    }

    private static func item(_ menu: LayersOpenMenu?, _ action: String) -> LayersMenuItem? {
        menu?.items.first { !$0.isSeparator && $0.action == action }
    }

    // MARK: - Context menu (§1)

    @Test func aSecondaryPressOnAnUnselectedRowSelectsItAloneFirst() {
        let m = Self.fixture()
        let sh = LayersTreeShell()
        Self.click(m, [0, 0])
        let menu = LayersPanel.treeSecondaryPress(path: [1, 0], model: m, shell: sh)
        #expect(Self.panelSel(m) == [[1, 0]], "the row becomes the SOLE panel selection")
        #expect(menu?.kind == .context)
        #expect(menu?.row == [1, 0])
        #expect(sh.openMenu != nil)
        #expect(sh.keyFocus == .tree)
        // The press dispatched nothing else: the document is untouched.
        #expect(Self.children(m, 0) == 3 && Self.children(m, 1) == 1)
    }

    @Test func aSecondaryPressOnASelectedRowKeepsTheSelection() {
        let m = Self.fixture()
        let sh = LayersTreeShell()
        Self.click(m, [0, 0])
        Self.click(m, [0, 1], .name, .command)
        LayersPanel.treeSecondaryPress(path: [0, 1], model: m, shell: sh)
        #expect(Set(Self.panelSel(m)) == Set([[0, 0], [0, 1]]))
    }

    @Test func aSecondaryPressBelowTheLastRowOpensNothing() {
        let m = Self.fixture()
        let sh = LayersTreeShell()
        Self.click(m, [0, 0])
        #expect(LayersPanel.treeSecondaryPress(path: nil, model: m, shell: sh) == nil)
        #expect(sh.openMenu == nil)
        #expect(Self.panelSel(m) == [[0, 0]], "the selection is untouched")
    }

    @Test func theContextMenuIsEvaluatedWithTheRowBound() {
        let m = Self.fixture()
        let sh = LayersTreeShell()
        let onLeaf = LayersPanel.treeSecondaryPress(path: [1, 0], model: m, shell: sh)
        #expect(Self.item(onLeaf, "open_layer_options")?.enabled == false, "only a layer has options")
        #expect(Self.item(onLeaf, "duplicate_layer_selection")?.enabled == true)
        #expect(Self.item(onLeaf, "enter_isolation_mode")?.enabled == false, "a leaf cannot be isolated")
        let onLayer = LayersPanel.treeSecondaryPress(path: [0], model: m, shell: sh)
        #expect(Self.item(onLayer, "open_layer_options")?.enabled == true)
        #expect(Self.item(onLayer, "enter_isolation_mode")?.label == "Enter Isolation Mode")
        #expect(Self.item(onLayer, "enter_isolation_mode")?.enabled == true)
    }

    @Test func aDisabledItemClaimsItsPressWithoutActing() {
        let m = Self.fixture()
        let sh = LayersTreeShell()
        LayersPanel.treeSecondaryPress(path: [1, 0], model: m, shell: sh)
        #expect(LayersPanel.treeMenuChoose(action: "open_layer_options", model: m, shell: sh) == nil)
        #expect(m.stateStore.getDialogId() == nil)
        #expect(sh.openMenu == nil, "the press closed the menu")
    }

    @Test func duplicateFromTheContextMenu() {
        let m = Self.fixture()
        let sh = LayersTreeShell()
        LayersPanel.treeSecondaryPress(path: [1, 0], model: m, shell: sh)
        #expect(LayersPanel.treeMenuChoose(action: "duplicate_layer_selection", model: m, shell: sh)
                == "duplicate_layer_selection")
        #expect(Self.children(m, 1) == 2)
    }

    @Test func deleteSelectionFromTheContextMenu() {
        let m = Self.fixture()
        let sh = LayersTreeShell()
        LayersPanel.treeSecondaryPress(path: [1, 0], model: m, shell: sh)
        #expect(LayersPanel.treeMenuChoose(action: "delete_layer_selection", model: m, shell: sh)
                == "delete_layer_selection")
        #expect(Self.children(m, 1) == 0)
        #expect(Self.panelSel(m).isEmpty, "the action leaves []; that is what is drawn")
    }

    // MARK: - Options for Layer (§1, G6)

    @Test func optionsForLayerOpensTheDialogOnTheRowsLayer() {
        let m = Self.fixture()
        let sh = LayersTreeShell()
        LayersPanel.treeSecondaryPress(path: [1], model: m, shell: sh)
        #expect(LayersPanel.treeMenuChoose(action: "open_layer_options", params: ["mode": "edit"],
                                           model: m, shell: sh) == "open_layer_options")
        #expect(m.stateStore.getDialogId() == "layer_options")
        let params = m.stateStore.getDialogParams() ?? [:]
        #expect(params["layer_id"] as? String == "1", "the row's PATH names the layer")
        #expect(params["mode"] as? String == "edit")
    }

    @Test func optionsForLayerOkEditsTheLayerAndNeverCreatesOne() {
        let m = Self.fixture()
        let sh = LayersTreeShell()
        LayersPanel.treeSecondaryPress(path: [0], model: m, shell: sh)
        LayersPanel.treeMenuChoose(action: "open_layer_options", model: m, shell: sh)
        let layerId = m.stateStore.getDialogParams()?["layer_id"] as? String
        #expect(layerId == "0")
        // OK, as the dialog's lo_ok passes its params.
        LayersPanel.dispatchYamlAction("layer_options_confirm", model: m,
                                       params: ["layer_id": layerId ?? NSNull(), "name": "Art",
                                                "lock": true, "show": false, "preview": true])
        #expect(m.document.layers.count == 2, "EDIT, never create")
        #expect(m.document.layers[0].name == "Art")
        #expect(m.document.layers[0].locked == true)
        #expect(m.document.layers[0].visibility == .invisible)
    }

    // MARK: - Panel menu (§1)

    @Test func thePanelMenuLabelsAreEvaluatedWhenItOpens() {
        let m = Self.fixture()
        let sh = LayersTreeShell()
        let menu = LayersPanel.treeOpenPanelMenu(model: m, shell: sh)
        #expect(Self.item(menu, "toggle_all_layers_visibility")?.label == "Hide All Layers")
        #expect(Self.item(menu, "toggle_all_layers_lock")?.label == "Lock All Layers")
        #expect(LayersPanel.treeMenuChoose(action: "toggle_all_layers_visibility", model: m, shell: sh)
                == "toggle_all_layers_visibility")
        #expect(m.document.layers.allSatisfy { $0.visibility == .invisible })
        let again = LayersPanel.treeOpenPanelMenu(model: m, shell: sh)
        #expect(Self.item(again, "toggle_all_layers_visibility")?.label == "Show All Layers")
        LayersPanel.treeMenuChoose(action: "toggle_all_layers_visibility", model: m, shell: sh)
        #expect(m.document.layers.allSatisfy { $0.visibility == .preview })
    }

    @Test func toggleAllLockBothDirections() {
        let m = Self.fixture()
        let sh = LayersTreeShell()
        LayersPanel.treeOpenPanelMenu(model: m, shell: sh)
        LayersPanel.treeMenuChoose(action: "toggle_all_layers_lock", model: m, shell: sh)
        #expect(m.document.layers.allSatisfy { $0.locked })
        let menu = LayersPanel.treeOpenPanelMenu(model: m, shell: sh)
        #expect(Self.item(menu, "toggle_all_layers_lock")?.label == "Unlock All Layers")
        LayersPanel.treeMenuChoose(action: "toggle_all_layers_lock", model: m, shell: sh)
        #expect(m.document.layers.allSatisfy { !$0.locked })
    }

    @Test func newLayerFromThePanelMenuRunsDirectlyWithNoDialog() {
        let m = Self.fixture()
        let sh = LayersTreeShell()
        LayersPanel.treeOpenPanelMenu(model: m, shell: sh)
        #expect(LayersPanel.treeMenuChoose(action: "new_layer", model: m, shell: sh) == "new_layer")
        #expect(m.document.layers.count == 3, "S3-4: no dialog, the layer is made")
        #expect(m.stateStore.getDialogId() == nil)
    }

    @Test func aDisabledPanelMenuItemDoesNothing() {
        let m = Self.fixture()
        let sh = LayersTreeShell()
        let menu = LayersPanel.treeOpenPanelMenu(model: m, shell: sh)
        #expect(Self.item(menu, "enter_isolation_mode")?.enabled == false, "nothing selected")
        #expect(Self.item(menu, "exit_isolation_mode")?.enabled == false, "not isolated")
        #expect(LayersPanel.treeMenuChoose(action: "enter_isolation_mode", model: m, shell: sh) == nil)
        #expect(m.layersIsolationStack.isEmpty)
        // The hamburger's own route is gated the same way.
        LayersPanel.runPanelMenuCommand("enter_isolation_mode", model: m)
        #expect(m.layersIsolationStack.isEmpty)
    }

    @Test func enterAndExitIsolationFromThePanelMenu() {
        let m = Self.fixture()
        let sh = LayersTreeShell()
        Self.click(m, [0, 2])
        LayersPanel.treeOpenPanelMenu(model: m, shell: sh)
        #expect(LayersPanel.treeMenuChoose(action: "enter_isolation_mode", model: m, shell: sh)
                == "enter_isolation_mode")
        #expect(m.layersIsolationStack == [[0, 2]])
        let menu = LayersPanel.treeOpenPanelMenu(model: m, shell: sh)
        #expect(Self.item(menu, "collect_in_new_layer")?.enabled == false, "disabled in isolation")
        LayersPanel.treeMenuChoose(action: "exit_isolation_mode", model: m, shell: sh)
        #expect(m.layersIsolationStack.isEmpty, "entering saved nothing, exiting restores nothing (S3-6)")
    }

    // MARK: - Isolation (§1)

    @Test func aRowDoubleClickOutsideTheNameIsolatesAContainer() {
        let m = Self.fixture()
        #expect(Self.doubleClick(m, [0]) == "enter_isolation_mode")
        #expect(m.layersIsolationStack == [[0]])
        #expect(Self.paths(m) == [[0, 2], [0, 2, 0], [0, 1], [0, 0]],
                "only the isolated container's proper descendants are drawn")
    }

    @Test func aDoubleClickOnTheNameRenamesAndOnALeafDoesNothing() {
        let m = Self.fixture()
        #expect(Self.doubleClick(m, [0], .name) == "rename_element")
        #expect(m.layersIsolationStack.isEmpty)
        LayersPanel.renameFieldKey("Escape", text: "", model: m)
        #expect(Self.doubleClick(m, [0, 0]) == nil, "a leaf is not a container")
        #expect(m.layersIsolationStack.isEmpty)
        #expect(Self.doubleClick(m, [0], .eye) == nil, "a button's presses are its own")
        #expect(m.layersIsolationStack.isEmpty)
    }

    @Test func nestedIsolationAndTheBreadcrumb() {
        let m = Self.fixture()
        Self.doubleClick(m, [0])
        Self.doubleClick(m, [0, 2])
        #expect(m.layersIsolationStack == [[0], [0, 2]])
        #expect(Self.paths(m) == [[0, 2, 0]])
        let crumbs = LayersPanel.treeBreadcrumb(model: m)
        #expect(crumbs.map { $0.label } == ["Layer 1", "<Group>"], "each level's element name, outermost first")
        #expect(crumbs.map { $0.levelIndex } == [1, 2])
        // Segment 1 keeps one level.
        LayersPanel.treeBreadcrumbClick(levelIndex: 1, model: m)
        #expect(m.layersIsolationStack == [[0]])
        // The chevron exits all.
        Self.doubleClick(m, [0, 2])
        LayersPanel.treeBreadcrumbClick(levelIndex: 0, model: m)
        #expect(m.layersIsolationStack.isEmpty)
        #expect(LayersPanel.treeBreadcrumb(model: m).isEmpty)
    }

    @Test func theCanvasSplitDimsEverythingOutsideTheIsolatedContainer() throws {
        let m = Self.fixture()
        let split = try #require(LayersPanel.isolationCanvasLayers(m.document, root: [0, 2]))
        // Background: the isolated group alone is hidden.
        #expect(split.background[0].children[2].visibility == .invisible)
        #expect(split.background[0].children[0].visibility == .preview)
        #expect(split.background[1].visibility == .preview)
        // Foreground: everything off the path to the group is hidden.
        #expect(split.foreground[1].visibility == .invisible)
        #expect(split.foreground[0].visibility == .preview)
        #expect(split.foreground[0].children[0].visibility == .invisible)
        #expect(split.foreground[0].children[1].visibility == .invisible)
        #expect(split.foreground[0].children[2].visibility == .preview)
        // The document itself is never written.
        #expect(m.document.layers[1].visibility == .preview)
        let stale = LayersPanel.isolationCanvasLayers(m.document, root: [5]) == nil
        #expect(stale, "a root naming no element: the canvas draws normally")
    }

    // MARK: - Escape's order (§1)

    @Test func escapeWithAMenuOpenClosesTheMenuAndKeepsIsolation() {
        let m = Self.fixture()
        let sh = LayersTreeShell()
        Self.doubleClick(m, [0], shell: sh)
        LayersPanel.treeSecondaryPress(path: [0, 2], model: m, shell: sh)
        #expect(LayersPanel.treeKey("Escape", mods: KeyMods(), model: m, shell: sh))
        #expect(sh.openMenu == nil)
        #expect(m.layersIsolationStack == [[0]], "the menu consumed the Escape")
        #expect(LayersPanel.treeEscape(model: m, shell: sh) == .exitedIsolationLevel)
        #expect(m.layersIsolationStack.isEmpty)
        #expect(LayersPanel.treeEscape(model: m, shell: sh) == .nothing)
    }

    @Test func escapeDuringARenameCancelsItAndKeepsIsolation() {
        let m = Self.fixture()
        let sh = LayersTreeShell()
        Self.doubleClick(m, [0], shell: sh)
        Self.doubleClick(m, [0, 1], .name, shell: sh)
        #expect(LayersPanel.treeRenamingPath(model: m) == [0, 1])
        #expect(LayersPanel.treeEscape(model: m, shell: sh) == .cancelledRename)
        #expect(LayersPanel.treeRenamingPath(model: m) == nil)
        #expect(m.layersIsolationStack == [[0]])
    }

    @Test func escapePopsOneIsolationLevelAtATime() {
        let m = Self.fixture()
        let sh = LayersTreeShell()
        Self.doubleClick(m, [0], shell: sh)
        Self.doubleClick(m, [0, 2], shell: sh)
        #expect(LayersPanel.treeKey("Escape", mods: KeyMods(), model: m, shell: sh))
        #expect(m.layersIsolationStack == [[0]])
        #expect(LayersPanel.treeKey("Escape", mods: KeyMods(), model: m, shell: sh))
        #expect(m.layersIsolationStack.isEmpty)
    }

    // MARK: - Delete (§1, G14)

    @Test func deleteAndBackspaceInTheTreeDeleteThePanelSelection() {
        let m = Self.fixture()
        let sh = LayersTreeShell()
        Self.click(m, [0, 1], shell: sh)
        #expect(LayersPanel.treeKey("Delete", mods: KeyMods(), model: m, shell: sh))
        #expect(Self.children(m, 0) == 2)
        #expect(Self.panelSel(m).isEmpty)
        Self.click(m, [1, 0], shell: sh)
        #expect(LayersPanel.treeKey("Backspace", mods: KeyMods(), model: m, shell: sh))
        #expect(Self.children(m, 1) == 0)
    }

    @Test func deleteWithNothingSelectedDoesNothing() {
        let m = Self.fixture()
        #expect(LayersPanel.treeDeleteSelection(model: m) == nil)
        #expect(Self.children(m, 0) == 3 && Self.children(m, 1) == 1)
    }

    @Test func deleteIsOneUndoStep() {
        let m = Self.fixture()
        Self.click(m, [0, 0])
        Self.click(m, [0, 1], .name, .command)
        LayersPanel.treeDeleteSelection(model: m)
        #expect(Self.children(m, 0) == 1)
        m.undo()
        #expect(Self.children(m, 0) == 3)
    }
}
