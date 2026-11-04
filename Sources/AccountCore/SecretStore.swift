import Foundation

public enum SecretStoreError: Error, Equatable {
    case commandFailed(status: Int32, message: String)
    case verifyFailed
}

/// Generic-password keychain access.
public protocol SecretStore: Sendable {
    func read(service: String, account: String?) throws -> String?
    func write(service: String, account: String, value: String) throws
    func delete(service: String, account: String) throws
}

/// Keychain access through `/usr/bin/security`, the same way Claude Code does it.
/// Items created by that tool trust it, so neither Claude Code nor this app gets a
/// keychain prompt, and a rebuilt (ad-hoc signed) app keeps working.
public struct SecurityCLISecretStore: SecretStore {
    /// `security -i` refuses longer stdin lines; above this the value goes in argv (as Claude Code does).
    static let stdinLineLimit = 4000
    let tool = "/usr/bin/security"
    static let timeout: TimeInterval = 15

    private final class TimedOut: @unchecked Sendable {
        private let lock = NSLock(); private var flag = false
        func set() { lock.lock(); flag = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }

    public init() {}

    public func read(service: String, account: String?) throws -> String? {
        var args = ["find-generic-password", "-s", service]
        if let account { args += ["-a", account] }
        args.append("-w")
        let r = try run(args)
        if r.status == 44 { return nil } // errSecItemNotFound
        guard r.status == 0 else { throw SecretStoreError.commandFailed(status: r.status, message: r.err) }
        return String(decoding: r.out, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    public func write(service: String, account: String, value: String) throws {
        let hex = Self.hex(value)
        let line = Self.addCommand(service: service, account: account, hex: hex)
        let r: (status: Int32, out: Data, err: String)
        if line.utf8.count <= Self.stdinLineLimit {
            r = try run(["-i"], stdin: line + "\n")
        } else {
            r = try run(["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex])
        }
        guard r.status == 0 else {
            throw SecretStoreError.commandFailed(status: r.status, message: r.err)
        }
        // `security -i` can exit 0 after a failed command, so read it back.
        guard try read(service: service, account: account) == value else { throw SecretStoreError.verifyFailed }
    }

    public func delete(service: String, account: String) throws {
        let r = try run(["delete-generic-password", "-s", service, "-a", account])
        guard r.status == 0 || r.status == 44 else {
            throw SecretStoreError.commandFailed(status: r.status, message: r.err)
        }
    }

    static func hex(_ s: String) -> String {
        s.utf8.map { String(format: "%02x", $0) }.joined()
    }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func addCommand(service: String, account: String, hex: String) -> String {
        "add-generic-password -U -a \(quote(account)) -s \(quote(service)) -X \(hex)"
    }

    private func run(_ args: [String], stdin: String? = nil) throws -> (status: Int32, out: Data, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let inPipe = Pipe()
        p.standardInput = inPipe
        try p.run()
        // A locked keychain or an unanswered prompt can make `security` wait forever, which would freeze
        // the whole account manager: kill it after a while so the call fails and the next sync retries.
        let timedOut = TimedOut()
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout) { if p.isRunning { timedOut.set(); p.terminate() } }
        if let stdin { inPipe.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? inPipe.fileHandleForWriting.close()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if timedOut.value {
            Diag.log("security \(args.first ?? "") timed out after \(Int(Self.timeout)) s (keychain locked or prompt open?)")
            return (-1, Data(), "timed out")
        }
        return (p.terminationStatus, o, String(decoding: e, as: UTF8.self))
    }
}

/// In-memory store for tests.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var items: [String: String] = [:]
    public init(_ items: [String: String] = [:]) { self.items = items }
    public static func key(_ s: String, _ a: String?) -> String { "\(s)|\(a ?? "*")" }

    public func read(service: String, account: String?) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        if let account { return items[Self.key(service, account)] }
        return items.first { $0.key.hasPrefix(service + "|") }?.value
    }
    public func write(service: String, account: String, value: String) throws {
        lock.lock(); defer { lock.unlock() }
        items[Self.key(service, account)] = value
    }
    public func delete(service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        items[Self.key(service, account)] = nil
    }
}
