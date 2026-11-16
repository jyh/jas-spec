import Testing
import Foundation
@testable import JasLib

/// TEMPORARY: dumps the two breadcrumb algorithm comparisons for the Layers
/// panel to S3-DIAG.txt at the repo root (the harness report is capped).
/// Removed once green.
@Suite struct LayersS3DiagTests {
    @Test func dump() throws {
        var out: [String] = []
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let bundleData = try Data(contentsOf: root.appendingPathComponent("workspace/workspace.json"))
        let bundle = try JSONSerialization.jsonObject(with: bundleData) as! [String: Any]
        let panels = bundle["panels"] as! [String: Any]
        for (file, fn) in [("panel_widget_tree.json", "widget_tree"), ("panel_layout.json", "layout_panel")] {
            let data = try Data(contentsOf: root.appendingPathComponent("test_fixtures/algorithms/" + file))
            let tests = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
            var mismatched: [String] = []
            for tc in tests {
                let name = tc["name"] as! String
                let args = tc["args"] as! [String: Any]
                guard let panel = panels[args["panel"] as! String] as? [String: Any] else { continue }
                let ctx = (args["ctx"] as? [String: Any]) ?? [:]
                let actual: Any = fn == "widget_tree"
                    ? WidgetTree.widgetTree(panel, ctx: ctx)
                    : PanelLayout.layoutPanel(panel, availW: (args["avail_w"] as! NSNumber).intValue,
                                              availH: (args["avail_h"] as? NSNumber)?.intValue ?? 0, ctx: ctx)
                let a = try JSONSerialization.data(withJSONObject: actual, options: [.sortedKeys])
                let e = try JSONSerialization.data(withJSONObject: tc["expected"]!, options: [.sortedKeys])
                if a != e {
                    mismatched.append(name)
                    if name.contains("layers") {
                        out.append("\(file) \(name)\nEXPECTED \(String(data: e, encoding: .utf8)!.prefix(3000))\nACTUAL   \(String(data: a, encoding: .utf8)!.prefix(3000))")
                    }
                }
            }
            out.append("\(file): \(mismatched.count) mismatched: \(mismatched)")
        }
        try? out.joined(separator: "\n").write(to: root.appendingPathComponent("S3-DIAG.txt"),
                                               atomically: true, encoding: .utf8)
    }
}
