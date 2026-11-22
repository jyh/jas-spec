import CoreGraphics
import Foundation
import Testing
@testable import JasLib

/// Two defects seen in the running Layers panel on
/// test_fixtures/svg/multi_layer.svg (layer Foreground holding a filled red
/// circle, then layer Background). See SYNTH-NOTES.md.
///
/// 1. Every row's `lp_preview` was a plain white square: the tree drew a
///    hard-coded white rectangle and never rasterized the element
///    (layers.yaml `lp_preview`; S1 §4 "best-effort … must converge").
/// 2. While isolated no `lp_breadcrumb` was drawn: the panel body's render
///    scope read `panel.isolation_stack` from the store, which nothing writes
///    (the stack lives on `Model.layersIsolationStack`), so the bar's
///    `visible: panel.isolation_stack.length > 0` was always false (S3 §1).
@Suite struct LayersPreviewAndBreadcrumbTests {

    private static let contentId = "layers_panel_content"

    /// Foreground [0] holds a red circle; Background [1] is empty.
    private static func fixture() -> Model {
        let circle = Element.ellipse(Ellipse(cx: 50, cy: 50, rx: 30, ry: 30,
                                             fill: Fill(color: Color(r: 1, g: 0, b: 0))))
        let doc = Document(layers: [Layer(name: "Foreground", children: [circle]),
                                    Layer(name: "Background", children: [])])
        let m = Model(document: doc)
        LayersPanel.ensureLayersScope(m)
        return m
    }

    /// The image composited over white, as the row draws it: RGBA bytes.
    private static func onWhite(_ img: CGImage) -> (bytes: [UInt8], w: Int, h: Int) {
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (buf, w, h)
    }

    private static func nonWhiteCount(_ img: CGImage) -> Int {
        let (b, w, h) = onWhite(img)
        var n = 0
        for i in 0..<(w * h) where b[i * 4] < 250 || b[i * 4 + 1] < 250 || b[i * 4 + 2] < 250 { n += 1 }
        return n
    }

    private static func isRedAtCentre(_ img: CGImage) -> Bool {
        let (b, w, h) = onWhite(img)
        let i = ((h / 2) * w + w / 2) * 4
        return b[i] > 200 && b[i + 1] < 60 && b[i + 2] < 60
    }

    // MARK: - Defect 1: the preview thumbnail

    @Test func aNonEmptyElementsPreviewIsNotBlank() throws {
        let m = Self.fixture()
        // The circle's row and its layer's row both show the circle.
        for path in [[0, 0], [0]] {
            let img = try #require(LayersPanel.treePreviewImage(model: m, path: path),
                                   "row \(path) must have a thumbnail")
            #expect(Self.nonWhiteCount(img) > img.width * img.height / 4,
                    "row \(path): the circle, scaled to fit, covers much of the square")
            #expect(Self.isRedAtCentre(img), "row \(path): the circle's red fill is drawn")
        }
    }

    @Test func anEmptyLayerShowsABlankPreview() {
        let m = Self.fixture()
        #expect(LayersPanel.treePreviewImage(model: m, path: [1]) == nil,
                "empty groups and layers show a blank preview")
    }

    @Test func anInvisibleElementIsPreviewedAsIfInPreviewMode() throws {
        let circle = Element.ellipse(Ellipse(cx: 10, cy: 10, rx: 5, ry: 5,
                                             fill: Fill(color: Color(r: 1, g: 0, b: 0)),
                                             visibility: .invisible))
        let img = try #require(LayersPanel.elementPreviewImage(circle))
        #expect(Self.isRedAtCentre(img))
    }

    // MARK: - Defect 2: the breadcrumb

    private static func breadcrumbVisible(_ m: Model) throws -> Bool {
        let ws = try #require(WorkspaceData.load())
        let crumb = try #require(LayersPanel.panelWidget("lp_breadcrumb"))
        let expr = try #require((crumb["bind"] as? [String: Any])?["visible"] as? String)
        let ctx = buildPanelBodyContext(ws: ws, model: m, contentId: contentId,
                                        opacityPanel: OpacityPanelState())
        return evaluate(expr, context: ctx).toBool()
    }

    @Test func theBreadcrumbIsVisibleExactlyWhileIsolated() throws {
        let m = Self.fixture()
        #expect(try !Self.breadcrumbVisible(m), "hidden while the isolation stack is empty")
        // Foreground panel-selected, then enter_isolation_mode.
        LayersPanel.treePress(region: .name, path: [0], model: m)
        LayersPanel.runPanelMenuCommand("enter_isolation_mode", model: m)
        #expect(m.layersIsolationStack == [[0]])
        #expect(try Self.breadcrumbVisible(m), "shown while the isolation stack is non-empty")
        LayersPanel.runPanelMenuCommand("exit_isolation_mode", model: m)
        #expect(m.layersIsolationStack.isEmpty)
        #expect(try !Self.breadcrumbVisible(m), "hidden again once isolation is exited")
    }

    @Test func theBreadcrumbsChevronExitsIsolation() throws {
        let m = Self.fixture()
        LayersPanel.treePress(region: .name, path: [0], model: m)
        LayersPanel.runPanelMenuCommand("enter_isolation_mode", model: m)
        #expect(m.layersIsolationStack == [[0]])
        let ws = try #require(WorkspaceData.load())
        let chevron = try #require(LayersPanel.panelWidget("lp_breadcrumb_exit_all"))
        let route = PanelWidgetEvents(model: m, panelId: Self.contentId,
                                      scope: buildPanelBodyContext(ws: ws, model: m,
                                                                   contentId: Self.contentId,
                                                                   opacityPanel: OpacityPanelState()))
        route.click(chevron)
        #expect(m.layersIsolationStack.isEmpty, "the chevron exits all levels")
        #expect(try !Self.breadcrumbVisible(m))
    }
}
