import Foundation

/// An app task on the desk display.
public struct DeskTask: Equatable, Sendable {
    public var id: Int
    public var package: String

    public init(id: Int, package: String) {
        self.id = id
        self.package = package
    }
}

/// Desk mode's Overview. Android has no Recents screen on a virtual display: the Recents key
/// and the swipe-and-hold gesture did nothing there (checked with `input -d <id> keyevent
/// KEYCODE_APP_SWITCH` on the Pixel). The Mac lists the display's tasks and draws its own.
public enum DeskTasks {
    public static func listArguments(serial: String) -> [String] {
        ["-s", serial, "shell", "dumpsys", "activity", "activities"]
    }

    /// Closes a task. A standard app task is its own root task, so `am stack remove` takes it.
    public static func removeArguments(serial: String, taskId: Int) -> [String] {
        ["-s", serial, "shell", "am", "stack", "remove", "\(taskId)"]
    }

    /// App tasks on `displayId`, front first, from `dumpsys activity activities`. The section
    /// looks like:
    ///
    ///     Display #57 (activities from top to bottom):
    ///       * Task{fa6983c #3318 type=standard A=10220:com.android.chrome U=0 ...}
    ///         topResumedActivity=ActivityRecord{38586927 u0 com.android.chrome/org.chromium...}
    ///         * Hist  #0: ActivityRecord{38586927 u0 com.android.chrome/org.chromium... t3318}
    ///
    /// Home tasks (`type=home`) are left out. The package comes from the task's first activity,
    /// since `A=` holds the task affinity, which an app may set to any name.
    public static func parse(_ dump: String, displayId: Int) -> [DeskTask] {
        var tasks: [DeskTask] = []
        var inDisplay = false
        var pendingTask: Int?
        for line in dump.split(separator: "\n") {
            if line.hasPrefix("Display #") {
                inDisplay = line.hasPrefix("Display #\(displayId) ")
                pendingTask = nil
                continue
            }
            guard inDisplay else { continue }
            // Top-level tasks sit two spaces in; nested ones (inside home) deeper.
            if line.hasPrefix("  * Task{") {
                pendingTask = line.contains("type=standard") ? taskNumber(in: line) : nil
                continue
            }
            if let id = pendingTask, let package = activityPackage(in: line) {
                pendingTask = nil
                if !tasks.contains(where: { $0.id == id }) { tasks.append(DeskTask(id: id, package: package)) }
            }
        }
        return tasks
    }

    /// `#3318` in a `Task{...}` line.
    static func taskNumber(in line: Substring) -> Int? {
        guard let hash = line.range(of: " #") else { return nil }
        return Int(line[hash.upperBound...].prefix { $0.isNumber })
    }

    /// `com.android.chrome` in `ActivityRecord{38586927 u0 com.android.chrome/...`.
    static func activityPackage(in line: Substring) -> String? {
        guard let record = line.range(of: "ActivityRecord{") else { return nil }
        let fields = line[record.upperBound...].split(separator: " ")
        guard fields.count >= 3, let slash = fields[2].firstIndex(of: "/") else { return nil }
        return String(fields[2][..<slash])
    }
}
