import Foundation
import Testing
@testable import MirrorDesk

struct CompanionSetupTests {
    let pmPath = "-s SER1 shell pm path dev.mirror.companion"
    let broadcast = "-s SER1 shell am broadcast -a dev.mirror.companion.APPROVE_NETWORK -n dev.mirror.companion/.CompanionReceiver"

    func granted(_ extra: [String: CommandResult]) -> [String: CommandResult] {
        var responses = extra
        responses[pmPath] = CommandResult(exitCode: 0, stdout: "package:/data/app/~~x/base.apk\n")
        for permission in CompanionSetup.permissions {
            responses["-s SER1 shell pm grant dev.mirror.companion \(permission)"] = CommandResult(exitCode: 0, stdout: "")
        }
        return responses
    }

    @Test("Grants the three permissions, then reads the approved network from am broadcast")
    func approves() async {
        let runner = ScriptedRunner(granted([
            broadcast: CommandResult(exitCode: 0, stdout: """
            Broadcasting: Intent { act=dev.mirror.companion.APPROVE_NETWORK flg=0x400000 cmp=dev.mirror.companion/.CompanionReceiver }
            Broadcast completed: result=-1, data="approved:HUAWEI-5G-9fDV"

            """),
        ]))
        let outcome = await CompanionSetup(adb: AdbClient(adbPath: "adb", runner: runner)).run(serial: "SER1")
        #expect(outcome == .approved(network: "HUAWEI-5G-9fDV"))
        let grants = runner.calls.filter { $0.contains("grant") }.map { $0.last ?? "" }
        #expect(grants == CompanionSetup.permissions)
    }

    @Test("A missing app is not an error and grants nothing")
    func notInstalled() async {
        let runner = ScriptedRunner([pmPath: CommandResult(exitCode: 1, stdout: "")])
        let outcome = await CompanionSetup(adb: AdbClient(adbPath: "adb", runner: runner)).run(serial: "SER1")
        #expect(outcome == .notInstalled)
        #expect(!runner.calls.contains { $0.contains("grant") })
    }

    @Test("The app's error reply (location off) comes back as notApproved")
    func appError() {
        let out = "Broadcast completed: result=0, data=\"error:network name hidden (location off or not granted)\"\n"
        #expect(CompanionSetup.parseApproveResult(out) == .notApproved(reason: "network name hidden (location off or not granted)"))
    }

    @Test("Network names with quotes survive parsing")
    func quotedName() {
        let out = "Broadcast completed: result=-1, data=\"approved:Ali's \"5G\"\"\n"
        #expect(CompanionSetup.parseApproveResult(out) == .approved(network: "Ali's \"5G\""))
    }

    @Test("No data line means the receiver never ran")
    func noReply() {
        #expect(CompanionSetup.parseApproveResult("Broadcast completed: result=0\n") == .failed("no reply from the companion app"))
    }
}
