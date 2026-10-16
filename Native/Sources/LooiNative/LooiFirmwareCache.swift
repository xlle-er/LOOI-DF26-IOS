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
