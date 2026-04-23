import Testing
@testable import SoundManager

@Suite
struct ProcessGroupingTests {
    // MARK: - normalize

    @Test
    func normalize_stripsHelperSuffix() {
        #expect(ProcessGrouping.normalize("com.google.Chrome.helper") == "com.google.Chrome")
        #expect(ProcessGrouping.normalize("com.google.Chrome.helper.Renderer") == "com.google.Chrome")
        #expect(ProcessGrouping.normalize("com.hnc.Discord.helper") == "com.hnc.Discord")
        #expect(ProcessGrouping.normalize("com.anthropic.claudefordesktop.helper") == "com.anthropic.claudefordesktop")
    }

    @Test
    func normalize_keepsBundleIDsWithoutHelper() {
        #expect(ProcessGrouping.normalize("com.apple.Music") == "com.apple.Music")
        #expect(ProcessGrouping.normalize("com.google.Chrome") == "com.google.Chrome")
        #expect(ProcessGrouping.normalize("") == "")
    }

    // MARK: - isSystemBundle

    @Test
    func isSystemBundle_detectsCoreAudioAndControlCenter() {
        #expect(ProcessGrouping.isSystemBundle("com.apple.audio.coreaudiod"))
        #expect(ProcessGrouping.isSystemBundle("com.apple.audio.Core-Audio-Driver-Service.helper"))
        #expect(ProcessGrouping.isSystemBundle("com.apple.controlcenter"))
        #expect(ProcessGrouping.isSystemBundle("com.apple.loginwindow"))
        #expect(ProcessGrouping.isSystemBundle("com.apple.mediaremoted"))
        #expect(ProcessGrouping.isSystemBundle("systemsoundserverd"))
    }

    @Test
    func isSystemBundle_acceptsUserApps() {
        #expect(!ProcessGrouping.isSystemBundle("com.apple.Music"))
        #expect(!ProcessGrouping.isSystemBundle("com.google.Chrome"))
        #expect(!ProcessGrouping.isSystemBundle("com.hnc.Discord"))
        #expect(!ProcessGrouping.isSystemBundle("com.anthropic.claudefordesktop"))
    }

    // MARK: - buildActiveApps

    @Test
    func buildActiveApps_groupsHelpersExcludesSystemAndResolvesNames() {
        let clients = [
            ActiveClient(pid: 100, bundleID: "com.google.Chrome.helper"),
            ActiveClient(pid: 101, bundleID: "com.google.Chrome.helper.Renderer"),
            ActiveClient(pid: 200, bundleID: "com.apple.Music"),
            ActiveClient(pid: 300, bundleID: "com.apple.controlcenter"),
            ActiveClient(pid: 400, bundleID: "systemsoundserverd"),
            ActiveClient(pid: 500, bundleID: "com.unknown.app"),
            ActiveClient(pid: 600, bundleID: ""),
        ]
        let apps = ProcessGrouping.buildActiveApps(from: clients) { bundleID in
            switch bundleID {
            case "com.google.Chrome": return ("Google Chrome", nil)
            case "com.apple.Music": return ("ミュージック", nil)
            default: return nil
            }
        }

        // 期待: Chrome (helper 統合), Music, Unknown の 3 件
        // 除外: controlcenter, systemsoundserverd, 空 bundleID
        #expect(apps.count == 3)

        let chrome = apps.first(where: { $0.bundleID == "com.google.Chrome" })
        #expect(chrome?.pids == [100, 101])
        #expect(chrome?.displayName == "Google Chrome")

        let music = apps.first(where: { $0.bundleID == "com.apple.Music" })
        #expect(music?.pids == [200])
        #expect(music?.displayName == "ミュージック")

        let unknown = apps.first(where: { $0.bundleID == "com.unknown.app" })
        #expect(unknown?.pids == [500])
        #expect(unknown?.displayName == "com.unknown.app")  // fallback to bundleID
    }

    @Test
    func buildActiveApps_sortsByDisplayName() {
        let clients = [
            ActiveClient(pid: 1, bundleID: "com.z.zero"),
            ActiveClient(pid: 2, bundleID: "com.a.apple"),
            ActiveClient(pid: 3, bundleID: "com.m.middle"),
        ]
        let apps = ProcessGrouping.buildActiveApps(from: clients) { bundleID in
            switch bundleID {
            case "com.z.zero": return ("Zero", nil)
            case "com.a.apple": return ("Apple", nil)
            case "com.m.middle": return ("Middle", nil)
            default: return nil
            }
        }
        #expect(apps.map(\.displayName) == ["Apple", "Middle", "Zero"])
    }

    @Test
    func buildActiveApps_emptyInputReturnsEmpty() {
        let apps = ProcessGrouping.buildActiveApps(from: []) { _ in nil }
        #expect(apps.isEmpty)
    }

    @Test
    func buildActiveApps_excludesSelfBundle() {
        let clients = [
            ActiveClient(pid: 100, bundleID: "io.github.uta-a.SoundManager"),
            ActiveClient(pid: 200, bundleID: "com.apple.Music"),
        ]
        let apps = ProcessGrouping.buildActiveApps(
            from: clients,
            excludingBundleIDs: ["io.github.uta-a.SoundManager"]
        ) { bundleID in
            bundleID == "com.apple.Music" ? ("ミュージック", nil) : nil
        }
        #expect(apps.count == 1)
        #expect(apps.first?.bundleID == "com.apple.Music")
    }
}
