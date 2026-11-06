#if DEBUG
import AppKit
import Sparkle
import EasyMarkdownCore

/// Uses a separate application bundle / preferences domain prepared by check-updates.py.
/// Production builds contain neither this driver nor the local-feed test hooks.
@MainActor enum UpdateCheck {
    private static var driver: Driver?
    private static var updater: SPUUpdater?

    static func run(output: URL) async {
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let scenario = Bundle.main.object(forInfoDictionaryKey: "EasyMarkdownUpdateScenario") as? String ?? "configuration"
            if scenario == "relaunch" {
                let report: [String: Any] = ["result": "relaunched", "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("relaunch.json"), options: .atomic)
                NSApp.terminate(nil)
                return
            }
            if scenario == "configuration" {
                guard let app = NSApp.delegate as? AppDelegate,
                      let menu = NSApp.mainMenu?.items.first?.submenu,
                      menu.items.count > 1,
                      menu.items[1].title == L10n.text("检查更新…"),
                      menu.items[1].target === app.updates,
                      Bundle.main.object(forInfoDictionaryKey: "SURequireSignedFeed") as? Bool == true,
                      Bundle.main.object(forInfoDictionaryKey: "SUVerifyUpdateBeforeExtraction") as? Bool == true,
                      Bundle.main.object(forInfoDictionaryKey: "SUAllowsAutomaticUpdates") as? Bool == false,
                      UpdateController.unavailableReason(bundleURL: URL(fileURLWithPath: "/tmp/EasyMarkdown"), isReadOnly: false) != nil,
                      UpdateController.unavailableReason(bundleURL: URL(fileURLWithPath: "/Volumes/Test/EasyMarkdown.app"), isReadOnly: true) != nil,
                      UpdateController.unavailableReason(bundleURL: URL(fileURLWithPath: "/Applications/EasyMarkdown.app"), isReadOnly: false) == nil else {
                    throw SmokeCheck.Failure(message: "Update configuration, menu target or location guard failed")
                }
                try Data("{\"result\":\"configuration-passed\"}".utf8).write(to: output.appendingPathComponent("report.json"))
                NSApp.terminate(nil)
                return
            }
            guard Bundle.main.object(forInfoDictionaryKey: "EasyMarkdownUpdateFixture") as? Bool == true,
                  Bundle.main.bundleIdentifier?.hasPrefix("app.easymarkdown.updatecheck.") == true else {
                throw SmokeCheck.Failure(message: "Network and installation checks require an isolated test bundle")
            }
            if scenario == "standard-current" {
                try await checkStandardInterface(output: output)
                NSApp.terminate(nil)
                return
            }
            let driver = Driver(output: output, scenario: scenario)
            self.driver = driver
            if scenario == "controller" {
                guard let application = NSApp.delegate as? AppDelegate else {
                    throw SmokeCheck.Failure(message: "Missing shared application updater")
                }
                let updates = application.updates
                updates.start()
                updates.start()
                guard updates.notice == nil, updates.canCheckForUpdates else {
                    throw SmokeCheck.Failure(message: "Shared updater failed to start")
                }
                updates.setAutomaticallyChecks(false)
                guard !updates.automaticallyChecks else {
                    throw SmokeCheck.Failure(message: "Shared updater did not publish disabled preference")
                }
                updates.setAutomaticallyChecks(true)
                guard updates.automaticallyChecks,
                      UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") as? Bool == true else {
                    throw SmokeCheck.Failure(message: "Shared updater did not persist enabled preference")
                }
                driver.finish("controller-passed")
                return
            }
            try await driver.prepareDocument()
            let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: nil)
            self.updater = updater
            try updater.start()
            if scenario == "preferences-restored" {
                guard updater.automaticallyChecksForUpdates,
                      UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") as? Bool == true else {
                    throw SmokeCheck.Failure(message: "Update preference was not restored after restart")
                }
                driver.finish("preferences-restored")
                return
            }
            // Exercise persisted preferences without using the real application's domain.
            updater.automaticallyChecksForUpdates = false
            guard UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") as? Bool == false else {
                throw SmokeCheck.Failure(message: "Automatic update preference was not persisted")
            }
            if scenario == "preferences" {
                updater.automaticallyChecksForUpdates = true
                guard updater.updateCheckInterval == 86400, !updater.automaticallyDownloadsUpdates,
                      !updater.sendsSystemProfile, !updater.allowsAutomaticUpdates else {
                    throw SmokeCheck.Failure(message: "Unsafe automatic update defaults")
                }
                driver.finish("preferences-passed")
                return
            }
            updater.checkForUpdates()
        } catch {
            FileHandle.standardError.write(Data("UPDATE CHECK FAILED: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func checkStandardInterface(output: URL) async throws {
        guard let application = NSApp.delegate as? AppDelegate else {
            throw SmokeCheck.Failure(message: "Missing shared application updater")
        }
        application.updates.start()
        guard application.updates.notice == nil, application.updates.canCheckForUpdates else {
            throw SmokeCheck.Failure(message: "Standard update controller failed to start")
        }
        var completed = false
        var failure: Error?
        var ticks = 0
        // Sparkle uses an AppKit modal loop. A run-loop timer can observe and
        // acknowledge it while ordinary main-actor tasks are suspended.
        let timer = Timer(timeInterval: 0.1, repeats: true) { timer in
            MainActor.assumeIsolated {
                ticks += 1
                for window in NSApp.windows where window.isVisible {
                    guard let content = window.contentView else { continue }
                    let strings = Driver.descendants(content).compactMap { ($0 as? NSTextField)?.stringValue }
                    if strings.contains(where: { $0.localizedCaseInsensitiveContains("up to date") }) {
                        do {
                            if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                                content.cacheDisplay(in: content.bounds, to: bitmap)
                                try bitmap.representation(using: .png, properties: [:])?
                                    .write(to: output.appendingPathComponent("standard-current.png"))
                            }
                            let report: [String: Any] = ["result": "standard-current", "labels": strings]
                            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted])
                                .write(to: output.appendingPathComponent("report.json"))
                        } catch { failure = error }
                        completed = true
                        timer.invalidate()
                        NSApp.stopModal(withCode: .alertFirstButtonReturn)
                        window.orderOut(nil)
                        return
                    }
                }
                if ticks >= 300 {
                    failure = SmokeCheck.Failure(message: "Standard updater did not show the current-version alert")
                    completed = true
                    timer.invalidate()
                    NSApp.abortModal()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
        application.updates.checkForUpdates(nil)
        application.updates.checkForUpdates(nil)
        while !completed { try await Task.sleep(for: .milliseconds(100)) }
        if let failure { throw failure }
    }

    private final class Driver: NSObject, SPUUserDriver {
        let output: URL
        let scenario: String
        var events: [String] = []
        var finished = false
        var document: MarkdownDocument?

        init(output: URL, scenario: String) { self.output = output; self.scenario = scenario }

        func prepareDocument() async throws {
            guard ["save", "discard", "cancel", "save-failure"].contains(scenario) else { return }
            let url = output.appendingPathComponent("document.md")
            let original = Data("# Original\n".utf8)
            try original.write(to: url)
            let document = MarkdownDocument(snapshot: try FileSnapshot(data: original), url: url)
            self.document = document
            NSDocumentController.shared.addDocument(document)
            document.makeWindowControllers()
            document.showWindows()
            document.session.edit("# Modified\n")
            if scenario == "save-failure" {
                // A nonexistent parent causes the actual coordinated save to fail.
                document.fileURL = output.appendingPathComponent("missing/document.md")
            }
        }

        func record(_ event: String) {
            events.append(event)
            FileHandle.standardError.write(Data("UPDATE: \(event)\n".utf8))
        }

        func finish(_ result: String, error: NSError? = nil) {
            guard !finished else { return }
            finished = true
            document?.updateChangeCount(.changeCleared)
            document?.close()
            var report: [String: Any] = ["result": result, "events": events]
            if let error {
                report["error"] = error.localizedDescription
                report["errorCode"] = error.code
                report["errorDomain"] = error.domain
                report["errorDetails"] = String(describing: error)
            }
            do {
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("report.json"), options: .atomic)
            } catch { exit(1) }
            // Let acknowledgement and cancellation callbacks unwind first.
            Task { try? await Task.sleep(for: .milliseconds(250)); NSApp.terminate(nil) }
        }

        func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
            reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
        }
        func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { record("checking") }
        func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
            record("found:\(appcastItem.versionString)")
            if scenario == "found" { reply(.dismiss); finish("found") }
            else { reply(.install) }
        }
        func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
        func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
        func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
            record("not-found"); acknowledgement(); finish("not-found", error: error as NSError)
        }
        func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
            record("error"); acknowledgement(); finish("error", error: error as NSError)
        }
        func showDownloadInitiated(cancellation: @escaping () -> Void) { record("downloading") }
        func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
        func showDownloadDidReceiveData(ofLength length: UInt64) {}
        func showDownloadDidStartExtractingUpdate() { record("extracting") }
        func showExtractionReceivedProgress(_ progress: Double) {}
        func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
            record("ready-to-install")
            // Write evidence before the installer terminates this process.
            let report: [String: Any] = ["result": "ready-to-install", "events": events]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]) {
                try? data.write(to: output.appendingPathComponent("report.json"), options: .atomic)
            }
            reply(.install)
            if document != nil {
                Task {
                    do { try await handleSavePrompt() }
                    catch { finish("error", error: error as NSError) }
                }
            }
        }

        private func handleSavePrompt() async throws {
            guard let document, let window = document.windowControllers.first?.window else { return }
            var buttons: [NSButton] = []
            for _ in 0..<200 {
                if let content = window.attachedSheet?.contentView {
                    buttons = Self.descendants(content).compactMap { $0 as? NSButton }
                    if buttons.contains(where: { $0.title == "Save" }) { break }
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            let title = scenario == "cancel" ? "Cancel" : scenario == "discard" ? "Don’t Save" : "Save"
            guard let button = buttons.first(where: { $0.title.replacingOccurrences(of: "'", with: "’") == title }) else {
                throw SmokeCheck.Failure(message: "Installer did not show the document save prompt: \(buttons.map(\.title))")
            }
            record("save-prompt:\(scenario)")
            button.performClick(nil)
            guard scenario == "cancel" || scenario == "save-failure" else { return }
            for _ in 0..<150 {
                if scenario == "cancel", window.attachedSheet == nil { break }
                if scenario == "save-failure", document.session.saveFailure != nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard document.isDocumentEdited, document.session.state.text == "# Modified\n",
                  Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String == "24",
                  scenario != "save-failure" || document.session.saveFailure != nil else {
                throw SmokeCheck.Failure(message: "Canceled or failed save lost document edits")
            }
            record("edited-document-preserved")
            // Close a native save error alert, if AppKit presented one.
            if scenario == "save-failure", let sheet = window.attachedSheet,
               let content = sheet.contentView,
               let ok = Self.descendants(content).compactMap({ $0 as? NSButton }).first(where: { ["OK", "Cancel"].contains($0.title) }) {
                ok.performClick(nil)
            }
            // The pending installer may remain ready for a later quit. Verify the edited
            // document while this process is still alive, then clean up this test copy.
            finish(scenario == "cancel" ? "cancel-preserved" : "save-failure-preserved")
        }

        static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) { record("installing") }
        func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement(); finish("installed") }
        func dismissUpdateInstallation() { record("dismissed") }
    }
}
#endif
