// Ed25519 ("EdDSA") keys and signatures for Sparkle updates, using CryptoKit.
//
//   swift scripts/update-signing.swift generate      create the private key in your login Keychain,
//                                                    print the public key (goes in release/update.env)
//   swift scripts/update-signing.swift public        print the public key again
//   swift scripts/update-signing.swift sign <file>   print the signature for an update archive
//   swift scripts/update-signing.swift sign-feed <appcast.xml>
//                                                    append Sparkle's signature block to the feed
//   swift scripts/update-signing.swift sign-release <archive.zip> <appcast.xml> <expected public key>
//                                                    both at once with one Keychain approval: fills
//                                                    __ED_SIGNATURE__ in the feed, then signs the feed
//
// The private key never leaves the Keychain except as a signature. Back it up (Keychain Access →
// "Dropwheel update signing key") — without it, existing installs can't accept new versions.
// DROPWHEEL_ED_KEY_FILE=<path> uses a key file instead of the Keychain; for local tests only.
import CryptoKit
import Foundation
import Security

let service = "Dropwheel update signing key"
let account = "ed25519"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func keyFromFile() -> Curve25519.Signing.PrivateKey? {
    guard let path = ProcessInfo.processInfo.environment["DROPWHEEL_ED_KEY_FILE"] else { return nil }
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("Unreadable key file \(path)") }
    return key
}

func keyFromKeychain() -> Curve25519.Signing.PrivateKey? {
    let query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
        kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
    return try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
}

func existingKey() -> Curve25519.Signing.PrivateKey {
    guard let key = keyFromFile() ?? keyFromKeychain() else {
        fail("No signing key. Run: swift scripts/update-signing.swift generate")
    }
    return key
}

/// No app is trusted to read the key silently: every use (each release) asks for approval.
/// SecAccess is the legacy-keychain API, but it is the one that sets a per-item prompt here;
/// marking the wrapper deprecated keeps the script's output free of the warning.
@available(macOS, deprecated: 10.10)
func askEveryTimeAccess() -> SecAccess? {
    var access: SecAccess?
    return SecAccessCreate(service as CFString, [] as CFArray, &access) == errSecSuccess ? access : nil
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "generate":
    if let path = ProcessInfo.processInfo.environment["DROPWHEEL_ED_KEY_FILE"] {
        let key = Curve25519.Signing.PrivateKey()
        FileManager.default.createFile(atPath: path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                       attributes: [.posixPermissions: 0o600])
        print(key.publicKey.rawRepresentation.base64EncodedString())
        break
    }
    guard keyFromKeychain() == nil else { fail("A key already exists; refusing to replace it (that would break updates).") }
    let key = Curve25519.Signing.PrivateKey()
    guard let access = askEveryTimeAccess() else { fail("Could not create the Keychain access rule") }
    let attributes: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
        kSecValueData: key.rawRepresentation, kSecAttrLabel: service, kSecAttrAccess: access,
    ]
    let status = SecItemAdd(attributes as CFDictionary, nil)
    guard status == errSecSuccess else { fail("Keychain error \(status)") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public":
    print(existingKey().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard arguments.count == 2, let data = FileManager.default.contents(atPath: arguments[1]) else {
        fail("usage: swift scripts/update-signing.swift sign <file>")
    }
    let key = existingKey()
    let signature = try key.signature(for: data)
    guard key.publicKey.isValidSignature(signature, for: data) else { fail("Signature self-check failed") }
    print(signature.base64EncodedString())
case "sign-release":
    guard arguments.count == 4, let archive = FileManager.default.contents(atPath: arguments[1]),
          let template = FileManager.default.contents(atPath: arguments[2]) else {
        fail("usage: swift scripts/update-signing.swift sign-release <archive.zip> <appcast.xml> <public key>")
    }
    let key = existingKey()
    guard key.publicKey.rawRepresentation.base64EncodedString() == arguments[3] else {
        fail("The signing key doesn't match the public key built into the app; refusing to sign.")
    }
    let feedText = String(decoding: template, as: UTF8.self)
    guard feedText.contains("__ED_SIGNATURE__"), !feedText.contains("sparkle-signatures:") else { fail("Unexpected feed template") }
    let feed = Data(feedText.replacingOccurrences(of: "__ED_SIGNATURE__", with: try key.signature(for: archive).base64EncodedString()).utf8)
    var signed = feed
    signed.append(Data("<!-- sparkle-signatures:\nedSignature: \(try key.signature(for: feed).base64EncodedString())\nlength: \(feed.count)\n-->\n".utf8))
    try signed.write(to: URL(fileURLWithPath: arguments[2]), options: .atomic)
case "sign-feed":
    // Sparkle's signed-feed format: the signature covers the file's bytes and is appended as
    // "<!-- sparkle-signatures:\nedSignature: …\nlength: …\n-->\n" (see Sparkle common_cli/Signing.swift).
    guard arguments.count == 2, let data = FileManager.default.contents(atPath: arguments[1]) else {
        fail("usage: swift scripts/update-signing.swift sign-feed <appcast.xml>")
    }
    guard !String(decoding: data, as: UTF8.self).contains("sparkle-signatures:") else { fail("Feed is already signed") }
    let signature = try existingKey().signature(for: data).base64EncodedString()
    var signed = data
    signed.append(Data("<!-- sparkle-signatures:\nedSignature: \(signature)\nlength: \(data.count)\n-->\n".utf8))
    try signed.write(to: URL(fileURLWithPath: arguments[1]), options: .atomic)
default:
    fail("usage: swift scripts/update-signing.swift generate | public | sign <file> | sign-feed <appcast.xml> | sign-release <zip> <appcast.xml> <public key>")
}
