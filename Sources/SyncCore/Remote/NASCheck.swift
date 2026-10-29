import Foundation

/// The step-by-step connection checklist shown when the NAS can't be reached.
public enum NASCheck {
    public struct Step: Sendable, Equatable, Codable {
        public enum State: String, Sendable, Codable { case ok, failed, skipped }
        public var title: String
        public var state: State
        public var detail: String?

        public init(title: String, state: State, detail: String?) {
            self.title = title
            self.state = state
            self.detail = detail
        }
    }

    public static func diagnose(_ nas: NAS, wifiName: String?, homeWiFi: String) -> [Step] {
        var steps: [Step] = []
        let onHome = wifiName == homeWiFi
        steps.append(Step(title: "On the home Wi-Fi", state: onHome ? .ok : .failed,
                          detail: onHome ? homeWiFi : (wifiName.map { "Connected to \($0)" } ?? "Wi-Fi name unknown")))
        guard onHome else { return steps }
        let hasRsync = nas.rsync != nil
        steps.append(Step(title: "rsync 3 installed", state: hasRsync ? .ok : .failed,
                          detail: hasRsync ? nas.rsync?.path(percentEncoded: false) : Rsync.missingMessage))
        guard hasRsync else {
            steps.append(Step(title: "Sync skipped", state: .skipped, detail: nil))
            return steps
        }
        switch nas.check() {
        case .success:
            steps.append(Step(title: "NAS answers over SSH", state: .ok, detail: nas.config.host))
            steps.append(Step(title: "Backup folder found", state: .ok, detail: nas.config.path))
        case .failure(let problem):
            switch problem {
            case .pathMissing:
                steps.append(Step(title: "NAS answers over SSH", state: .ok, detail: nas.config.host))
                steps.append(Step(title: "Backup folder found", state: .failed, detail: problem.description))
            default:
                steps.append(Step(title: "NAS answers over SSH", state: .failed, detail: problem.description))
            }
            steps.append(Step(title: "Sync skipped", state: .skipped, detail: nil))
        }
        return steps
    }
}
