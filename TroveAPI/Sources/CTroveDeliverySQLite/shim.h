// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT
#include <sqlite3.h>
#include <stdlib.h>
#include <errno.h>

static inline int trove_delivery_current_errno(void) {
    return errno;
}

// These wrappers call the host SQLite library, even when another module imports extension dispatch macros.
#pragma push_macro("sqlite3_bind_text")
#pragma push_macro("sqlite3_bind_blob")
#undef sqlite3_bind_text
#undef sqlite3_bind_blob

// SQLite copies the binding before Swift's temporary buffer leaves its scope.
static inline int trove_delivery_bind_text(sqlite3_stmt *statement, int index, const char *value, int length) {
    return sqlite3_bind_text(statement, index, value, length, SQLITE_TRANSIENT);
}
static inline int trove_delivery_bind_blob(sqlite3_stmt *statement, int index, const void *value, int length) {
    return sqlite3_bind_blob(statement, index, value, length, SQLITE_TRANSIENT);
}

#pragma pop_macro("sqlite3_bind_blob")
#pragma pop_macro("sqlite3_bind_text")
