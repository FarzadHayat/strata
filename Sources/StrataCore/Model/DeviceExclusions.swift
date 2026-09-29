/// Matching rule for `(defcfg exclude-devices …)`: an entry names one keyboard product, and matches
/// only when the whole product name is equal, ignoring case. Partial names never match, so
/// “Keychron K2” cannot accidentally cover “Keychron K2 Pro”.
public enum DeviceExclusions {
    public static func matches(product: String, excludes: [String]) -> Bool {
        guard !product.isEmpty else { return false }
        return excludes.contains { $0.caseInsensitiveCompare(product) == .orderedSame }
    }
}
