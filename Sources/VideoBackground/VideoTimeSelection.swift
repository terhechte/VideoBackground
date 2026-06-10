import AVFoundation
import Foundation

struct VideoTimeSelection: Sendable {
    let startSeconds: Double
    let durationSeconds: Double

    var endSeconds: Double {
        startSeconds + durationSeconds
    }

    var cmTimeRange: CMTimeRange {
        CMTimeRange(
            start: CMTime(seconds: startSeconds, preferredTimescale: 600),
            duration: CMTime(seconds: durationSeconds, preferredTimescale: 600)
        )
    }
}
