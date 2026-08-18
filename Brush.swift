import Cocoa
import Carbon.HIToolbox

// MARK: - 도구

enum Tool: Int {
    case pen, arrow, rect, text, eraser, click
}

extension Tool {
    // 캔버스에 포커스가 있을 때 쓰는 한 글자 단축키
    init?(shortcut s: String) {
        switch s.lowercased() {
        case "p": self = .pen
        case "a": self = .arrow
        case "r": self = .rect
        case "t": self = .text
        case "e": self = .eraser
        case "c": self = .click
        default: return nil
        }
    }
}

struct Shape {
    let tool: Tool
    let points: [NSPoint]
    let color: NSColor
    let width: CGFloat
    var text: String? = nil
}

// 툴바에 그대로 한 줄씩 놓이는 굵기 — 강의 화면에서 보이라고 전체적으로 굵게 잡았다
let brushWidths: [CGFloat] = [4, 8, 14, 22]

// 텍스트 크기도 굵기에 묶는다 (별도 컨트롤을 만들 이유가 없음) — 기본 8 → 36pt
func fontSize(for width: CGFloat) -> CGFloat { 12 + width * 3 }

// MARK: - 캔버스

final class CanvasView: NSView, NSTextFieldDelegate {
    var shapes: [Shape] = []
    private var current: [NSPoint] = []
    private(set) var editor: NSTextField?
    private var editorWidth: CGFloat = 0  // 입력 시작 시점의 굵기 — 도중에 툴바를 만져도 안 흔들리게

    var tool: Tool = .pen
    var inkColor: NSColor = .systemRed
    var lineWidth: CGFloat = brushWidths[1]

    // 단축키로 도구를 바꿀 때 툴바 하이라이트/클릭 통과까지 같이 손봐야 해서 앱에 넘긴다
    var onToolShortcut: ((Tool) -> Void)?

    // MARK: 실행취소 — 도형 배열을 통째로 스냅샷한다.
    // 도형 수가 많지 않은 앱이라 역연산을 도구별로 짜는 것보다 이쪽이 단순하고 안전하다.
    private var undoStack: [[Shape]] = []
    private var redoStack: [[Shape]] = []
    private let historyLimit = 100
    private var eraseStrokeSnapshotted = false

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private func snapshot() {
        undoStack.append(shapes)
        if undoStack.count > historyLimit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(shapes)
        shapes = prev
        needsDisplay = true
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(shapes)
        shapes = next
        needsDisplay = true
    }

    // 브러시를 끌 때 호출 — 사라진 그림이 다음 세션에서 되살아나면 곤란하다
    func resetHistory() { undoStack = []; redoStack = [] }

    // 클릭 도구: 오버레이가 마우스를 그대로 통과시켜 브러시를 켠 채로 밑 앱을 쓴다
    func applyClickThrough() {
        window?.ignoresMouseEvents = (tool == .click)
        window?.invalidateCursorRects(for: self)
    }

    override var acceptsFirstResponder: Bool { true }
    // 다른 앱이 활성 상태일 때 첫 클릭이 '앱 활성화'로 먹히지 않게 함 — 없으면 첫 획이 통째로 사라진다
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }

    // 마우스 핸들러가 부르는 것과 같은 진입점 — 셀프테스트도 여기를 쓴다
    func begin(at p: NSPoint) { current = [p]; needsDisplay = true }
    func extend(to p: NSPoint) {
        switch tool {
        case .pen: current.append(p)
        case .arrow, .rect: current = [current[0], p]  // 시작점 고정, 끝점만 갱신
        case .text, .eraser, .click: break  // 그리는 도구가 아님
        }
        needsDisplay = true
    }
    func end() {
        if current.count > 1 {
            snapshot()
            shapes.append(Shape(tool: tool, points: current, color: inkColor, width: lineWidth))
        }
        current = []
        needsDisplay = true
    }
    func clear() {
        editor?.removeFromSuperview(); editor = nil
        if !shapes.isEmpty { snapshot() }  // ESC로 통째로 날린 것도 ⌘Z로 되돌릴 수 있게
        shapes = []; current = []; needsDisplay = true
    }

    // MARK: 텍스트 — 클릭한 자리에 입력 필드를 띄우고, 엔터/포커스 이탈 시 도형으로 확정
    func beginText(at p: NSPoint) {
        commitText()
        editorWidth = lineWidth
        let size = fontSize(for: lineWidth)
        let f = NSTextField(frame: NSRect(x: p.x, y: p.y, width: 320, height: size * 1.5))
        f.font = .boldSystemFont(ofSize: size)
        f.textColor = inkColor
        f.backgroundColor = .clear
        f.drawsBackground = false
        f.isBordered = false
        f.focusRingType = .none
        f.placeholderString = "입력 후 Enter"
        f.delegate = self
        addSubview(f)
        window?.makeFirstResponder(f)
        editor = f
    }

    func commitText() {
        guard let f = editor else { return }
        editor = nil  // 델리게이트 콜백이 다시 들어와도 재진입하지 않게 먼저 비운다
        let s = f.stringValue
        let color = f.textColor ?? inkColor
        let origin = f.frame.origin
        f.removeFromSuperview()
        if !s.isEmpty {
            snapshot()
            shapes.append(Shape(tool: .text, points: [origin], color: color, width: editorWidth, text: s))
        }
        window?.makeFirstResponder(self)  // ESC 전체 지우기가 다시 캔버스로 오도록
        needsDisplay = true
    }

    func controlTextDidEndEditing(_ n: Notification) { commitText() }

    // MARK: 지우개 — 픽셀이 아니라 도형 단위로 지운다 (도형 목록만 들고 있는 구조라 그게 자연스럽다)
    var eraserRadius: CGFloat { max(14, lineWidth * 1.5) }

    // 지우개는 드래그 한 번이 실행취소 한 번 — 지나간 도형마다 스냅샷을 쌓으면 ⌘Z를 수십 번 눌러야 한다
    func beginEraseStroke() { eraseStrokeSnapshotted = false }

    func erase(at p: NSPoint) {
        var kept = shapes
        kept.removeAll { hits($0, at: p) }
        guard kept.count != shapes.count else { return }
        if !eraseStrokeSnapshotted {
            snapshot()
            eraseStrokeSnapshotted = true
        }
        shapes = kept
        needsDisplay = true
    }

    private func hits(_ s: Shape, at p: NSPoint) -> Bool {
        let tol = eraserRadius + s.width / 2
        guard let first = s.points.first, let last = s.points.last else { return false }
        switch s.tool {
        case .pen, .arrow:
            return zip(s.points, s.points.dropFirst()).contains { distance(from: p, toSegment: $0, $1) <= tol }
        case .rect:
            // 테두리만 그려지므로 안쪽을 훑어도 안 지워지게 네 변으로 따진다
            let r = NSRect(x: min(first.x, last.x), y: min(first.y, last.y),
                           width: abs(last.x - first.x), height: abs(last.y - first.y))
            let corners = [NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.maxX, y: r.minY),
                           NSPoint(x: r.maxX, y: r.maxY), NSPoint(x: r.minX, y: r.maxY)]
            return (0..<4).contains { distance(from: p, toSegment: corners[$0], corners[($0 + 1) % 4]) <= tol }
        case .text:
            let attrs = [NSAttributedString.Key.font: NSFont.boldSystemFont(ofSize: fontSize(for: s.width))]
            let size = ((s.text ?? "") as NSString).size(withAttributes: attrs)
            return NSRect(origin: first, size: size).insetBy(dx: -tol, dy: -tol).contains(p)
        case .eraser, .click:
            return false
        }
    }

    private func distance(from p: NSPoint, toSegment a: NSPoint, _ b: NSPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        switch tool {
        case .text: beginText(at: p)
        case .eraser: beginEraseStroke(); erase(at: p)
        case .click: break  // 실제로는 ignoresMouseEvents로 이미 통과된다
        default: begin(at: p)
        }
    }
    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        switch tool {
        case .text, .click: break
        case .eraser: erase(at: p)
        default: extend(to: p)
        }
    }
    override func mouseUp(with e: NSEvent) {
        switch tool {
        case .text, .eraser, .click: break
        default: end()
        }
    }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == UInt16(kVK_Escape) { clear(); return }
        // 텍스트 입력 중에는 필드가 first responder라 여기까지 오지 않는다 — 글자 단축키가 입력을 먹지 않음
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.isDisjoint(with: [.command, .control, .option]),
           let t = Tool(shortcut: e.charactersIgnoringModifiers ?? "") {
            onToolShortcut?(t)
            return
        }
        super.keyDown(with: e)
    }

    // 메뉴 없이 도는 앱이라 ⌘Z / ⇧⌘Z를 직접 받는다. 텍스트 입력 중이면 필드 자체 실행취소가 먼저다.
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard editor == nil else { return super.performKeyEquivalent(with: e) }
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.contains(.command), e.charactersIgnoringModifiers?.lowercased() == "z" else {
            return super.performKeyEquivalent(with: e)
        }
        mods.contains(.shift) ? redo() : undo()
        return true
    }

    override func resetCursorRects() {
        guard tool != .click else { return }  // 클릭 모드에서는 밑 앱 커서를 그대로 둔다
        addCursorRect(bounds, cursor: .crosshair)
    }

    // ponytail: 점 하나 찍힐 때마다 전체 다시 그림. 선이 수백 개로 늘어 버벅이면 CAShapeLayer로.
    override func draw(_ dirty: NSRect) {
        for s in shapes + (current.count > 1 ? [Shape(tool: tool, points: current, color: inkColor, width: lineWidth)] : []) {
            drawShape(s)
        }
    }

    private func drawShape(_ s: Shape) {
        guard let first = s.points.first, let last = s.points.last else { return }
        s.color.setStroke()
        s.color.setFill()
        switch s.tool {
        case .pen:
            let path = NSBezierPath()
            path.lineWidth = s.width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: first)
            for p in s.points.dropFirst() { path.line(to: p) }
            path.stroke()
        case .rect:
            let rect = NSRect(x: min(first.x, last.x), y: min(first.y, last.y),
                               width: abs(last.x - first.x), height: abs(last.y - first.y))
            NSBezierPath(rect: rect).apply { $0.lineWidth = s.width; $0.stroke() }
        case .arrow:
            drawArrow(from: first, to: last, width: s.width)
        case .text:
            (s.text ?? "").draw(at: first, withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: fontSize(for: s.width)),
                .foregroundColor: s.color,
            ])
        case .eraser, .click:
            break  // 도형으로 남지 않는다
        }
    }

    private func drawArrow(from a: NSPoint, to b: NSPoint, width: CGFloat) {
        let line = NSBezierPath()
        line.lineWidth = width
        line.lineCapStyle = .round
        line.move(to: a)
        line.line(to: b)
        line.stroke()

        let angle = atan2(b.y - a.y, b.x - a.x)
        let headLength = max(14, width * 3.5)
        let headAngle: CGFloat = .pi / 7
        let p1 = NSPoint(x: b.x - headLength * cos(angle - headAngle), y: b.y - headLength * sin(angle - headAngle))
        let p2 = NSPoint(x: b.x - headLength * cos(angle + headAngle), y: b.y - headLength * sin(angle + headAngle))
        let head = NSBezierPath()
        head.move(to: b)
        head.line(to: p1)
        head.line(to: p2)
        head.close()
        head.fill()
    }
}

private extension NSBezierPath {
    func apply(_ body: (NSBezierPath) -> Void) { body(self) }
}

// MARK: - 도구 버튼 (플랫 스타일, 선택 시 강조색 한 가지로만 표시)

final class ToolbarButton: NSButton {
    var isSelected: Bool = false { didSet { updateAppearance() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 9
        isBordered = false
        imagePosition = .imageOnly
        updateAppearance()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func updateAppearance() {
        layer?.backgroundColor = (isSelected ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.06)).cgColor
        contentTintColor = isSelected ? .white : NSColor.white.withAlphaComponent(0.8)
    }
}

// MARK: - 도구 모음 (펜/화살표/사각형 + 색상 + 굵기)

final class ToolbarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

final class Toolbar: NSObject {
    let panel: ToolbarPanel
    // 도구 선택은 앱이 처리한다 — 툴바 하이라이트 말고도 클릭 통과/포커스까지 같이 손봐야 하기 때문
    var onSelectTool: ((Tool) -> Void)?
    var onUndo: (() -> Void)?
    private let canvas: CanvasView
    private var toolButtons: [Tool: ToolbarButton] = [:]
    private var colorButton: NSButton!
    private var sizeButtons: [ToolbarButton] = []

    // 색상 패널 안의 "형광펜" 커스텀 팔레트로 들어감 — 툴바에는 스와치 무더기 대신 색상 버튼 하나만 둔다
    private let presetColors: [(name: String, color: NSColor)] = [
        ("빨강", .systemRed), ("검정", .black), ("파랑", .systemBlue),
        ("형광노랑", NSColor(red: 0.85, green: 1.0, blue: 0.0, alpha: 1)),
        ("형광핑크", NSColor(red: 1.0, green: 0.0, blue: 0.8, alpha: 1)),
        ("형광초록", NSColor(red: 0.22, green: 1.0, blue: 0.08, alpha: 1)),
    ]

    init(canvas: CanvasView) {
        self.canvas = canvas
        panel = ToolbarPanel(contentRect: NSRect(x: 0, y: 0, width: 56, height: 260),
                              styleMask: [.hudWindow, .nonactivatingPanel, .utilityWindow],
                              backing: .buffered, defer: false)
        // 논액티베이팅 패널 — 버튼을 눌러도 캔버스 창의 key 상태(ESC 처리)를 뺏지 않는다
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        super.init()
        buildUI()
    }

    private func buildUI() {
        let pen = makeToolButton(.pen, symbol: "pencil", tip: "펜 · P / ⌥1")
        let arrow = makeToolButton(.arrow, symbol: "arrow.up.right", tip: "화살표 · A / ⌥2")
        let rect = makeToolButton(.rect, symbol: "square", tip: "사각형 · R / ⌥3")
        let text = makeToolButton(.text, symbol: "textformat", tip: "텍스트 · T / ⌥4")
        let eraser = makeToolButton(.eraser, symbol: "eraser", tip: "지우개 · E / ⌥5 (닿는 것만 지움 · 전체는 ESC)")
        let click = makeToolButton(.click, symbol: "cursorarrow", tip: "클릭 · C / ⌥6 (브러시를 켠 채로 밑 화면 클릭)")
        toolButtons[.pen]?.isSelected = true

        let undo = makeUndoButton()

        let colorControl = makeColorControl()

        let stack = NSStackView(views: [pen, arrow, rect, text, eraser, click, separator(), undo, separator(), colorControl, separator()] + makeSizeButtons())
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8  // 버튼이 11개로 늘어 세로가 길어진 만큼 간격을 좁힘
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 10, bottom: 16, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        panel.contentView = content
        panel.setContentSize(stack.fittingSize)
    }

    private func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        return b
    }

    // 색상칩을 누르면 직접 시스템 색상 패널을 띄운다 (NSColorWell 자동 팝업은 패널 레벨을 자기 마음대로
    // 초기화해버려서, 전체화면을 덮는 캔버스 뒤로 깔리는 문제가 있었다 — 매번 우리가 직접 레벨을 지정)
    private func makeColorControl() -> NSButton {
        let list = NSColorList(name: "형광펜")
        for (name, color) in presetColors { list.setColor(color, forKey: name) }
        NSColorPanel.shared.attachColorList(list)

        let b = NSButton(frame: .zero)
        b.title = ""
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 9
        b.layer?.borderWidth = 1
        b.layer?.borderColor = NSColor.white.withAlphaComponent(0.5).cgColor
        b.layer?.backgroundColor = canvas.inkColor.cgColor
        b.target = self
        b.action = #selector(openColorPanel)
        b.toolTip = "색상 선택 (형광펜 팔레트 포함)"
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 36).isActive = true
        b.heightAnchor.constraint(equalToConstant: 36).isActive = true
        colorButton = b
        return b
    }

    private func makeToolButton(_ tool: Tool, symbol: String, tip: String) -> ToolbarButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage()
        image.isTemplate = true
        let b = ToolbarButton(frame: .zero)
        b.image = image
        b.target = self
        b.action = #selector(toolTapped(_:))
        b.translatesAutoresizingMaskIntoConstraints = false
        b.tag = tool.rawValue
        b.toolTip = tip
        b.widthAnchor.constraint(equalToConstant: 36).isActive = true
        b.heightAnchor.constraint(equalToConstant: 36).isActive = true
        toolButtons[tool] = b
        return b
    }

    @objc private func toolTapped(_ sender: NSButton) {
        guard let tool = Tool(rawValue: sender.tag) else { return }
        onSelectTool?(tool)
    }

    // 단축키로 바뀐 도구도 툴바에 그대로 비치게 — 선택 표시는 한 곳에서만 갱신한다
    func select(_ tool: Tool) {
        for (t, btn) in toolButtons { btn.isSelected = (t == tool) }
    }

    // 클릭 모드에서는 ⌘Z가 밑 앱으로 가버리므로 툴바에도 실행취소를 둔다
    private func makeUndoButton() -> ToolbarButton {
        let image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "실행취소") ?? NSImage()
        image.isTemplate = true
        let b = ToolbarButton(frame: .zero)
        b.image = image
        b.target = self
        b.action = #selector(undoTapped)
        b.toolTip = "실행취소 · ⌘Z (다시 실행 ⇧⌘Z)"
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 36).isActive = true
        b.heightAnchor.constraint(equalToConstant: 36).isActive = true
        return b
    }

    @objc private func undoTapped() { onUndo?() }

    @objc private func openColorPanel() {
        let cp = NSColorPanel.shared
        cp.setTarget(self)
        cp.setAction(#selector(colorPanelChanged(_:)))
        cp.color = canvas.inkColor
        // 여기서 매번 다시 지정 — NSColorPanel이 뜰 때 레벨을 자체적으로 되돌리는 경우가 있어
        // "한 번만 설정"으로는 캔버스(screenSaver 레벨) 뒤로 깔리는 걸 막지 못했다
        cp.level = NSWindow.Level(rawValue: panel.level.rawValue + 1)
        cp.makeKeyAndOrderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        canvas.inkColor = sender.color
        colorButton.layer?.backgroundColor = sender.color.cgColor
    }

    // 굵기는 버튼 한 줄씩 — 순환 토글은 원하는 값까지 여러 번 눌러야 해서 바로 고르게 바꿨다
    private func makeSizeButtons() -> [ToolbarButton] {
        sizeButtons = brushWidths.enumerated().map { i, w in
            let b = ToolbarButton(frame: .zero)
            b.image = dotImage(diameter: min(w + 4, 22))
            b.tag = i
            b.target = self
            b.action = #selector(sizeTapped(_:))
            b.toolTip = "굵기 \(Int(w))"
            b.isSelected = (w == canvas.lineWidth)
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 36).isActive = true
            b.heightAnchor.constraint(equalToConstant: 36).isActive = true
            return b
        }
        return sizeButtons
    }

    @objc private func sizeTapped(_ sender: NSButton) {
        canvas.lineWidth = brushWidths[sender.tag]
        for (i, b) in sizeButtons.enumerated() { b.isSelected = (i == sender.tag) }
    }

    private func dotImage(diameter d: CGFloat) -> NSImage {
        let side: CGFloat = 24
        let img = NSImage(size: NSSize(width: side, height: side))
        img.lockFocus()
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: (side - d) / 2, y: (side - d) / 2, width: d, height: d)).fill()
        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    func reposition(near screenFrame: NSRect) {
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: screenFrame.minX + 24, y: screenFrame.midY - size.height / 2))
    }
}

// MARK: - 오버레이 창

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

// MARK: - 앱

final class BrushApp: NSObject, NSApplicationDelegate {
    private var window: OverlayWindow!
    private var canvas: CanvasView!
    private var toolbar: Toolbar!
    private var statusItem: NSStatusItem!
    private var hotKey: EventHotKeyRef?
    private(set) var isOn = false

    func applicationDidFinishLaunching(_ n: Notification) {
        let frame = screenUnderMouse().frame
        canvas = CanvasView(frame: NSRect(origin: .zero, size: frame.size))

        window = OverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        // 완전 투명(alpha 0)이면 윈도우 서버가 클릭을 밑 앱으로 통과시킨다 → 눈에 안 보이는 최소 알파 필요
        window.backgroundColor = NSColor(white: 0, alpha: 0.01)
        window.hasShadow = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = canvas

        toolbar = Toolbar(canvas: canvas)
        toolbar.panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        toolbar.onSelectTool = { [weak self] in self?.selectTool($0) }
        toolbar.onUndo = { [weak self] in self?.canvas.undo() }
        canvas.onToolShortcut = { [weak self] in self?.selectTool($0) }

        setUpStatusItem()
        registerHotKey()
    }

    private func screenUnderMouse() -> NSScreen {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "✏️"
        let menu = NSMenu()
        menu.addItem(withTitle: "브러시 켜기 / 끄기  (⌥Z)", action: #selector(toggleFromMenu), keyEquivalent: "").target = self
        menu.addItem(withTitle: "실행취소  (⌘Z)", action: #selector(undoFromMenu), keyEquivalent: "").target = self
        menu.addItem(withTitle: "전체 지우기  (ESC)", action: #selector(clearFromMenu), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func toggleFromMenu() { toggle() }
    @objc private func clearFromMenu() { canvas.clear() }
    @objc private func undoFromMenu() { canvas.undo() }

    // 도구 전환의 단일 통로 — 툴바 클릭 / 캔버스 글자 단축키 / 전역 ⌥숫자 단축키가 모두 여기로 온다
    func selectTool(_ tool: Tool) {
        canvas.commitText()  // 입력 중이던 텍스트를 도구 바꾸며 잃지 않게
        canvas.tool = tool
        canvas.applyClickThrough()
        toolbar.select(tool)
        if tool != .click {
            // 클릭 모드에서 다른 앱으로 넘어간 포커스를 다시 가져와야 ESC·⌘Z·글자 단축키가 산다
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            window.makeFirstResponder(canvas)
        }
    }

    func toggle() {
        isOn ? turnOff() : turnOn()
    }

    private func turnOn() {
        let frame = screenUnderMouse().frame
        window.setFrame(frame, display: false)
        canvas.frame = NSRect(origin: .zero, size: frame.size)
        toolbar.reposition(near: frame)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.makeFirstResponder(canvas)
        canvas.applyClickThrough()
        toolbar.panel.orderFrontRegardless()
        registerToolHotKeys()
        isOn = true
        statusItem.button?.title = "🖍️"
    }

    private func turnOff() {
        canvas.clear()
        canvas.resetHistory()  // 지워진 그림이 다음에 켤 때 ⌘Z로 되살아나면 곤란하다
        unregisterToolHotKeys()
        window.orderOut(nil)
        toolbar.panel.orderOut(nil)
        isOn = false
        statusItem.button?.title = "✏️"
    }

    // MARK: 전역 단축키 (⌥Z) — 접근성 권한 없이 동작
    // 바꾸려면 아래 두 상수만 고치고 ./build.sh
    private let hotKeyCode = UInt32(kVK_ANSI_Z)
    private let hotKeyModifiers = UInt32(optionKey)

    // 브러시가 켜져 있는 동안에만 사는 단축키들 — 클릭 모드에서 우리 창이 키를 놓쳐도 도구를 되돌릴 수 있어야 한다.
    // 항상 물고 있으면 다른 앱에서 ⌥1(¡) 같은 입력을 통째로 막아버리므로 켤 때 등록하고 끌 때 푼다.
    private let toolHotKeys: [(tool: Tool, code: UInt32)] = [
        (.pen, UInt32(kVK_ANSI_1)), (.arrow, UInt32(kVK_ANSI_2)), (.rect, UInt32(kVK_ANSI_3)),
        (.text, UInt32(kVK_ANSI_4)), (.eraser, UInt32(kVK_ANSI_5)), (.click, UInt32(kVK_ANSI_6)),
    ]
    private var sessionHotKeys: [EventHotKeyRef] = []
    private let signature = OSType(0x42525348 /* 'BRSH' */)
    private let toggleHotKeyID: UInt32 = 1
    private let undoHotKeyID: UInt32 = 2
    private let firstToolHotKeyID: UInt32 = 10

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: signature, id: toggleHotKeyID)
        let status = RegisterEventHotKey(hotKeyCode, hotKeyModifiers, id, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { warnHotKeyTaken(status) }
    }

    private func registerToolHotKeys() {
        guard sessionHotKeys.isEmpty else { return }
        var specs: [(UInt32, UInt32, UInt32)] = toolHotKeys.enumerated().map {
            ($1.code, hotKeyModifiers, firstToolHotKeyID + UInt32($0))
        }
        // ⌥⌘Z — 클릭 모드에서는 ⌘Z가 밑 앱 것이 되므로 별도로 하나 둔다
        specs.append((UInt32(kVK_ANSI_Z), hotKeyModifiers | UInt32(cmdKey), undoHotKeyID))
        for (code, mods, id) in specs {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: signature, id: id)
            if RegisterEventHotKey(code, mods, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                sessionHotKeys.append(ref)
            }
        }
    }

    private func unregisterToolHotKeys() {
        for ref in sessionHotKeys { UnregisterEventHotKey(ref) }
        sessionHotKeys = []
    }

    func handleHotKey(id: UInt32) {
        switch id {
        case toggleHotKeyID: toggle()
        case undoHotKeyID where isOn: canvas.undo()
        default:
            let index = Int(id) - Int(firstToolHotKeyID)
            guard isOn, toolHotKeys.indices.contains(index) else { return }
            selectTool(toolHotKeys[index].tool)
        }
    }

    private func warnHotKeyTaken(_ status: OSStatus) {
        statusItem.button?.title = "⚠️"
        let item = NSMenuItem(title: "단축키를 다른 앱이 쓰는 중 (err \(status))", action: nil, keyEquivalent: "")
        item.isEnabled = false
        statusItem.menu?.insertItem(item, at: 0)
        statusItem.menu?.insertItem(.separator(), at: 1)
    }
}

private var sharedApp: BrushApp?

private func hotKeyCallback(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    var id = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                      nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    sharedApp?.handleHotKey(id: id.id)
    return noErr
}

// MARK: - 셀프테스트 (--selftest)

func runSelfTest() -> Never {
    let v = CanvasView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
    var failures = 0

    func check(_ cond: Bool, _ msg: String) {
        print(cond ? "  ok   \(msg)" : "  FAIL \(msg)")
        if !cond { failures += 1 }
    }

    func inkPixels() -> Int {
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return -1 }
        v.cacheDisplay(in: v.bounds, to: rep)
        var n = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.alphaComponent > 0.3 && c.redComponent > 0.5 && c.greenComponent < 0.5 { n += 1 }
            }
        }
        return n
    }

    check(inkPixels() == 0, "빈 캔버스에는 잉크 없음")

    v.begin(at: NSPoint(x: 20, y: 20))
    v.extend(to: NSPoint(x: 100, y: 100))
    v.extend(to: NSPoint(x: 180, y: 180))
    check(inkPixels() > 20, "드래그 중인 선이 즉시 보임")

    v.end()
    check(v.shapes.count == 1 && v.shapes[0].points.count == 3, "마우스를 떼면 도형 1개 확정")
    check(inkPixels() > 20, "확정된 도형이 계속 보임")

    v.begin(at: NSPoint(x: 5, y: 5)); v.end()
    check(v.shapes.count == 1, "점 하나짜리(=단순 클릭)는 도형으로 안 남음")

    v.clear()
    check(v.shapes.isEmpty && inkPixels() == 0, "clear() 후 캔버스 비워짐")

    v.tool = .rect
    v.inkColor = .systemRed
    v.begin(at: NSPoint(x: 20, y: 20))
    v.extend(to: NSPoint(x: 20, y: 20))
    v.extend(to: NSPoint(x: 150, y: 150))
    v.end()
    check(v.shapes.count == 1 && v.shapes[0].tool == .rect, "사각형 도구로 도형 1개 확정")
    check(inkPixels() > 5, "사각형 테두리가 보임")
    v.clear()

    v.tool = .arrow
    v.begin(at: NSPoint(x: 20, y: 100))
    v.extend(to: NSPoint(x: 180, y: 100))
    v.end()
    check(v.shapes.count == 1 && v.shapes[0].tool == .arrow, "화살표 도구로 도형 1개 확정")
    check(inkPixels() > 20, "화살표가 보임")
    v.clear()

    v.tool = .pen
    v.inkColor = .systemRed
    v.lineWidth = 8
    v.begin(at: NSPoint(x: 20, y: 20)); v.extend(to: NSPoint(x: 180, y: 180)); v.end()
    v.begin(at: NSPoint(x: 20, y: 180)); v.extend(to: NSPoint(x: 60, y: 180)); v.end()
    v.tool = .eraser
    v.beginEraseStroke()
    v.erase(at: NSPoint(x: 190, y: 20))
    check(v.shapes.count == 2, "빈 곳을 지워도 도형은 그대로")
    v.erase(at: NSPoint(x: 100, y: 100))
    check(v.shapes.count == 1, "선 위를 지우면 그 도형만 사라짐")
    v.erase(at: NSPoint(x: 40, y: 180))
    check(v.shapes.isEmpty && inkPixels() == 0, "남은 도형도 지워짐")
    v.undo()
    check(v.shapes.count == 2, "지우개 드래그 한 번은 ⌘Z 한 번으로 통째로 복구")
    v.clear()

    v.tool = .text
    v.inkColor = .systemRed
    v.lineWidth = 14
    v.beginText(at: NSPoint(x: 10, y: 90))
    v.editor?.stringValue = "가나다ABC"
    v.commitText()
    check(v.shapes.count == 1 && v.shapes[0].text == "가나다ABC", "텍스트 입력이 도형 1개로 확정됨")
    check(inkPixels() > 20, "확정된 텍스트가 보임")

    v.beginText(at: NSPoint(x: 10, y: 40))
    v.commitText()
    check(v.shapes.count == 1, "빈 텍스트는 도형으로 안 남음")
    v.clear()
    check(v.editor == nil && inkPixels() == 0, "clear()가 입력 중인 텍스트 필드도 걷어냄")

    v.tool = .pen
    v.inkColor = .systemBlue
    v.lineWidth = 10
    v.begin(at: NSPoint(x: 10, y: 10)); v.extend(to: NSPoint(x: 190, y: 190)); v.end()
    check(v.shapes[0].color == .systemBlue && v.shapes[0].width == 10, "색상/굵기 변경이 새 도형에 반영됨")

    // MARK: 실행취소 / 다시 실행
    v.clear()
    v.resetHistory()
    v.tool = .pen
    v.inkColor = .systemRed
    v.lineWidth = 8

    v.undo()
    check(v.shapes.isEmpty, "되돌릴 게 없으면 ⌘Z는 아무 일도 안 함")

    v.begin(at: NSPoint(x: 20, y: 20)); v.extend(to: NSPoint(x: 180, y: 180)); v.end()
    v.begin(at: NSPoint(x: 20, y: 180)); v.extend(to: NSPoint(x: 180, y: 20)); v.end()
    check(v.shapes.count == 2 && v.canUndo, "획 2개, 실행취소 가능")

    v.undo()
    check(v.shapes.count == 1, "⌘Z가 마지막 획만 되돌림")
    v.undo()
    check(v.shapes.isEmpty && inkPixels() == 0 && !v.canUndo, "⌘Z를 더 누르면 처음 상태")

    v.redo()
    check(v.shapes.count == 1, "⇧⌘Z로 다시 실행")
    v.redo()
    check(v.shapes.count == 2 && !v.canRedo, "다시 실행이 끝까지 감")

    v.begin(at: NSPoint(x: 10, y: 100)); v.extend(to: NSPoint(x: 190, y: 100)); v.end()
    check(!v.canRedo, "되돌린 뒤 새로 그리면 다시 실행 이력은 버려짐")

    v.clear()
    check(v.shapes.isEmpty, "ESC 전체 지우기")
    v.undo()
    check(v.shapes.count == 3, "ESC로 지운 것도 ⌘Z로 복구")

    v.tool = .text
    v.beginText(at: NSPoint(x: 10, y: 40))
    v.editor?.stringValue = "취소될 글자"
    v.commitText()
    check(v.shapes.count == 4, "텍스트 확정")
    v.undo()
    check(v.shapes.count == 3, "확정된 텍스트도 ⌘Z로 되돌림")

    v.resetHistory()
    check(!v.canUndo && !v.canRedo, "브러시를 끄면 이력이 비워짐")

    // MARK: 클릭 도구 — 그리지도, 지우지도 않는다
    v.clear()
    v.resetHistory()
    v.tool = .click
    v.begin(at: NSPoint(x: 20, y: 20))
    v.extend(to: NSPoint(x: 180, y: 180))
    v.end()
    check(v.shapes.isEmpty && inkPixels() == 0 && !v.canUndo, "클릭 도구는 드래그해도 아무것도 안 남김")
    check(Tool(shortcut: "c") == .click && Tool(shortcut: "P") == .pen && Tool(shortcut: "x") == nil,
          "글자 단축키가 도구로 매핑됨")

    print(failures == 0 ? "\n셀프테스트 통과" : "\n실패 \(failures)건")
    exit(failures == 0 ? 0 : 1)
}

// MARK: - 진입점

if CommandLine.arguments.contains("--selftest") { runSelfTest() }

let app = NSApplication.shared
let delegate = BrushApp()
sharedApp = delegate
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
