// SnapMark: capture a screen area, annotate it, copy it to the clipboard.
// No network code. No files written. The image lives in memory and on the clipboard only.

import Cocoa
import Carbon.HIToolbox
import CoreImage
import Vision

// MARK: - Model

enum Tool: Int { case text, arrow, rect, oval, pen, marker, blur, step, spot, magnify }

enum Shape {
    case text(String, NSPoint, CGFloat)
    case arrow(NSPoint, NSPoint)
    case rect(NSRect)
    case oval(NSRect)
    case pen([NSPoint])
    case marker([NSPoint])             // a wide stroke that you can see through
    case blur(NSRect)
    case step(Int, NSPoint, CGFloat)   // number, center, radius
    case spot(NSRect)                  // the area that stays bright
    case magnify(NSRect)               // a lens that shows the area at two times its size
}

struct Annotation {
    var shape: Shape
    var color: NSColor
    var width: CGFloat
}

// Text that matches one of these patterns is private data.
let privatePatterns: [NSRegularExpression] = [
    "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}",                                   // email
    "(?<![\\w.])\\+?\\d[\\d ()-]{8,}\\d(?![\\w.])",                             // phone or card number
    "\\b(?:sk|pk|rk)[-_][A-Z0-9_-]{16,}|\\bgh[pousr]_[A-Z0-9]{20,}|\\bAKIA[A-Z0-9]{12,}|\\beyJ[A-Z0-9_-]{20,}|\\bxox[abp]-[A-Z0-9-]{10,}",   // keys and tokens
    "(?:password|passwd|secret|token|api[ _-]?key)\\s*[:=]\\s*(\\S+)",             // a value after a label
].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

func rectFrom(_ a: NSPoint, _ b: NSPoint) -> NSRect {
    NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
}

// MARK: - Canvas

final class CanvasView: NSView, NSTextFieldDelegate {
    let base: NSImage
    let pixellated: NSImage
    let pointSize: NSSize
    let pixelSize: NSSize
    let cgImage: CGImage

    // The colors of the background gradient. With nil, the image has no background.
    var background: [NSColor]? { didSet { needsDisplay = true; onChange?() } }
    var inset: CGFloat {
        background == nil ? 0 : min(max(max(pointSize.width, pointSize.height) * 0.06, 24), 64)
    }
    var totalSize: NSSize { NSSize(width: pointSize.width + inset * 2, height: pointSize.height + inset * 2) }

    // Each change goes to the clipboard at once.
    var annotations: [Annotation] = [] { didSet { onChange?() } }
    var onChange: (() -> Void)?
    var tool: Tool = .pen
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 4
    var fontSize: CGFloat = 20

    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?
    var onToolKey: ((Tool) -> Void)?

    private var dragStart: NSPoint?
    private var dragNow: NSPoint?
    private var penPoints: [NSPoint] = []
    private var field: NSTextField?

    init(cgImage: CGImage, scale: CGFloat) {
        self.cgImage = cgImage
        pixelSize = NSSize(width: cgImage.width, height: cgImage.height)
        pointSize = NSSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
        base = NSImage(cgImage: cgImage, size: pointSize)

        let ci = CIImage(cgImage: cgImage)
        let filter = CIFilter(name: "CIPixellate")!
        filter.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(max(10 * scale, 12), forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
        let out = filter.outputImage!.cropped(to: ci.extent)
        let blurred = CIContext().createCGImage(out, from: ci.extent) ?? cgImage
        pixellated = NSImage(cgImage: blurred, size: pointSize)

        super.init(frame: NSRect(origin: .zero, size: pointSize))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    // The first click on the window must draw. It must not only focus the window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        drawAll()
    }

    func drawAll() {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        guard let colors = background else { drawContent(); return }
        let pad = inset
        NSGradient(colors: colors.count > 1 ? colors : [colors[0], colors[0]])?
            .draw(in: NSRect(origin: .zero, size: totalSize), angle: -45)
        let card = CGPath(roundedRect: NSRect(x: pad, y: pad, width: pointSize.width, height: pointSize.height),
                          cornerWidth: 10, cornerHeight: 10, transform: nil)
        cg.saveGState()
        cg.setShadow(offset: .zero, blur: 28 * abs(cg.ctm.a), color: NSColor.black.withAlphaComponent(0.4).cgColor)
        cg.setFillColor(NSColor.white.cgColor)
        cg.addPath(card)
        cg.fillPath()
        cg.restoreGState()
        cg.saveGState()
        cg.addPath(card)
        cg.clip()
        cg.translateBy(x: pad, y: pad)
        drawContent()
        cg.restoreGState()
    }

    private func drawContent() {
        let full = NSRect(origin: .zero, size: pointSize)
        base.draw(in: full, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        var all = annotations
        if let live = liveAnnotation() { all.append(live) }
        // Order: blurs, then the spotlight dim, then the marks. The marks stay bright.
        for a in all { if case .blur = a.shape { draw(a) } }
        let spots = all.compactMap { a -> NSRect? in if case .spot(let r) = a.shape { return r }; return nil }
        if !spots.isEmpty, let cg = NSGraphicsContext.current?.cgContext {
            cg.saveGState()
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            cg.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
            cg.fill(full)
            cg.setBlendMode(.clear)
            for r in spots { cg.addPath(CGPath(roundedRect: r, cornerWidth: min(8, r.width / 2), cornerHeight: min(8, r.height / 2), transform: nil)) }
            cg.fillPath()
            cg.endTransparencyLayer()
            cg.restoreGState()
        }
        for a in all {
            switch a.shape {
            case .blur, .spot: break
            default: draw(a)
            }
        }
    }

    private func liveAnnotation() -> Annotation? {
        guard let s = dragStart, let n = dragNow else { return nil }
        let shape: Shape
        switch tool {
        case .arrow: shape = .arrow(s, n)
        case .rect: shape = .rect(rectFrom(s, n))
        case .oval: shape = .oval(rectFrom(s, n))
        case .blur: shape = .blur(rectFrom(s, n))
        case .pen: shape = .pen(penPoints)
        case .marker: shape = .marker(penPoints)
        case .spot: shape = .spot(rectFrom(s, n))
        case .magnify: shape = .magnify(rectFrom(s, n))
        case .text, .step: return nil
        }
        return Annotation(shape: shape, color: color, width: lineWidth)
    }

    private func draw(_ a: Annotation) {
        a.color.setStroke()
        a.color.setFill()
        switch a.shape {
        case .text(let s, let p, let size):
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                .foregroundColor: a.color,
                .shadow: shadow,
            ]
            (s as NSString).draw(at: p, withAttributes: attrs)
        case .arrow(let from, let to):
            let dx = to.x - from.x, dy = to.y - from.y
            let len = hypot(dx, dy)
            guard len > 1 else { return }
            let ux = dx / len, uy = dy / len
            let head = min(max(a.width * 4.5, 12), len)
            let half = head * 0.45
            let neck = NSPoint(x: to.x - ux * head, y: to.y - uy * head)
            let line = NSBezierPath()
            line.lineWidth = a.width
            line.lineCapStyle = .round
            line.move(to: from)
            line.line(to: NSPoint(x: to.x - ux * head * 0.8, y: to.y - uy * head * 0.8))
            line.stroke()
            let tri = NSBezierPath()
            tri.move(to: to)
            tri.line(to: NSPoint(x: neck.x - uy * half, y: neck.y + ux * half))
            tri.line(to: NSPoint(x: neck.x + uy * half, y: neck.y - ux * half))
            tri.close()
            tri.fill()
        case .rect(let r):
            let p = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
            p.lineWidth = a.width
            p.stroke()
        case .oval(let r):
            let p = NSBezierPath(ovalIn: r)
            p.lineWidth = a.width
            p.stroke()
        case .pen(let pts):
            guard let first = pts.first else { return }
            let p = NSBezierPath()
            p.lineWidth = a.width
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            p.move(to: first)
            for pt in pts.dropFirst() { p.line(to: pt) }
            if pts.count == 1 { p.line(to: first) }
            p.stroke()
        case .marker(let pts):
            guard let first = pts.first else { return }
            a.color.withAlphaComponent(0.4).setStroke()
            let p = NSBezierPath()
            p.lineWidth = a.width * 4
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            p.move(to: first)
            for pt in pts.dropFirst() { p.line(to: pt) }
            if pts.count == 1 { p.line(to: first) }
            p.stroke()
        case .blur(let r):
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: r).addClip()
            pixellated.draw(in: NSRect(origin: .zero, size: pointSize), from: .zero,
                            operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        case .step(let n, let c, let r):
            let circle = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            circle.fill()
            NSColor.white.withAlphaComponent(0.9).setStroke()
            circle.lineWidth = max(1.5, r * 0.12)
            circle.stroke()
            let light = a.color == NSColor.white || a.color == NSColor.systemYellow
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: r * 1.15, weight: .bold),
                .foregroundColor: light ? NSColor.black : NSColor.white,
            ]
            let str = "\(n)" as NSString
            let size = str.size(withAttributes: attrs)
            str.draw(at: NSPoint(x: c.x - size.width / 2, y: c.y - size.height / 2), withAttributes: attrs)
        case .spot:
            break   // drawContent draws all spotlights in one pass
        case .magnify(let r):
            guard let cg = NSGraphicsContext.current?.cgContext, r.width > 2, r.height > 2 else { return }
            let lens = NSBezierPath(ovalIn: r)
            cg.saveGState()
            lens.addClip()
            cg.translateBy(x: r.midX, y: r.midY)
            cg.scaleBy(x: 2, y: 2)
            cg.translateBy(x: -r.midX, y: -r.midY)
            base.draw(in: NSRect(origin: .zero, size: pointSize), from: .zero,
                      operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            // Blurred areas stay blurred in the lens.
            for b in annotations { if case .blur = b.shape { draw(b) } }
            cg.restoreGState()
            NSColor.white.setStroke()
            lens.lineWidth = 3
            lens.stroke()
            a.color.setStroke()
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: -2.5, dy: -2.5))
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    // MARK: Output

    func renderPNG() -> Data? {
        commitText()
        let k = pixelSize.width / pointSize.width
        let outW = (totalSize.width * k).rounded(), outH = (totalSize.height * k).rounded()
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(outW), pixelsHigh: Int(outH),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let cg = ctx.cgContext
        // Map canvas points to pixels, with a top-left origin to match the flipped view.
        cg.translateBy(x: 0, y: outH)
        cg.scaleBy(x: k, y: -k)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        drawAll()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    func undo() {
        if field != nil { discardText(); return }
        if !annotations.isEmpty { annotations.removeLast(); needsDisplay = true }
    }

    // MARK: Private data

    // Finds private text with the on-device text recognition of macOS and blurs it.
    func hidePrivateData(done: @escaping (Int) -> Void) {
        let image = cgImage, size = pointSize
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [NSRect] = []
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try? VNImageRequestHandler(cgImage: image).perform([request])
            for line in request.results ?? [] {
                guard let best = line.topCandidates(1).first else { continue }
                let text = best.string
                for (i, pattern) in privatePatterns.enumerated() {
                    for m in pattern.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                        let ns = m.numberOfRanges > 1 && m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range
                        guard let range = Range(ns, in: text) else { continue }
                        // A number is private only with 10 digits or more. This keeps dates and prices.
                        if i == 1 && text[range].filter(\.isNumber).count < 10 { continue }
                        guard let box = try? best.boundingBox(for: range)?.boundingBox else { continue }
                        let r = NSRect(x: box.minX * size.width - 3, y: (1 - box.maxY) * size.height - 2,
                                       width: box.width * size.width + 6, height: box.height * size.height + 4)
                        if !found.contains(where: { $0.intersects(r) }) { found.append(r) }
                    }
                }
            }
            DispatchQueue.main.async {
                if !found.isEmpty {
                    self.annotations += found.map { Annotation(shape: .blur($0), color: .clear, width: 0) }
                    self.needsDisplay = true
                }
                done(found.count)
            }
        }
    }

    // MARK: Mouse

    // The position of the event on the image, without the background inset.
    private func local(_ event: NSEvent) -> NSPoint {
        let p = convert(event.locationInWindow, from: nil)
        return NSPoint(x: p.x - inset, y: p.y - inset)
    }

    private func clamp(_ p: NSPoint) -> NSPoint {
        NSPoint(x: min(max(p.x, 0), pointSize.width), y: min(max(p.y, 0), pointSize.height))
    }

    override func mouseDown(with event: NSEvent) {
        let hadField = field != nil
        commitText()
        window?.makeFirstResponder(self)
        let p = clamp(local(event))
        if tool == .text {
            if !hadField { beginText(at: p) }
            return
        }
        if tool == .step {
            // Each color has its own count. Option-click starts the count at 1 again.
            var n = 1
            if !event.modifierFlags.contains(.option) {
                for a in annotations.reversed() {
                    if case .step(let k, _, _) = a.shape, a.color == color { n = k + 1; break }
                }
            }
            annotations.append(Annotation(shape: .step(n, p, fontSize * 0.8), color: color, width: 0))
            needsDisplay = true
            return
        }
        dragStart = p
        dragNow = p
        penPoints = [p]
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStart != nil else { return }
        let p = clamp(local(event))
        dragNow = p
        if tool == .pen || tool == .marker { penPoints.append(p) }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; dragNow = nil; penPoints = []; needsDisplay = true }
        guard let s = dragStart, let n = dragNow, var a = liveAnnotation() else { return }
        let moved = hypot(n.x - s.x, n.y - s.y)
        if tool != .pen && tool != .marker && moved < 4 { return }
        if case .blur = a.shape { a.width = 0 }
        annotations.append(a)
    }

    // MARK: Text

    private func beginText(at p: NSPoint) {
        let h = fontSize * 1.4
        let w = max(pointSize.width - p.x, 80)
        let f = NSTextField(frame: NSRect(x: p.x - 2 + inset, y: p.y - h / 2 + inset, width: w, height: h))
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        f.textColor = color
        f.placeholderString = "Type, then Enter"
        f.delegate = self
        f.cell?.usesSingleLineMode = true
        f.cell?.isScrollable = true
        addSubview(f)
        field = f
        window?.makeFirstResponder(f)
    }

    func commitText() {
        guard let f = field else { return }
        field = nil
        let s = f.stringValue.trimmingCharacters(in: .whitespaces)
        if !s.isEmpty {
            let size = f.font?.pointSize ?? fontSize
            let origin = NSPoint(x: f.frame.minX + 2 - inset, y: f.frame.minY - inset)
            annotations.append(Annotation(shape: .text(s, origin, size),
                                          color: f.textColor ?? color, width: 0))
        }
        f.removeFromSuperview()
        needsDisplay = true
    }

    private func discardText() {
        field?.stringValue = ""
        commitText()
        window?.makeFirstResponder(self)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitText()
        DispatchQueue.main.async { self.window?.makeFirstResponder(self) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            discardText()
            return true
        }
        return false
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: onDone?(); return
        case kVK_Escape: onCancel?(); return
        case kVK_Delete: undo(); return
        default: break
        }
        if cmd && key == "z" { undo(); return }
        if cmd && key == "c" { onDone?(); return }
        if cmd && key == "w" { onCancel?(); return }
        if !cmd {
            let map: [String: Tool] = ["t": .text, "a": .arrow, "r": .rect, "o": .oval, "p": .pen, "m": .marker, "b": .blur,
                                       "n": .step, "s": .spot, "z": .magnify]
            if let t = map[key] { onToolKey?(t); return }
        }
        super.keyDown(with: event)
    }
}

// MARK: - Editor window

final class Editor: NSObject, NSWindowDelegate {
    let window: NSWindow
    let canvas: CanvasView
    private let tools = NSSegmentedControl()
    private let colors = NSSegmentedControl()
    private let sizes = NSSlider()
    private let backgrounds = NSPopUpButton()
    private let hide = NSButton()
    private let status = NSTextField(labelWithString: "")
    private var area = NSRect.zero
    private let presets: [(name: String, colors: [NSColor])] = [
        ("Dawn", [NSColor(srgbRed: 1.00, green: 0.72, blue: 0.55, alpha: 1), NSColor(srgbRed: 0.87, green: 0.38, blue: 0.38, alpha: 1)]),
        ("Sea", [NSColor(srgbRed: 0.26, green: 0.78, blue: 0.67, alpha: 1), NSColor(srgbRed: 0.10, green: 0.09, blue: 0.33, alpha: 1)]),
        ("Lilac", [NSColor(srgbRed: 0.79, green: 0.71, blue: 1.00, alpha: 1), NSColor(srgbRed: 0.43, green: 0.55, blue: 1.00, alpha: 1)]),
        ("Mint", [NSColor(srgbRed: 0.83, green: 0.99, blue: 0.47, alpha: 1), NSColor(srgbRed: 0.59, green: 0.90, blue: 0.63, alpha: 1)]),
        ("Slate", [NSColor(srgbRed: 0.26, green: 0.26, blue: 0.28, alpha: 1), NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1)]),
        ("Paper", [NSColor(srgbRed: 0.96, green: 0.95, blue: 0.92, alpha: 1)]),
    ]
    var onClose: (() -> Void)?

    private let palette: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemBlue, .black, .white]

    init(cgImage: CGImage) {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        canvas = CanvasView(cgImage: cgImage, scale: screen.backingScaleFactor)

        let barHeight: CGFloat = 80
        let pad: CGFloat = 12
        let avail = screen.visibleFrame.size
        let maxW = avail.width * 0.9 - pad * 2
        let maxH = avail.height * 0.9 - barHeight - pad * 2 - 30
        let fit = min(1, maxW / canvas.pointSize.width, maxH / canvas.pointSize.height)
        let shown = NSSize(width: floor(canvas.pointSize.width * fit), height: floor(canvas.pointSize.height * fit))
        let contentW = max(shown.width + pad * 2, 960)
        let contentH = shown.height + pad * 2 + barHeight

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: contentW, height: contentH),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()

        window.title = "SnapMark    Each edit is copied    Enter: close    Cmd+Z: undo"
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.delegate = self

        let root = NSView(frame: NSRect(x: 0, y: 0, width: contentW, height: contentH))
        window.contentView = root

        area = NSRect(x: pad, y: pad, width: contentW - pad * 2, height: shown.height)
        layoutCanvas()
        canvas.wantsLayer = true
        canvas.layer?.borderWidth = 1
        canvas.layer?.borderColor = NSColor.separatorColor.cgColor
        root.addSubview(canvas)

        let names = ["Text", "Arrow", "Box", "Oval", "Pen", "Marker", "Blur", "Step", "Spot", "Zoom"]
        tools.segmentCount = names.count
        for (i, n) in names.enumerated() { tools.setLabel(n, forSegment: i) }
        tools.trackingMode = .selectOne
        tools.selectedSegment = Tool.pen.rawValue
        tools.target = self
        tools.action = #selector(toolChanged)

        colors.segmentCount = palette.count
        for (i, c) in palette.enumerated() {
            colors.setImage(Editor.swatch(c), forSegment: i)
            colors.setWidth(28, forSegment: i)
        }
        colors.trackingMode = .selectOne
        colors.selectedSegment = 0
        colors.target = self
        colors.action = #selector(colorChanged)

        // One slider sets the size of the pen, the marker, the lines, the text, and the step numbers.
        sizes.minValue = 0
        sizes.maxValue = 1
        sizes.doubleValue = 0.2
        sizes.isContinuous = true
        sizes.controlSize = .small
        sizes.toolTip = "Size"
        sizes.target = self
        sizes.action = #selector(sizeChanged)
        sizes.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let sizeLabel = NSTextField(labelWithString: "Size")
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.font = NSFont.systemFont(ofSize: 11)

        let undo = NSButton(title: "Undo", target: self, action: #selector(undoTapped))
        let copy = NSButton(title: "Done", target: self, action: #selector(done))
        copy.bezelColor = .controlAccentColor
        for b in [undo, copy] { b.bezelStyle = .rounded }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bgLabel = NSTextField(labelWithString: "Background")
        bgLabel.textColor = .secondaryLabelColor
        bgLabel.font = NSFont.systemFont(ofSize: 11)
        backgrounds.addItems(withTitles: ["None"] + presets.map { $0.name })
        backgrounds.target = self
        backgrounds.action = #selector(backgroundChanged)
        hide.title = "Hide private data"
        hide.bezelStyle = .rounded
        hide.target = self
        hide.action = #selector(hideTapped)
        hide.toolTip = "Blurs emails, phone numbers, card numbers, and keys"
        status.textColor = .secondaryLabelColor
        status.font = NSFont.systemFont(ofSize: 11)
        let spacer2 = NSView()
        spacer2.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let rows: [[NSView]] = [[tools, colors, sizeLabel, sizes, spacer],
                                [bgLabel, backgrounds, hide, status, spacer2, undo, copy]]
        for (i, views) in rows.enumerated() {
            let bar = NSStackView(views: views)
            bar.orientation = .horizontal
            bar.spacing = 10
            bar.edgeInsets = NSEdgeInsets(top: 0, left: pad, bottom: 0, right: pad)
            bar.frame = NSRect(x: 0, y: contentH - barHeight / 2 * CGFloat(i + 1), width: contentW, height: barHeight / 2)
            root.addSubview(bar)
        }

        for c in [tools, colors, sizes, backgrounds, hide, undo, copy] as [NSControl] { c.refusesFirstResponder = true }

        canvas.onDone = { [weak self] in self?.done() }
        canvas.onChange = { [weak self] in self?.copyImage() }
        canvas.onCancel = { [weak self] in self?.window.close() }
        sizeChanged()
        canvas.onToolKey = { [weak self] t in
            self?.tools.selectedSegment = t.rawValue
            self?.toolChanged()
        }
    }

    static func swatch(_ c: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { r in
            let p = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
            c.setFill(); p.fill()
            NSColor.gray.setStroke(); p.lineWidth = 0.5; p.stroke()
            return true
        }
    }

    func show() {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.makeFirstResponder(canvas)
    }

    @objc func toolChanged() {
        canvas.commitText()
        canvas.tool = Tool(rawValue: tools.selectedSegment) ?? .text
        window.makeFirstResponder(canvas)
    }

    @objc func colorChanged() {
        canvas.color = palette[max(colors.selectedSegment, 0)]
    }

    @objc func sizeChanged() {
        let v = CGFloat(sizes.doubleValue)
        canvas.lineWidth = 1.5 + v * 12.5
        canvas.fontSize = 12 + v * 40
    }

    @objc func undoTapped() { canvas.undo() }

    // Fits the image, with its background, in the area below the toolbar.
    func layoutCanvas() {
        let t = canvas.totalSize
        let fit = min(area.width / t.width, area.height / t.height, 1)
        let w = floor(t.width * fit), h = floor(t.height * fit)
        canvas.frame = NSRect(x: floor(area.midX - w / 2), y: floor(area.midY - h / 2), width: w, height: h)
        canvas.setBoundsSize(t)
        canvas.needsDisplay = true
        window.invalidateCursorRects(for: canvas)
    }

    @objc func backgroundChanged() {
        canvas.commitText()
        let i = backgrounds.indexOfSelectedItem
        canvas.background = i <= 0 ? nil : presets[i - 1].colors
        layoutCanvas()
        window.makeFirstResponder(canvas)
    }

    @objc func hideTapped() {
        canvas.commitText()
        hide.isEnabled = false
        status.stringValue = "Search in progress"
        canvas.hidePrivateData { [weak self] n in
            self?.hide.isEnabled = true
            self?.status.stringValue = n == 0 ? "No private data found" : "\(n) hidden"
        }
    }

    @objc func done() {
        guard copyImage() else { NSSound.beep(); return }
        window.close()
    }

    @discardableResult
    func copyImage() -> Bool {
        guard let png = canvas.renderPNG() else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        pb.writeObjects([item])
        return true
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var editor: Editor?
    private var capturing = false
    private var hotKey: EventHotKeyRef?

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "pencil.and.outline", accessibilityDescription: "SnapMark")
        let menu = NSMenu()
        let cap = NSMenuItem(title: "Capture area", action: #selector(capture), keyEquivalent: "a")
        cap.keyEquivalentModifierMask = [.control, .shift]
        cap.target = self
        menu.addItem(cap)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit SnapMark", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        registerHotKey()
        NSLog("SnapMark: started. Screen Recording permission: \(CGPreflightScreenCaptureAccess())")
    }

    // Ctrl+Shift+A. A Carbon hot key needs no Accessibility permission.
    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.capture() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x534E_4150), id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_A), UInt32(controlKey | shiftKey), id,
                                         GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { NSLog("SnapMark: hot key registration failed (\(status))") }
    }

    @objc func capture() {
        guard !capturing else { return }
        // Without Screen Recording permission the capture gives no image. Tell the user.
        if !CGPreflightScreenCaptureAccess() {
            NSLog("SnapMark: no Screen Recording permission")
            CGRequestScreenCaptureAccess()
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "SnapMark needs Screen Recording permission"
            alert.informativeText = "Open System Settings, then Privacy & Security, then Screen & System Audio Recording. Turn SnapMark on. Then quit SnapMark and open it again."
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        capturing = true
        editor?.window.close()

        // The system tool draws the selection crosshair and puts the image on the clipboard.
        let pb = NSPasteboard.general
        let before = pb.changeCount
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-i", "-c", "-x"]
        task.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            DispatchQueue.main.async {
                guard let self else { return }
                self.capturing = false
                guard pb.changeCount != before,
                      let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
                      let cg = NSBitmapImageRep(data: data)?.cgImage else {
                    NSLog("SnapMark: no image. screencapture status \(status), clipboard changed \(pb.changeCount != before)")
                    return
                }
                NSLog("SnapMark: image \(cg.width) x \(cg.height), editor opens")
                self.open(cg)
            }
        }
        do { try task.run() } catch { capturing = false; NSSound.beep() }
    }

    private func open(_ image: CGImage) {
        let e = Editor(cgImage: image)
        e.onClose = { [weak self, weak e] in if self?.editor === e { self?.editor = nil } }
        editor = e
        e.show()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
