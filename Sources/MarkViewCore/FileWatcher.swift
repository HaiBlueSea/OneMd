import Foundation

/// Serializes watcher lifetime and watches the parent to recover a missing file.
public final class FileWatcher: @unchecked Sendable {
    private let path: String
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "local.mdos.filewatcher", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private var source: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    private var debounceWorkItem: DispatchWorkItem?
    private var running = false
    private var generation = 0

    public init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
        queue.setSpecific(key: queueKey, value: true)
    }

    private func serialized(_ operation: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) == true { operation() }
        else { queue.sync(execute: operation) }
    }

    public func start() {
        serialized {
            stopOnQueue()
            running = true
            let token = generation
            attachFile(generation: token)
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
            let fd = open(parent, O_EVTONLY)
            guard fd >= 0 else { return }
            let directory = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue
            )
            directory.setEventHandler { [weak self] in
                guard let self, self.running, self.generation == token, self.source == nil else { return }
                self.attachFile(generation: token)
                if self.source != nil { self.notifyDebounced(generation: token) }
            }
            directory.setCancelHandler { close(fd) }
            directorySource = directory
            directory.resume()
        }
    }

    public func stop() { serialized { stopOnQueue() } }

    private func stopOnQueue() {
        running = false
        generation += 1
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        source?.cancel()
        source = nil
        directorySource?.cancel()
        directorySource = nil
    }

    private func attachFile(generation token: Int) {
        guard running, generation == token, source == nil else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let file = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .attrib], queue: queue
        )
        file.setEventHandler { [weak self] in
            guard let self, self.running, self.generation == token, let source = self.source else { return }
            if !source.data.intersection([.rename, .delete]).isEmpty {
                source.cancel()
                self.source = nil
                self.attachFile(generation: token)
            }
            self.notifyDebounced(generation: token)
        }
        file.setCancelHandler { close(fd) }
        source = file
        file.resume()
    }

    private func notifyDebounced(generation token: Int) {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running, self.generation == token else { return }
            self.onChange()
        }
        debounceWorkItem = work
        queue.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    deinit { stop() }
}
