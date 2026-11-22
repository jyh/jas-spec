/// The Layers row's `lp_preview` thumbnail (layers.yaml `lp_preview`,
/// LAYERS.md ELEMENT_PREVIEW): "a 24px square rasterized thumbnail of the
/// element, scaled to fit on a white background … Outline/invisible elements
/// are rendered as if in preview mode. Empty containers show blank."
/// Best-effort (S1 §4): the tree draws it from the document on every render,
/// so it converges as soon as the document is idle.
///
/// The image is the element's ink only; the white background and the frame
/// are the row's (LayersTreeView). nil means a blank preview: an empty group
/// or layer, or an element with nothing to measure.

import CoreGraphics
import Foundation

extension LayersPanel {

    /// The thumbnail's side in points (DECISION S1-7: 24).
    public static let previewSide = 24

    /// The thumbnail of the element at `path` in the model's document, at
    /// `pixelScale` pixels per point; nil for a blank preview.
    public static func treePreviewImage(model: Model, path: [Int],
                                        pixelScale: Int = 2) -> CGImage? {
        guard let elem = model.document.tryGetElement(path) else { return nil }
        return elementPreviewImage(elem, pixelScale: pixelScale)
    }

    /// Rasterize `elem` scaled to fit a `previewSide` square (aspect kept,
    /// centred, a one-point margin) on a transparent background. nil when the
    /// element occupies nothing (an empty container shows blank).
    public static func elementPreviewImage(_ elem: Element, pixelScale: Int = 2) -> CGImage? {
        guard let box = previewExtent(elem) else { return nil }
        let px = previewSide * max(1, pixelScale)
        guard let ctx = CGContext(data: nil, width: px, height: px,
                                  bitsPerComponent: 8, bytesPerRow: px * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let side = Double(px)
        let margin = Double(max(1, pixelScale))
        let avail = side - 2 * margin
        let w = max(box.width, 1e-6), h = max(box.height, 1e-6)
        let s = min(avail / w, avail / h)
        // Document y runs down; the bitmap's runs up.
        ctx.translateBy(x: 0, y: CGFloat(side))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: CGFloat((side - box.width * s) / 2),
                        y: CGFloat((side - box.height * s) / 2))
        ctx.scaleBy(x: CGFloat(s), y: CGFloat(s))
        ctx.translateBy(x: CGFloat(-box.minX), y: CGFloat(-box.minY))
        drawElement(ctx, previewVisible(elem))
        return ctx.makeImage()
    }

    /// The element with every visibility flag in its subtree set to preview
    /// ("rendered as if in preview mode").
    static func previewVisible(_ elem: Element) -> Element {
        switch elem {
        case .group(let g):
            return Element.group(g.withChildren(g.children.map(previewVisible)))
                .withVisibility(.preview)
        case .layer(let l):
            return Element.layer(l.withChildren(l.children.map(previewVisible)))
                .withVisibility(.preview)
        default:
            return elem.withVisibility(.preview)
        }
    }

    /// The element's extent in its parent's space (its own transform
    /// applied): a container's is the union of its children's; nil when it
    /// occupies nothing (an empty container, or a zero box).
    static func previewExtent(_ elem: Element) -> (minX: Double, minY: Double,
                                                    width: Double, height: Double)? {
        var local: (Double, Double, Double, Double)? // minX, minY, maxX, maxY
        let children: [Element]?
        switch elem {
        case .group(let g): children = g.children
        case .layer(let l): children = l.children
        default: children = nil
        }
        if let kids = children {
            for c in kids {
                guard let b = previewExtent(c) else { continue }
                if let (ax, ay, bx, by) = local {
                    local = (min(ax, b.minX), min(ay, b.minY),
                             max(bx, b.minX + b.width), max(by, b.minY + b.height))
                } else {
                    local = (b.minX, b.minY, b.minX + b.width, b.minY + b.height)
                }
            }
        } else {
            let b = elem.bounds
            guard b.width.isFinite, b.height.isFinite, b.width > 0 || b.height > 0 else { return nil }
            local = (b.x, b.y, b.x + b.width, b.y + b.height)
        }
        guard let (x0, y0, x1, y1) = local else { return nil }
        let t = elem.transform ?? .identity
        let corners = [t.applyPoint(x0, y0), t.applyPoint(x1, y0),
                       t.applyPoint(x1, y1), t.applyPoint(x0, y1)]
        let xs = corners.map(\.0), ys = corners.map(\.1)
        let minX = xs.min()!, minY = ys.min()!
        let width = xs.max()! - minX, height = ys.max()! - minY
        guard width > 0 || height > 0 else { return nil }
        return (minX, minY, width, height)
    }
}
