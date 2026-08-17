//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveStudyDefinition
import SwiftUI


struct ParticipationCriteriaView: View {
    private struct Row {
        let text: String
        let depth: Int
        let criterion: StudyDefinition.ParticipationCriterion
    }

    let criterion: StudyDefinition.ParticipationCriterion
    let environment: StudyDefinition.ParticipationCriterion.EvaluationEnvironment

    var body: some View {
        let rows = Self.flatten(criterion, depth: 0)
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                statusIcon(for: row.criterion)
                Text(row.text)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(max(row.depth - 1, 0)) * 16)
        }
    }

    private static func flatten(
        _ criterion: StudyDefinition.ParticipationCriterion,
        depth: Int
    ) -> [Row] {
        switch criterion {
        case .ageAtLeast, .isFromRegion, .speaksLanguage, .custom, .not:
            return [Row(text: format(criterion), depth: depth, criterion: criterion)]
        case .all(let children):
            if children.isEmpty {
                return [Row(text: "No restrictions", depth: depth, criterion: criterion)]
            }
            if children.count == 1 {
                return flatten(children[0], depth: depth)
            }
            var rows = [Row(text: "All of the following must be true:", depth: depth, criterion: criterion)]
            for child in children {
                rows.append(contentsOf: flatten(child, depth: depth + 1))
            }
            return rows
        case .any(let children):
            if children.isEmpty {
                return [Row(text: "Not eligible", depth: depth, criterion: criterion)]
            }
            if children.count == 1 {
                return flatten(children[0], depth: depth)
            }
            var rows = [Row(text: "Any of the following must be true:", depth: depth, criterion: criterion)]
            for child in children {
                rows.append(contentsOf: flatten(child, depth: depth + 1))
            }
            return rows
        }
    }

    private static func format(_ criterion: StudyDefinition.ParticipationCriterion) -> String {
        switch criterion {
        case .ageAtLeast(let minAge):
            return "Age at least \(minAge)"
        case .isFromRegion(let region):
            let name = Locale.current.localizedString(forRegionCode: region.identifier) ?? region.identifier
            return "Resides in \(name)"
        case .speaksLanguage(let language):
            let code = language.languageCode?.identifier ?? language.minimalIdentifier
            let name = Locale.current.localizedString(forLanguageCode: code) ?? code
            return "Speaks \(name)"
        case .custom(let key):
            return key.displayTitle
        case .not(let inner):
            return "Not: \(format(inner))"
        case .all(let children) where children.isEmpty:
            return "No restrictions"
        case .any(let children) where children.isEmpty:
            return "Not eligible"
        case .all, .any:
            return ""
        }
    }

    @ViewBuilder
    private func statusIcon(for criterion: StudyDefinition.ParticipationCriterion) -> some View {
        if criterion.evaluate(environment) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Met")
        } else {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Not met")
        }
    }
}
