import Testing
import Foundation
@testable import MirrorCoreBridge

@Suite("2FA OTP Extractor Tests")
struct OTPExtractorTests {
    let extractor = OTPExtractor()

    @Test("Extracts standard 6-digit codes with service context")
    func testExtractStandardCodes() {
        let text1 = "Your Google verification code is 849201. Never share this code."
        let otp1 = extractor.extractOTP(from: text1)
        #expect(otp1 != nil)
        #expect(otp1?.code == "849201")
        #expect(otp1?.service == "Google")

        let text2 = "Use 391820 to log in to your GitHub account."
        let otp2 = extractor.extractOTP(from: text2)
        #expect(otp2 != nil)
        #expect(otp2?.code == "391820")
        #expect(otp2?.service == "GitHub")

        let text3 = "Your Bank security passcode is 502914"
        let otp3 = extractor.extractOTP(from: text3)
        #expect(otp3 != nil)
        #expect(otp3?.code == "502914")
        #expect(otp3?.service == "Bank")
    }

    @Test("Extracts hyphenated 6-digit codes")
    func testExtractHyphenatedCodes() {
        let text = "Your Microsoft one-time passcode is 492-108"
        let otp = extractor.extractOTP(from: text)
        #expect(otp != nil)
        #expect(otp?.code == "492108")
        #expect(otp?.service == "Microsoft")
    }

    @Test("Rejects text without verification context")
    func testRejectsNonOTPText() {
        let text = "Meeting at 1400 on 5th Avenue with John."
        let otp = extractor.extractOTP(from: text)
        #expect(otp == nil)
    }

    @Test("Enforces 60-second expiration window")
    func testOTPExpiration() {
        let now = Date()
        let event = OTPEvent(code: "123456", service: "Test", originalText: "Code 123456", receivedAt: now)

        // At 30 seconds: still valid
        let after30s = now.addingTimeInterval(30)
        #expect(!event.isExpired(at: after30s))
        #expect(event.remainingSeconds(at: after30s) > 25.0)

        // At 61 seconds: expired
        let after61s = now.addingTimeInterval(61)
        #expect(event.isExpired(at: after61s))
        #expect(event.remainingSeconds(at: after61s) == 0.0)
    }
}
