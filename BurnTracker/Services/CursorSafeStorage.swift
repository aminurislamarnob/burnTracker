import CommonCrypto
import Foundation

/// Decrypts Cursor's `cursor-safe-storage:v1:` values from `state.vscdb`.
///
/// The Cursor app and `cursor-agent` store JWTs this way: base64 of Electron's
/// `v10` ciphertext, keyed by the Keychain item "Cursor Safe Storage" /
/// "Cursor Key" (PBKDF2-SHA1, AES-128-CBC, IV of 16 spaces). That is the login
/// `cursor-agent` writes; it is not a raw JWT in SQLite.
enum CursorSafeStorage {
    private static let prefix = "cursor-safe-storage:v1:"

    static func unwrap(_ stored: String?) -> String? {
        guard let stored = stored?.trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty else {
            return nil
        }
        if stored.split(separator: ".").count >= 3, !stored.hasPrefix(prefix) {
            return stored
        }
        guard stored.hasPrefix(prefix) else { return nil }
        let payload = String(stored.dropFirst(prefix.count))
        return decrypt(base64Payload: payload)
    }

    private static func decrypt(base64Payload: String) -> String? {
        guard let blob = Data(base64Encoded: base64Payload),
              blob.count > 3,
              blob.prefix(3) == Data("v10".utf8),
              let password = safeStoragePassword() else { return nil }

        let key = deriveKey(password: password)
        let ciphertext = blob.dropFirst(3)
        let outputCapacity = ciphertext.count + kCCBlockSizeAES128
        var output = Data(count: outputCapacity)
        var outputLength = 0
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        let status = output.withUnsafeMutableBytes { outputBytes in
            ciphertext.withUnsafeBytes { cipherBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            cipherBytes.baseAddress, ciphertext.count,
                            outputBytes.baseAddress, outputCapacity,
                            &outputLength)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        output.count = outputLength
        guard let text = String(data: output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              text.split(separator: ".").count >= 3 else { return nil }
        return text
    }

    /// Electron safeStorage key derivation on macOS.
    private static func deriveKey(password: String) -> Data {
        let passwordData = Data(password.utf8)
        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        _ = key.withUnsafeMutableBytes { keyBytes in
            passwordData.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        passwordData.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        kCCKeySizeAES128)
                }
            }
        }
        return key
    }

    /// The safe-storage password. Read with `security` so a menu-bar app can use
    /// the item Cursor already created, without a second generic-password prompt.
    private static func safeStoragePassword() -> String? {
        let result = runSecurity([
            "find-generic-password", "-s", "Cursor Safe Storage", "-a", "Cursor Key", "-w"
        ])
        guard result.status == 0,
              let text = String(data: result.output, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    private static func runSecurity(_ arguments: [String]) -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, Data())
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }
}
