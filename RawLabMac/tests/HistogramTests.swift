import RawLabKit
import Foundation

@main
struct HistogramTests {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        print("PASS: \(message)")
    }

    static func close(_ actual: Double, _ expected: Double, _ message: String) {
        check(abs(actual - expected) < 0.000001, message)
    }

    static func main() {
        let ratio = HistogramPresentation(bins: [[1], [100], []])
        close(ratio.normalizedBins[0][0], 0.01, "A count of one is one percent of a shared peak of one hundred")
        close(ratio.normalizedBins[1][0], 1, "The shared peak reaches the full histogram height")

        let sharedPeak = HistogramPresentation(bins: [[50], [0, 100], [0, 0, 25]])
        close(sharedPeak.peak, 100, "All channels use one shared linear peak")
        close(sharedPeak.normalizedBins[0][0], 0.5, "The red channel is scaled against the shared peak")
        close(sharedPeak.normalizedBins[2][2], 0.25, "The blue channel is scaled against the shared peak")

        var bins = Array(repeating: Array(repeating: 0.0, count: 256), count: 3)
        bins[0][10] = 1
        bins[1][10] = 1
        bins[2][10] = 1
        bins[0][11] = 1
        bins[1][11] = 1
        bins[0][12] = 1
        bins[2][12] = 1
        bins[1][13] = 1
        bins[2][13] = 1
        let overlaps = HistogramPresentation(bins: bins)
        check(overlaps.segments(at: 10).map(\.fill) == [.neutralGray],
              "Triple RGB overlap uses a neutral gray fill")
        check(overlaps.segments(at: 11).map(\.fill) == [.yellow],
              "Red and green overlap uses yellow")
        check(overlaps.segments(at: 12).map(\.fill) == [.magenta],
              "Red and blue overlap uses magenta")
        check(overlaps.segments(at: 13).map(\.fill) == [.cyan],
              "Green and blue overlap uses cyan")

        let malformed = HistogramPresentation(bins: [[.nan, -1, .infinity, 1], [2], [3], [4]])
        check(malformed.normalizedBins.count == 3 && malformed.normalizedBins.allSatisfy { $0.count == 256 },
              "Malformed input is bounded to three 256-bin channels")
        check(malformed.normalizedBins[0][0] == 0 && malformed.normalizedBins[0][1] == 0 &&
              malformed.normalizedBins[0][2] == 0,
              "Non-finite and negative counts are ignored")
        check(malformed.segments(at: -1).isEmpty && malformed.segments(at: 256).isEmpty,
              "Out-of-range bins produce no drawing segments")

        let empty = HistogramPresentation(bins: [])
        check(empty.peak == 1 && empty.segments(at: 0).isEmpty,
              "Empty histogram input stays safe and empty")
    }
}
