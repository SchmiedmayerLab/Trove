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
    records++; in_record = 1; lines = 0; print; next
}
/^DA:/ {
    if (!in_record || $0 !~ /^DA:[0-9]+,[0-9]+(,.*)?$/) invalid = 1
    lines++; print; next
}
/^L[FH]:[0-9]+$/ { print; next }
/^end_of_record$/ {
    if (!in_record || lines == 0) invalid = 1
    in_record = 0
    print
}
END {
    if (records == 0 || in_record || invalid) {
        print "Missing or incomplete source-line coverage records." > "/dev/stderr"
        exit 1
    }
}
