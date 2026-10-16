// Ed25519 signing for release archives.
//   swift scripts/sign-release.swift <file.zip>              write <file.zip>.sig (raw signature, checked by the in-app
//                                                            updater) and <file.zip>.sshsig (the same key in OpenSSH's
//                                                            SSHSIG format, checked by install.sh with ssh-keygen -Y verify)
//   swift scripts/sign-release.swift --any-key <file.zip>    skip the embedded-key check (key rotation: the release
//                                                            that ships a new public key is signed with the old key)
// Key source: $EQUINOX_SIGNING_KEY (base64 raw key; the EQUINOX_SIGNING_KEY secret on the production environment in CI),
// else ~/.config/equinox/release-signing-key. The signature is checked against the public key embedded in
// Sources/EquinoxCore/Updates.swift, so a release can never ship with a signature the app would reject.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadKey() -> Curve25519.Signing.PrivateKey {
    let fileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/equinox/release-signing-key")
    let text = ProcessInfo.processInfo.environment["EQUINOX_SIGNING_KEY"] ?? (try? String(contentsOf: fileURL, encoding: .utf8))
    guard let text, let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("No release signing key: set EQUINOX_SIGNING_KEY or create \(fileURL.path).")
    }
    return key
}

func embeddedPublicKey() -> Data {
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../Sources/EquinoxCore/Updates.swift").standardizedFileURL
    guard let text = try? String(contentsOf: source, encoding: .utf8),
          let start = text.range(of: "releasePublicKey = Data(base64Encoded: \""),
          let end = text.range(of: "\")", range: start.upperBound..<text.endIndex),
          let key = Data(base64Encoded: String(text[start.upperBound..<end.lowerBound])) else {
        fail("Couldn't read the embedded release public key from \(source.path).")
    }
    return key
}

/// OpenSSH signature (PROTOCOL.sshsig) over `message`, armored like `ssh-keygen -Y sign` output.
func sshSignature(of message: Data, key: Curve25519.Signing.PrivateKey, namespace: String) throws -> String {
    func string(_ d: Data) -> Data { var n = UInt32(d.count).bigEndian; return Data(bytes: &n, count: 4) + d }
    func string(_ s: String) -> Data { string(Data(s.utf8)) }
    let magic = Data("SSHSIG".utf8), hash = "sha512"
    let signed = magic + string(namespace) + string("") + string(hash) + string(Data(SHA512.hash(data: message)))
    let publicKey = string("ssh-ed25519") + string(key.publicKey.rawRepresentation)
    let signature = string("ssh-ed25519") + string(try key.signature(for: signed))
    var version = UInt32(1).bigEndian
    let blob = magic + Data(bytes: &version, count: 4) + string(publicKey) + string(namespace) + string("") + string(hash)
        + string(signature)
    let b64 = blob.base64EncodedString()
    let lines = stride(from: 0, to: b64.count, by: 70).map { i -> String in
        let start = b64.index(b64.startIndex, offsetBy: i)
        return String(b64[start..<(b64.index(start, offsetBy: 70, limitedBy: b64.endIndex) ?? b64.endIndex)])
    }
    return (["-----BEGIN SSH SIGNATURE-----"] + lines + ["-----END SSH SIGNATURE-----", ""]).joined(separator: "\n")
}

var args = Array(CommandLine.arguments.dropFirst())
let anyKey = args.first == "--any-key"
if anyKey { args.removeFirst() }
guard let path = args.first else { fail("usage: sign-release.swift [--any-key] <archive>") }
let file = URL(fileURLWithPath: path)
let key = loadKey()
guard anyKey || key.publicKey.rawRepresentation == embeddedPublicKey() else {
    fail("This signing key doesn't match the public key embedded in the app; the updater would reject the release.")
}
let archive = try Data(contentsOf: file)
try key.signature(for: archive).write(to: file.appendingPathExtension("sig"))
try sshSignature(of: archive, key: key, namespace: "equinox-release")
    .write(to: file.appendingPathExtension("sshsig"), atomically: true, encoding: .utf8)
print("Signed \(file.lastPathComponent) → \(file.lastPathComponent).sig, \(file.lastPathComponent).sshsig")
