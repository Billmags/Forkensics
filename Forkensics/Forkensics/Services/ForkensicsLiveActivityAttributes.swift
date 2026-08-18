import ActivityKit
import Foundation

struct ForkensicsCaseActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let status: String
    }

    let caseID: String
    let caseTitle: String
    let posterName: String
    let revealAt: Date
    let thumbnailData: Data
}
