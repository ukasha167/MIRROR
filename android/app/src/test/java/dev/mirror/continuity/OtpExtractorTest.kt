package dev.mirror.continuity

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Hardware-free unit tests for 2FA OTP regex and heuristic extraction.
 */
class OtpExtractorTest {

    @Test
    fun testStandardBankVerificationCode() {
        val snippet = "Your Chase verification code is 492019. Do not share this with anyone."
        val result = OtpExtractor.extract(snippet, "com.chase.sig.android")
        assertNotNull(result)
        assertEquals("492019", result?.code)
    }

    @Test
    fun testGooglePrefixedOtp() {
        val snippet = "G-948201 is your Google verification code."
        val result = OtpExtractor.extract(snippet, "com.google.android.apps.messaging")
        assertNotNull(result)
        assertEquals("948201", result?.code)
    }

    @Test
    fun testHyphenatedOtp() {
        val snippet = "Your security code is 123-456. Valid for 5 minutes."
        val result = OtpExtractor.extract(snippet, "com.whatsapp")
        assertNotNull(result)
        assertEquals("123456", result?.code)
    }

    @Test
    fun testSpanishLanguageOtp() {
        val snippet = "Su código de verificación de Santander es 849201."
        val result = OtpExtractor.extract(snippet, "com.santander.app")
        assertNotNull(result)
        assertEquals("849201", result?.code)
    }

    @Test
    fun testAuthAppKeyword() {
        val snippet = "Your authentication code: 582194"
        val result = OtpExtractor.extract(snippet, "com.github.android")
        assertNotNull(result)
        assertEquals("582194", result?.code)
    }

    @Test
    fun testExcludesDollarAmounts() {
        val snippet = "Your credit card transaction of $2500 USD was approved."
        val result = OtpExtractor.extract(snippet, "com.bank.app")
        assertNull(result)
    }

    @Test
    fun testExcludesStandaloneYears() {
        val snippet = "Welcome to the 2026 conference schedule!"
        val result = OtpExtractor.extract(snippet, "com.event.app")
        assertNull(result)
    }

    @Test
    fun testBlankOrNullInput() {
        assertNull(OtpExtractor.extract(null))
        assertNull(OtpExtractor.extract(""))
        assertNull(OtpExtractor.extract("   "))
    }
}
