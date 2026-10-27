#include "HTBacktrace.h"

/// Removes pointer authentication bits. XPACLRI is a no-op on hardware without pointer
/// authentication, so it is safe in non-arm64e code.
static inline uintptr_t ht_strip(uintptr_t address) {
#if defined(__arm64__)
    register uintptr_t x30 __asm__("x30") = address;
    __asm__("xpaclri" : "+r"(x30));
    return x30;
#else
    return address;
#endif
}

/// Unlike a direct read, does not fault if the memory is unmapped.
static inline int ht_read_memory(uintptr_t address, void *destination, size_t size) {
    vm_size_t bytes_read = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)address, size,
                                         (vm_address_t)destination, &bytes_read);
    return kr == KERN_SUCCESS && bytes_read == size;
}

size_t ht_backtrace_thread(thread_t thread, uintptr_t *frames, size_t max_frames) {
    if (max_frames == 0) {
        return 0;
    }

    size_t count = 0;
    uintptr_t fp = 0;

#if defined(__arm64__)
    arm_thread_state64_t state;
    mach_msg_type_number_t state_count = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(thread, ARM_THREAD_STATE64, (thread_state_t)&state, &state_count) == KERN_SUCCESS) {
        frames[count++] = ht_strip((uintptr_t)arm_thread_state64_get_pc(state));
        // A leaf function may not have pushed a frame, leaving its caller only in LR.
        uintptr_t lr = ht_strip((uintptr_t)arm_thread_state64_get_lr(state));
        if (lr != 0 && count < max_frames) {
            frames[count++] = lr;
        }
        fp = (uintptr_t)arm_thread_state64_get_fp(state);
    }
#elif defined(__x86_64__)
    x86_thread_state64_t state;
    mach_msg_type_number_t state_count = x86_THREAD_STATE64_COUNT;
    if (thread_get_state(thread, x86_THREAD_STATE64, (thread_state_t)&state, &state_count) == KERN_SUCCESS) {
        frames[count++] = (uintptr_t)state.__rip;
        fp = (uintptr_t)state.__rbp;
    }
#endif

    // Each frame record is {previous fp, return address}. Stacks grow down, so callers' records
    // are at strictly higher addresses.
    while (fp != 0 && (fp & (sizeof(uintptr_t) - 1)) == 0 && count < max_frames) {
        uintptr_t record[2];
        if (!ht_read_memory(fp, record, sizeof(record))) {
            break;
        }
        uintptr_t return_address = ht_strip(record[1]);
        if (return_address == 0) {
            break;
        }
        frames[count++] = return_address;
        if (record[0] <= fp) {
            break;
        }
        fp = record[0];
    }

    return count;
}
