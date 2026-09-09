// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT
#include <sqlite3.h>
#include <stdlib.h>
#include <errno.h>

static inline int trove_delivery_current_errno(void) {
    return errno;
}

// SQLite copies the binding before Swift's temporary buffer leaves its scope.
static inline int trove_delivery_bind_text(sqlite3_stmt *statement, int index, const char *value, int length) {
    return sqlite3_bind_text(statement, index, value, length, SQLITE_TRANSIENT);
}
static inline int trove_delivery_bind_blob(sqlite3_stmt *statement, int index, const void *value, int length) {
    return sqlite3_bind_blob(statement, index, value, length, SQLITE_TRANSIENT);
}
