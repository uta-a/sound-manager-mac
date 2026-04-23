import SwiftUI

@main
struct SoundManagerApp: App {
    var body: some Scene {
        MenuBarExtra("SoundManager", systemImage: "speaker.wave.2.fill") {
            MenuBarView()
        }
        .menuBarExtraStyle(.window)

        Window("SoundManager セットアップ", id: "sound-manager.onboarding") {
            OnboardingView()
        }
        .windowResizability(.contentSize)
    }
}
