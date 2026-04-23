import Testing
@testable import SoundManager

@Suite
@MainActor
struct PermissionCheckerTests {
    @Test
    func audioCaptureStatus_isNotRequiredAtM3() {
        let checker = PermissionChecker()
        #expect(checker.audioCaptureStatus() == .notRequired)
    }

    @Test
    func allRequiredGranted_isTrueWhenAllNotRequired() {
        let checker = PermissionChecker()
        #expect(checker.allRequiredGranted())
    }

    @Test
    func systemSettingsURL_hasExpectedScheme() {
        let url = PermissionChecker.systemSettingsURL(for: "Microphone")
        #expect(url?.scheme == "x-apple.systempreferences")
        #expect(url?.absoluteString.contains("Privacy_Microphone") == true)
    }
}
