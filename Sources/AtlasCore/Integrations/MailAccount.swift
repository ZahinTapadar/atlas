import Foundation

/// The check-in address's outgoing mail server and the app password for it, kept in the login Keychain
/// (service "ATLAS SMTP"). Saving goes through `security -i` over stdin so the password never appears in
/// a process's arguments, and reading through `/usr/bin/security`, which owns the item, so background
/// check-ins never trigger a Keychain prompt.
public enum MailAccount {
    public static let keychainService = "ATLAS SMTP"

    public struct Failure: LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
    }

    public static func server(for address: String) -> (url: String, startTLS: Bool)? {
        let domain = address.split(separator: "@").last.map { $0.lowercased() } ?? ""
        switch domain {
        case "gmail.com", "googlemail.com": return ("smtps://smtp.gmail.com:465", false)
        case "icloud.com", "me.com", "mac.com": return ("smtp://smtp.mail.me.com:587", true)
        default: return nil
        }
    }

    public static func supportsHTML(_ address: String) -> Bool { server(for: address) != nil }

    /// Where the user creates an app password for this address.
    public static func appPasswordPage(for address: String) -> URL? {
        let domain = address.split(separator: "@").last.map { $0.lowercased() } ?? ""
        switch domain {
        case "gmail.com", "googlemail.com": return URL(string: "https://myaccount.google.com/apppasswords")
        case "icloud.com", "me.com", "mac.com": return URL(string: "https://account.apple.com/account/manage")
        default: return nil
        }
    }

    public static func password(for address: String) -> String? {
        let r = run(["find-generic-password", "-s", keychainService, "-a", address, "-w"])
        let s = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.status == 0 && !s.isEmpty ? s : nil
    }

    public static func isConfigured(_ address: String) -> Bool { supportsHTML(address) && password(for: address) != nil }

    /// Normalises a pasted app password (Google shows it in groups of four) or returns nil if it can't be one.
    public static func normalise(_ pasted: String) -> String? {
        let p = pasted.replacingOccurrences(of: " ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return p.range(of: #"^[A-Za-z0-9-]{12,40}$"#, options: .regularExpression) != nil ? p : nil
    }

    public static func savePassword(_ pass: String, for address: String) throws {
        guard pass.range(of: #"^[A-Za-z0-9-]+$"#, options: .regularExpression) != nil,
              address.range(of: #"^[^"\s]+$"#, options: .regularExpression) != nil else {
            throw Failure(message: "Unexpected characters; nothing was saved.")
        }
        let line = "add-generic-password -U -s \"\(keychainService)\" -a \"\(address)\" -l \"ATLAS check-in email\" -T /usr/bin/security -w \(pass)\n"
        let r = run(["-i"], stdin: line)
        guard r.status == 0, password(for: address) == pass else {
            throw Failure(message: "The Keychain didn't save the password. \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    public static func deletePassword(for address: String) {
        _ = run(["delete-generic-password", "-s", keychainService, "-a", address])
    }

    private static func run(_ args: [String], stdin: String? = nil) -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let out = Pipe(), err = Pipe(), input = Pipe()
        p.standardOutput = out
        p.standardError = err
        if stdin != nil { p.standardInput = input }
        do { try p.run() } catch { return (-1, "", error.localizedDescription) }
        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }
        let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }
}
