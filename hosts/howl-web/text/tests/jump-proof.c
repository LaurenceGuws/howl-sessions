/* Exercise real C nonlocal jumps entirely within C, never across Zig defers. */
#include <setjmp.h>
static void jump_to(jmp_buf env, int value) { longjmp(env, value); }
unsigned jump_proof_c(void) {
    jmp_buf first;
    int result = setjmp(first);
    if (result == 0) jump_to(first, 7);
    if (result != 7) return 0;
    jmp_buf second;
    result = setjmp(second);
    if (result == 0) jump_to(second, 0);
    return result == 1;
}
