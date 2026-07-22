import Foundation

/// Watches a single file for changes and invokes `onChange`. Re-arms itself if
/// the file is atomically replaced (rename/delete), which invalidates the
/// underlying inode watch — the case an editor's replace-on-write produces.
final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "burntracker.filewatcher", qos: .utility)

    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var retryScheduled = false
    private var stopped = false

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        queue.async { [weak self] in self?.arm() }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopped = true
            self?.teardown()
        }
    }

    private func arm() {
        guard !stopped else { return }
        teardown()

        fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            scheduleRetry()   // File may not exist yet; retry until it appears.
            return
        }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .rename, .delete, .link],
            queue: queue)

        src.setEventHandler { [weak self] in
            guard let self, let source = self.source else { return }
            let flags = source.data
            self.onChange()
            if flags.contains(.rename) || flags.contains(.delete) {
                // The file was replaced; reopen against the new inode.
                self.arm()
            }
        }
        src.setCancelHandler { [fd = fileDescriptor] in
            if fd >= 0 { close(fd) }
        }

        source = src
        src.resume()
    }

    private func scheduleRetry() {
        guard !retryScheduled, !stopped else { return }
        retryScheduled = true
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.retryScheduled = false
            self?.arm()
        }
    }

    private func teardown() {
        source?.cancel()
        source = nil
        fileDescriptor = -1   // Actual close happens in the cancel handler.
    }
}
