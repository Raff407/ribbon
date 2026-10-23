import AppKit
import ApplicationServices
import QuartzCore
import RibbonCore

/// Moves windows through the Accessibility API, animating origins with springs driven by
/// a main-run-loop timer. The main thread only steps springs; every AX write goes to the
/// owning app's serial queue (`AXWorkQueues`), and frame updates are latest-wins, so a
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

    /// Coalesces full-frame gesture writes as well as animated positions.
    private let mailbox = FrameWriteMailbox()

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
    /// A settled window's size is read back this long after it was set (some apps apply
    /// a new size a moment later), to catch windows that keep a minimum or fixed size.
    private static let sizeCheckDelay: TimeInterval = 0.15
    /// Width difference (points) that counts as the window refusing its size.
    private static let refusedSizeTolerance: CGFloat = 4

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
        mailbox.remove(id)
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
            guard let element = source.element(for: id), let pid = source.pid(of: id) else {
                applyLocal(id, transition)
                continue
            }
            expected[id] = transition.settledFrame
            suspendEnhancedUI(pid)
            source.noteOwnMove(id)
            if let animation {
                animate(id, element: element, pid: pid, transition: transition, parameters: animation.spring)
            } else {
                animations[id] = nil
                write(transition.settledFrame, to: id, element: element, pid: pid, checksSize: true)
            }
        }
        if animations.isEmpty {
            finishAnimating()
        } else {
            startTimer()
        }
    }

    /// Ribbon's own window: moved straight to its settled frame with AppKit (no AX, no
    /// spring; it's rarely on screen while things scroll).
    private func applyLocal(_ id: WindowID, _ transition: FrameTransition) {
        guard source.local.contains(id) else { return }
        expected[id] = transition.settledFrame
        animations[id] = nil
        source.noteOwnMove(id)
        source.local.setFrame(id, to: transition.settledFrame)
    }

    // MARK: Animation

    private func animate(_ id: WindowID, element: AXUIElement, pid: pid_t, transition: FrameTransition, parameters: SpringParameters) {
        if let start = transition.start {
            animations[id] = nil
            write(start, to: id, element: element, pid: pid)
        }
        let target = transition.target
        // Capture the origin before changing the cached size. A first resize must not
        // invent a (0, 0) origin. Batch the initial position and size into one AX read.
        let currentFrame = sent[id] ?? element.frame()
        let origin = transition.start?.origin ?? currentFrame?.origin ?? target.origin
        let currentSize = currentFrame?.size
        if sent[id] == nil { sent[id] = CGRect(origin: origin, size: currentSize ?? target.size) }
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
        let spring = OriginSpring(from: origin, to: target.origin)
        if spring.isSettled {
            write(transition.final ?? target, to: id, element: element, pid: pid, checksSize: true)
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
                write(next.final ?? CGRect(origin: next.spring.target, size: next.size), to: id, element: element, pid: pid,
                      forceSize: true, checksSize: true)
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
    /// or just the position when the size is already right. `checksSize`: this is where
    /// the window settles, so make sure it took the size (see `checkSize`).
    private func write(_ frame: CGRect, to id: WindowID, element: AXUIElement, pid: pid_t,
                       forceSize: Bool = false, checksSize: Bool = false) {
        let sizeChanged = forceSize || (sent[id].map { abs($0.width - frame.width) > 0.5 || abs($0.height - frame.height) > 0.5 } ?? true)
        sent[id] = frame
        enqueue(FrameWrite(position: frame.origin, size: sizeChanged ? frame.size : nil, checksSize: checksSize && sizeChanged),
                to: id, element: element, pid: pid)
    }

    private func writeSize(_ size: CGSize, to id: WindowID, element: AXUIElement, pid: pid_t) {
        if let origin = sent[id]?.origin { sent[id] = CGRect(origin: origin, size: size) }
        enqueue(FrameWrite(position: nil, size: size), to: id, element: element, pid: pid)
    }

    private func writePosition(_ point: CGPoint, to id: WindowID, element: AXUIElement, pid: pid_t) {
        if let size = sent[id]?.size { sent[id] = CGRect(origin: point, size: size) }
        enqueue(FrameWrite(position: point, size: nil), to: id, element: element, pid: pid)
    }

    private func enqueue(_ write: FrameWrite, to id: WindowID, element: AXUIElement, pid: pid_t) {
        guard let token = mailbox.submit(write, for: id) else { return }
        queues.queue(for: pid).async { [weak self] in
            guard let self, let latest = self.mailbox.take(for: id, token: token) else { return }
            var invalid = false
            if let size = latest.size { invalid = element.setSize(size) == .invalidUIElement }
            if let point = latest.position {
                invalid = element.setPosition(point) == .invalidUIElement || invalid
                // Apps may clamp the first size on the old screen. Reapply at the new
                // position, including forced final sizes on otherwise same-size moves.
                if let size = latest.size { invalid = element.setSize(size) == .invalidUIElement || invalid }
            }
            if invalid {
                DispatchQueue.main.async { [weak self] in
                    guard let self, let current = self.source.element(for: id), CFEqual(current, element) else { return }
                    self.forget(id)
                }
            } else if latest.checksSize, let size = latest.size {
                self.checkSize(size, of: id, element: element, pid: pid)
            }
        }
    }

    /// Reads the size back (on the app's queue) and reports a window that kept a
    /// different width, unless Ribbon has asked for another size since.
    private func checkSize(_ requested: CGSize, of id: WindowID, element: AXUIElement, pid: pid_t) {
        queues.queue(for: pid).asyncAfter(deadline: .now() + Self.sizeCheckDelay) { [weak self] in
            guard let actual = element.frame(), abs(actual.width - requested.width) > Self.refusedSizeTolerance else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.animations[id] == nil, self.sent[id]?.size == requested,
                      let current = self.source.element(for: id), CFEqual(current, element) else { return }
                self.sent[id] = actual
                self.source.reportRefusedSize(id, frame: actual)
            }
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
