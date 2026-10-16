// Ed25519 signing for release archives (verified by the in-app updater).
//   swift scripts/sign-release.swift --generate     create the key pair (once); prints the public key to embed
//   swift scripts/sign-release.swift <file.zip>     write <file.zip>.sig
// The private key lives at ~/.config/equinox/release-signing-key (base64, mode 600) and must never be committed.
import CryptoKit
import Foundation

let keyURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/equinox/release-signing-key")
let args = CommandLine.arguments.dropFirst()

func loadKey() -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOf: keyURL, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        FileHandle.standardError.write(Data("No signing key at \(keyURL.path). Run with --generate first.\n".utf8))
        exit(1)
    }
    return key
}

if args.first == "--generate" {
    if FileManager.default.fileExists(atPath: keyURL.path) {
        print("Key already exists. Public key:", loadKey().publicKey.rawRepresentation.base64EncodedString())
        exit(0)
    }
    let key = Curve25519.Signing.PrivateKey()
    try FileManager.default.createDirectory(at: keyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try key.rawRepresentation.base64EncodedString().write(to: keyURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
    print("Wrote \(keyURL.path). Public key:", key.publicKey.rawRepresentation.base64EncodedString())
} else if let path = args.first {
    let file = URL(fileURLWithPath: path)
    let signature = try loadKey().signature(for: Data(contentsOf: file))
    try signature.write(to: file.appendingPathExtension("sig"))
    print("Signed \(file.lastPathComponent) → \(file.lastPathComponent).sig")
} else {
    print("usage: sign-release.swift --generate | <archive>")
    exit(2)
}
