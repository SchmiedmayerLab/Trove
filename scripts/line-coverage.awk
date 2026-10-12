#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

# Keep actual source-line execution. Function invocation counts cannot reconstruct
# uncovered branches/lines and are deliberately excluded from the merge input.
/^SF:/ {
    if (in_record) invalid = 1
    records++; in_record = 1; lines = 0
    found_seen = 0; hit_seen = 0; print; next
}
/^DA:/ {
    if (!in_record || $0 !~ /^DA:[0-9]+,[0-9]+(,.*)?$/) invalid = 1
    lines++; total_lines++; print; next
}
/^LF:/ {
    if (!in_record || $0 !~ /^LF:[0-9]+$/) invalid = 1
    found_seen++; found = substr($0, 4) + 0; print; next
}
/^LH:/ {
    if (!in_record || $0 !~ /^LH:[0-9]+$/) invalid = 1
    hit_seen++; hit = substr($0, 4) + 0; print; next
}
/^end_of_record$/ {
    if (!in_record) invalid = 1
    # Macro-only files can have function records but no instrumented source lines.
    # Accept that only when the compiler explicitly reports both line counts as zero.
    if (lines == 0 && !(found_seen == 1 && hit_seen == 1 && found == 0 && hit == 0)) invalid = 1
    if (found_seen > 1 || hit_seen > 1) invalid = 1
    in_record = 0
    print
}
END {
    if (records == 0 || total_lines == 0 || in_record || invalid) {
        print "Missing or incomplete source-line coverage records." > "/dev/stderr"
        exit 1
    }
}
