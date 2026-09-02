import Foundation

/// One completed job from /jobs/api/job-list. This is the record that answers
/// "who printed this" -- the fault history has no user attached to it.
struct JobRecord: Identifiable, Hashable, Sendable {
    let jobID: Int
    let type: String          // PRINT, COPY, SCAN, ...
    let userName: String
    let userID: String
    let state: String
    let created: Date?
    let completed: Date?
    let colour: String        // MONOCHROME / FULL_COLOR ...
    let mediumSize: String
    let sheets: Int?
    let impressions: Int?
    let copies: Int?
    let protocolName: String
    let fileName: String
    let fileNameHidden: Bool

    var id: Int { jobID }

    var isColour: Bool { colour.uppercased().contains("COLOR") && !colour.uppercased().contains("MONO") }

    var displayFile: String {
        if fileNameHidden || fileName.isEmpty || fileName.allSatisfy({ $0 == "*" }) {
            return "—"
        }
        return fileName
    }

    var displayUser: String {
        if !userName.isEmpty { return userName }
        return userID.isEmpty ? "—" : userID
    }
}

struct JobList: Decodable, Sendable {
    let supported: Bool
    /// True when more pages remain.
    let next: Bool
    let jobs: [JobRecord]

    private struct Wrapper: Decodable {
        let jobInfo: Info?
        enum CodingKeys: String, CodingKey { case jobInfo = "JobInfo" }

        struct Info: Decodable {
            let jobID: Int?
            let userJobType: String?
            let userName: String?
            let userID: String?
            let state: String?
            let created: String?
            let completed: String?
            let settingPrintColor: String?
            let settingMediumSize: String?
            let outputSheets: Int?
            let printImpressions: Int?
            let copiesRequested: Int?
            let netInProtocol: String?
            let netInFilename: String?
            let netInFilenameHide: Bool?

            enum CodingKeys: String, CodingKey {
                case jobID = "JobID", userJobType = "UserJobType"
                case userName = "UserName", userID = "UserID", state = "State"
                case created = "Created", completed = "Completed"
                case settingPrintColor = "SettingPrintColor"
                case settingMediumSize = "SettingMediumSize"
                case outputSheets = "OutputSheets", printImpressions = "PrintImpressions"
                case copiesRequested = "CopiesRequested"
                case netInProtocol = "NetInProtocol"
                case netInFilename = "NetInFilename", netInFilenameHide = "NetInFilenameHide"
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case supported = "Supported", next = "Next", jobs = "Jobs"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        supported = c.value(.supported, or: true)
        next = c.value(.next, or: false)
        let wrapped = c.value(.jobs, or: [Wrapper]())
        let iso = ISO8601DateFormatter()
        jobs = wrapped.compactMap { w in
            guard let i = w.jobInfo, let id = i.jobID else { return nil }
            return JobRecord(
                jobID: id,
                type: i.userJobType ?? "UNKNOWN",
                userName: i.userName ?? "",
                userID: i.userID ?? "",
                state: i.state ?? "",
                created: i.created.flatMap { iso.date(from: $0) },
                completed: i.completed.flatMap { iso.date(from: $0) },
                colour: i.settingPrintColor ?? "",
                mediumSize: i.settingMediumSize ?? "",
                sheets: i.outputSheets,
                impressions: i.printImpressions,
                copies: i.copiesRequested,
                protocolName: i.netInProtocol ?? "",
                fileName: i.netInFilename ?? "",
                fileNameHidden: i.netInFilenameHide ?? false)
        }
    }
}
