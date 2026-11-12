import Darwin
import Foundation
import Testing
@testable import WombatCore

struct StorageBoundaryTests {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Wombat-storage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func existingDatabaseAndDirectoryPermissionsAreMadePrivate() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("usage.sqlite")
        do { _ = try UsageLedger(location: .file(file)) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let before = try Data(contentsOf: file)
        do { _ = try UsageLedger(location: .file(file)) }
        #expect(try Data(contentsOf: file) == before)
        for (url, expected) in [(folder, 0o700), (file, 0o600)] {
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            #expect(permissions?.intValue == expected)
        }
    }

    @Test func databaseLinksAndNonregularFilesAreRejectedWithoutChangingTargets() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("target"), file = folder.appendingPathComponent("usage.sqlite")
        let sentinel = Data("unchanged fixture".utf8)
        try sentinel.write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        #expect(throws: UsageError.self) { _ = try UsageLedger(location: .file(file)) }
        try FileManager.default.removeItem(at: file)
        try FileManager.default.linkItem(at: target, to: file)
        #expect(throws: UsageError.self) { _ = try UsageLedger(location: .file(file)) }
        try FileManager.default.removeItem(at: file)
        #expect(mkfifo(file.path, 0o600) == 0)
        #expect(throws: UsageError.self) { _ = try UsageLedger(location: .file(file)) }
        #expect(try Data(contentsOf: target) == sentinel)
        let permissions = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o644)
    }

    @Test func linkedParentAndSQLiteSidecarsAreRejected() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("real"), link = root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        #expect(throws: UsageError.self) { _ = try UsageLedger(location: .file(link.appendingPathComponent("usage.sqlite"))) }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("usage.sqlite").path))
        let target = root.appendingPathComponent("sentinel")
        let sentinel = Data("unchanged sidecar fixture".utf8)
        try sentinel.write(to: target)
        let file = folder.appendingPathComponent("usage.sqlite")
        for suffix in ["-journal", "-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: file.path + suffix)
            try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: target)
            #expect(throws: UsageError.self) { _ = try UsageLedger(location: .file(file)) }
            try FileManager.default.removeItem(at: sidecar)
            try FileManager.default.linkItem(at: target, to: sidecar)
            #expect(throws: UsageError.self) { _ = try UsageLedger(location: .file(file)) }
            try FileManager.default.removeItem(at: sidecar)
            #expect(mkfifo(sidecar.path, 0o600) == 0)
            #expect(throws: UsageError.self) { _ = try UsageLedger(location: .file(file)) }
            try FileManager.default.removeItem(at: sidecar)
        }
        #expect(try Data(contentsOf: target) == sentinel)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
