import Foundation

/// A kqueue watcher on one file or folder, delivering on the main queue. Unlike FSEvents it also
/// reports appends to a file another app keeps open. Cancel the returned source to stop it.
enum FileWatch {
    static func start(_ url: URL, events: DispatchSource.FileSystemEvent = .write,
                      handler: @escaping () -> Void) -> DispatchSourceFileSystemObject? {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: .main)
        source.setEventHandler(handler: handler)
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }
}
