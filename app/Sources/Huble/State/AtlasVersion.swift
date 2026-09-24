import Foundation

/// Atlas plugin versions look like `2026.9.23-35`: numeric parts split on
/// "." and "-", missing parts count as 0, a non-numeric part means "cannot
/// compare" (nil) and clients then show no update button. Same rule as the
/// plugin's Get Started (huble-pipeline/scripts/atlas-version.mjs).
enum AtlasVersion {
    static func compare(_ a: String, _ b: String) -> ComparisonResult? {
        guard let pa = parts(a), let pb = parts(b) else { return nil }
        let n = max(pa.count, pb.count)
        for i in 0..<n {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x < y { return .orderedAscending }
            if x > y { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func parts(_ v: String) -> [Int]? {
        var out: [Int] = []
        for p in v.split(whereSeparator: { $0 == "." || $0 == "-" }) {
            guard let n = Int(p) else { return nil }
            out.append(n)
        }
        return out.isEmpty ? nil : out
    }
}
