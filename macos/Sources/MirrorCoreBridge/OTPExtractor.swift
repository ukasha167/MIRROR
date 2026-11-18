import Foundation

#if canImport(AppKit)
import AppKit
#endif

/// Extracted 2FA One-Time Passcode event.
public struct OTPEvent: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let code: String
    public let service: String?
    public let originalText: String
    public let receivedAt: Date
    public let expiresAt: Date

    public init(
        id: UUID = UUID(),
        code: String,
        service: String?,
        originalText: String,
        receivedAt: Date = Date(),
        expirationSeconds: TimeInterval = 60.0
    ) {
        self.id = id
        self.code = code
        self.service = service
        self.originalText = originalText
        self.receivedAt = receivedAt
        self.expiresAt = receivedAt.addingTimeInterval(expirationSeconds)
    }

    /// Checks if the OTP code has passed its 60-second validity window.
    public func isExpired(at date: Date = Date()) -> Bool {
        date >= expiresAt
    }

    /// Seconds remaining before expiry, clamped to 0.
    public func remainingSeconds(at date: Date = Date()) -> TimeInterval {
        max(0.0, expiresAt.timeIntervalSince(date))
    }
}

/// Heuristic parser for extracting 2FA verification codes from SMS and notifications.
public final class OTPExtractor: Sendable {
    public init() {}

    // Regex pattern looking for 4-8 digit numeric codes or standard hyphenated (e.g. 123-456)
    // with context words indicating a verification code.
    private static let contextKeywords = [
        "code", "verification", "verify", "otp", "one-time", "passcode",
        "pin", "secret", "security", "confirm", "confirmation", "login",
        "log in", "log-in", "account", "auth", "two-factor", "2fa"
    ]

    private static let digitPattern = #"(?<!\d)(?:(?<prefix>\d{3})-(?<suffix>\d{3})|(?<code>\d{4,8}))(?!\d)"#

    private static let knownServices = [
        "Google", "GitHub", "Apple", "Microsoft", "Amazon", "Twitter",
        "Facebook", "Instagram", "WhatsApp", "Telegram", "Slack", "Discord",
        "Uber", "Lyft", "Coinbase", "Binance", "PayPal", "Stripe", "Bank"
    ]

    /// Extracts an OTP code and optional service name from notification or SMS body.
    public func extractOTP(from text: String, receivedAt: Date = Date()) -> OTPEvent? {
        let lowerText = text.lowercased()

        // 1. Must contain at least one context keyword
        let hasContext = Self.contextKeywords.contains { lowerText.contains($0) }
        guard hasContext else { return nil }

        // 2. Search for 4 to 8 digit numbers
        guard let regex = try? NSRegularExpression(pattern: Self.digitPattern, options: []) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)

        for match in matches {
            var extractedCode: String?
            if let codeRange = Range(match.range(withName: "code"), in: text) {
                extractedCode = String(text[codeRange])
            } else if let preRange = Range(match.range(withName: "prefix"), in: text),
                      let sufRange = Range(match.range(withName: "suffix"), in: text) {
                extractedCode = "\(text[preRange])\(text[sufRange])"
            }

            guard let code = extractedCode else { continue }

            // Filter out common false positives like years (e.g. 2024, 2025, 2026) if 4 digits
            if code.count == 4, let num = Int(code), num >= 1990 && num <= 2030 {
                // If it looks like a year, only accept if "code is" or "code:" appears right next to it
                let immediateContext = lowerText.contains("code is \(code)") ||
                                       lowerText.contains("code: \(code)") ||
                                       lowerText.contains("code: \(code)")
                if !immediateContext {
                    continue
                }
            }

            let service = detectService(in: text)
            return OTPEvent(
                code: code,
                service: service,
                originalText: text,
                receivedAt: receivedAt
            )
        }

        return nil
    }

    private func detectService(in text: String) -> String? {
        for service in Self.knownServices {
            if text.range(of: service, options: .caseInsensitive) != nil {
                return service
            }
        }
        return nil
    }

    /// Copies the extracted code directly to macOS NSPasteboard.
    #if canImport(AppKit)
    @MainActor
    public func copyToPasteboard(event: OTPEvent) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(event.code, forType: .string)
    }
    #endif
}
