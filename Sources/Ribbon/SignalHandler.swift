import Dispatch
import Foundation

/// Runs `cleanup` (un-park every window) and exits on SIGTERM / SIGINT / SIGHUP, so killing
/// Ribbon from a terminal never leaves windows stranded in a screen corner.
final class SignalHandler {
    private var sources: [DispatchSourceSignal] = []

    init(cleanup: @escaping () -> Void) {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                cleanup()
                exit(0)
            }
            source.resume()
            sources.append(source)
        }
    }
}
