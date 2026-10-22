import AppKit
import ApplicationServices
import QuartzCore
import RibbonCore

/// Moves windows through the Accessibility API, animating origins with springs driven by
/// a main-run-loop timer. The main thread only steps springs; every AX write goes to the
/// owning app's serial queue (`AXWorkQueues`), and position updates are latest-wins, so a
/// slow app drops frames instead of stalling Ribbon. Sizes are applied once up front
/// (resizing every frame makes apps relayout constantly).
public final class AXFrameApplier: FrameApplying {
    private struct Animation {
        var spring: OriginSpring
        var parameters: SpringParameters
        var final: CGRect?
        var lastSet: CGPoint
        var size: CGSize
    }

    private let source: AXWindowSource
    private let queues = AXWorkQueues.shared
    private var animations: [WindowID: Animation] = [:]
    private var expected: [WindowID: CGRect] = [:]
    /// The frame most recently sent to each window (where it is once queued writes land),
    /// so Ribbon never has to ask the app where its window is.
    private var sent: [WindowID: CGRect] = [:]
    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0

    /// Latest-wins position mailbox shared with the AX queues.
    private let mailboxLock = NSLock()
    private var mailbox: [WindowID: CGPoint] = [:]

    /// Apps whose `AXEnhancedUserInterface` was checked since the last restore (main).
    private var enhancedUIChecked: Set<pid_t> = []
    /// Apps Ribbon switched it off for (touched on the AX queues).
    private let enhancedUILock = NSLock()
    private var enhancedUIDisabled: [pid_t: AXUIElement] = [:]
    private var restoreWorkItem: DispatchWorkItem?

    /// Longest frame step the springs integrate (a stalled frame shouldn't teleport windows).
    private static let maxStep: CFTimeInterval = 1.0 / 20
    /// Enhanced UI is switched back on this long after the last move, so a gesture
    /// doesn't toggle it (Chromium rebuilds its whole AX tree every time) per frame.
    private static let enhancedUIRestoreDelay: TimeInterval = 0.5

    public init(source: AXWindowSource) {
        self.source = source
    }

    deinit {
        timer?.invalidate()
        restoreWorkItem?.cancel()
    }

    public var isAnimating: Bool { !animations.isEmpty }

    public func expectedFrame(of id: WindowID) -> CGRect? { expected[id] }

    public func forget(_ id: WindowID) {
        animations[id] = nil
        expected[id] = nil
        sent[id] = nil
        mailboxLock.lock()
        mailbox[id] = nil
        mailboxLock.unlock()
        if animations.isEmpty { finishAnimating() }
    }

    /// Stops every animation where it is; the expected frame becomes where it stopped.
    public func cancelAll() {
        for (id, animation) in animations {
            expected[id] = CGRect(origin: animation.lastSet, size: animation.size)
        }
        animations = [:]
        finishAnimating()
    }

    public func finishPendingWrites() {
        restoreWorkItem?.cancel()
        restoreEnhancedUI()
        queues.drain(timeout: 2)
    }

    public func apply(_ transitions: [WindowID: FrameTransition], animation: AnimationSpec?) {
        restoreWorkItem?.cancel()
        restoreWorkItem = nil
        for (id, transition) in transitions {
            guard let element = source.element(for: id), let pid = source.pid(of: id) else { continue }
            expected[id] = transition.settledFrame
            suspendEnhancedUI(pid)
            source.noteOwnMove(id)
            if let animation {
                animate(id, element: element, pid: pid, transition: transition, parameters: animation.spring)
            } else {
                animations[id] = nil
                write(transition.settledFrame, to: id, element: element, pid: pid)
            }
        }
        if animations.isEmpty {
            finishAnimating()
        } else {
            startTimer()
        }
    }

    // MARK: Animation

    private func animate(_ id: WindowID, element: AXUIElement, pid: pid_t, transition: FrameTransition, parameters: SpringParameters) {
        if let start = transition.start {
            animations[id] = nil
            write(start, to: id, element: element, pid: pid)
        }
        let target = transition.target
        let currentSize = sent[id]?.size ?? element.size(kAXSizeAttribute)
        if currentSize.map({ abs($0.width - target.width) > 0.5 || abs($0.height - target.height) > 0.5 }) ?? true {
            writeSize(target.size, to: id, element: element, pid: pid)
        }
        if var running = animations[id] {
            running.spring = running.spring.retargeted(to: target.origin)
            running.parameters = parameters
            running.final = transition.final
            running.size = target.size
            animations[id] = running
            return
        }
        let origin = transition.start?.origin ?? sent[id]?.origin ?? element.point(kAXPositionAttribute) ?? target.origin
        let spring = OriginSpring(from: origin, to: target.origin)
        if spring.isSettled {
            write(transition.final ?? target, to: id, element: element, pid: pid)
            return
        }
        animations[id] = Animation(spring: spring, parameters: parameters, final: transition.final, lastSet: origin, size: target.size)
    }

    private func startTimer() {
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        let fps = max(30, NSScreen.screens.first?.maximumFramesPerSecond ?? 60)
        let timer = Timer(timeInterval: 1.0 / Double(fps), repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, Self.maxStep)
        lastTick = now
        for (id, animation) in animations {
            guard let element = source.element(for: id), let pid = source.pid(of: id) else {
                animations[id] = nil
                continue
            }
            var next = animation
            next.spring = animation.spring.stepped(dt: dt, parameters: animation.parameters)
            source.noteOwnMove(id)
            if next.spring.isSettled {
                // Full frame: re-applies the size at the final position (apps clamp sizes
                // to the screen they're on when the size is set).
                write(next.final ?? CGRect(origin: next.spring.target, size: next.size), to: id, element: element, pid: pid, forceSize: true)
                animations[id] = nil
                continue
            }
            let rounded = CGPoint(x: next.spring.origin.x.rounded(), y: next.spring.origin.y.rounded())
            if rounded != next.lastSet {
                writePosition(rounded, to: id, element: element, pid: pid)
                next.lastSet = rounded
            }
            animations[id] = next
        }
        if animations.isEmpty { finishAnimating() }
    }

    private func finishAnimating() {
        timer?.invalidate()
        timer = nil
        guard !enhancedUIChecked.isEmpty else { return }
        restoreWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.restoreEnhancedUI() }
        restoreWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.enhancedUIRestoreDelay, execute: item)
    }

    // MARK: Queued writes

    /// Full frame. Size → position → size (apps clamp sizes by position near screen edges),
    /// or just the position when the size is already right.
    private func write(_ frame: CGRect, to id: WindowID, element: AXUIElement, pid: pid_t, forceSize: Bool = false) {
        let sizeChanged = forceSize || (sent[id].map { abs($0.width - frame.width) > 0.5 || abs($0.height - frame.height) > 0.5 } ?? true)
        sent[id] = frame
        mailboxLock.lock()
        mailbox[id] = nil
        mailboxLock.unlock()
        queues.queue(for: pid).async { [weak self] in
            let result: AXError
            if sizeChanged {
                element.setSize(frame.size)
                result = element.setPosition(frame.origin)
                element.setSize(frame.size)
            } else {
                result = element.setPosition(frame.origin)
            }
            if result == .invalidUIElement { DispatchQueue.main.async { self?.forget(id) } }
        }
    }

    private func writeSize(_ size: CGSize, to id: WindowID, element: AXUIElement, pid: pid_t) {
        sent[id] = CGRect(origin: sent[id]?.origin ?? .zero, size: size)
        queues.queue(for: pid).async { element.setSize(size) }
    }

    /// Latest-wins: if a position for this window is still waiting, it's replaced.
    private func writePosition(_ point: CGPoint, to id: WindowID, element: AXUIElement, pid: pid_t) {
        if let size = sent[id]?.size { sent[id] = CGRect(origin: point, size: size) }
        mailboxLock.lock()
        let alreadyQueued = mailbox[id] != nil
        mailbox[id] = point
        mailboxLock.unlock()
        guard !alreadyQueued else { return }
        queues.queue(for: pid).async { [weak self] in
            guard let self else { return }
            self.mailboxLock.lock()
            let latest = self.mailbox.removeValue(forKey: id)
            self.mailboxLock.unlock()
            guard let latest else { return }
            if element.setPosition(latest) == .invalidUIElement { DispatchQueue.main.async { self.forget(id) } }
        }
    }

    // MARK: Enhanced UI

    private func suspendEnhancedUI(_ pid: pid_t) {
        guard enhancedUIChecked.insert(pid).inserted, let app = source.appElement(for: pid) else { return }
        queues.queue(for: pid).async { [weak self] in
            guard let self, app.bool(AXAttributeName.enhancedUserInterface) == true else { return }
            app.setBool(AXAttributeName.enhancedUserInterface, false)
            self.enhancedUILock.lock()
            self.enhancedUIDisabled[pid] = app
            self.enhancedUILock.unlock()
        }
    }

    /// Queued behind each app's pending writes, so it never runs before the check that
    /// switched enhanced UI off.
    private func restoreEnhancedUI() {
        for pid in enhancedUIChecked {
            queues.queue(for: pid).async { [weak self] in
                guard let self else { return }
                self.enhancedUILock.lock()
                let app = self.enhancedUIDisabled.removeValue(forKey: pid)
                self.enhancedUILock.unlock()
                app?.setBool(AXAttributeName.enhancedUserInterface, true)
            }
        }
        enhancedUIChecked = []
        restoreWorkItem = nil
    }
}
