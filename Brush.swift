import Cocoa
import Carbon.HIToolbox
import ScreenCaptureKit
import CoreMedia
import CoreImage

// MARK: - 도구

enum Tool: Int {
    case pen, arrow, rect, text, eraser, click
    case laser, arrowPointer, circleMagnifier, rectangleMagnifier
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

extension Tool {
    var isTransient: Bool {
        switch self {
        case .laser, .arrowPointer, .circleMagnifier, .rectangleMagnifier: return true
        default: return false
        }
    }

    var isMagnifier: Bool { self == .circleMagnifier || self == .rectangleMagnifier }
}

// MARK: - 저장 설정 / 단축키 모델

struct Shortcut: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    var displayName: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + (Shortcut.keyNames[keyCode] ?? "키코드 \(keyCode)")
    }

    var isValid: Bool {
        let allowed = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        guard modifiers & ~allowed == 0, Shortcut.keyNames[keyCode] != nil else { return false }
        return modifiers != 0 || keyCode == UInt32(kVK_Escape)
    }

    static func from(event: NSEvent) -> Shortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        // 수정키 없는 전역 단축키는 일반 타이핑을 가로채므로 허용하지 않는다.
        let shortcut = Shortcut(keyCode: UInt32(event.keyCode), modifiers: carbon)
        guard shortcut.isValid else { return nil }
        return shortcut
    }

    private static let keyNames: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
        UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
        UInt32(kVK_ANSI_9): "9", UInt32(kVK_Space): "Space", UInt32(kVK_Tab): "Tab",
        UInt32(kVK_Return): "Return", UInt32(kVK_ANSI_Minus): "-", UInt32(kVK_ANSI_Equal): "=",
        UInt32(kVK_ANSI_LeftBracket): "[", UInt32(kVK_ANSI_RightBracket): "]",
        UInt32(kVK_ANSI_Semicolon): ";", UInt32(kVK_ANSI_Quote): "'",
        UInt32(kVK_ANSI_Comma): ",", UInt32(kVK_ANSI_Period): ".", UInt32(kVK_ANSI_Slash): "/",
        UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_Escape): "Esc", UInt32(kVK_Delete): "⌫", UInt32(kVK_ForwardDelete): "⌦",
    ]
}

enum ShortcutAction: String, CaseIterable {
    case toggle, click, pen, arrow, rect, text, eraser
    case laser, arrowPointer, circleMagnifier, rectangleMagnifier, undo, clear

    var title: String {
        switch self {
        case .toggle: return "브러시 켜기 / 끄기"
        case .pen: return "펜"
        case .arrow: return "화살표 그리기"
        case .rect: return "사각형 그리기"
        case .text: return "텍스트"
        case .eraser: return "지우개"
        case .click: return "클릭 통과"
        case .laser: return "레이저 포인터"
        case .arrowPointer: return "화살표 포인터"
        case .circleMagnifier: return "원형 확대"
        case .rectangleMagnifier: return "사각형 확대"
        case .undo: return "실행취소"
        case .clear: return "전체 취소 후 마우스 모드"
        }
    }

    var tool: Tool? {
        switch self {
        case .pen: return .pen
        case .arrow: return .arrow
        case .rect: return .rect
        case .text: return .text
        case .eraser: return .eraser
        case .click: return .click
        case .laser: return .laser
        case .arrowPointer: return .arrowPointer
        case .circleMagnifier: return .circleMagnifier
        case .rectangleMagnifier: return .rectangleMagnifier
        case .toggle, .undo, .clear: return nil
        }
    }

    static let defaults: [ShortcutAction: Shortcut] = [
        .toggle: Shortcut(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(optionKey)),
        .click: Shortcut(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(optionKey)),
        .pen: Shortcut(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(optionKey)),
        .arrow: Shortcut(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(optionKey)),
        .rect: Shortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(optionKey)),
        .text: Shortcut(keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(optionKey)),
        .eraser: Shortcut(keyCode: UInt32(kVK_ANSI_6), modifiers: UInt32(optionKey)),
        .laser: Shortcut(keyCode: UInt32(kVK_ANSI_7), modifiers: UInt32(optionKey)),
        .arrowPointer: Shortcut(keyCode: UInt32(kVK_ANSI_8), modifiers: UInt32(optionKey)),
        .circleMagnifier: Shortcut(keyCode: UInt32(kVK_ANSI_9), modifiers: UInt32(optionKey)),
        .rectangleMagnifier: Shortcut(keyCode: UInt32(kVK_ANSI_0), modifiers: UInt32(optionKey)),
        .undo: Shortcut(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(optionKey | cmdKey)),
        .clear: Shortcut(keyCode: UInt32(kVK_Escape), modifiers: 0),
    ]
}

final class AppSettings {
    private let defaults: UserDefaults
    private let prefix = "brush.settings."
    private(set) var shortcuts: [ShortcutAction: Shortcut] = [:]
    var laserSize: CGFloat { didSet { laserSize = Self.normalizedSize(laserSize, min: 8, max: 80, fallback: 24); defaults.set(Double(laserSize), forKey: prefix + "laserSize") } }
    var laserColor: NSColor { didSet { store(color: laserColor, key: "laserColor") } }
    var arrowPointerSize: CGFloat { didSet { arrowPointerSize = Self.normalizedSize(arrowPointerSize, min: 24, max: 160, fallback: 64); defaults.set(Double(arrowPointerSize), forKey: prefix + "arrowPointerSize") } }
    var arrowPointerColor: NSColor { didSet { store(color: arrowPointerColor, key: "arrowPointerColor") } }
    var magnification: CGFloat { didSet { magnification = Self.normalizedMagnification(magnification); defaults.set(Double(magnification), forKey: prefix + "magnification") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedLaser = defaults.object(forKey: prefix + "laserSize") as? Double
        let storedArrow = defaults.object(forKey: prefix + "arrowPointerSize") as? Double
        let storedZoom = defaults.object(forKey: prefix + "magnification") as? Double
        laserSize = Self.normalizedSize(CGFloat(storedLaser ?? 24), min: 8, max: 80, fallback: 24)
        arrowPointerSize = Self.normalizedSize(CGFloat(storedArrow ?? 64), min: 24, max: 160, fallback: 64)
        magnification = Self.normalizedMagnification(CGFloat(storedZoom ?? 2))
        laserColor = Self.readColor(defaults: defaults, key: prefix + "laserColor", fallback: .systemRed)
        arrowPointerColor = Self.readColor(defaults: defaults, key: prefix + "arrowPointerColor", fallback: .systemYellow)
        for action in ShortcutAction.allCases {
            let codeKey = prefix + "shortcut.\(action.rawValue).code"
            let modsKey = prefix + "shortcut.\(action.rawValue).modifiers"
            if defaults.object(forKey: codeKey) != nil, defaults.object(forKey: modsKey) != nil,
               let code = UInt32(exactly: defaults.integer(forKey: codeKey)),
               let modifiers = UInt32(exactly: defaults.integer(forKey: modsKey)) {
                shortcuts[action] = Shortcut(keyCode: code, modifiers: modifiers)
            } else {
                shortcuts[action] = ShortcutAction.defaults[action]
            }
        }
        // 오래되거나 외부에서 손상된 중복 설정은 안전한 기본값으로 되돌린다.
        if shortcuts.values.contains(where: { !$0.isValid }) || Self.duplicateAction(in: shortcuts) != nil {
            shortcuts = ShortcutAction.defaults
        }
    }

    func persist(shortcuts newValue: [ShortcutAction: Shortcut]) {
        shortcuts = newValue
        for (action, shortcut) in newValue {
            defaults.set(Int(shortcut.keyCode), forKey: prefix + "shortcut.\(action.rawValue).code")
            defaults.set(Int(shortcut.modifiers), forKey: prefix + "shortcut.\(action.rawValue).modifiers")
        }
    }

    func resetShortcuts() { persist(shortcuts: ShortcutAction.defaults) }

    static func duplicateAction(in shortcuts: [ShortcutAction: Shortcut]) -> (ShortcutAction, ShortcutAction)? {
        let actions = ShortcutAction.allCases
        for i in actions.indices {
            for j in actions.index(after: i)..<actions.endIndex where shortcuts[actions[i]] == shortcuts[actions[j]] {
                return (actions[i], actions[j])
            }
        }
        return nil
    }

    static func normalizedMagnification(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 2 }
        return min(8, max(1.25, (value * 4).rounded() / 4))
    }

    private static func normalizedSize(_ value: CGFloat, min minimum: CGFloat, max maximum: CGFloat,
                                       fallback: CGFloat) -> CGFloat {
        guard value.isFinite else { return fallback }
        return Swift.min(maximum, Swift.max(minimum, value))
    }

    private func store(color: NSColor, key: String) {
        guard let c = color.usingColorSpace(.sRGB) else { return }
        defaults.set([Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent)],
                     forKey: prefix + key)
    }

    private static func readColor(defaults: UserDefaults, key: String, fallback: NSColor) -> NSColor {
        guard let values = defaults.array(forKey: key) as? [Double], values.count == 4,
              values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return fallback }
        return NSColor(srgbRed: values[0], green: values[1], blue: values[2], alpha: values[3])
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

func magnificationLabel(_ value: CGFloat) -> String {
    let hundredths = Int((value * 100).rounded())
    if hundredths % 100 == 0 { return "\(hundredths / 100)×" }
    if hundredths % 10 == 0 { return String(format: "%.1f×", value) }
    return String(format: "%.2f×", value)
}

struct MagnifierGeometry {
    static func sourceRect(center: NSPoint, sourceSize: NSSize, inside bounds: NSRect) -> NSRect {
        let width = min(sourceSize.width, bounds.width)
        let height = min(sourceSize.height, bounds.height)
        let x = min(bounds.maxX - width, max(bounds.minX, center.x - width / 2))
        let y = min(bounds.maxY - height, max(bounds.minY, center.y - height / 2))
        return NSRect(x: x, y: y, width: width, height: height)
    }

    static func destinationRect(center: NSPoint, size: NSSize, inside bounds: NSRect) -> NSRect {
        sourceRect(center: center, sourceSize: size, inside: bounds)
    }

    static func isSelectionDrag(from start: NSPoint, to end: NSPoint, threshold: CGFloat = 8) -> Bool {
        hypot(end.x - start.x, end.y - start.y) >= threshold
    }

    static func selectionRect(from start: NSPoint, to end: NSPoint, circular: Bool,
                              inside bounds: NSRect,
                              minimum: NSSize = NSSize(width: 96, height: 96),
                              maximum: NSSize = NSSize(width: 640, height: 480)) -> NSRect {
        guard !bounds.isEmpty else { return .zero }
        let dx = end.x - start.x
        let dy = end.y - start.y
        let maxWidth = min(maximum.width, bounds.width)
        let maxHeight = min(maximum.height, bounds.height)
        let minWidth = min(minimum.width, maxWidth)
        let minHeight = min(minimum.height, maxHeight)
        let width: CGFloat
        let height: CGFloat
        if circular {
            let minSide = min(minWidth, minHeight)
            let maxSide = min(maxWidth, maxHeight)
            let side = min(maxSide, max(minSide, max(abs(dx), abs(dy))))
            width = side
            height = side
        } else {
            width = min(maxWidth, max(minWidth, abs(dx)))
            height = min(maxHeight, max(minHeight, abs(dy)))
        }
        let origin = NSPoint(x: dx < 0 ? start.x - width : start.x,
                             y: dy < 0 ? start.y - height : start.y)
        let raw = NSRect(origin: origin, size: NSSize(width: width, height: height))
        return destinationRect(center: NSPoint(x: raw.midX, y: raw.midY), size: raw.size, inside: bounds)
    }
}

enum MagnifierInteraction: Equatable {
    case follow
    case selecting(NSRect)
    case locked(NSRect)
}

// ScreenCaptureKit은 macOS 12.3부터 제공된다. 현재 프로세스의 모든 창을 필터에서 빼므로
// 캔버스, 툴바, 환경설정, 색상 패널이 확대 화면 안에 다시 나타나지 않는다.
final class ScreenCaptureService: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((CGImage, NSRect) -> Void)?
    var onFailure: (() -> Void)?
    private let outputQueue = DispatchQueue(label: "brush.magnifier.capture", qos: .userInteractive)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var generation = 0
    private var capturedScreenFrame: NSRect = .zero

    func start(for screen: NSScreen) {
        let (requestedGeneration, previousStream): (Int, SCStream?) = withStateLock {
            generation += 1
            let previous = stream
            stream = nil
            capturedScreenFrame = .zero
            return (generation, previous)
        }
        previousStream?.stopCapture(completionHandler: { _ in })
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            reportFailure(generation: requestedGeneration)
            return
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        let screenFrame = screen.frame
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self, self.isCurrent(generation: requestedGeneration) else { return }
            guard error == nil, let content,
                  let display = content.displays.first(where: { $0.displayID == displayID }) else {
                self.reportFailure(generation: requestedGeneration)
                return
            }
            let ownApps = content.applications.filter { $0.processID == getpid() }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = display.width
            configuration.height = display.height
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 20)
            configuration.queueDepth = 2
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.showsCursor = false
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.outputQueue)
                let installed = self.withStateLock {
                    guard self.generation == requestedGeneration, self.stream == nil else { return false }
                    self.stream = stream
                    self.capturedScreenFrame = screenFrame
                    return true
                }
                guard installed else { return }
                stream.startCapture { [weak self] error in
                    guard error != nil else { return }
                    self?.reportFailure(generation: requestedGeneration, stream: stream)
                }
            } catch {
                self.reportFailure(generation: requestedGeneration)
            }
        }
    }

    func stop() {
        let previousStream: SCStream? = withStateLock {
            generation += 1
            let previous = stream
            stream = nil
            capturedScreenFrame = .zero
            return previous
        }
        previousStream?.stopCapture(completionHandler: { _ in })
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        guard let state: (generation: Int, frame: NSRect) = withStateLock({
            guard stream === self.stream else { return nil }
            return (self.generation, self.capturedScreenFrame)
        }) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let image = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(generation: state.generation, stream: stream) else { return }
            self.onFrame?(image, state.frame)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard let stoppedGeneration: Int = withStateLock({
            stream === self.stream ? self.generation : nil
        }) else { return }
        reportFailure(generation: stoppedGeneration, stream: stream)
    }

    private func reportFailure(generation: Int, stream: SCStream? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(generation: generation, stream: stream) else { return }
            self.onFailure?()
        }
    }

    private func isCurrent(generation expectedGeneration: Int, stream expectedStream: SCStream? = nil) -> Bool {
        withStateLock {
            guard generation == expectedGeneration else { return false }
            return expectedStream == nil || expectedStream === stream
        }
    }

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    deinit {
        let previousStream: SCStream? = withStateLock {
            let previous = stream
            stream = nil
            return previous
        }
        previousStream?.stopCapture(completionHandler: { _ in })
    }
}

// MARK: - 캔버스

final class CanvasView: NSView, NSTextFieldDelegate {
    var shapes: [Shape] = []
    private var current: [NSPoint] = []
    private(set) var editor: NSTextField?
    private var editorWidth: CGFloat = 0  // 입력 시작 시점의 굵기 — 도중에 툴바를 만져도 안 흔들리게

    var tool: Tool = .pen
    var inkColor: NSColor = .systemRed
    var lineWidth: CGFloat = brushWidths[1]

    // 포인터/확대 효과는 Shape 및 실행취소 이력과 완전히 분리한다.
    var laserSize: CGFloat = 24 { didSet { needsDisplay = true } }
    var laserColor: NSColor = .systemRed { didSet { needsDisplay = true } }
    var arrowPointerSize: CGFloat = 64 { didSet { needsDisplay = true } }
    var arrowPointerColor: NSColor = .systemYellow { didSet { needsDisplay = true } }
    private(set) var magnification: CGFloat = 2
    private(set) var magnifierInteraction: MagnifierInteraction = .follow
    var onMagnificationChanged: ((CGFloat) -> Void)?
    private var transientPoint: NSPoint?
    private var magnifierDragStart: NSPoint?
    private var magnifierImage: CGImage?
    private var capturedDisplayImage: CGImage?
    private var capturedScreenFrame: NSRect = .zero
    private var magnifierCaptureFailed = false
    private var tracking: NSTrackingArea?
    private let magnifierDiameter: CGFloat = 220
    private var preciseScrollAccumulator: CGFloat = 0
    private lazy var captureService: ScreenCaptureService = {
        let service = ScreenCaptureService()
        service.onFrame = { [weak self] image, screenFrame in
            guard let self, self.tool.isMagnifier else { return }
            let wasFailed = self.magnifierCaptureFailed
            self.capturedDisplayImage = image
            self.capturedScreenFrame = screenFrame
            self.magnifierCaptureFailed = false
            if wasFailed { self.window?.invalidateCursorRects(for: self) }
            self.refreshMagnifier()
        }
        service.onFailure = { [weak self] in
            self?.capturedDisplayImage = nil
            self?.magnifierImage = nil
            self?.magnifierCaptureFailed = true
            self?.magnifierInteraction = .follow
            self?.magnifierDragStart = nil
            self?.restoreCursor()
            self?.needsDisplay = true
        }
        return service
    }()

    private static let invisibleCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: .zero)
    }()

    // 단축키로 도구를 바꿀 때 툴바 하이라이트/클릭 통과까지 같이 손봐야 해서 앱에 넘긴다
    var onToolShortcut: ((Tool) -> Void)?
    var onCancelToMouseMode: (() -> Void)?

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

    func setMagnification(_ value: CGFloat, notify: Bool = false) {
        let normalized = AppSettings.normalizedMagnification(value)
        guard normalized != magnification else { return }
        magnification = normalized
        refreshMagnifier()
        if notify { onMagnificationChanged?(normalized) }
    }

    func activateTransientEffects(for newTool: Tool) {
        preciseScrollAccumulator = 0
        magnifierInteraction = .follow
        magnifierDragStart = nil
        if !newTool.isMagnifier { captureService.stop() }
        if let window, newTool.isTransient {
            transientPoint = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        } else {
            transientPoint = nil
        }
        magnifierImage = nil
        capturedDisplayImage = nil
        magnifierCaptureFailed = false
        if newTool.isTransient {
            if newTool.isMagnifier {
                if let screen = window?.screen { captureService.start(for: screen) }
            }
        } else {
            captureService.stop()
            restoreCursor()
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    func stopTransientEffects() {
        captureService.stop()
        transientPoint = nil
        magnifierImage = nil
        capturedDisplayImage = nil
        preciseScrollAccumulator = 0
        magnifierInteraction = .follow
        magnifierDragStart = nil
        restoreCursor()
        needsDisplay = true
    }

    func restoreCursor() {
        NSCursor.arrow.set()
        window?.invalidateCursorRects(for: self)
    }

    private var magnifierUsableBounds: NSRect {
        let inset: CGFloat = bounds.width > 12 && bounds.height > 12 ? 6 : 0
        return bounds.insetBy(dx: inset, dy: inset)
    }

    func beginMagnifierSelection(at point: NSPoint) {
        guard tool.isMagnifier else { return }
        magnifierDragStart = point
        if magnifierInteraction == .follow { transientPoint = point }
        needsDisplay = true
    }

    func updateMagnifierSelection(to point: NSPoint) {
        guard tool.isMagnifier, let start = magnifierDragStart else { return }
        guard MagnifierGeometry.isSelectionDrag(from: start, to: point) else { return }
        let wasFollowing = magnifierInteraction == .follow
        let rect = MagnifierGeometry.selectionRect(from: start, to: point,
                                                    circular: tool == .circleMagnifier,
                                                    inside: magnifierUsableBounds)
        magnifierInteraction = .selecting(rect)
        if wasFollowing { window?.invalidateCursorRects(for: self) }
        refreshMagnifier()
        needsDisplay = true
    }

    func endMagnifierSelection(at point: NSPoint) {
        guard tool.isMagnifier, let start = magnifierDragStart else { return }
        magnifierDragStart = nil
        if MagnifierGeometry.isSelectionDrag(from: start, to: point) {
            let rect = MagnifierGeometry.selectionRect(from: start, to: point,
                                                        circular: tool == .circleMagnifier,
                                                        inside: magnifierUsableBounds)
            magnifierInteraction = .locked(rect)
        } else {
            // 짧은 클릭은 고정을 풀고 클릭 위치를 따라가는 기본 모드로 돌아간다.
            magnifierInteraction = .follow
            transientPoint = point
        }
        window?.invalidateCursorRects(for: self)
        refreshMagnifier()
        needsDisplay = true
    }

    @discardableResult
    func cancelMagnifierLock() -> Bool {
        guard tool.isMagnifier, magnifierInteraction != .follow || magnifierDragStart != nil else { return false }
        magnifierInteraction = .follow
        magnifierDragStart = nil
        if let window { transientPoint = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil) }
        window?.invalidateCursorRects(for: self)
        refreshMagnifier()
        needsDisplay = true
        return true
    }

    func currentMagnifierLensRect() -> NSRect? {
        guard tool.isMagnifier else { return nil }
        switch magnifierInteraction {
        case .follow:
            guard let point = transientPoint else { return nil }
            return MagnifierGeometry.destinationRect(center: point,
                                                      size: NSSize(width: magnifierDiameter, height: magnifierDiameter),
                                                      inside: magnifierUsableBounds)
        case .selecting(let rect), .locked(let rect):
            return rect
        }
    }

    deinit {
        if tool.isMagnifier { captureService.stop() }
        restoreCursor()
    }

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
        case .text, .eraser, .click, .laser, .arrowPointer, .circleMagnifier, .rectangleMagnifier:
            break  // 그리는 도구가 아님
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

    // ESC는 단순 지우기가 아니라 현재 작업 전체를 버린다. 다시 실행으로 되살아나지 않도록
    // 이력도 비우며, 실제 마우스 모드 전환은 앱의 단일 도구 전환 통로에 맡긴다.
    func cancelAll() {
        magnifierInteraction = .follow
        magnifierDragStart = nil
        clear()
        resetHistory()
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
        case .eraser, .click, .laser, .arrowPointer, .circleMagnifier, .rectangleMagnifier:
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
        case .circleMagnifier, .rectangleMagnifier: beginMagnifierSelection(at: p)
        case .click, .laser, .arrowPointer: updateTransientPoint(p)
        default: begin(at: p)
        }
    }
    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        switch tool {
        case .text, .click: break
        case .eraser: erase(at: p)
        case .circleMagnifier, .rectangleMagnifier: updateMagnifierSelection(to: p)
        case .laser, .arrowPointer: updateTransientPoint(p)
        default: extend(to: p)
        }
    }
    override func mouseUp(with e: NSEvent) {
        switch tool {
        case .circleMagnifier, .rectangleMagnifier:
            endMagnifierSelection(at: convert(e.locationInWindow, from: nil))
        case .text, .eraser, .click, .laser, .arrowPointer: break
        default: end()
        }
    }

    override func mouseMoved(with e: NSEvent) {
        guard tool.isTransient else { return }
        if tool.isMagnifier, magnifierInteraction != .follow { return }
        updateTransientPoint(convert(e.locationInWindow, from: nil))
    }

    override func scrollWheel(with e: NSEvent) {
        guard tool.isMagnifier else { super.scrollWheel(with: e); return }
        let delta = e.scrollingDeltaY
        if abs(delta) > 0.01 {
            applyMagnificationScroll(delta: delta, precise: e.hasPreciseScrollingDeltas)
        }
        if e.hasPreciseScrollingDeltas,
           e.phase == .ended || e.momentumPhase == .ended {
            if abs(preciseScrollAccumulator) >= 1 {
                setMagnification(magnification + (preciseScrollAccumulator > 0 ? 0.25 : -0.25), notify: true)
            }
            preciseScrollAccumulator = 0
        }
    }

    func applyMagnificationScroll(delta: CGFloat, precise: Bool) {
        guard tool.isMagnifier, delta.isFinite else { return }
        if !precise {
            setMagnification(magnification + (delta > 0 ? 0.25 : -0.25), notify: true)
            return
        }
        preciseScrollAccumulator += delta
        let threshold: CGFloat = 8
        while abs(preciseScrollAccumulator) >= threshold {
            let direction: CGFloat = preciseScrollAccumulator > 0 ? 1 : -1
            setMagnification(magnification + direction * 0.25, notify: true)
            preciseScrollAccumulator -= direction * threshold
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with e: NSEvent) {
        if tool.isTransient { window?.invalidateCursorRects(for: self) }
    }

    override func mouseExited(with e: NSEvent) {
        // 다른 모니터나 앱 영역으로 빠졌을 때 시스템 커서가 사라진 채 남지 않게 한다.
        restoreCursor()
        if tool.isMagnifier, magnifierInteraction != .follow { return }
        transientPoint = nil
        magnifierImage = nil
        needsDisplay = true
    }

    func updateTransientPoint(_ point: NSPoint) {
        if tool.isMagnifier, magnifierInteraction != .follow { return }
        transientPoint = point
        if tool.isMagnifier { refreshMagnifier() }
        needsDisplay = true
    }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == UInt16(kVK_Escape) { onCancelToMouseMode?(); return }
        // 텍스트 입력 중에는 필드가 first responder라 여기까지 오지 않는다 — 글자 단축키가 입력을 먹지 않음
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.isDisjoint(with: [.command, .control, .option]),
           let t = Tool(shortcut: e.charactersIgnoringModifiers ?? "") {
            onToolShortcut?(t)
            return
        }
        super.keyDown(with: e)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        onCancelToMouseMode?()
        return true
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
        if tool.isTransient {
            let cursor: NSCursor
            if magnifierCaptureFailed {
                cursor = .arrow
            } else if tool.isMagnifier && magnifierInteraction != .follow {
                cursor = .crosshair
            } else {
                cursor = Self.invisibleCursor
            }
            addCursorRect(bounds, cursor: cursor)
            return
        }
        guard tool != .click else { return }
        addCursorRect(bounds, cursor: .crosshair)
    }

    var hidesSystemCursorForCurrentTool: Bool {
        guard tool.isTransient, !magnifierCaptureFailed else { return false }
        return !tool.isMagnifier || magnifierInteraction == .follow
    }

    // ponytail: 점 하나 찍힐 때마다 전체 다시 그림. 선이 수백 개로 늘어 버벅이면 CAShapeLayer로.
    override func draw(_ dirty: NSRect) {
        for s in shapes + (current.count > 1 ? [Shape(tool: tool, points: current, color: inkColor, width: lineWidth)] : []) {
            drawShape(s)
        }
        drawTransientEffect()
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
        case .eraser, .click, .laser, .arrowPointer, .circleMagnifier, .rectangleMagnifier:
            break  // 도형으로 남지 않는다
        }
    }

    private func drawTransientEffect() {
        switch tool {
        case .laser:
            guard let p = transientPoint else { return }
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = laserColor.withAlphaComponent(0.8)
            shadow.shadowBlurRadius = max(8, laserSize * 0.6)
            shadow.shadowOffset = .zero
            shadow.set()
            laserColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - laserSize / 2, y: p.y - laserSize / 2,
                                        width: laserSize, height: laserSize)).fill()
            NSGraphicsContext.restoreGraphicsState()
        case .arrowPointer:
            guard let p = transientPoint else { return }
            drawArrowPointer(at: p)
        case .circleMagnifier, .rectangleMagnifier:
            guard let lens = currentMagnifierLensRect() else { return }
            drawMagnifier(in: lens, circular: tool == .circleMagnifier)
        default:
            break
        }
    }

    private func drawArrowPointer(at p: NSPoint) {
        let s = arrowPointerSize
        let path = NSBezierPath()
        path.move(to: p)
        path.line(to: NSPoint(x: p.x + s * 0.18, y: p.y - s * 0.72))
        path.line(to: NSPoint(x: p.x + s * 0.36, y: p.y - s * 0.54))
        path.line(to: NSPoint(x: p.x + s * 0.58, y: p.y - s * 0.88))
        path.line(to: NSPoint(x: p.x + s * 0.72, y: p.y - s * 0.78))
        path.line(to: NSPoint(x: p.x + s * 0.50, y: p.y - s * 0.46))
        path.line(to: NSPoint(x: p.x + s * 0.76, y: p.y - s * 0.42))
        path.close()
        let rgb = arrowPointerColor.usingColorSpace(.sRGB)
        let brightness = (rgb?.redComponent ?? 1) * 0.299 + (rgb?.greenComponent ?? 1) * 0.587 + (rgb?.blueComponent ?? 1) * 0.114
        (brightness > 0.55 ? NSColor.black : NSColor.white).withAlphaComponent(0.9).setStroke()
        arrowPointerColor.setFill()
        path.lineWidth = max(2, s / 24)
        path.lineJoinStyle = .round
        path.fill()
        path.stroke()
    }

    private func drawMagnifier(in lens: NSRect, circular: Bool) {
        let clip = circular ? NSBezierPath(ovalIn: lens) : NSBezierPath(roundedRect: lens, xRadius: 14, yRadius: 14)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        if let image = magnifierImage {
            NSImage(cgImage: image, size: lens.size).draw(in: lens, from: .zero, operation: .copy, fraction: 1)
        } else {
            NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
            clip.fill()
            let message = magnifierCaptureFailed ? "화면 기록 권한이 필요합니다" : "확대 준비 중…"
            message.draw(at: NSPoint(x: lens.minX + 22, y: lens.midY - 8), withAttributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ])
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.95).setStroke()
        clip.lineWidth = 4
        if case .selecting = magnifierInteraction { clip.setLineDash([8, 5], count: 2, phase: 0) }
        clip.stroke()
        let badge = magnificationLabel(magnification)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.72),
        ]
        badge.draw(at: NSPoint(x: lens.midX - 18, y: lens.minY + 9), withAttributes: attrs)
    }

    private func refreshMagnifier() {
        guard tool.isMagnifier, let lens = currentMagnifierLensRect(), let window,
              let displayImage = capturedDisplayImage, !capturedScreenFrame.isEmpty else { return }
        let global = window.convertPoint(toScreen: NSPoint(x: lens.midX, y: lens.midY))
        guard capturedScreenFrame.contains(global) else {
            magnifierImage = nil
            needsDisplay = true
            return
        }
        let appKitSource = MagnifierGeometry.sourceRect(center: global,
                                                        sourceSize: NSSize(width: lens.width / magnification,
                                                                           height: lens.height / magnification),
                                                        inside: capturedScreenFrame)
        let scaleX = CGFloat(displayImage.width) / capturedScreenFrame.width
        let scaleY = CGFloat(displayImage.height) / capturedScreenFrame.height
        let localX = appKitSource.minX - capturedScreenFrame.minX
        let localY = appKitSource.minY - capturedScreenFrame.minY
        // ScreenCaptureKit 프레임은 위쪽 원점, AppKit 화면 좌표는 아래쪽 원점이다.
        let pixelRect = CGRect(x: localX * scaleX,
                               y: (capturedScreenFrame.height - localY - appKitSource.height) * scaleY,
                               width: appKitSource.width * scaleX,
                               height: appKitSource.height * scaleY).integral
            .intersection(CGRect(x: 0, y: 0, width: displayImage.width, height: displayImage.height))
        magnifierImage = pixelRect.isEmpty ? nil : displayImage.cropping(to: pixelRect)
        magnifierCaptureFailed = (magnifierImage == nil)
        needsDisplay = true
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
    private var undoButton: ToolbarButton!
    private(set) var displayedToolOrder: [Tool] = []
    private let buttonSide: CGFloat = 34
    private var mainStack: NSStackView!

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
        let click = makeToolButton(.click, symbol: "cursorarrow", tip: "클릭 통과 · C / ⌥1 (브러시를 켠 채로 밑 화면 클릭)")
        let pen = makeToolButton(.pen, symbol: "pencil", tip: "펜 · P / ⌥2")
        let arrow = makeToolButton(.arrow, symbol: "arrow.up.right", tip: "화살표 · A / ⌥3")
        let rect = makeToolButton(.rect, symbol: "square", tip: "사각형 · R / ⌥4")
        let text = makeToolButton(.text, symbol: "textformat", tip: "텍스트 · T / ⌥5")
        let eraser = makeToolButton(.eraser, symbol: "eraser", tip: "지우개 · E / ⌥6 (닿는 것만 지움 · 전체는 ESC)")
        let laser = makeToolButton(.laser, symbol: "dot.scope", tip: "레이저 포인터 · ⌥7")
        let arrowPointer = makeToolButton(.arrowPointer, symbol: "cursorarrow.rays", tip: "화살표 포인터 · ⌥8")
        let circleMagnifier = makeToolButton(.circleMagnifier, symbol: "plus.magnifyingglass", tip: "원형 확대 · ⌥9 (드래그로 고정 · 짧은 클릭으로 해제 · 휠 배율)")
        let rectangleMagnifier = makeToolButton(.rectangleMagnifier, symbol: "rectangle.and.text.magnifyingglass", tip: "사각형 확대 · ⌥0 (드래그로 고정 · 짧은 클릭으로 해제 · 휠 배율)")
        toolButtons[.pen]?.isSelected = true

        let undo = makeUndoButton()

        let colorControl = makeColorControl()

        displayedToolOrder = [.click, .pen, .arrow, .rect, .text, .eraser,
                              .laser, .arrowPointer, .circleMagnifier, .rectangleMagnifier]
        // 도구, 실행취소/색상, 굵기까지 모두 하나의 세로 열에 둔다. 34pt 버튼과 1pt 간격으로
        // 16개 컨트롤 전체가 600pt급 화면의 사용 가능 높이 안에 들어간다.
        let stack = NSStackView(views: [click, pen, arrow, rect, text, eraser,
                                        laser, arrowPointer, circleMagnifier, rectangleMagnifier,
                                        separator(), undo, colorControl, separator()] + makeSizeButtons())
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        mainStack = stack

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

    var isSingleColumnLayout: Bool {
        mainStack.orientation == .vertical && mainStack.arrangedSubviews.filter { !($0 is NSBox) }.count == 16
    }

    var toolButtonTagsAreValid: Bool {
        displayedToolOrder.allSatisfy { toolButtons[$0]?.tag == $0.rawValue }
    }

    func toolTip(for tool: Tool) -> String? { toolButtons[tool]?.toolTip }

    private func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: buttonSide).isActive = true
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
        b.widthAnchor.constraint(equalToConstant: buttonSide).isActive = true
        b.heightAnchor.constraint(equalToConstant: buttonSide).isActive = true
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
        b.widthAnchor.constraint(equalToConstant: buttonSide).isActive = true
        b.heightAnchor.constraint(equalToConstant: buttonSide).isActive = true
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

    func updateShortcutTips(_ shortcuts: [ShortcutAction: Shortcut]) {
        func key(_ action: ShortcutAction) -> String { shortcuts[action]?.displayName ?? "—" }
        toolButtons[.pen]?.toolTip = "펜 · P (로컬) / \(key(.pen)) (전역)"
        toolButtons[.arrow]?.toolTip = "화살표 그리기 · A (로컬) / \(key(.arrow)) (전역)"
        toolButtons[.rect]?.toolTip = "사각형 그리기 · R (로컬) / \(key(.rect)) (전역)"
        toolButtons[.text]?.toolTip = "텍스트 · T (로컬) / \(key(.text)) (전역)"
        toolButtons[.eraser]?.toolTip = "지우개 · E (로컬) / \(key(.eraser)) (전역)"
        toolButtons[.click]?.toolTip = "클릭 통과 · C (로컬) / \(key(.click)) (전역)"
        toolButtons[.laser]?.toolTip = "레이저 포인터 · \(key(.laser))"
        toolButtons[.arrowPointer]?.toolTip = "화살표 포인터 · \(key(.arrowPointer))"
        toolButtons[.circleMagnifier]?.toolTip = "원형 확대 · \(key(.circleMagnifier)) (드래그로 고정 · 짧은 클릭으로 해제 · 휠 배율)"
        toolButtons[.rectangleMagnifier]?.toolTip = "사각형 확대 · \(key(.rectangleMagnifier)) (드래그로 고정 · 짧은 클릭으로 해제 · 휠 배율)"
        undoButton?.toolTip = "실행취소 · ⌘Z (로컬) / \(key(.undo)) (전역)"
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
        b.widthAnchor.constraint(equalToConstant: buttonSide).isActive = true
        b.heightAnchor.constraint(equalToConstant: buttonSide).isActive = true
        undoButton = b
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
            b.widthAnchor.constraint(equalToConstant: buttonSide).isActive = true
            b.heightAnchor.constraint(equalToConstant: buttonSide).isActive = true
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
        let x = min(screenFrame.maxX - size.width - 8, screenFrame.minX + 24)
        let y = min(screenFrame.maxY - size.height - 8,
                    max(screenFrame.minY + 8, screenFrame.midY - size.height / 2))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - 오버레이 창

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class ShortcutRecorderField: NSTextField {
    let shortcutAction: ShortcutAction
    var onRecord: ((ShortcutAction, Shortcut) -> Bool)?

    init(action: ShortcutAction, shortcut: Shortcut) {
        shortcutAction = action
        super.init(frame: .zero)
        stringValue = shortcut.displayName
        alignment = .center
        isEditable = false
        isSelectable = false
        isBezeled = true
        focusRingType = .exterior
        toolTip = "클릭한 뒤 원하는 단축키를 누르세요"
    }

    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard let shortcut = Shortcut.from(event: event) else {
            NSSound.beep()
            return
        }
        if onRecord?(shortcutAction, shortcut) == true {
            stringValue = shortcut.displayName
        } else {
            NSSound.beep()
        }
    }
}

final class PreferencesController: NSWindowController {
    let settings: AppSettings
    var onShortcutsChanged: (([ShortcutAction: Shortcut]) -> String?)?
    var onAppearanceChanged: (() -> Void)?
    private var recorderFields: [ShortcutAction: ShortcutRecorderField] = [:]
    private let statusLabel = NSTextField(labelWithString: "")
    private var laserSizeLabel = NSTextField(labelWithString: "")
    private var arrowSizeLabel = NSTextField(labelWithString: "")
    private var zoomLabel = NSTextField(labelWithString: "")

    init(settings: AppSettings) {
        self.settings = settings
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 690),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Brush 환경설정"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        NotificationCenter.default.addObserver(self, selector: #selector(colorPanelBecameKey),
                                               name: NSWindow.didBecomeKeyNotification, object: NSColorPanel.shared)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    func present() {
        reloadShortcutFields()
        NSColorPanel.shared.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 3)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func refreshAppearanceLabels() {
        laserSizeLabel.stringValue = "\(Int(settings.laserSize)) pt"
        arrowSizeLabel.stringValue = "\(Int(settings.arrowPointerSize)) pt"
        zoomLabel.stringValue = magnificationLabel(settings.magnification)
    }

    private func buildUI() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false

        root.addArrangedSubview(sectionTitle("전역 단축키"))
        let shortcutHint = NSTextField(wrappingLabelWithString: "브러시가 활성화된 동안에는 P/A/R/T/E/C와 ESC 로컬 단축키도 계속 사용할 수 있습니다.")
        shortcutHint.textColor = .secondaryLabelColor
        shortcutHint.preferredMaxLayoutWidth = 550
        root.addArrangedSubview(shortcutHint)
        let grid = NSGridView()
        grid.columnSpacing = 16
        grid.rowSpacing = 5
        for action in ShortcutAction.allCases {
            let label = NSTextField(labelWithString: action.title)
            label.alignment = .right
            let field = ShortcutRecorderField(action: action, shortcut: settings.shortcuts[action]!)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 150).isActive = true
            field.onRecord = { [weak self] action, shortcut in self?.record(action: action, shortcut: shortcut) ?? false }
            recorderFields[action] = field
            grid.addRow(with: [label, field])
        }
        root.addArrangedSubview(grid)

        let reset = NSButton(title: "기본 단축키로 복원", target: self, action: #selector(resetShortcuts))
        root.addArrangedSubview(reset)
        statusLabel.textColor = .systemRed
        statusLabel.maximumNumberOfLines = 2
        root.addArrangedSubview(statusLabel)
        root.addArrangedSubview(separator())

        root.addArrangedSubview(sectionTitle("포인터"))
        let laserSlider = slider(min: 8, max: 80, value: settings.laserSize, action: #selector(laserSizeChanged(_:)))
        let laserColor = NSColorWell()
        laserColor.color = settings.laserColor
        laserColor.target = self
        laserColor.action = #selector(laserColorChanged(_:))
        root.addArrangedSubview(settingRow(title: "레이저 점 크기", control: laserSlider, valueLabel: laserSizeLabel, colorWell: laserColor))

        let arrowSlider = slider(min: 24, max: 160, value: settings.arrowPointerSize, action: #selector(arrowSizeChanged(_:)))
        let arrowColor = NSColorWell()
        arrowColor.color = settings.arrowPointerColor
        arrowColor.target = self
        arrowColor.action = #selector(arrowColorChanged(_:))
        root.addArrangedSubview(settingRow(title: "화살표 크기", control: arrowSlider, valueLabel: arrowSizeLabel, colorWell: arrowColor))

        root.addArrangedSubview(separator())
        root.addArrangedSubview(sectionTitle("확대"))
        let zoomSlider = slider(min: 1.25, max: 8, value: settings.magnification, action: #selector(zoomChanged(_:)))
        zoomSlider.numberOfTickMarks = 28
        zoomSlider.allowsTickMarkValuesOnly = true
        root.addArrangedSubview(settingRow(title: "기본/마지막 배율", control: zoomSlider, valueLabel: zoomLabel, colorWell: nil))
        let hint = NSTextField(wrappingLabelWithString: "확대: 드래그로 고정, 짧은 클릭으로 해제 · 휠 1.25×~8× · 마지막 배율 자동 저장")
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 550
        root.addArrangedSubview(hint)

        guard let content = window?.contentView else { return }
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        refreshAppearanceLabels()
    }

    private func sectionTitle(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: 15)
        return label
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 570).isActive = true
        return box
    }

    private func slider(min: CGFloat, max: CGFloat, value: CGFloat, action: Selector) -> NSSlider {
        let slider = NSSlider(value: Double(value), minValue: Double(min), maxValue: Double(max), target: self, action: action)
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 270).isActive = true
        return slider
    }

    private func settingRow(title: String, control: NSView, valueLabel: NSTextField, colorWell: NSColorWell?) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 125).isActive = true
        valueLabel.alignment = .right
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true
        var views: [NSView] = [label, control, valueLabel]
        if let colorWell {
            colorWell.translatesAutoresizingMaskIntoConstraints = false
            colorWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
            views.append(colorWell)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 9
        return stack
    }

    private func record(action: ShortcutAction, shortcut: Shortcut) -> Bool {
        statusLabel.textColor = .systemRed
        var candidate = settings.shortcuts
        candidate[action] = shortcut
        if let duplicate = AppSettings.duplicateAction(in: candidate) {
            statusLabel.stringValue = "‘\(duplicate.0.title)’과 ‘\(duplicate.1.title)’ 단축키가 겹칩니다."
            return false
        }
        if let error = onShortcutsChanged?(candidate) {
            statusLabel.stringValue = error
            return false
        }
        statusLabel.stringValue = ""
        reloadShortcutFields()
        return true
    }

    private func reloadShortcutFields() {
        for (action, field) in recorderFields {
            field.stringValue = settings.shortcuts[action]?.displayName ?? "—"
        }
    }

    @objc private func resetShortcuts() {
        statusLabel.textColor = .systemRed
        if let error = onShortcutsChanged?(ShortcutAction.defaults) {
            statusLabel.stringValue = error
        } else {
            statusLabel.stringValue = "기본 단축키로 복원했습니다."
            statusLabel.textColor = .secondaryLabelColor
            reloadShortcutFields()
        }
    }

    @objc private func laserSizeChanged(_ sender: NSSlider) {
        settings.laserSize = CGFloat(sender.doubleValue.rounded())
        refreshAppearanceLabels()
        onAppearanceChanged?()
    }

    @objc private func laserColorChanged(_ sender: NSColorWell) {
        settings.laserColor = sender.color
        onAppearanceChanged?()
    }

    @objc private func arrowSizeChanged(_ sender: NSSlider) {
        settings.arrowPointerSize = CGFloat(sender.doubleValue.rounded())
        refreshAppearanceLabels()
        onAppearanceChanged?()
    }

    @objc private func arrowColorChanged(_ sender: NSColorWell) {
        settings.arrowPointerColor = sender.color
        onAppearanceChanged?()
    }

    @objc private func zoomChanged(_ sender: NSSlider) {
        settings.magnification = CGFloat(sender.doubleValue)
        sender.doubleValue = Double(settings.magnification)
        refreshAppearanceLabels()
        onAppearanceChanged?()
    }

    @objc private func colorPanelBecameKey() {
        NSColorPanel.shared.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 3)
    }
}

final class HotKeyManager {
    private let signature = OSType(0x42525348 /* 'BRSH' */)
    private var refs: [ShortcutAction: EventHotKeyRef] = [:]
    private(set) var shortcuts: [ShortcutAction: Shortcut]
    private(set) var sessionActive = false

    init(shortcuts: [ShortcutAction: Shortcut]) {
        self.shortcuts = shortcuts
    }

    func registerInitial() -> OSStatus {
        transact(to: shortcuts, keepSessionActive: false, testAll: true)
    }

    func setSessionActive(_ active: Bool) -> OSStatus {
        guard active != sessionActive else { return noErr }
        return transact(to: shortcuts, keepSessionActive: active, testAll: false)
    }

    // 후보 전체를 실제 Carbon API에 등록해 본 뒤 성공할 때만 확정한다. 중간에 하나라도 실패하면
    // 부분 등록을 모두 제거하고 이전 구성을 원래 활성 상태 그대로 되살린다.
    func apply(_ candidate: [ShortcutAction: Shortcut]) -> OSStatus {
        guard AppSettings.duplicateAction(in: candidate) == nil else { return OSStatus(eventHotKeyExistsErr) }
        return transact(to: candidate, keepSessionActive: sessionActive, testAll: true)
    }

    func action(for id: UInt32) -> ShortcutAction? {
        let index = Int(id) - 1
        guard ShortcutAction.allCases.indices.contains(index) else { return nil }
        return ShortcutAction.allCases[index]
    }

    func unregisterAll() {
        unregisterCurrent()
        sessionActive = false
    }

    private func transact(to candidate: [ShortcutAction: Shortcut], keepSessionActive: Bool, testAll: Bool) -> OSStatus {
        let previous = shortcuts
        let previousSession = sessionActive
        unregisterCurrent()

        let actions = (keepSessionActive || testAll) ? ShortcutAction.allCases : [.toggle]
        let result = register(candidate, actions: actions)
        if result != noErr {
            unregisterCurrent()
            let restoreActions = previousSession ? ShortcutAction.allCases : [.toggle]
            _ = register(previous, actions: restoreActions)
            shortcuts = previous
            sessionActive = previousSession
            return result
        }

        shortcuts = candidate
        sessionActive = keepSessionActive
        if testAll && !keepSessionActive {
            for action in ShortcutAction.allCases where action != .toggle {
                if let ref = refs.removeValue(forKey: action) { UnregisterEventHotKey(ref) }
            }
        }
        return noErr
    }

    private func register(_ values: [ShortcutAction: Shortcut], actions: [ShortcutAction]) -> OSStatus {
        for action in actions {
            guard let shortcut = values[action],
                  let index = ShortcutAction.allCases.firstIndex(of: action) else { return OSStatus(paramErr) }
            let id = EventHotKeyID(signature: signature, id: UInt32(index + 1))
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id,
                                             GetApplicationEventTarget(), 0, &ref)
            guard status == noErr, let ref else { return status == noErr ? OSStatus(paramErr) : status }
            refs[action] = ref
        }
        return noErr
    }

    private func unregisterCurrent() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }

    deinit { unregisterCurrent() }
}

// MARK: - 앱

final class BrushApp: NSObject, NSApplicationDelegate {
    private var window: OverlayWindow!
    private var canvas: CanvasView!
    private var toolbar: Toolbar!
    private var statusItem: NSStatusItem!
    private var toggleMenuItem: NSMenuItem!
    private var undoMenuItem: NSMenuItem!
    private var clearMenuItem: NSMenuItem!
    private let settings = AppSettings()
    private var hotKeys: HotKeyManager!
    private var preferences: PreferencesController!
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
        window.acceptsMouseMovedEvents = true

        toolbar = Toolbar(canvas: canvas)
        toolbar.panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        toolbar.onSelectTool = { [weak self] in self?.selectTool($0) }
        toolbar.onUndo = { [weak self] in self?.canvas.undo() }
        canvas.onToolShortcut = { [weak self] in self?.selectTool($0) }
        canvas.onCancelToMouseMode = { [weak self] in self?.cancelToMouseMode() }
        canvas.onMagnificationChanged = { [weak self] value in
            self?.settings.magnification = value
            self?.preferences?.refreshAppearanceLabels()
        }

        preferences = PreferencesController(settings: settings)
        preferences.window?.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        preferences.window?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        preferences.onAppearanceChanged = { [weak self] in self?.applyAppearanceSettings() }
        preferences.onShortcutsChanged = { [weak self] candidate in self?.applyShortcutSettings(candidate) }
        applyAppearanceSettings()

        setUpStatusItem()
        refreshShortcutPresentation()
        hotKeys = HotKeyManager(shortcuts: settings.shortcuts)
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 1, &spec, nil, nil)
        let status = hotKeys.registerInitial()
        if status != noErr { warnHotKeyTaken(status) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        canvas?.stopTransientEffects()
        hotKeys?.unregisterAll()
    }

    private func screenUnderMouse() -> NSScreen {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "✏️"
        let menu = NSMenu()
        toggleMenuItem = menu.addItem(withTitle: "브러시 켜기 / 끄기", action: #selector(toggleFromMenu), keyEquivalent: "")
        toggleMenuItem.target = self
        undoMenuItem = menu.addItem(withTitle: "실행취소", action: #selector(undoFromMenu), keyEquivalent: "")
        undoMenuItem.target = self
        clearMenuItem = menu.addItem(withTitle: "전체 취소 후 마우스 모드", action: #selector(clearFromMenu), keyEquivalent: "")
        clearMenuItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "환경설정…", action: #selector(openPreferences), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func toggleFromMenu() { toggle() }
    @objc private func clearFromMenu() { cancelToMouseMode() }
    @objc private func undoFromMenu() { canvas.undo() }
    @objc private func openPreferences() { preferences.present() }

    private func applyAppearanceSettings() {
        canvas.laserSize = settings.laserSize
        canvas.laserColor = settings.laserColor
        canvas.arrowPointerSize = settings.arrowPointerSize
        canvas.arrowPointerColor = settings.arrowPointerColor
        canvas.setMagnification(settings.magnification)
        canvas.needsDisplay = true
    }

    private func applyShortcutSettings(_ candidate: [ShortcutAction: Shortcut]) -> String? {
        let status = hotKeys.apply(candidate)
        guard status == noErr else { return "이 단축키는 다른 앱이 사용 중입니다. 기존 설정을 유지했습니다. (err \(status))" }
        settings.persist(shortcuts: candidate)
        refreshShortcutPresentation()
        return nil
    }

    private func refreshShortcutPresentation() {
        func key(_ action: ShortcutAction) -> String { settings.shortcuts[action]?.displayName ?? "—" }
        func localAndGlobal(_ local: String, _ action: ShortcutAction) -> String {
            let global = key(action)
            return local == global ? local : "\(local) / \(global)"
        }
        toggleMenuItem?.title = "브러시 켜기 / 끄기  (\(key(.toggle)))"
        undoMenuItem?.title = "실행취소  (\(localAndGlobal("⌘Z", .undo)))"
        clearMenuItem?.title = "전체 취소 후 마우스 모드  (\(localAndGlobal("Esc", .clear)))"
        toolbar?.updateShortcutTips(settings.shortcuts)
    }

    // 도구 전환의 단일 통로 — 툴바 클릭 / 캔버스 글자 단축키 / 전역 ⌥숫자 단축키가 모두 여기로 온다
    func selectTool(_ tool: Tool) {
        canvas.commitText()  // 입력 중이던 텍스트를 도구 바꾸며 잃지 않게
        canvas.tool = tool
        canvas.activateTransientEffects(for: tool)
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

    private func cancelToMouseMode() {
        canvas.cancelAll()
        selectTool(.click)
    }

    func toggle() {
        isOn ? turnOff() : turnOn()
    }

    private func turnOn() {
        let screen = screenUnderMouse()
        let frame = screen.frame
        window.setFrame(frame, display: false)
        canvas.frame = NSRect(origin: .zero, size: frame.size)
        // 캔버스/캡처는 전체 화면을 유지하되 툴바만 메뉴 막대와 Dock을 제외한 영역에 둔다.
        toolbar.reposition(near: screen.visibleFrame)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.makeFirstResponder(canvas)
        canvas.applyClickThrough()
        toolbar.panel.orderFrontRegardless()
        canvas.activateTransientEffects(for: canvas.tool)
        let status = hotKeys.setSessionActive(true)
        if status != noErr { warnHotKeyTaken(status) }
        isOn = true
        statusItem.button?.title = "🖍️"
    }

    private func turnOff() {
        canvas.clear()
        canvas.resetHistory()  // 지워진 그림이 다음에 켤 때 ⌘Z로 되살아나면 곤란하다
        canvas.stopTransientEffects()
        _ = hotKeys.setSessionActive(false)
        window.orderOut(nil)
        toolbar.panel.orderOut(nil)
        isOn = false
        statusItem.button?.title = "✏️"
    }

    func handleHotKey(id: UInt32) {
        guard let action = hotKeys.action(for: id) else { return }
        if action == .toggle { toggle(); return }
        guard isOn else { return }
        if action == .undo { canvas.undo(); return }
        if action == .clear { cancelToMouseMode(); return }
        if let tool = action.tool { selectTool(tool) }
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
    check(v.shapes.isEmpty, "clear() 전체 지우기")
    v.undo()
    check(v.shapes.count == 3, "clear()로 지운 것도 ⌘Z로 복구")

    v.tool = .text
    v.beginText(at: NSPoint(x: 10, y: 40))
    v.editor?.stringValue = "취소될 글자"
    v.commitText()
    check(v.shapes.count == 4, "텍스트 확정")
    v.undo()
    check(v.shapes.count == 3, "확정된 텍스트도 ⌘Z로 되돌림")

    v.resetHistory()
    check(!v.canUndo && !v.canRedo, "브러시를 끄면 이력이 비워짐")

    v.tool = .pen
    v.begin(at: NSPoint(x: 20, y: 20)); v.extend(to: NSPoint(x: 180, y: 180)); v.end()
    v.cancelAll()
    check(v.shapes.isEmpty && !v.canUndo && !v.canRedo,
          "ESC 전체 취소는 그림과 실행취소 이력을 함께 비움")

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

    // MARK: 툴바 순서 / 단일 열 / 작은 화면 배치
    let toolbarCanvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let testToolbar = Toolbar(canvas: toolbarCanvas)
    testToolbar.panel.contentView?.layoutSubtreeIfNeeded()
    let expectedToolOrder: [Tool] = [.click, .pen, .arrow, .rect, .text, .eraser,
                                     .laser, .arrowPointer, .circleMagnifier, .rectangleMagnifier]
    check(testToolbar.displayedToolOrder == expectedToolOrder && testToolbar.toolButtonTagsAreValid,
          "클릭 통과가 첫 항목이고 10개 도구 버튼 tag/순서가 일치")
    check(testToolbar.isSingleColumnLayout, "도구·실행취소·색상·굵기 16개 컨트롤이 모두 단일 세로 열")
    check(testToolbar.panel.frame.height <= 584,
          "툴바 실제 높이가 600pt 화면의 상하 8pt 여백 안에 들어감 (\(Int(testToolbar.panel.frame.height))pt)")
    // 720pt 전체 화면에서 메뉴 막대/큰 Dock이 120pt를 차지한 상황을 본뜬 visibleFrame.
    let compactVisibleFrame = NSRect(x: -740, y: -120, width: 740, height: 600)
    testToolbar.reposition(near: compactVisibleFrame)
    check(testToolbar.panel.frame.minX >= compactVisibleFrame.minX + 8 &&
          testToolbar.panel.frame.maxX <= compactVisibleFrame.maxX - 8 &&
          testToolbar.panel.frame.minY >= compactVisibleFrame.minY + 8 &&
          testToolbar.panel.frame.maxY <= compactVisibleFrame.maxY - 8,
          "메뉴 막대/큰 Dock을 제외한 음수 원점 visibleFrame 안에 툴바 전체 배치")
    testToolbar.updateShortcutTips(ShortcutAction.defaults)
    check(testToolbar.toolTip(for: .click)?.contains("⌥1") == true &&
          testToolbar.toolTip(for: .pen)?.contains("⌥2") == true,
          "툴바 툴팁이 새 기본 번호 순서를 표시")

    // MARK: 임시 포인터 / 확대 — 도형 및 실행취소 이력과 분리
    for transientTool in [Tool.laser, .arrowPointer, .circleMagnifier, .rectangleMagnifier] {
        v.tool = transientTool
        v.begin(at: NSPoint(x: 30, y: 30))
        v.extend(to: NSPoint(x: 120, y: 120))
        v.end()
    }
    check(v.shapes.isEmpty && !v.canUndo, "포인터·확대 도구는 Shape/실행취소 이력에 남지 않음")

    v.setMagnification(1)
    check(v.magnification == 1.25, "확대 배율 하한은 1.25×")
    v.setMagnification(3.12)
    check(v.magnification == 3, "확대 배율은 0.25× 단위로 정규화")
    v.setMagnification(99)
    check(v.magnification == 8, "확대 배율 상한은 8×")
    v.tool = .circleMagnifier
    v.setMagnification(2)
    v.applyMagnificationScroll(delta: 7, precise: true)
    check(v.magnification == 2, "트랙패드의 작은 연속 스크롤은 임계값까지 누적")
    v.applyMagnificationScroll(delta: 1, precise: true)
    check(v.magnification == 2.25, "트랙패드 스크롤 누적 후 0.25× 변경")
    v.applyMagnificationScroll(delta: -1, precise: false)
    check(v.magnification == 2, "마우스 휠은 한 단계씩 계속 배율 변경")
    check(magnificationLabel(1.25) == "1.25×" && magnificationLabel(2) == "2×",
          "확대 배율 라벨이 값을 줄이지 않고 표시")
    v.activateTransientEffects(for: .laser)
    v.stopTransientEffects()
    v.stopTransientEffects()
    check(v.shapes.isEmpty, "임시 효과 정리를 반복 호출해도 안전함")

    // MARK: 확대 드래그 선택 / 고정 상태
    v.tool = .circleMagnifier
    v.activateTransientEffects(for: .circleMagnifier)
    v.updateTransientPoint(NSPoint(x: 100, y: 100))
    check(v.magnifierInteraction == .follow && v.currentMagnifierLensRect() != nil && v.hidesSystemCursorForCurrentTool,
          "확대 도구는 포인터 추적 모드로 시작")
    v.beginMagnifierSelection(at: NSPoint(x: 30, y: 40))
    v.updateMagnifierSelection(to: NSPoint(x: 150, y: 100))
    var circlePreview: NSRect?
    if case .selecting(let rect) = v.magnifierInteraction { circlePreview = rect }
    check(circlePreview?.width == 120 && circlePreview?.height == 120 && !v.hidesSystemCursorForCurrentTool,
          "원형 확대 드래그 미리보기는 정사각형 경계 유지")
    v.endMagnifierSelection(at: NSPoint(x: 150, y: 100))
    var lockedCircle: NSRect?
    if case .locked(let rect) = v.magnifierInteraction { lockedCircle = rect }
    check(lockedCircle == circlePreview && !v.hidesSystemCursorForCurrentTool,
          "마우스를 놓으면 미리보기와 같은 위치/크기로 고정하고 커서를 표시")
    v.updateTransientPoint(NSPoint(x: 190, y: 190))
    check(v.currentMagnifierLensRect() == lockedCircle, "고정 확대는 마우스 이동에 흔들리지 않음")
    v.setMagnification(2)
    v.applyMagnificationScroll(delta: 1, precise: false)
    check(v.magnification == 2.25 && v.currentMagnifierLensRect() == lockedCircle,
          "고정 확대에서도 휠 배율 변경 후 렌즈 위치/크기 유지")
    v.beginMagnifierSelection(at: NSPoint(x: 70, y: 70))
    v.endMagnifierSelection(at: NSPoint(x: 74, y: 73))
    check(v.magnifierInteraction == .follow && v.hidesSystemCursorForCurrentTool,
          "짧은 클릭은 고정을 풀고 커서를 숨긴 포인터 추적으로 복귀")

    v.tool = .rectangleMagnifier
    v.activateTransientEffects(for: .rectangleMagnifier)
    v.beginMagnifierSelection(at: NSPoint(x: 20, y: 30))
    v.updateMagnifierSelection(to: NSPoint(x: 170, y: 150))
    v.endMagnifierSelection(at: NSPoint(x: 170, y: 150))
    var lockedRectangle: NSRect?
    if case .locked(let rect) = v.magnifierInteraction { lockedRectangle = rect }
    check(lockedRectangle?.width == 150 && lockedRectangle?.height == 120,
          "사각형 확대는 선택한 종횡비와 크기를 보존")
    check(v.cancelMagnifierLock() && v.magnifierInteraction == .follow,
          "ESC/취소 경로가 고정 확대를 포인터 추적으로 정리")
    v.beginMagnifierSelection(at: NSPoint(x: 20, y: 20))
    v.updateMagnifierSelection(to: NSPoint(x: 180, y: 180))
    v.endMagnifierSelection(at: NSPoint(x: 180, y: 180))
    v.stopTransientEffects()
    check(v.magnifierInteraction == .follow && v.shapes.isEmpty && !v.canUndo,
          "브러시 종료 정리는 확대 고정만 해제하고 Shape/이력은 건드리지 않음")

    // MARK: 확대 좌표 — 화면 원점이 음수인 보조 모니터와 가장자리 보정
    let displayBounds = NSRect(x: -1920, y: -180, width: 1920, height: 1080)
    let leftEdge = MagnifierGeometry.sourceRect(center: NSPoint(x: -1920, y: 0),
                                                 sourceSize: NSSize(width: 100, height: 100),
                                                 inside: displayBounds)
    let rightEdge = MagnifierGeometry.sourceRect(center: NSPoint(x: 0, y: 900),
                                                  sourceSize: NSSize(width: 100, height: 100),
                                                  inside: displayBounds)
    check(leftEdge.minX == displayBounds.minX && leftEdge.minY >= displayBounds.minY,
          "음수 원점 디스플레이의 왼쪽 확대 영역 보정")
    check(rightEdge.maxX == displayBounds.maxX && rightEdge.maxY == displayBounds.maxY,
          "디스플레이 오른쪽/위쪽 확대 영역 보정")
    let lensAtCorner = MagnifierGeometry.destinationRect(center: .zero,
                                                          size: NSSize(width: 220, height: 220),
                                                          inside: NSRect(x: 6, y: 6, width: 188, height: 188))
    check(lensAtCorner.minX == 6 && lensAtCorner.minY == 6 && lensAtCorner.maxX <= 194,
          "화면 모서리에서도 확대 렌즈 전체가 보이도록 위치/크기 보정")
    let negativeCircle = MagnifierGeometry.selectionRect(from: NSPoint(x: -5, y: 850),
                                                          to: NSPoint(x: -800, y: 100), circular: true,
                                                          inside: displayBounds)
    check(negativeCircle.width == negativeCircle.height && displayBounds.contains(negativeCircle),
          "음수 원점 화면에서도 원형 선택 크기/위치를 경계 안으로 보정")
    let minimumRectangle = MagnifierGeometry.selectionRect(from: NSPoint(x: -1000, y: 300),
                                                            to: NSPoint(x: -991, y: 300), circular: false,
                                                            inside: displayBounds)
    check(minimumRectangle.width == 96 && minimumRectangle.height == 96,
          "임계값을 넘긴 작은 선택은 사용 가능한 최소 96×96으로 보정")

    // MARK: 설정 검증 / 영속성
    let suite = "BrushSelfTest.\(UUID().uuidString)"
    let testDefaults = UserDefaults(suiteName: suite)!
    defer { testDefaults.removePersistentDomain(forName: suite) }
    let testSettings = AppSettings(defaults: testDefaults)
    let expectedDefaultKeys: [ShortcutAction: String] = [
        .click: "⌥1", .pen: "⌥2", .arrow: "⌥3", .rect: "⌥4", .text: "⌥5", .eraser: "⌥6",
        .laser: "⌥7", .arrowPointer: "⌥8", .circleMagnifier: "⌥9", .rectangleMagnifier: "⌥0",
    ]
    check(expectedDefaultKeys.allSatisfy { testSettings.shortcuts[$0.key]?.displayName == $0.value } &&
          testSettings.magnification == 2,
          "새 설정은 클릭 ⌥1, 그리기 ⌥2~6, 프레젠테이션 ⌥7~0 기본값으로 시작")
    check(Array(ShortcutAction.allCases.prefix(7)) == [.toggle, .click, .pen, .arrow, .rect, .text, .eraser],
          "환경설정 단축키 목록이 실제 번호 순서로 표시")

    // 이름 기반 저장키는 바꾸지 않는다. 구 버전 기본값이 이미 저장된 사용자도 자동 변경하지 않는다.
    var legacyStoredShortcuts = testSettings.shortcuts
    legacyStoredShortcuts[.pen] = Shortcut(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(optionKey))
    legacyStoredShortcuts[.arrow] = Shortcut(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(optionKey))
    legacyStoredShortcuts[.rect] = Shortcut(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(optionKey))
    legacyStoredShortcuts[.text] = Shortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(optionKey))
    legacyStoredShortcuts[.eraser] = Shortcut(keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(optionKey))
    legacyStoredShortcuts[.click] = Shortcut(keyCode: UInt32(kVK_ANSI_6), modifiers: UInt32(optionKey))
    testSettings.persist(shortcuts: legacyStoredShortcuts)
    let legacyReloaded = AppSettings(defaults: testDefaults)
    check(legacyReloaded.shortcuts[.pen]?.displayName == "⌥1" && legacyReloaded.shortcuts[.click]?.displayName == "⌥6",
          "기존 사용자가 저장한 구 번호 단축키는 이름 기반 키로 그대로 보존")
    testSettings.laserSize = 200
    testSettings.arrowPointerSize = 2
    testSettings.magnification = 4.63
    testSettings.laserColor = NSColor(srgbRed: 0.1, green: 0.3, blue: 0.7, alpha: 1)
    var changedShortcuts = legacyReloaded.shortcuts
    changedShortcuts[.laser] = Shortcut(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(controlKey | optionKey))
    testSettings.persist(shortcuts: changedShortcuts)
    let reloaded = AppSettings(defaults: testDefaults)
    let storedColor = reloaded.laserColor.usingColorSpace(.sRGB)
    check(reloaded.laserSize == 80 && reloaded.arrowPointerSize == 24 && reloaded.magnification == 4.75,
          "크기·배율 설정이 범위/단위에 맞게 저장됨")
    check(reloaded.shortcuts[.laser] == changedShortcuts[.laser], "변경한 단축키가 재시작 후 복원됨")
    check(abs((storedColor?.blueComponent ?? 0) - 0.7) < 0.01, "레이저 색상이 재시작 후 복원됨")
    var duplicateShortcuts = reloaded.shortcuts
    duplicateShortcuts[.laser] = duplicateShortcuts[.pen]
    check(AppSettings.duplicateAction(in: duplicateShortcuts) != nil, "중복 단축키를 저장 전에 검출")
    testDefaults.set(999, forKey: "brush.settings.shortcut.laser.code")
    testDefaults.set(0, forKey: "brush.settings.shortcut.laser.modifiers")
    testDefaults.set(Double.nan, forKey: "brush.settings.laserSize")
    testDefaults.set(Double.nan, forKey: "brush.settings.magnification")
    testDefaults.set([Double.nan, 0.0, 0.0, 1.0], forKey: "brush.settings.laserColor")
    let sanitized = AppSettings(defaults: testDefaults)
    check(sanitized.shortcuts[.laser] == ShortcutAction.defaults[.laser] && sanitized.laserSize == 24 && sanitized.magnification == 2,
          "손상된 단축키/숫자 설정은 안전한 기본값으로 복구")
    check(sanitized.laserColor.usingColorSpace(.sRGB)?.redComponent ?? 0 > 0.9,
          "손상된 색상 설정은 기본 레이저 색으로 복구")
    testDefaults.set(-1, forKey: "brush.settings.shortcut.arrowPointer.code")
    testDefaults.set(-1, forKey: "brush.settings.shortcut.arrowPointer.modifiers")
    let negativeSanitized = AppSettings(defaults: testDefaults)
    check(negativeSanitized.shortcuts[.arrowPointer] == ShortcutAction.defaults[.arrowPointer],
          "음수 단축키 저장값은 변환 중단 없이 기본값으로 복구")

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
