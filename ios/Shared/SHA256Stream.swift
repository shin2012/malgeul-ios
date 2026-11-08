import Foundation
import CryptoKit

enum SHA256Stream {
    /// 큰 파일도 메모리에 다 올리지 않고 4MB씩 읽어 해시
    static func hex(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            let chunk = autoreleasepool { h.readData(ofLength: 4 * 1024 * 1024) }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
