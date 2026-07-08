import Foundation
import CryptoKit

// MARK: - Offline redeem codes

/// Fully offline promotional unlock codes — giveaways, press, friends,
/// testing. No server, no network call (preserves the app's zero-data-
/// collection posture, see docs/SECURITY_AUDIT.md).
///
/// Two tiers, checked in order:
/// 1. A tiny hardcoded allowlist of memorable literal codes handed out
///    personally.
/// 2. A checksum-validated format, `MOSHPIT-XXXX-XXXX`, where the last group
///    is a truncated keyed hash (HMAC-SHA256, fixed local secret) of the
///    first group. Unlimited unique-looking codes can be generated offline
///    with the same function; holding ONE valid code doesn't let someone
///    derive others without the secret.
///
/// SECURITY TRADEOFF — INTENTIONAL, NOT A BUG: this is soft security. The
/// secret ships inside the binary, so a determined person could extract it
/// (or brute-force the 20-bit checksum), and with no server there is no
/// usage-count or single-redemption enforcement — one valid code can be
/// shared and reused across devices. That is an accepted cost of staying
/// fully offline: these codes protect a $5 promotional unlock (only
/// save-to-Photos is gated), not significant revenue.
enum RedeemCodes {

    /// Memorable codes handed out personally. Uppercased, no separators.
    private static let allowlist: Set<String> = [
        "MOSHPITFRIEND",
        "MOSHPITPRESS2026",
    ]

    /// Fixed local secret for the keyed checksum. Compiled into the binary
    /// by design (see the soft-security note above).
    private static let secret = "moshpit-redeem-v1-7d2f9a41"

    /// Base32-ish alphabet (RFC 4648, no 0/1/8/9 lookalike digits).
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    /// Validates a user-entered string. Whitespace-trimmed and uppercased
    /// before checking, so entry is forgiving.
    static func isValid(_ input: String) -> Bool {
        let code = normalize(input)
        if allowlist.contains(code) { return true }
        // MOSHPIT-XXXX-XXXX: payload group + checksum group.
        let parts = code.split(separator: "-").map(String.init)
        guard parts.count == 3, parts[0] == "MOSHPIT",
              parts[1].count == 4, parts[2].count == 4,
              parts[1].allSatisfy({ alphabet.contains($0) }) else { return false }
        return checksum(payload: parts[1]) == parts[2]
    }

    static func normalize(_ input: String) -> String {
        input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// 4-char truncated keyed hash of the payload group.
    static func checksum(payload: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: key)
        return String(Data(mac).prefix(4).map { alphabet[Int($0 % 32)] })
    }

    #if DEBUG
    /// Generator for handing out codes. Callable from the debugger or a
    /// throwaway test, or replicate offline with this standalone script
    /// (same secret + alphabet, run `swift gencode.swift GIGS VJ42` —
    /// payloads are 4 chars from the alphabet, so no 0/1/8/9):
    ///
    ///     import Foundation
    ///     import CryptoKit
    ///     let secret = "moshpit-redeem-v1-7d2f9a41"
    ///     let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    ///     for payload in CommandLine.arguments.dropFirst() {
    ///         let key = SymmetricKey(data: Data(secret.utf8))
    ///         let mac = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: key)
    ///         let check = String(Data(mac).prefix(4).map { alphabet[Int($0 % 32)] })
    ///         print("MOSHPIT-\(payload)-\(check)")
    ///     }
    ///
    /// Example valid codes: MOSHPIT-GIGS-LSJL, MOSHPIT-VJ42-P3V5,
    /// MOSHPIT-TEST-6LJ3, MOSHPIT-MOSH-BE5I.
    static func generate(payload: String) -> String {
        let p = normalize(payload)
        precondition(p.count == 4 && p.allSatisfy { alphabet.contains($0) },
                     "payload must be 4 chars from \(String(alphabet))")
        return "MOSHPIT-\(p)-\(checksum(payload: p))"
    }
    #endif
}
