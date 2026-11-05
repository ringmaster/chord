import Foundation
import OSLog
import WebKit
import chord_logic

/// Why an extension's native message could not reach an app.
enum NativeMessagingError: LocalizedError {
    /// The extension did not name an app.
    case noApplicationName
    /// The extension was loaded from a Safari app extension. Its messages go to
    /// the app extension inside its app, and only Safari may load those.
    case safariAppExtension
    /// The extension folder has no Chrome ID, so no host manifest can list it.
    case noExtensionID
    case lookup(NativeMessagingHosts.LookupError)
    /// The app could not start.
    case launchFailed(String)
    /// The app quit before it replied.
    case closedWithoutReply

    var errorDescription: String? {
        switch self {
        case .noApplicationName: "The extension did not name a native messaging host."
        case .safariAppExtension: "Chord cannot send native messages for Safari app extensions. Use the extension's Chrome version."
        case .noExtensionID: "The extension has no Chrome ID, so no native messaging host can allow it."
        case .lookup(let error): "Native messaging host lookup failed: \(error)"
        case .launchFailed(let reason): "The native messaging host did not start: \(reason)"
        case .closedWithoutReply: "The native messaging host quit before it replied."
        }
    }
}

/// One running native messaging host: an app Chord started for an extension,
/// which exchanges framed JSON messages with Chord over standard input and output.
///
/// Contract:
/// - `start(manifest:origin:)` starts `manifest.path` with the extension's origin
///   as its only argument, as Chrome does on macOS, or throws `launchFailed`.
/// - `send(_:)` writes one JSON-serializable message. Writes happen in order on
///   a background queue, so a host that stops reading cannot block the main thread.
/// - `onMessage` is called on the main actor for each message the host sends.
/// - `onClose` is called once, on the main actor, when the host quits, when it
///   sends bytes that are not a valid message, or after `close()`.
/// - There are no retries. A host that quits stays closed; the extension connects again.
@MainActor
final class NativeHostConnection {
    nonisolated static let log = Logger(subsystem: "net.asymptomatic.Chord", category: "native-messaging")

    var onMessage: ((Any) -> Void)?
    var onClose: ((Error?) -> Void)?
    let name: String

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let writeQueue = DispatchQueue(label: "net.asymptomatic.Chord.native-messaging.write")
    private var framing = NativeMessageFraming()
    private var isClosed = false

    private init(name: String) {
        self.name = name
    }

    static func start(manifest: NativeMessagingHostManifest, origin: String) throws -> NativeHostConnection {
        let connection = NativeHostConnection(name: manifest.name)
        try connection.launch(path: manifest.path, origin: origin)
        return connection
    }

    private func launch(path: String, origin: String) throws {
        process.executableURL = URL(filePath: path)
        process.arguments = [origin]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // Each handler runs on a background queue. DispatchQueue.main keeps the
        // reads in order, which a Task would not promise.
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(data) } }
        }
        let name = name
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            NativeHostConnection.log.info("\(name, privacy: .public) stderr: \(text, privacy: .public)")
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    NativeHostConnection.log.info("\(name, privacy: .public) quit with status \(status)")
                    self?.finish(nil)
                }
            }
        }
        do {
            try process.run()
        } catch {
            throw NativeMessagingError.launchFailed(error.localizedDescription)
        }
        NativeHostConnection.log.info("Started \(name, privacy: .public) for \(origin, privacy: .public)")
    }

    func send(_ message: Any) throws {
        guard !isClosed else { return }
        let json = try JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed])
        let framed = try NativeMessageFraming.frame(json)
        let handle = input.fileHandleForWriting
        writeQueue.async {
            do {
                try handle.write(contentsOf: framed)
            } catch {
                NativeHostConnection.log.error("Write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func close() {
        finish(nil)
    }

    private func received(_ data: Data) {
        guard !isClosed else { return }
        if data.isEmpty {
            // The host closed its output.
            return finish(nil)
        }
        do {
            for message in try framing.append(data) {
                let value = try JSONSerialization.jsonObject(with: message, options: [.fragmentsAllowed])
                onMessage?(value)
            }
        } catch {
            NativeHostConnection.log.error("\(self.name, privacy: .public) sent a bad message: \(String(describing: error), privacy: .public)")
            finish(error)
        }
    }

    private func finish(_ error: Error?) {
        guard !isClosed else { return }
        isClosed = true
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
        let onClose = onClose
        self.onClose = nil
        onMessage = nil
        onClose?(error)
    }
}
