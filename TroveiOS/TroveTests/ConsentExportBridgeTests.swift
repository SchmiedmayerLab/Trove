//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveConsent
import PDFKit
import PencilKit
import Testing
@testable import Trove


@MainActor
struct ConsentExportBridgeTests {
    private struct Signature: Encodable {
        let name: PersonNameComponents
        let signature: PKDrawing
        let size: [Double]
    }

    private struct Responses: Encodable {
        let toggles = ["agree": true]
        let selects: [String: String] = [:]
        let signatures: [String: Signature]
    }

    @Test
    func realPencilKitDrawingAndCanvasDimensionsSurviveCodableBridge() throws {
        let original = drawing()
        let responses = try fixture(drawing: original, size: [200, 80])
        let bridged = try ConsentExportBridge.responses(responses)
        let signature = try #require(bridged.signatures?.additionalProperties["participant"])
        #expect(signature.size == [200, 80])
        #expect(signature.name.givenName == "Alice")
        let bytes = try #require(Data(base64Encoded: signature.signature))
        let restored = try PKDrawing(data: bytes)
        #expect(restored.strokes.count == original.strokes.count)
        #expect(restored.bounds == original.bounds)
    }

    @Test(arguments: [[0.0, 80.0], [200.0, -1.0]])
    func rejectsMissingCanvasEvidence(size: [Double]) throws {
        let responses = try fixture(drawing: drawing(), size: size)
        #expect(throws: ConsentFailure.incomplete) {
            try ConsentExportBridge.responses(responses)
        }
    }

    @Test
    func exportedPDFRetainsStructuredConsentText() throws {
        let text = "# Review this study.\n\nParticipation is **voluntary**.\n\n- Ask questions\n- Withdraw at any time"
        let document = try ConsentDocument(markdown: text)
        let exported = try ConsentExportBridge.export(document)
        let pdf = try #require(PDFDocument(data: exported.pdf))
        let contents = try #require(pdf.string)
        #expect(contents.contains("Review this study."))
        #expect(contents.contains("Participation is voluntary."))
        #expect(contents.contains("Ask questions"))
        #expect(!contents.contains("**"))
        #expect(pdf.pageCount > 0)
    }

    private func fixture(drawing: PKDrawing, size: [Double]) throws -> ConsentDocument.UserResponses {
        // Fixtures supply canvas dimensions only in the existing Codable format. Production
        // dimensions come from Grove's real signature canvas, exercised by the UI test.
        let signature = Signature(
            name: .init(givenName: "Alice", familyName: "Participant"), signature: drawing, size: size
        )
        let encoded = try JSONEncoder().encode(Responses(signatures: ["participant": signature]))
        return try JSONDecoder().decode(ConsentDocument.UserResponses.self, from: encoded)
    }

    private func drawing() -> PKDrawing {
        let points = [CGPoint(x: 20, y: 30), CGPoint(x: 120, y: 50)].enumerated().map { index, point in
            PKStrokePoint(
                location: point,
                timeOffset: Double(index) / 10,
                size: CGSize(width: 3, height: 3),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        }
        return PKDrawing(strokes: [
            PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: .distantPast))
        ])
    }
}
