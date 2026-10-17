import Foundation
import CryptoKit

struct LooiFirmwareCache {
    let directory: URL
    static func allowsUpdate(_ manifest: [String: Any], includePreview: Bool = false) -> Bool {
        let channel = manifest["channel"] as? String ?? "stable"
        return channel == "stable" || (channel == "preview" && includePreview)
    }
    static func verify(_ bytes: Data, manifest: [String: Any]) throws {
        guard ["stable", "preview"].contains(manifest["channel"] as? String ?? "stable") else { throw LooiError.message("升级通道无效") }
        guard manifest["chip"] as? String == "ESP32-S3", ((manifest["partition"] as? String == "app3M_fat9M_16MB" && (manifest["board"] as? String ?? "n16r8") == "n16r8") || (manifest["partition"] as? String == "looi_8m" && manifest["board"] as? String == "n8r8")), let size = manifest["size"] as? Int, (32...3145728).contains(size), let sha = manifest["sha256"] as? String, sha.count == 64, sha.allSatisfy({ $0.isHexDigit }) else { throw LooiError.message("固件版本或分区不兼容") }
        guard bytes.count == size, bytes.first == 0xe9 else { throw LooiError.message("固件大小校验失败") }
        guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == sha.lowercased() else { throw LooiError.message("固件 SHA-256 校验失败") }
    }
    func read() throws -> (manifest: [String: Any], bytes: Data)? {
        let meta = directory.appendingPathComponent("ready.json")
        guard FileManager.default.fileExists(atPath: meta.path) else { return nil }
        guard let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: meta)) as? [String: Any], let sha = manifest["sha256"] as? String, sha.count == 64, sha.allSatisfy({ $0.isHexDigit }) else { throw LooiError.message("固件缓存无效，请重新下载") }
        let image = directory.appendingPathComponent(sha.lowercased() + ".bin")
        let size = try image.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard (32...3145728).contains(size) else { throw LooiError.message("固件缓存无效，请重新下载") }
        let bytes = try Data(contentsOf: image); try Self.verify(bytes, manifest: manifest)
        return (manifest, bytes)
    }
    func save(_ bytes: Data, manifest: [String: Any]) throws {
        try Self.verify(bytes, manifest: manifest)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sha = (manifest["sha256"] as! String).lowercased()
        try bytes.write(to: directory.appendingPathComponent(sha + ".bin"), options: .atomic)
        try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("ready.json"), options: .atomic)
    }
}

// Compare version precedence independently of publication dates or build metadata.
func looiCompareVersions(_ lhs: String, _ rhs: String) -> Int {
    func parts(_ value: String) -> ([String], [String]?) {
        let text = (value.hasPrefix("v") ? String(value.dropFirst()) : value).components(separatedBy: "+")[0]
        let pair = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        return (pair[0].components(separatedBy: "."), pair.count > 1 ? pair[1].components(separatedBy: ".") : nil)
    }
    func numeric(_ s: String) -> Bool { !s.isEmpty && s.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } }
    func number(_ a: String, _ b: String) -> Int {
        let a = String(a.drop(while: { $0 == "0" })), b = String(b.drop(while: { $0 == "0" }))
        if a.count != b.count { return a.count > b.count ? 1 : -1 }
        return a == b ? 0 : (a > b ? 1 : -1)
    }
    let (a, ap) = parts(lhs), (b, bp) = parts(rhs)
    for i in 0..<max(a.count, b.count) {
        let n = number(i < a.count ? a[i] : "0", i < b.count ? b[i] : "0"); if n != 0 { return n }
    }
    guard let ap, let bp else { return ap == nil && bp == nil ? 0 : (ap == nil ? 1 : -1) }
    for i in 0..<min(ap.count, bp.count) where ap[i] != bp[i] {
        let an = numeric(ap[i]), bn = numeric(bp[i])
        if an && bn { return number(ap[i], bp[i]) }
        if an != bn { return an ? -1 : 1 }
        return ap[i] > bp[i] ? 1 : -1
    }
    return ap.count == bp.count ? 0 : (ap.count > bp.count ? 1 : -1)
}
