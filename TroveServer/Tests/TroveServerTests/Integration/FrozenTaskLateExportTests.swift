// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import TroveAPIServer
import TroveAPITypes
@testable import TroveServer
import VaporTesting


struct FrozenTaskLateExportTests {
    private typealias Fixture = TaskCompletionFixture

    /// A response authored within the window and accepted after the cutoff, or by a server clock up to the tolerance before
    /// the opening, exports as completed, and an export frozen while the occurrence was still ready stays readable.
    @Test(arguments: [false, true])
    func completionAcceptedOutsideTheWindowExportsAndKeepsEarlierExportsReadable(early: Bool) async throws {
        try await PublicationWorkflowFixtures.withApp(validator: QuestionnaireWorkerReply.validator()) { app, researcher in
            let assignment = try await Fixture.assign(app: app, researcher: researcher)
            let task = try await ParticipantTaskOutcomeTests.sameDayOccurrence(
                like: assignment.task, day: DateComponents(year: 2027, month: 6, day: 15), on: app
            )
            let cutoff = try #require(task.cutoffAt)
            let exporter = try await FrozenTaskExportTests.exporter()
            let beforePath = try await FrozenTaskExportTests.create(assignment.study, app: app, bearer: exporter)
            let before = try await FrozenTaskExportTests.execute(beforePath, app: app, bearer: exporter)
            let opens = task.opensAt
            // A device clock ahead of the server: the session and response lie in the window, the acceptance before it.
            let sync = early ? opens.addingTimeInterval(-120) : cutoff.addingTimeInterval(3 * 86_400)
            let startedAt = early ? opens.addingTimeInterval(10) : cutoff.addingTimeInterval(-300)
            let authored = early ? opens.addingTimeInterval(40) : cutoff.addingTimeInterval(-60)
            let receipt = try await TaskClock.$now.withValue({ sync }) {
                try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                    let session = try await app.grove[ConsentService.self].startTaskSession(
                        task: task.id,
                        tag: "\"\(task.version)\"",
                        session: UUID(),
                        language: try #require(LanguageTag(rawValue: "en-US")),
                        startedAt: startedAt
                    )
                    let bytes = try Fixture.response(for: session, authored: StudyPointExport.timestamp(authored))
                    return try await Fixture.complete(task.id, session: session, bytes: bytes, on: app)
                }
            }
            #expect(receipt.acceptedAt == sync)
            let download = try await app.sendRequest(.GET, before.path + "/download") { $0.bearerAuth(exporter) }
            #expect(download.status == .ok && Data(download.body.readableBytesView) == before.data)
            let afterPath = try await FrozenTaskExportTests.create(assignment.study, app: app, bearer: exporter)
            let after = try await FrozenTaskExportTests.execute(afterPath, app: app, bearer: exporter)
            let line = try FrozenStudyExportTests.task(try FrozenStudyExportTests.lines(after.data), id: task.id)
            let resource = try #require(line.resources.first)
            #expect(resource["status"]?.string == "completed" && line.resources.count == 2)
            // lastModified never precedes authoredOn, the assignment time.
            #expect(resource["lastModified"]?.string == (try TroveDateTranscoder().encode(max(sync, task.assignedAt))))
        }
    }
}
