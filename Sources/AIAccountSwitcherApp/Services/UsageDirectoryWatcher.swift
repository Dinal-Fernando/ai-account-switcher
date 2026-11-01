import Foundation

/// Watches `~/.aiswitch/usage` so beacon files written by Claude Code's status line are picked up immediately.
/// Events are coalesced (250 ms) and delivered on the main queue.
final class UsageDirectoryWatcher {
    private let fd: Int32
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    init?(directory: URL, onChange: @escaping () -> Void) {
        fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.pending?.cancel()
            let item = DispatchWorkItem { onChange() }
            self.pending = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
        }
        let descriptor = fd
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    deinit {
        pending?.cancel()
        source?.cancel()
    }
}
