//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract


/// Exact row selection for a query batch. A batch envelope is not a single native measurement.
/// The caller resolves authority; this value neither grants access nor changes source identity.
struct RecordingRowSelection: Sendable {
    struct Window: Sendable {
        let start: RecordedInstant
        let end: RecordedInstant

        init(start: Date, end: Date) throws {
            self.start = try RecordedInstant(authorityDate: start)
            self.end = try RecordedInstant(authorityDate: end)
            guard self.end > self.start else { throw FHIRValidationClient.invalid }
        }

        fileprivate init(start: RecordedInstant, end: RecordedInstant) {
            self.start = start
            self.end = end
        }
    }

    struct Result: Sendable {
        let file: RecordingFile
        let sourceRows: Int
        let selectedRows: Int
        var isDerived: Bool { sourceRows != selectedRows }
    }

    private let windows: [Window]

    init(windows: [Window]) {
        var merged: [Window] = []
        for window in windows.sorted(by: { $0.start < $1.start }) {
            if let previous = merged.last, window.start <= previous.end {
                merged[merged.count - 1] = Window(start: previous.start, end: max(previous.end, window.end))
            } else {
                merged.append(window)
            }
        }
        self.windows = merged
    }

    /// Reads the complete verified source, retaining one bounded row and file chunk.
    /// Selected numeric lexemes are copied without a Double or Date conversion.
    /// A complete selection returns the original file and its exact original bytes.
    @concurrent
    func filter(_ source: RecordingFile, format: RegisteredRecordingFormat) async throws -> Result {
        try Self.requireQueryBatchFormat(format)
        var input = source.makeChunkReader()
        var parser = try RecordingCSVReader.Stream(format: format, limits: .init(
            maximumByteCount: source.byteCount,
            maximumRecordByteCount: RecordingCSVReader.Limits.default.maximumRecordByteCount,
            maximumFieldByteCount: RecordingCSVReader.Limits.default.maximumFieldByteCount
        ))
        var output = try RecordingCSVFileWriter(format: format, maximumByteCount: source.byteCount)
        var sourceRows = 0, selectedRows = 0
        while let bytes = try input.readNextChunk() {
            try parser.read(bytes) { row in
                sourceRows += 1
                if try includes(row, format: format) {
                    try output.append(row.fields.map(RecordingCSVWriter.Field.text))
                    selectedRows += 1
                }
            }
        }
        try parser.finish()
        let derived = try output.finish()
        return Result(file: sourceRows == selectedRows ? source : derived, sourceRows: sourceRows, selectedRows: selectedRows)
    }

    func includes(_ row: RecordingCSVReader.Row, format: RegisteredRecordingFormat) throws -> Bool {
        try Self.requireQueryBatchFormat(format)
        let isInterval = format == .pedometerSamples || format == .odometerSamples
        let start = try Self.instant(row[isInterval ? "start" : "timestamp"])
        let end = isInterval ? try Self.instant(row["end"]) : start
        guard end >= start else { throw FHIRValidationClient.invalid }
        // Find the first window ending after the row starts. The merged windows are ordered and disjoint.
        var lower = 0, upper = windows.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if windows[middle].end <= start { lower = middle + 1 } else { upper = middle }
        }
        guard lower < windows.count else {
            return false
        }
        let window = windows[lower]
        // A native interval row is kept whole when it overlaps; individual point rows are half-open.
        return end > start ? end > window.start : start >= window.start
    }
}


extension RecordingRowSelection {
    private static func requireQueryBatchFormat(_ format: RegisteredRecordingFormat) throws {
        switch format {
        case .ambientLightSamples, .ambientPressureSamples, .deviceMotionSamples, .headphoneSettingsSamples,
             .heartRateSamples, .odometerSamples, .pedometerSamples, .triaxialAccelerationSamples, .triaxialRotationSamples:
            break
        default: throw FHIRValidationClient.invalid
        }
    }

    /// The registered CSV reader validates canonical numeric grammar before this exact comparator is used.
    private static func instant(_ value: String?) throws -> RecordedInstant {
        guard let value else { throw FHIRValidationClient.invalid }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let seconds = Int64(parts[0]), (0...253_402_300_799).contains(seconds) else {
            throw FHIRValidationClient.invalid
        }
        var fraction = parts.count == 2 ? String(parts[1]) : ""
        guard parts.count == 1 || !fraction.isEmpty, fraction.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw FHIRValidationClient.invalid
        }
        while fraction.last == "0" { fraction.removeLast() }
        return RecordedInstant(seconds: seconds, fraction: fraction)
    }
}
