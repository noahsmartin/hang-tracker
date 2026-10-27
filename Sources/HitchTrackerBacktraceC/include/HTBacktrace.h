#ifndef HTBacktrace_h
#define HTBacktrace_h

#include <mach/mach.h>
#include <stddef.h>
#include <stdint.h>

/// Writes the frame pointer chain of `thread`, which must be suspended, into `frames` (innermost
/// first). Returns the number of frames written, or 0 on failure.
size_t ht_backtrace_thread(thread_t thread, uintptr_t *frames, size_t max_frames);

#endif /* HTBacktrace_h */
