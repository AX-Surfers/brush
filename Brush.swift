import Cocoa
import Carbon.HIToolbox

// MARK: - 도구

enum Tool: Int {
    case pen, arrow, rect, text
}

struct Shape {
    let tool: Tool
    let points: [NSPoint]
    let color: NSColor
    let width: CGFloat
    var text: String? = nil
}

// 굵기 토글이 도는 순서 — 툴바 버튼을 누를 때마다 다음 값
let brushWidths: [CGFloat] = [2, 4, 8, 14]

// 텍스트 크기도 굵기 토글에 묶는다 (별도 컨트롤을 만들 이유가 없음)
func fontSize(for width: CGFloat) -> CGFloat { 8 + width * 2 }

// MARK: - 캔버스

final class CanvasView: NSView, NSTextFieldDelegate {
    var shapes: [Shape] = []
    private var current: [NSPoint] = []
    private(set) var editor: NSTextField?

    var tool: Tool = .pen
    var inkColor: NSColor = .systemRed
    var lineWidth: CGFloat = 4

    override var acceptsFirstResponder: Bool { true }
    // 다른 앱이 활성 상태일 때 첫 클릭이 '앱 활성화'로 먹히지 않게 함 — 없으면 첫 획이 통째로 사라진다
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }

    // 마우스 핸들러가 부르는 것과 같은 진입점 — 셀프테스트도 여기를 쓴다
    func begin(at p: NSPoint) { current = [p]; needsDisplay = true }
    func extend(to p: NSPoint) {
        switch tool {
        case .pen: current.append(p)
        case .arrow, .rect: current = [current[0], p]  // 시작점 고정, 끝점만 갱신
        case .text: break  // 텍스트는 드래그 개념이 없음
        }
        needsDisplay = true
    }
    func end() {
        if current.count > 1 { shapes.append(Shape(tool: tool, points: current, color: inkColor, width: lineWidth)) }
        current = []
        needsDisplay = true
    }
    func clear() {
        editor?.removeFromSuperview(); editor = nil
        shapes = []; current = []; needsDisplay = true
    }

    // MARK: 텍스트 — 클릭한 자리에 입력 필드를 띄우고, 엔터/포커스 이탈 시 도형으로 확정
    func beginText(at p: NSPoint) {
        commitText()
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
        let width = ((f.font?.pointSize ?? 16) - 8) / 2
        let color = f.textColor ?? inkColor
        let origin = f.frame.origin
        f.removeFromSuperview()
        if !s.isEmpty {
            shapes.append(Shape(tool: .text, points: [origin], color: color, width: width, text: s))
        }
        window?.makeFirstResponder(self)  // ESC 전체 지우기가 다시 캔버스로 오도록
        needsDisplay = true
    }

    func controlTextDidEndEditing(_ n: Notification) { commitText() }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if tool == .text { beginText(at: p) } else { begin(at: p) }
    }
    override func mouseDragged(with e: NSEvent) {
        guard tool != .text else { return }
        extend(to: convert(e.locationInWindow, from: nil))
    }
    override func mouseUp(with e: NSEvent) { if tool != .text { end() } }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == UInt16(kVK_Escape) { clear() } else { super.keyDown(with: e) }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

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
    private let canvas: CanvasView
    private var toolButtons: [Tool: ToolbarButton] = [:]
    private var colorButton: NSButton!
    private var sizeButton: ToolbarButton!

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
        let pen = makeToolButton(.pen, symbol: "pencil", tip: "펜")
        let arrow = makeToolButton(.arrow, symbol: "arrow.up.right", tip: "화살표")
        let rect = makeToolButton(.rect, symbol: "square", tip: "사각형")
        let text = makeToolButton(.text, symbol: "textformat", tip: "텍스트")
        toolButtons[.pen]?.isSelected = true

        let colorControl = makeColorControl()
        let sizeControl = makeSizeControl()

        let stack = NSStackView(views: [pen, arrow, rect, text, separator(), colorControl, separator(), sizeControl])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
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
        canvas.commitText()  // 입력 중이던 텍스트를 도구 바꾸며 잃지 않게
        canvas.tool = tool
        for (t, btn) in toolButtons { btn.isSelected = (t == tool) }
    }

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

    // 슬라이더 대신 토글 — 누를 때마다 다음 굵기로 돌고, 버튼 안 점 크기로 현재 값을 보여준다
    private func makeSizeControl() -> ToolbarButton {
        let b = ToolbarButton(frame: .zero)
        b.target = self
        b.action = #selector(sizeTapped)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 36).isActive = true
        b.heightAnchor.constraint(equalToConstant: 36).isActive = true
        sizeButton = b
        updateSizeButton()
        return b
    }

    @objc private func sizeTapped() {
        let i = brushWidths.firstIndex(of: canvas.lineWidth) ?? 0
        canvas.lineWidth = brushWidths[(i + 1) % brushWidths.count]
        updateSizeButton()
    }

    private func updateSizeButton() {
        let w = canvas.lineWidth
        sizeButton.image = dotImage(diameter: w + 5)  // 2pt 점은 눌러야 할 표적으로 너무 작아 살짝 키움
        sizeButton.toolTip = "굵기 \(Int(w)) — 눌러서 변경"
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
        menu.addItem(withTitle: "전체 지우기  (ESC)", action: #selector(clearFromMenu), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func toggleFromMenu() { toggle() }
    @objc private func clearFromMenu() { canvas.clear() }

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
        toolbar.panel.orderFrontRegardless()
        isOn = true
        statusItem.button?.title = "🖍️"
    }

    private func turnOff() {
        canvas.clear()
        window.orderOut(nil)
        toolbar.panel.orderOut(nil)
        isOn = false
        statusItem.button?.title = "✏️"
    }

    // MARK: 전역 단축키 (⌥Z) — 접근성 권한 없이 동작
    // 바꾸려면 아래 두 상수만 고치고 ./build.sh
    private let hotKeyCode = UInt32(kVK_ANSI_Z)
    private let hotKeyModifiers = UInt32(optionKey)

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x42525348 /* 'BRSH' */), id: 1)
        let status = RegisterEventHotKey(hotKeyCode, hotKeyModifiers, id, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { warnHotKeyTaken(status) }
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
    sharedApp?.toggle()
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
