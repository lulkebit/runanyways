import Darwin
import Foundation

public protocol SleepOverrideJournal: AnyObject {
    /// Returns the original setting if a prior helper invocation still owns it.
    func recordedOriginalValue() throws -> Bool?
    /// Must durably record ownership before the helper changes system policy.
    func record(originalValue: Bool) throws
    /// Removes the record only after the system setting has been restored and verified.
    func clear() throws
}

/// Root-only recovery journal. O_NOFOLLOW, ownership/mode checks, and a private
/// parent directory prevent an unprivileged process from substituting a symlink.
public final class FileSleepOverrideJournal: SleepOverrideJournal {
    public static let directoryPath = "/private/var/db/RunAnyways"
    public static let filePath = directoryPath + "/sleep-override.json"
    private let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
    private let fileURL = URL(fileURLWithPath: filePath)

    public init() throws {
        try Self.ensureSecureDirectory()
    }

    public func recordedOriginalValue() throws -> Bool? {
        let descriptor = open(fileURL.path, O_RDONLY | O_NOFOLLOW)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw JournalError.systemCall("open", errno)
        }
        defer { _ = close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw JournalError.systemCall("fstat", errno)
        }
        try Self.validateFileMetadata(metadata)
        guard metadata.st_size > 0, metadata.st_size <= 1024 else {
            throw JournalError.invalidContents
        }

        var data = Data(count: Int(metadata.st_size))
        let bytesRead = data.withUnsafeMutableBytes { buffer in
            read(descriptor, buffer.baseAddress, buffer.count)
        }
        guard bytesRead == data.count else {
            throw JournalError.systemCall("read", errno)
        }
        guard let record = try? JSONDecoder().decode(JournalRecord.self, from: data), record.schemaVersion == 1 else {
            throw JournalError.invalidContents
        }
        return record.originalSleepDisabled
    }

    public func record(originalValue: Bool) throws {
        let data = try JSONEncoder().encode(JournalRecord(schemaVersion: 1, originalSleepDisabled: originalValue))
        let descriptor = open(fileURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else {
            throw JournalError.systemCall("create journal", errno)
        }
        var shouldUnlink = true
        defer {
            _ = close(descriptor)
            if shouldUnlink { _ = unlink(fileURL.path) }
        }

        let bytesWritten = data.withUnsafeBytes { buffer in
            write(descriptor, buffer.baseAddress, buffer.count)
        }
        guard bytesWritten == data.count else {
            throw JournalError.systemCall("write journal", errno)
        }
        guard fsync(descriptor) == 0 else {
            throw JournalError.systemCall("sync journal", errno)
        }
        try syncDirectory()
        shouldUnlink = false
    }

    public func clear() throws {
        var metadata = stat()
        guard lstat(fileURL.path, &metadata) == 0 else {
            if errno == ENOENT { return }
            throw JournalError.systemCall("lstat journal", errno)
        }
        try Self.validateFileMetadata(metadata)
        guard unlink(fileURL.path) == 0 else {
            throw JournalError.systemCall("unlink journal", errno)
        }
        try syncDirectory()
    }

    private static func ensureSecureDirectory() throws {
        for parentPath in ["/private", "/private/var", "/private/var/db"] {
            var parentMetadata = stat()
            guard lstat(parentPath, &parentMetadata) == 0,
                  (parentMetadata.st_mode & S_IFMT) == S_IFDIR,
                  parentMetadata.st_uid == 0,
                  (parentMetadata.st_mode & 0o022) == 0 else {
                throw JournalError.insecureDirectory(parentPath)
            }
        }

        if mkdir(directoryPath, mode_t(S_IRWXU)) != 0, errno != EEXIST {
            throw JournalError.systemCall("create journal directory", errno)
        }
        var directoryMetadata = stat()
        guard lstat(directoryPath, &directoryMetadata) == 0,
              (directoryMetadata.st_mode & S_IFMT) == S_IFDIR,
              directoryMetadata.st_uid == 0,
              (directoryMetadata.st_mode & 0o077) == 0 else {
            throw JournalError.insecureDirectory(directoryPath)
        }
        guard chmod(directoryPath, mode_t(S_IRWXU)) == 0 else {
            throw JournalError.systemCall("secure journal directory", errno)
        }
    }

    private static func validateFileMetadata(_ metadata: stat) throws {
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == 0,
              metadata.st_nlink == 1,
              (metadata.st_mode & 0o077) == 0 else {
            throw JournalError.insecureFile
        }
    }

    private func syncDirectory() throws {
        let descriptor = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw JournalError.systemCall("open journal directory", errno)
        }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw JournalError.systemCall("sync journal directory", errno)
        }
    }

    private struct JournalRecord: Codable {
        let schemaVersion: Int
        let originalSleepDisabled: Bool
    }
}

public enum JournalError: Error, LocalizedError {
    case insecureDirectory(String)
    case insecureFile
    case invalidContents
    case systemCall(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .insecureDirectory(let path): "The helper journal directory is not root-only: \(path)."
        case .insecureFile: "The helper journal is not a root-owned regular file with private permissions."
        case .invalidContents: "The helper recovery journal is corrupt or has an unsupported format."
        case .systemCall(let operation, let code): "Could not \(operation) for the helper journal (errno \(code))."
        }
    }
}
