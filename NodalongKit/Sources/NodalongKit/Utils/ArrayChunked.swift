import Foundation

public extension Array {
    /// Splits the array into consecutive sub-arrays of at most `size` elements.
    ///
    /// Used to batch Firestore `in`-queries, which cap at 30 values per query
    /// (e.g. fetching many catalog docs by document id in one round-trip). A
    /// `size` of `0` or less returns a single chunk containing the whole array
    /// rather than trapping.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
