// Settings window: SwiftUI with Liquid Glass on macOS 26+, frosted material on older systems.
// Preferences live in UserDefaults; main.swift reads Preferences.shared on every frame
// and re-applies window settings through onChange.

import SwiftUI
import ServiceManagement
import Combine

enum Skin: String, CaseIterable {
    case fluffy, ginger, midnight, calico
    var title: String { rawValue.capitalized }
}

enum BubbleMode: String, CaseIterable {
    case all, alerts, off
    var title: String { ["all": "Always", "alerts": "Only alerts", "off": "Off"][rawValue]! }
}

enum Speed: String, CaseIterable {
    case calm, normal, lively
    var title: String { rawValue.capitalized }
    var rate: Double { ["calm": 0.6, "normal": 1, "lively": 1.5][rawValue]! }  // animation frames per 1/12 s tick
}

final class Preferences: ObservableObject {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard
    var onChange: (() -> Void)?
    var onResetPosition: (() -> Void)?

    @Published var skin: Skin { didSet { save(skin.rawValue, "skin") } }
    @Published var size: Double { didSet { save(size, "size") } }          // 0.5…2, 1 = 192×208 pt
    @Published var opacity: Double { didSet { save(opacity, "opacity") } } // 0.3…1
    @Published var flip: Bool { didSet { save(flip, "flip") } }            // face left
    @Published var speed: Speed { didSet { save(speed.rawValue, "speed") } }
    @Published var bubbles: BubbleMode { didSet { save(bubbles.rawValue, "bubbles") } }
    @Published var onTop: Bool { didSet { save(onTop, "onTop") } }
    @Published var allSpaces: Bool { didSet { save(allSpaces, "allSpaces") } }
    @Published var menuBarIcon: Bool { didSet { save(menuBarIcon, "menuBarIcon") } }
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                DispatchQueue.main.async { self.launchAtLogin = !self.launchAtLogin }  // roll the toggle back
            }
        }
    }

    private init() {
        let d = defaults
        skin = Skin(rawValue: d.string(forKey: "skin") ?? "") ?? .fluffy
        size = d.object(forKey: "size") as? Double ?? 1
        opacity = d.object(forKey: "opacity") as? Double ?? 1
        flip = d.bool(forKey: "flip")
        speed = Speed(rawValue: d.string(forKey: "speed") ?? "") ?? .normal
        bubbles = BubbleMode(rawValue: d.string(forKey: "bubbles") ?? "") ?? .all
        onTop = d.object(forKey: "onTop") as? Bool ?? true
        allSpaces = d.object(forKey: "allSpaces") as? Bool ?? true
        menuBarIcon = d.object(forKey: "menuBarIcon") as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        onChange?()
    }

    func resetAppearance() {
        skin = .fluffy; size = 1; opacity = 1; flip = false; speed = .normal
    }

    var hooksInstalled: Bool {
        let settings = (try? String(contentsOfFile: home + "/.claude/settings.json", encoding: .utf8)) ?? ""
        return settings.contains(".purrminal/hook.sh")
    }
}

// The app carries install.sh and the hook in Resources, so a downloaded zip can wire up Claude Code itself.
enum Hooks {
    static let path = "/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin:/usr/local/bin"
    static var jqFound: Bool {
        path.split(separator: ":").contains { FileManager.default.isExecutableFile(atPath: "\($0)/jq") }
    }

    // Returns the script's output when it fails, nil on success.
    static func install() -> String? {
        guard let script = Bundle.main.url(forResource: "install", withExtension: "sh") else {
            return "install.sh is missing from the app bundle"
        }
        let process = Process(), out = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, "--hooks"]
        process.environment = ProcessInfo.processInfo.environment.merging(["PATH": path]) { $1 }
        process.standardOutput = out
        process.standardError = out
        do { try process.run() } catch { return error.localizedDescription }
        process.waitUntilExit()  // a few lines of output, well under the pipe buffer
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return process.terminationStatus == 0 ? nil : text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Glass helpers

extension View {
    @ViewBuilder func glassCard(_ radius: CGFloat = 18, tint: Color? = nil) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular.tint(tint), in: .rect(cornerRadius: radius))
        } else {
            self.background((tint ?? .clear).opacity(0.25), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.25)))
        }
    }

    @ViewBuilder func glassButton() -> some View {
        if #available(macOS 26, *) { self.buttonStyle(.glass) } else { self.buttonStyle(.bordered) }
    }
}

extension PetState {
    var tint: Color {
        switch self {
        case .working: return .blue
        case .waiting: return .orange
        case .error: return .red
        case .done: return .green
        case .idle: return .secondary
        }
    }
    var title: String {
        switch self {
        case .idle: return "Napping"
        case .working: return "Working"
        case .waiting: return "Needs you"
        case .done: return "All done"
        case .error: return "Something failed"
        }
    }
}

// MARK: - Views

enum SettingsTab: String, CaseIterable {
    case look = "Look", behavior = "Behavior", agents = "Agents"
    var icon: String { ["Look": "paintpalette.fill", "Behavior": "slider.horizontal.3", "Agents": "sparkles"][rawValue]! }
}

struct SettingsView: View {
    @ObservedObject var prefs = Preferences.shared
    @AppStorage("settingsTab") private var tab = SettingsTab.look  // reopens on the last tab
    @State private var tick = 0
    @State private var state: (PetState, String) = readState()
    @State private var agents: [AgentStatus] = readStatuses()
    @State private var hooks = Preferences.shared.hooksInstalled
    @State private var hookError: String?
    @Namespace private var tabNS
    private let timer = Timer.publish(every: 1.0 / 6, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 14) {
            header
            tabBar
            Group {
                switch tab {
                case .look: lookTab
                case .behavior: behaviorTab
                case .agents: agentsTab
                }
            }
            .transition(.opacity)
            footer
        }
        .padding(.horizontal, 18).padding(.top, 34).padding(.bottom, 18)
        .frame(width: 420)
        .background(backdrop)
        .animation(.spring(duration: 0.3), value: tab)
        .onReceive(timer) { _ in
            tick += 1
            if tick % 6 == 0 { state = readState(); agents = readStatuses(); hooks = prefs.hooksInstalled }
        }
    }

    // MARK: Header and tabs

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: catImage(state.0, frame: Int(Double(tick * 2) * prefs.speed.rate)))
                .interpolation(.high).resizable().scaledToFit()
                .frame(width: 64, height: 64)
                .padding(6)
                .glassCard(38)
            VStack(alignment: .leading, spacing: 4) {
                Text("Purrminal").font(.system(size: 22, weight: .bold, design: .rounded))
                HStack(spacing: 6) {
                    Circle().fill(state.0.tint).frame(width: 8, height: 8)
                    Text(state.1.isEmpty ? state.0.title : "\(state.0.title) · \(state.1)")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases, id: \.self) { t in
                Button { tab = t } label: {
                    Label(t.rawValue, systemImage: t.icon)
                        .font(.callout.weight(tab == t ? .semibold : .regular))
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .foregroundStyle(tab == t ? .primary : .secondary)
                        .background {
                            if tab == t {
                                Capsule().fill(.white.opacity(0.22))
                                    .matchedGeometryEffect(id: "tab", in: tabNS)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .glassCard(22)
    }

    // MARK: Look

    private var lookTab: some View {
        VStack(spacing: 14) {
            card("Cat", icon: "pawprint.fill") {
                HStack(spacing: 10) {
                    ForEach(Skin.allCases, id: \.self) { skinTile($0) }
                }
            }
            card("Appearance", icon: "wand.and.stars") {
                sliderRow("Size", value: $prefs.size, in: 0.5...2, step: 0.25)
                Divider().opacity(0.4)
                sliderRow("Opacity", value: $prefs.opacity, in: 0.3...1, step: 0.05)
                Divider().opacity(0.4)
                row("Face left") { Toggle("", isOn: $prefs.flip).toggleStyle(.switch).labelsHidden() }
                Divider().opacity(0.4)
                row("Animation") { segmented($prefs.speed, Speed.allCases, \.title) }
                Divider().opacity(0.4)
                row("Reset look") { Button("Reset") { prefs.resetAppearance() }.glassButton() }
            }
        }
    }

    private func skinTile(_ skin: Skin) -> some View {
        let selected = prefs.skin == skin
        return Button { prefs.skin = skin } label: {
            VStack(spacing: 6) {
                Image(decorative: sprite(skin, "waiting"), scale: 1)
                    .interpolation(.high).resizable().scaledToFit()
                    .scaleEffect(x: prefs.flip ? -1 : 1)
                    .frame(height: 58)
                    .scaleEffect(selected ? 1.06 : 1)
                Text(skin.title).font(.caption.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .padding(.vertical, 10).frame(maxWidth: .infinity)
            .glassCard(14, tint: selected ? .accentColor.opacity(0.35) : nil)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(selected ? 0.9 : 0), lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.25), value: selected)
    }

    // MARK: Behavior

    private var behaviorTab: some View {
        VStack(spacing: 14) {
            card("Speech bubbles", icon: "bubble.left.fill") {
                row("Show") { segmented($prefs.bubbles, BubbleMode.allCases, \.title) }
            }
            card("Desktop", icon: "macwindow") {
                row("Always on top") { Toggle("", isOn: $prefs.onTop).toggleStyle(.switch).labelsHidden() }
                Divider().opacity(0.4)
                row("Show on all Spaces") { Toggle("", isOn: $prefs.allSpaces).toggleStyle(.switch).labelsHidden() }
                Divider().opacity(0.4)
                row("Launch at login") { Toggle("", isOn: $prefs.launchAtLogin).toggleStyle(.switch).labelsHidden() }
                Divider().opacity(0.4)
                row("Menu bar icon") { Toggle("", isOn: $prefs.menuBarIcon).toggleStyle(.switch).labelsHidden() }
                Divider().opacity(0.4)
                row("Position") {
                    Button("Move to corner") { prefs.onResetPosition?() }.glassButton()
                }
            }
        }
    }

    // MARK: Agents

    private var agentsTab: some View {
        card("Claude Code", icon: "sparkles") {
            row("Hooks") {
                if hooks {
                    Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        .padding(.horizontal, 10).padding(.vertical, 4).glassCard(12)
                } else if !Hooks.jqFound {
                    Text("Needs jq · brew install jq").foregroundStyle(.orange)
                } else {
                    Button("Install hooks") { hookError = Hooks.install(); hooks = prefs.hooksInstalled }.glassButton()
                }
            }
            if !hooks {
                Text("Adds Purrminal to ~/.claude/settings.json and keeps a backup next to it. "
                     + "Claude Code sessions started afterwards show up on the cat.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let hookError {
                Text(hookError).font(.caption).foregroundStyle(.red).lineLimit(4)
            }
            Divider().opacity(0.4)
            if agents.isEmpty {
                Text("No agents running").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(agents.prefix(8).enumerated()), id: \.offset) { _, agent in agentRow(agent) }
                if agents.count > 8 {
                    Text("+\(agents.count - 8) more").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func agentRow(_ agent: AgentStatus) -> some View {
        HStack(spacing: 8) {
            if agent.isSubagent { Text("↳").foregroundStyle(.tertiary) }
            Circle().fill(agent.state.tint).frame(width: 7, height: 7)
            Text(agent.label.isEmpty ? "session" : agent.label).lineLimit(1)
            Spacer()
            Text(agent.caption.isEmpty ? agent.state.title : agent.caption)
                .foregroundStyle(.secondary).lineLimit(1)
        }
        .font(.callout)
        .padding(.leading, agent.isSubagent ? 12 : 0)
    }

    // MARK: Building blocks

    private var footer: some View {
        HStack {
            Text("Purrminal " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Quit Purrminal") { NSApp.terminate(nil) }.glassButton()
        }
        .padding(.horizontal, 4)
    }

    private func card<Content: View>(_ title: String, icon: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // Every row has the same height and label column, whatever control sits on the right.
    private static let controlWidth: CGFloat = 230

    private func row<Trailing: View>(_ title: String, @ViewBuilder _ trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) { Text(title); Spacer(minLength: 8); trailing() }
            .frame(minHeight: 30)
    }

    private func segmented<T: Hashable>(_ selection: Binding<T>, _ options: [T], _ title: KeyPath<T, String>) -> some View {
        Picker("", selection: selection) {
            ForEach(options, id: \.self) { Text($0[keyPath: title]).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
    }

    // Snaps to `step` without the tick marks a stepped Slider draws on macOS.
    private func sliderRow(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double) -> some View {
        let snapped = Binding(get: { value.wrappedValue },
                              set: { value.wrappedValue = ($0 / step).rounded() * step })
        return row(title) {
            HStack(spacing: 10) {
                Slider(value: snapped, in: range)
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .monospacedDigit().foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
            }
            .frame(width: Self.controlWidth)
        }
    }

    private var backdrop: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(colors: [Color(red: 1, green: 0.78, blue: 0.68).opacity(0.35),
                                    Color(red: 0.72, green: 0.66, blue: 1).opacity(0.30)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .ignoresSafeArea()
    }
}

// The current cat without its speech bubble, as drawn on the desktop; the empty bubble space on top is cropped.
func catImage(_ state: PetState, frame: Int) -> NSImage {
    let prefs = Preferences.shared
    return NSImage(size: CGSize(width: cellSize.width, height: 172), flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        drawPet(ctx, at: .zero, state: state, frame: frame, caption: "", bubbles: .off, skin: prefs.skin, flip: prefs.flip)
        return true
    }
}

// Tabs have different heights; growing or shrinking keeps the title bar in place instead of the bottom edge.
final class TopAnchoredWindow: NSWindow {
    override func setFrame(_ rect: NSRect, display: Bool) {
        var rect = rect
        if isVisible { rect.origin.y = frame.maxY - rect.height }
        super.setFrame(rect, display: display)
    }
}

enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView())
            host.sizingOptions = .preferredContentSize
            let w = TopAnchoredWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.title = "Purrminal Settings"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.isOpaque = false
            w.backgroundColor = .clear
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
