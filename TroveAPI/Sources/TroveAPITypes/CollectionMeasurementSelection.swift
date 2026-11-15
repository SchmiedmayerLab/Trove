//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// Shared acquisition/admission selection. A selected interval is retained whole;
/// clipping it would change the source observation and its identity.
public enum CollectionMeasurementSelection {
    /// Windows are half-open. Nonempty sample intervals must overlap the window;
    /// a point or zero-duration sample must lie within it. Empty windows select nothing.
    public static func includes(sampleStart: Date, sampleEnd: Date?, windowStart: Date, windowEnd: Date?) -> Bool {
        guard sampleStart.timeIntervalSinceReferenceDate.isFinite,
              windowStart.timeIntervalSinceReferenceDate.isFinite,
              sampleEnd.map({ $0.timeIntervalSinceReferenceDate.isFinite && $0 >= sampleStart }) ?? true,
              windowEnd.map({ $0.timeIntervalSinceReferenceDate.isFinite && $0 > windowStart }) ?? true else {
            return false
        }
        guard let sampleEnd, sampleEnd > sampleStart else {
            return sampleStart >= windowStart && (windowEnd.map { sampleStart < $0 } ?? true)
        }
        return sampleEnd > windowStart && (windowEnd.map { sampleStart < $0 } ?? true)
    }
}
