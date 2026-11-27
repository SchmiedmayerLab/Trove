//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import ArgumentParser


struct StudyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "study",
        subcommands: [
            CreateStudy.self, GetStudy.self, GetStudyTasks.self, GetStudyData.self, GetStudyRecording.self,
            EditStudy.self, ScheduleCommand.self, ValidateStudy.self, PublishStudy.self, ApproveLanguage.self, RevokeLanguageApproval.self
        ]
    )
}


struct QuestionnaireCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "questionnaire",
        subcommands: [ImportQuestionnaire.self, ExportQuestionnaire.self, ValidateQuestionnaire.self, EvaluateQuestionnaireScenarios.self]
    )
}


@main
struct TroveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trove",
        abstract: "Read study data and author study drafts through the Trove API.",
        discussion: "Writes use the revision you reviewed. A conflict requires a new read and review, never an automatic retry.",
        subcommands: [StudyCommand.self, QuestionnaireCommand.self]
    )
}
