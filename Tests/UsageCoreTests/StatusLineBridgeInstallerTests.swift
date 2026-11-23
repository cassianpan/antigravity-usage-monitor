import Foundation
import XCTest
@testable import UsageCore

final class StatusLineBridgeInstallerTests: XCTestCase {
    func testDirectInstallAndUninstall() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agy-bridge-direct-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let settingsURL = tempDir.appendingPathComponent("settings.json")
        try "{\"verbosity\": \"medium\"}\n".write(to: settingsURL, atomically: true, encoding: .utf8)

        let installer = StatusLineBridgeInstaller(cliConfigDirectory: tempDir)
        XCTAssertEqual(installer.status(), .notInstalled(existingCommand: nil))

        let installed = try installer.install()
        XCTAssertEqual(installed, .installedDirect)
        XCTAssertEqual(installer.status(), .installedDirect)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installer.backupSettingsURL.path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installer.bridgeScriptURL.path))

        // Run the generated bridge script with sample stdin JSON and verify atomic snapshot write
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [installer.bridgeScriptURL.path]
        let inputPipe = Pipe()
        process.standardInput = inputPipe
        try process.run()
        let samplePayload = "{\"plan_tier\":\"Pro\",\"quota\":{\"gemini-weekly\":{\"remaining_fraction\":0.9}}}"
        inputPipe.fileHandleForWriting.write(Data(samplePayload.utf8))
        try inputPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let snapshot = QuotaEvaluator().loadSnapshot(from: installer.snapshotURL)
        XCTAssertEqual(snapshot?.planTier, "Pro")
        XCTAssertEqual(snapshot?.quota?["gemini-weekly"]?.remainingFraction, 0.9)

        // Uninstall restores settings without losing unrelated keys
        try installer.uninstall()
        XCTAssertEqual(installer.status(), .notInstalled(existingCommand: nil))
        let restoredData = try Data(contentsOf: settingsURL)
        let restoredJSON = try JSONSerialization.jsonObject(with: restoredData) as? [String: Any]
        XCTAssertEqual(restoredJSON?["verbosity"] as? String, "medium")
        XCTAssertNil(restoredJSON?["statusLine"])
    }

    func testChainsExistingCustomScriptAndRestores() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agy-bridge-chain-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let customScript = tempDir.appendingPathComponent("my-custom.sh")
        try "#!/bin/sh\ncat >/dev/null\necho 'CUSTOM_STATUS_OK'\n".write(to: customScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: customScript.path)

        let settingsURL = tempDir.appendingPathComponent("settings.json")
        let initialSettings: [String: Any] = [
            "statusLine": [
                "type": "command",
                "command": customScript.path,
                "padding": 1,
                "stack_with_default": false,
            ]
        ]
        let initialData = try JSONSerialization.data(withJSONObject: initialSettings, options: [.prettyPrinted])
        try initialData.write(to: settingsURL)

        let installer = StatusLineBridgeInstaller(cliConfigDirectory: tempDir)
        let installed = try installer.install()
        XCTAssertEqual(installed, .installedChained(originalCommand: customScript.path))

        // Execute bridge script and verify both snapshot creation AND original stdout forwarding
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [installer.bridgeScriptURL.path]
        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        try process.run()
        inPipe.fileHandleForWriting.write(Data("{\"email\":\"test@example.com\"}".utf8))
        try inPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(output, "CUSTOM_STATUS_OK")
        XCTAssertEqual(QuotaEvaluator().loadSnapshot(from: installer.snapshotURL)?.email, "test@example.com")

        // Uninstall restores the exact original statusLine config
        try installer.uninstall()
        let restoredData = try Data(contentsOf: settingsURL)
        let restoredJSON = try JSONSerialization.jsonObject(with: restoredData) as? [String: Any]
        let restoredStatusLine = restoredJSON?["statusLine"] as? [String: Any]
        XCTAssertEqual(restoredStatusLine?["command"] as? String, customScript.path)
        XCTAssertEqual(restoredStatusLine?["padding"] as? Int, 1)
        XCTAssertEqual(restoredStatusLine?["stack_with_default"] as? Bool, false)
    }
}
