import CryptoKit
import Foundation
import Security

struct UpdateVersion: Comparable, CustomStringConvertible {
    private let components: [Int]

    init?(_ value: String) {
        let version = value.hasPrefix("v") ? value.dropFirst() : value[...]
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({
            !$0.isEmpty && ($0.count == 1 || $0.first != "0") && $0.utf8.allSatisfy { (48...57).contains($0) }
        }) else { return nil }
        let numbers = parts.compactMap { Int32($0).map(Int.init) }
        guard numbers.count == 3 else { return nil }
        components = numbers
    }

    var description: String { components.map(String.init).joined(separator: ".") }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.components.lexicographicallyPrecedes(rhs.components) }
}

struct UpdateOffer {
    let version: UpdateVersion
    let download: URL
    let page: URL
    let sha256: String
    let size: Int64
}

enum UpdaterError: LocalizedError {
    case invalidResponse, invalidPackage, wrongIdentity, cannotReplace

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "无法读取 GitHub 上的更新信息，请稍后重试。"
        case .invalidPackage: return "更新包的大小、校验值或版本有误。原应用可以继续使用。"
        case .wrongIdentity: return "新版的应用标识或签名与当前安装不符，请从 GitHub 手动更新。"
        case .cannotReplace: return "当前应用位置无法自动替换，请从 GitHub 下载新版后手动更新。"
        }
    }
}

private final class UpdateRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, url.scheme == "https", url.port == nil,
              let host = url.host, ["api.github.com", "github.com", "release-assets.githubusercontent.com",
                                  "objects.githubusercontent.com"].contains(host) else { return nil }
        return request
    }
}

enum GitHubUpdater {
    static let releasePage = URL(string: "https://github.com/neowangx/suixinjie/releases")!
    private static let endpoint = URL(string: "https://api.github.com/repos/neowangx/suixinjie/releases/latest")!
    private static let limit: Int64 = 64 * 1024 * 1024
    private static let appName = "随心截.app"
    private static let entries = ["Contents/Info.plist", "Contents/MacOS/Suixinjie",
                                  "Contents/Resources/AppIcon.icns", "Contents/_CodeSignature/CodeResources"]
    #if arch(arm64)
    static let assetName = "Suixinjie-macos-arm64.zip"
    #else
    static let assetName = "Suixinjie-macos-x86_64.zip"
    #endif

    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    private struct Asset: Decodable {
        let name: String
        let browser_download_url: String
        let digest: String?
        let size: Int64
        let state: String
    }

    static func offer(from data: Data, installed: UpdateVersion, assetName: String) throws -> UpdateOffer? {
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, !release.prerelease, let version = UpdateVersion(release.tag_name),
              installed < version else { return nil }
        let root = releasePage.absoluteString
        let assetURL = "\(root)/download/\(release.tag_name)/\(assetName)"
        guard let asset = release.assets.first(where: { $0.name == assetName && $0.state == "uploaded" }) else { return nil }
        guard asset.browser_download_url == assetURL, let download = URL(string: assetURL),
              let digest = asset.digest, digest.hasPrefix("sha256:"),
              digest.utf8.count == 71, digest.dropFirst(7).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              asset.size > 0, asset.size <= limit,
              let page = URL(string: "\(root)/tag/\(release.tag_name)") else { throw UpdaterError.invalidPackage }
        return UpdateOffer(version: version, download: download, page: page, sha256: String(digest.dropFirst(7)), size: asset.size)
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 120
        configuration.httpAdditionalHeaders = ["User-Agent": "Suixinjie-Updater"]
        return URLSession(configuration: configuration, delegate: UpdateRedirects(), delegateQueue: nil)
    }()

    static func latest(installed: UpdateVersion) async throws -> UpdateOffer? {
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdaterError.invalidResponse }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw UpdaterError.invalidResponse }
        return try offer(from: body, installed: installed, assetName: assetName)
    }

    static func prepareAndLaunch(_ update: UpdateOffer, replacing installed: URL) async throws {
        let files = FileManager.default
        let parent = installed.deletingLastPathComponent()
        guard installed.pathExtension == "app", !installed.path.contains("/AppTranslocation/"),
              files.isWritableFile(atPath: parent.path), files.isWritableFile(atPath: installed.path),
              try installed.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw UpdaterError.cannotReplace
        }
        let (archive, response) = try await session.download(from: update.download)
        defer { try? files.removeItem(at: archive) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdaterError.invalidResponse }
        try installArchive(archive, update: update, replacing: installed)
    }

    static func installArchive(_ archive: URL, update: UpdateOffer, replacing installed: URL) throws {
        try verifyArchive(archive, size: update.size, sha256: update.sha256)
        let files = FileManager.default
        let parent = installed.deletingLastPathComponent()
        let stage = parent.appendingPathComponent(".suixinjie-update-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let candidate = try unpack(archive, in: stage, version: update.version)
            try validateSignature(candidate, replacing: installed)
            try launchInstaller(stage: stage, candidate: candidate, installed: installed)
        } catch {
            try? files.removeItem(at: stage)
            throw error
        }
    }

    static func verifyArchive(_ archive: URL, size: Int64, sha256: String) throws {
        guard let actualSize = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              actualSize == size else { throw UpdaterError.invalidPackage }
        let reader = try FileHandle(forReadingFrom: archive)
        defer { try? reader.close() }
        var hash = SHA256()
        while let block = try reader.read(upToCount: 64 * 1024), !block.isEmpty { hash.update(data: block) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw UpdaterError.invalidPackage
        }
    }

    static func unpack(_ archive: URL, in stage: URL, version: UpdateVersion) throws -> URL {
        let files = FileManager.default
        let candidate = stage.appendingPathComponent(appName, isDirectory: true)
        for entry in entries {
            let target = candidate.appendingPathComponent(entry)
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard files.createFile(atPath: target.path, contents: nil) else { throw UpdaterError.invalidPackage }
            try unpackEntry("\(appName)/\(entry)", from: archive, to: target)
            if entry == "Contents/MacOS/Suixinjie" {
                try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            }
        }
        let info = try Data(contentsOf: candidate.appendingPathComponent("Contents/Info.plist"))
        guard let values = try PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any],
              values["CFBundleShortVersionString"] as? String == version.description else { throw UpdaterError.invalidPackage }
        guard values["CFBundleIdentifier"] as? String == "app.suixinjie.macos",
              values["CFBundleExecutable"] as? String == "Suixinjie" else { throw UpdaterError.wrongIdentity }
        return candidate
    }

    private static func unpackEntry(_ entry: String, from archive: URL, to target: URL) throws {
        // Extract fixed files to destinations controlled by the updater, never by archive paths.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", archive.path, entry]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let writer = try FileHandle(forWritingTo: target)
        defer { try? writer.close() }
        try process.run()
        do {
            var written: Int64 = 0
            while let data = try pipe.fileHandleForReading.read(upToCount: 64 * 1024), !data.isEmpty {
                written += Int64(data.count)
                guard written <= limit else { throw UpdaterError.invalidPackage }
                try writer.write(contentsOf: data)
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0, written > 0 else { throw UpdaterError.invalidPackage }
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw error
        }
    }

    static func validateSignature(_ candidate: URL, replacing installed: URL) throws {
        var old: SecStaticCode?
        var fresh: SecStaticCode?
        guard SecStaticCodeCreateWithPath(installed as CFURL, [], &old) == errSecSuccess, let old,
              SecStaticCodeCreateWithPath(candidate as CFURL, [], &fresh) == errSecSuccess, let fresh else {
            throw UpdaterError.wrongIdentity
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(old, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let signing = info as? [String: Any] else { throw UpdaterError.wrongIdentity }
        var requirement: SecRequirement?
        if let certs = signing[kSecCodeInfoCertificates as String] as? [SecCertificate], !certs.isEmpty {
            guard SecCodeCopyDesignatedRequirement(old, [], &requirement) == errSecSuccess, requirement != nil else {
                throw UpdaterError.wrongIdentity
            }
        }
        let options = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCheckValidity(fresh, options, requirement) == errSecSuccess else { throw UpdaterError.wrongIdentity }
    }

    private static func launchInstaller(stage: URL, candidate: URL, installed: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", """
            set -eu
            pid="$1"; stage="$2"; candidate="$3"; installed="$4"; backup="$stage/previous.app"
            i=0
            while kill -0 "$pid" 2>/dev/null; do
                i=$((i+1))
                if [ "$i" -ge 60 ]; then /bin/rm -rf "$stage"; exit 1; fi
                /bin/sleep 0.5
            done
            failed() {
                /usr/bin/open -n "$installed" 2>/dev/null || true
                /usr/bin/osascript -e 'display alert "随心截更新失败" message "请从 GitHub 下载新版后手动更新。"' || true
            }
            if ! /bin/mv "$installed" "$backup"; then
                /bin/rm -rf "$stage"
                failed
                exit 1
            fi
            if /bin/mv "$candidate" "$installed"; then
                if /usr/bin/open -n "$installed"; then /bin/rm -rf "$stage"; exit 0; fi
                /bin/mv "$installed" "$candidate" || { failed; exit 1; }
            fi
            if /bin/mv "$backup" "$installed"; then /bin/rm -rf "$stage"; fi
            failed
            exit 1
            """, "suixinjie-updater", String(ProcessInfo.processInfo.processIdentifier),
            stage.path, candidate.path, installed.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
