import Foundation

/// Dotted numeric version comparison for release tags such as "v1.0.42".
public enum AppVersion {
    /// True when version `a` is strictly newer than `b` ("1.0.10" beats "1.0.9").
    /// A leading "v" and any "-suffix" are ignored; missing components count as 0.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            var s = s
            if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
            if let dash = s.firstIndex(of: "-") { s = String(s[..<dash]) }   // "1.0.5-dev"
            return s.split(separator: ".").map { Int($0) ?? 0 }
        }
        var x = parts(a), y = parts(b)
        while x.count < y.count { x.append(0) }
        while y.count < x.count { y.append(0) }
        for (p, q) in zip(x, y) where p != q { return p > q }
        return false
    }
}
