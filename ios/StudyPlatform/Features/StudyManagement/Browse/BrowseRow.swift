//
// This source file is part of the StudyPlatform-iOS open source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SpeziLocalization
import SpeziStudyDefinition
import SwiftUI

struct BrowseRow: View {
    let item: StudyPlatform.Study

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            if !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 4)
    }

    private var title: String {
        item.metadata.title[.currentOrDefault] ?? item.studyId
    }

    private var description: String {
        item.metadata.shortExplanationText[.currentOrDefault] ?? ""
    }
}
