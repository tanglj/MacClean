import Foundation

public enum FileSizeFormatter {
    public static func string(fromByteCount bytes: Int64) -> String {
        guard bytes != 0 else { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
