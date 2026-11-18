// Purrminal: a chonky pixel cat on the desktop that mirrors what your coding agent is doing.
// State comes from one file per agent session in ~/.purrminal/sessions (line 1: idle|working|waiting|done|error,
// line 2: caption, line 3: session label), written by Claude Code hooks via purrminal-hook.sh, plus ~/.purrminal/state.
// Click the cat to pet it, drag to move (the spot is remembered), right-click or the menu bar paw for
// Hide Cat, Settings (settings.swift) and Quit.
//
// Build: ./build.sh   (Purrminal.app + dist/Purrminal.zip; dev binary: swiftc -O main.swift settings.swift -o Purrminal)
// Run:   ./Purrminal
//        ./Purrminal --sheet out.png   (every state as a sprite sheet)
//        ./Purrminal --gif out.gif     (looping demo of every state)

import AppKit
import ImageIO
import UniformTypeIdentifiers

enum PetState: String, CaseIterable { case idle, working, waiting, done, error }

let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()  // same $HOME the hook writes under
let sessionsDir = home + "/.purrminal/sessions"
let manualStateFile = home + "/.purrminal/state"  // for scripts and other agents: one shared file

extension PetState {
    // What the cat shows when sessions disagree: a request for the user beats everything,
    // an error stays visible for its few seconds even while other agents keep working.
    var priority: Int { [.idle: 0, .done: 1, .working: 2, .error: 3, .waiting: 4][self]! }
}

struct AgentStatus { let state: PetState; let caption: String; let label: String; let age: TimeInterval; var isSubagent = false }

// One file per agent (written by purrminal-hook.sh) plus the manual file. Stale entries are dropped:
// "done" celebrates for 6s, "error" shows for 8s and then counts as still working,
// "working"/"waiting" with no hook event for 5 minutes means the agent died without Stop or SessionEnd.
func readStatuses() -> [AgentStatus] {
    let fm = FileManager.default
    let files = ((try? fm.contentsOfDirectory(atPath: sessionsDir)) ?? [])
        .filter { !$0.hasSuffix(".tmp") }.map { sessionsDir + "/" + $0 } + [manualStateFile]
    let now = Date()
    return files.compactMap { path in
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard let state = PetState(rawValue: lines[0].trimmingCharacters(in: .whitespaces)) else { return nil }
        let age = now.timeIntervalSince(modified)
        if age > 3600 && path != manualStateFile { try? fm.removeItem(atPath: path); return nil }
        switch state {
        case .done where age > 6, .idle: return nil
        case .working where age > 300, .waiting where age > 300: return nil
        default: break
        }
        // Session ids are 36-char UUIDs; a subagent's file adds "-<agent_id>".
        let isSubagent = path != manualStateFile && (path as NSString).lastPathComponent.count > 36
        let label = lines.count > 2 ? lines[2] : ""
        if state == .error && age > 8 { return AgentStatus(state: .working, caption: "", label: label, age: age, isSubagent: isSubagent) }
        // MCP tools arrive as mcp__<server>__<tool>; the bubble only has room for the tool.
        let caption = (lines.count > 1 ? lines[1] : "")
            .replacingOccurrences(of: #"mcp__\S*?__"#, with: "", options: .regularExpression)
        return AgentStatus(state: state, caption: caption, label: label, age: age, isSubagent: isSubagent)
    }
}

// The highest-priority state wins; the most recent agent in that state gives the caption.
// With several agents the caption says which session needs you, or how many agents are busy.
func readState() -> (PetState, String) {
    let all = readStatuses()
    guard let top = all.max(by: { ($0.state.priority, -$0.age) < ($1.state.priority, -$1.age) }) else { return (.idle, "") }
    let label = top.label.count > 10 ? String(top.label.prefix(9)) + "…" : top.label
    switch top.state {
    case .waiting, .error:
        let busy = all.filter { $0.state.priority >= PetState.working.priority }.count
        return (top.state, busy > 1 && !label.isEmpty ? "\(label): \(top.caption)" : top.caption)
    case .working:
        let n = all.filter { $0.state == .working }.count
        return (.working, n > 1 ? "\(n) agents · \(top.caption)" : top.caption)
    default:
        return (top.state, top.caption)
    }
}

// MARK: - Palette and canvas (the speech bubble is drawn on a coarse pixel grid)

let gridW = 48, gridH = 52, scale: CGFloat = 4
let cellSize = CGSize(width: CGFloat(gridW) * scale, height: CGFloat(gridH) * scale)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

let outlineC = rgb(0x1f2340)

struct Canvas {
    let ctx: CGContext
    let origin: CGPoint

    func px(_ x: Int, _ y: Int, _ color: CGColor) {
        guard x >= 0, x < gridW, y >= 0, y < gridH else { return }
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: origin.x + CGFloat(x) * scale, y: origin.y + CGFloat(gridH - 1 - y) * scale,
                        width: scale, height: scale))
    }

    // Fills every cell where `inside` holds; cells on the shape's border get the outline color,
    // so overlapping parts (body, ears, tail, paws) share one clean silhouette.
    func shape(_ inside: (Int, Int) -> Bool, outline: CGColor?, fill: (Int, Int) -> CGColor) {
        for y in 0..<gridH {
            for x in 0..<gridW where inside(x, y) {
                let edge = !inside(x - 1, y) || !inside(x + 1, y) || !inside(x, y - 1) || !inside(x, y + 1)
                px(x, y, edge ? (outline ?? fill(x, y)) : fill(x, y))
            }
        }
    }
}

// Speech bubble pinned to the top of the canvas with a tail pointing at the cat's head.
func drawBubble(_ cv: Canvas, _ text: String, fill: CGColor, ink: NSColor, tipX: Int) {
    // Long captions ("Reddit ma…: WebFetch failed") shrink the font so the bubble stays inside the canvas.
    func styled(_ pt: CGFloat) -> NSAttributedString {
        let base = NSFont.systemFont(ofSize: pt, weight: .heavy)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: pt) } ?? base
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: ink])
    }
    let maxW = CGFloat(gridW - 5) * scale
    let full = styled(13).size().width
    let label = full > maxW ? styled(max(9, 13 * maxW / full)) : styled(13)
    let size = label.size()
    let w = min(gridW, Int((size.width / scale).rounded(.up)) + 5)
    let x0 = max(0, min(gridW - w, tipX - w / 2)), x1 = x0 + w - 1, y0 = 2, y1 = 10
    cv.shape({ x, y in
        if y == y1 + 1 { return abs(x - tipX) <= 1 }
        if y == y1 + 2 { return x == tipX }
        guard x >= x0, x <= x1, y >= y0, y <= y1 else { return false }
        return min(x - x0, x1 - x) + min(y - y0, y1 - y) >= 1
    }, outline: outlineC) { _, _ in fill }
    let left = cv.origin.x + (CGFloat(x0) + CGFloat(w) / 2) * scale - size.width / 2
    let bottom = cv.origin.y + CGFloat(gridH - 1 - y1) * scale
    label.draw(at: CGPoint(x: left, y: bottom + (CGFloat(y1 - y0 + 1) * scale - size.height) / 2))
}

// MARK: - The cat

// One painted pose per state and skin (sprites/<skin>/<pose>.png, sliced from drafts/ by slice.py),
// animated with squash, hops and shakes.
let spriteDir = Bundle.main.resourceURL!.appendingPathComponent("sprites")  // Contents/Resources in the .app, the binary's folder in dev
var spriteCache: [String: CGImage] = [:]
func sprite(_ skin: Skin, _ pose: String) -> CGImage {
    let key = skin.rawValue + "/" + pose
    if let img = spriteCache[key] { return img }
    let url = spriteDir.appendingPathComponent(key + ".png")
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else { fatalError("missing sprite \(url.path); run python3 slice.py") }
    spriteCache[key] = img
    return img
}
let spriteH: CGFloat = 150

func drawPet(_ ctx: CGContext, at origin: CGPoint, state: PetState, frame f: Int, caption: String, petted: Int? = nil,
             bubbles: BubbleMode = .all, skin: Skin = .fluffy, flip: Bool = false) {
    let cv = Canvas(ctx: ctx, origin: origin)
    let t = Double(f)
    var lift = 0.0, squash = 0.0, shake = 0.0
    var name = state.rawValue

    switch state {
    case .idle:
        squash = 0.025 * sin(t * 0.3)
    case .working:
        lift = f % 4 < 2 ? 1.5 : 0; squash = f % 4 < 2 ? -0.015 : 0.015
    case .waiting:
        let hop = [0, 0, 3, 8, 11, 12, 11, 8, 3, 0, 0, 0][f % 12]
        lift = Double(hop); squash = hop == 0 && f % 12 >= 9 ? 0.08 : (hop >= 8 ? -0.05 : 0)
    case .done:
        let jump = [0, 6, 12, 16, 18, 18, 16, 12, 6, 0, 0, 0][f % 12]
        lift = Double(jump); squash = jump == 0 && f % 12 >= 9 ? 0.1 : (jump > 10 ? -0.06 : 0)
    case .error:
        shake = sin(t * 2.6) * 1.2; squash = 0.02 + 0.02 * sin(t * 1.3)
    }
    if let p = petted {
        name = "petted"; lift = 0; shake = 0
        squash = 0.09 * sin(Double(p) * 0.9) * max(0, 1 - Double(p) / 18)
    }

    let img = sprite(skin, name)
    let h = spriteH, w = h * CGFloat(img.width) / CGFloat(img.height)
    let footX = origin.x + cellSize.width / 2, footY = origin.y + 4

    // Ground shadow shrinks while the cat is in the air.
    let sw = (w * 0.6) * CGFloat(max(0.4, 1 - lift / 30))
    ctx.setFillColor(rgb(0x000000, 0.13))
    ctx.fillEllipse(in: CGRect(x: footX - sw / 2, y: footY - 3, width: sw, height: 7))

    ctx.saveGState()
    ctx.translateBy(x: footX + CGFloat(shake), y: footY + CGFloat(lift))
    ctx.scaleBy(x: CGFloat(1 + squash), y: CGFloat(1 - squash))
    if flip { ctx.scaleBy(x: -1, y: 1) }
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: -w / 2, y: 0, width: w, height: h))
    ctx.restoreGState()

    let darkInk = NSColor(cgColor: outlineC)!
    if petted != nil {
        drawBubble(cv, "purr~", fill: rgb(0xffe1ec), ink: darkInk, tipX: gridW / 2)
        return
    }
    if bubbles == .off || (bubbles == .alerts && state != .waiting && state != .error) { return }
    switch state {
    case .idle:
        break
    case .working:
        let dots = String(repeating: ".", count: (f / 3) % 4)
        drawBubble(cv, (caption.isEmpty ? "thinking" : caption) + dots, fill: rgb(0xffffff), ink: darkInk, tipX: gridW / 2)
    case .waiting:
        drawBubble(cv, caption.isEmpty ? "need you!" : caption, fill: rgb(0xff9f43), ink: .white, tipX: gridW / 2)
    case .done:
        drawBubble(cv, caption.isEmpty ? "all done!" : caption, fill: rgb(0xffffff), ink: darkInk, tipX: gridW / 2)
    case .error:
        drawBubble(cv, caption.isEmpty ? "oops..." : caption, fill: rgb(0xff6b6b), ink: .white, tipX: gridW / 2)
    }
}

// MARK: - Offscreen rendering (sprite sheet, GIF)

let demo: [(state: PetState, caption: String, petted: Bool)] = [
    (.idle, "", false), (.working, "Bash", false), (.waiting, "", false),
    (.done, "", false), (.error, "tests failed", false), (.idle, "", true),
]

func bitmap(_ size: CGSize, zoom: CGFloat, _ body: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * zoom), pixelsHigh: Int(size.height * zoom),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = g
    g.cgContext.scaleBy(x: zoom, y: zoom)
    g.cgContext.setFillColor(rgb(0xfff7ee))
    g.cgContext.fill(CGRect(origin: .zero, size: size))
    body(g.cgContext)
    NSGraphicsContext.current = nil
    return rep
}

func renderSheet(to path: String) {
    let cols = 8
    let size = CGSize(width: cellSize.width * CGFloat(cols), height: cellSize.height * CGFloat(demo.count))
    let rep = bitmap(size, zoom: 1) { ctx in
        for (row, item) in demo.enumerated() {
            for col in 0..<cols {
                let origin = CGPoint(x: CGFloat(col) * cellSize.width, y: CGFloat(demo.count - 1 - row) * cellSize.height)
                drawPet(ctx, at: origin, state: item.state, frame: col * 3, caption: item.caption,
                        petted: item.petted ? col * 3 : nil)
            }
        }
    }
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

func renderGIF(to path: String) {
    let perState = 36
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.gif.identifier as CFString,
                                               demo.count * perState, nil)!
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    let delay = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / 12]] as CFDictionary
    for item in demo {
        for f in 0..<perState {
            let rep = bitmap(cellSize, zoom: 2) { ctx in
                drawPet(ctx, at: .zero, state: item.state, frame: f, caption: item.caption, petted: item.petted ? f % 24 : nil)
            }
            CGImageDestinationAddImage(dest, rep.cgImage!, delay)
        }
    }
    CGImageDestinationFinalize(dest)
}

// MARK: - Floating window

final class PetView: NSView {
    var frameIndex = 0, ticks = 0, phase = 0.0
    var state = PetState.idle
    var caption = ""
    var pettedAt: Int?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let petted = pettedAt.map { frameIndex - $0 }.flatMap { $0 < 24 ? $0 : nil }
        let prefs = Preferences.shared, s = CGFloat(prefs.size)
        ctx.scaleBy(x: s, y: s)
        drawPet(ctx, at: .zero, state: state, frame: frameIndex, caption: caption, petted: petted,
                bubbles: prefs.bubbles, skin: prefs.skin, flip: prefs.flip)
    }

    // A click pets the cat; holding and dragging moves it.
    override func mouseDown(with event: NSEvent) {
        pettedAt = frameIndex
        window?.performDrag(with: event)
    }

    func tick() {
        ticks += 1
        phase += Preferences.shared.speed.rate
        frameIndex = Int(phase)
        if ticks % 4 == 0 { (state, caption) = readState() }
        needsDisplay = true
    }
}

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--sheet"), i + 1 < args.count { renderSheet(to: args[i + 1]); exit(0) }
if let i = args.firstIndex(of: "--gif"), i + 1 < args.count { renderGIF(to: args[i + 1]); exit(0) }
if args.contains("--status") { let (s, c) = readState(); print("\(s.rawValue)\t\(c)"); exit(0) }  // what the cat would show now

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let panel = NSPanel(contentRect: NSRect(origin: .zero, size: cellSize),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
panel.isOpaque = false
panel.backgroundColor = .clear
panel.hasShadow = false

let view = PetView(frame: NSRect(origin: .zero, size: cellSize))
panel.contentView = view

// Applies window settings; a size change scales the panel around the cat's feet.
func applyPrefs() {
    let prefs = Preferences.shared, s = CGFloat(prefs.size)
    let size = CGSize(width: cellSize.width * s, height: cellSize.height * s), old = panel.frame
    if old.size != size {
        panel.setFrame(NSRect(x: old.midX - size.width / 2, y: old.minY, width: size.width, height: size.height), display: true)
        view.frame = NSRect(origin: .zero, size: size)
    }
    panel.alphaValue = CGFloat(prefs.opacity)
    panel.level = prefs.onTop ? .floating : .normal
    panel.collectionBehavior = prefs.allSpaces ? [.canJoinAllSpaces, .stationary] : [.managed]
    statusItem.isVisible = prefs.menuBarIcon
    view.needsDisplay = true
}

// Bottom-right corner of the screen the cat is on.
func resetPosition() {
    let visible = (panel.screen ?? NSScreen.main!).visibleFrame, size = panel.frame.size
    panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 24, y: visible.minY + 8))
}

// The cat comes back where it was dragged, unless that spot is off every connected screen.
func restorePosition() {
    let d = UserDefaults.standard
    if let x = d.object(forKey: "petX") as? Double, let y = d.object(forKey: "petY") as? Double {
        let spot = NSRect(origin: NSPoint(x: x, y: y), size: panel.frame.size)
        if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(spot) }) { panel.setFrameOrigin(spot.origin); return }
    }
    resetPosition()
}

// Hiding is for calls and screen sharing; it lasts until shown again or the app restarts.
var catHidden = false
func setCatHidden(_ hidden: Bool) {
    catHidden = hidden
    if hidden { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    statusMenu.item(at: 0)?.title = hidden ? "Show Cat" : "Hide Cat"
}

final class MenuActions: NSObject, NSApplicationDelegate {
    @objc func openSettings() { SettingsWindow.show() }
    @objc func toggleCat() { setCatHidden(!catHidden) }
    // Opening the app again (Finder, Spotlight, `open`) brings the cat and its settings back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        setCatHidden(false)
        SettingsWindow.show()
        return false
    }
}
let menuActions = MenuActions()
app.delegate = menuActions

func makeMenu(hideTitle: String) -> NSMenu {
    let menu = NSMenu()
    menu.addItem(withTitle: hideTitle, action: #selector(MenuActions.toggleCat), keyEquivalent: "").target = menuActions
    menu.addItem(withTitle: "Settings…", action: #selector(MenuActions.openSettings), keyEquivalent: ",").target = menuActions
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit Purrminal", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    return menu
}
let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
statusItem.button?.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Purrminal")
let statusMenu = makeMenu(hideTitle: "Hide Cat")
statusItem.menu = statusMenu
view.menu = makeMenu(hideTitle: "Hide Cat")

Preferences.shared.onChange = applyPrefs
Preferences.shared.onResetPosition = resetPosition
applyPrefs()
restorePosition()
NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { _ in
    UserDefaults.standard.set(Double(panel.frame.minX), forKey: "petX")
    UserDefaults.standard.set(Double(panel.frame.minY), forKey: "petY")
}

panel.orderFrontRegardless()
// First launch from a downloaded zip: the cat can't see Claude Code until the hooks are in.
if !Preferences.shared.hooksInstalled { UserDefaults.standard.set(SettingsTab.agents.rawValue, forKey: "settingsTab") }
if args.contains("--settings") || !Preferences.shared.hooksInstalled { SettingsWindow.show() }

let timer = Timer(timeInterval: 1.0 / 12, repeats: true) { _ in view.tick() }
RunLoop.main.add(timer, forMode: .common)
app.run()
