// Hold Please: ⌘Q only quits when you hold it.
//
// A quick ⌘Q does nothing at all — the key never reaches the app in front, so
// there is no menu flash and no quit. Keep it held for a moment and the app
// quits the polite way, exactly as ⌘Q always did: an app with unsaved work
// still gets to put its sheet up.
//
// Nothing about the system's ⌘Q binding is changed. The key is caught with a
// session-level CGEventTap and swallowed, which is why this needs Accessibility
// permission. Quitting is NSRunningApplication.terminate(), all public API.
//
// Left alone on purpose:
//   - ⌥⌘Q and ⇧⌘Q. ⌥⌘Q is the way out when you do want an instant quit.
//   - Finder, which has no Quit item, so there is nothing to guard.
//   - Anything you list yourself:
//       defaults write com.adammackey.holdplease excludedBundleIDs -array com.some.app
//       defaults write com.adammackey.holdplease holdSeconds -float 1.0

import AppKit
import ApplicationServices
import ServiceManagement
import os

let bundleID = Bundle.main.bundleIdentifier ?? "com.adammackey.holdplease"
let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Hold Please"
let logger = Logger(subsystem: bundleID, category: "app")

// `build.sh uninstall` runs the app with this to remove its login item.
if CommandLine.arguments.contains("--unregister") {
    try? SMAppService.mainApp.unregister()
    exit(0)
}

// MARK: - Settings

/// How long ⌘Q has to be held. Kept inside sane bounds, so a stray `defaults
/// write` can't turn Q into a key that quits on touch or never quits at all.
var holdSeconds: TimeInterval {
    let stored = UserDefaults.standard.double(forKey: "holdSeconds")
    return stored > 0 ? min(max(stored, 0.2), 3) : 0.6
}

/// Apps that keep plain ⌘Q. Finder is always in here: it has no Quit item, so
/// swallowing its ⌘Q would guard nothing and quitting it would be a surprise.
var excludedBundleIDs: Set<String> {
    let listed = UserDefaults.standard.array(forKey: "excludedBundleIDs") as? [String] ?? []
    return Set(listed.map { $0.lowercased() }).union(["com.apple.finder"])
}

// MARK: - Login

/// Start at login. Only done once, so switching it off in System Settings sticks.
func registerLoginItemOnce() {
    let key = "RegisteredLoginItem"
    guard !UserDefaults.standard.bool(forKey: key) else { return }
    do {
        try SMAppService.mainApp.register()
        UserDefaults.standard.set(true, forKey: key)
        logger.notice("Added to Login Items")
    } catch {
        logger.error("Couldn't add to Login Items: \(error.localizedDescription, privacy: .public)")
    }
}

// MARK: - The bar you see while holding

/// A small panel that says what will quit, with a bar that fills as you hold.
/// It never takes focus: the app being quit has to stay the app in front.
final class HoldHUD {
    private let size = NSSize(width: 300, height: 78)
    private let label = NSTextField(labelWithString: "")
    private let track = NSView()
    private let fill = NSView()
    private var tick: Timer?
    private var startedAt = Date()
    private var duration: TimeInterval = 0.6

    private lazy var panel: NSPanel = {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        // Above a full-screen app, and present on whichever Space you're on.
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 18
        blur.layer?.masksToBounds = true

        label.frame = NSRect(x: 20, y: 40, width: size.width - 40, height: 20)
        label.alignment = .center
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail

        track.frame = NSRect(x: 24, y: 24, width: size.width - 48, height: 6)
        track.wantsLayer = true
        track.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        track.layer?.cornerRadius = 3

        fill.frame = NSRect(x: 0, y: 0, width: 0, height: 6)
        fill.wantsLayer = true
        fill.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
        fill.layer?.cornerRadius = 3

        track.addSubview(fill)
        blur.addSubview(label)
        blur.addSubview(track)
        panel.contentView = blur
        return panel
    }()

    func show(appName: String, duration: TimeInterval) {
        self.duration = duration
        startedAt = Date()
        label.stringValue = "Hold ⌘Q to quit \(appName)"
        fill.frame.size.width = 0

        // The screen holding the app you're quitting, which is the one with key focus.
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let visible = screen?.frame {
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                         y: visible.minY + visible.height * 0.16))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let progress = min(1, Date().timeIntervalSince(self.startedAt) / self.duration)
            self.fill.frame.size.width = self.track.bounds.width * progress
            if progress >= 1 { timer.invalidate() }
        }
    }

    func hide() {
        tick?.invalidate()
        tick = nil
        guard panel.isVisible, panel.alphaValue > 0 else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.panel.alphaValue == 0 else { return }  // shown again mid-fade
            self.panel.orderOut(nil)
        })
    }
}

// MARK: - Holding ⌘Q

final class Controller {
    private let hud = HoldHUD()
    /// True while Q is down and being kept from the app in front.
    private var holding = false
    private var holdTimer: Timer?
    private var watchdog: Timer?

    private let qKeyCode: Int64 = 12  // kVK_ANSI_Q: the physical key, whatever the layout

    /// Called for every key down. Returns true to swallow it. Answers quickly:
    /// macOS switches off a tap that's slow, and this one sits in front of typing.
    func shouldCatchKeyDown(_ event: CGEvent) -> Bool {
        guard event.getIntegerValueField(.keyboardEventKeycode) == qKeyCode else { return false }
        // Key repeats while Q is down, including after ⌘ was let go again.
        if holding { return true }
        // Exactly ⌘Q. ⌥⌘Q, ⇧⌘Q and a bare q are macOS's business, not ours.
        guard event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]) == .maskCommand,
              let app = NSWorkspace.shared.frontmostApplication,
              !excludedBundleIDs.contains(app.bundleIdentifier?.lowercased() ?? "") else { return false }
        holding = true
        DispatchQueue.main.async { self.startHold(app) }
        return true
    }

    /// Swallow the key up too, so an app never sees half a keystroke.
    func shouldCatchKeyUp(_ event: CGEvent) -> Bool {
        guard holding, event.getIntegerValueField(.keyboardEventKeycode) == qKeyCode else { return false }
        holding = false
        DispatchQueue.main.async { self.release() }
        return true
    }

    /// Letting go of ⌘ with Q still down means this stopped being a ⌘Q hold.
    func flagsChanged(_ event: CGEvent) {
        guard holding, !event.flags.contains(.maskCommand) else { return }
        DispatchQueue.main.async { self.stopHold() }
    }

    /// The tap was switched off, so the key up may never arrive.
    func reset() {
        guard holding else { return }
        holding = false
        DispatchQueue.main.async { self.release() }
    }

    private func startHold(_ app: NSRunningApplication) {
        let name = app.localizedName ?? "the app in front"
        let duration = holdSeconds
        logger.notice("Caught ⌘Q in \(name, privacy: .public)")
        hud.show(appName: name, duration: duration)

        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.quit(app, after: duration)
        }
        // If a key up ever goes missing, don't leave Q swallowed for good.
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: duration + 5, repeats: false) { [weak self] _ in
            guard let self, self.holding else { return }
            logger.error("No key up after \(String(format: "%.1f", duration + 5), privacy: .public)s, letting Q go")
            self.reset()
        }
    }

    private func quit(_ app: NSRunningApplication, after duration: TimeInterval) {
        stopHold()
        guard !app.isTerminated else { return }
        logger.notice("Held \(String(format: "%.1f", duration), privacy: .public)s, quitting \(app.localizedName ?? "it", privacy: .public)")
        _ = app.terminate()
    }

    /// Stops the countdown and takes the bar away. The key stays swallowed
    /// until it comes back up.
    private func stopHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        hud.hide()
    }

    private func release() {
        stopHold()
        watchdog?.invalidate()
        watchdog = nil
    }
}

// MARK: - Catching the key

/// A session-level event tap: it sees keys on their way to the app in front and
/// can swallow them. Needs Accessibility permission, and gets nothing while a
/// password field has secure input on, where ⌘Q keeps quitting the old way.
final class KeyWatcher {
    let controller: Controller
    private var tap: CFMachPort?

    init(controller: Controller) {
        self.controller = controller
    }

    /// Returns false while Accessibility isn't allowed yet.
    func start() -> Bool {
        guard tap == nil else { return true }
        let events = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: events,
            callback: { _, type, event, watcher in
                Unmanaged<KeyWatcher>.fromOpaque(watcher!).takeUnretainedValue().handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS switches a tap off if it's ever too slow; switch it straight back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            controller.reset()
        case .keyDown where controller.shouldCatchKeyDown(event):
            return nil
        case .keyUp where controller.shouldCatchKeyUp(event):
            return nil
        case .flagsChanged:
            controller.flagsChanged(event)
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = Controller()
    lazy var keyWatcher = KeyWatcher(controller: controller)
    private var permissionTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerLoginItemOnce()
        if keyWatcher.start() {
            logWatching()
        } else {
            logger.notice("Waiting for Accessibility permission")
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
            // Start as soon as it's allowed, without a relaunch.
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard let self, self.keyWatcher.start() else { return }
                timer.invalidate()
                self.logWatching()
            }
        }

        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    private func logWatching() {
        logger.notice("Watching ⌘Q, hold \(String(format: "%.2f", holdSeconds), privacy: .public)s to quit")
    }

    /// There's no window or menu bar icon, so opening the app again while it
    /// runs is the way to reach Quit.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "\(appName) is running"
        alert.informativeText = "⌘Q quits the app in front only when you hold it for "
            + "\(String(format: "%.2g", holdSeconds)) seconds. A quick ⌘Q does nothing, and ⌥⌘Q still quits straight away. "
            + "It opens again at login unless you turn it off in System Settings → General → Login Items."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() == .alertSecondButtonReturn { NSApp.terminate(nil) }
        return false
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
