// Ed25519 signing for release archives (verified by the in-app updater).
//   swift scripts/sign-release.swift <file.zip>     write <file.zip>.sig
// Key source: $EQUINOX_SIGNING_KEY (base64 raw key; set from the EQUINOX_RELEASE_SIGNING_KEY repo secret in CI),
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

guard let path = CommandLine.arguments.dropFirst().first else { fail("usage: sign-release.swift <archive>") }
let file = URL(fileURLWithPath: path)
let key = loadKey()
guard key.publicKey.rawRepresentation == embeddedPublicKey() else {
    fail("This signing key doesn't match the public key embedded in the app; the updater would reject the release.")
}
let signature = try key.signature(for: Data(contentsOf: file))
try signature.write(to: file.appendingPathExtension("sig"))
print("Signed \(file.lastPathComponent) → \(file.lastPathComponent).sig")
