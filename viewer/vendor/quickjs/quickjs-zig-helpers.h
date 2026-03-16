// Thin helpers for values that are C macros and can't be translated by Zig's @cImport
#ifndef QUICKJS_ZIG_HELPERS_H
#define QUICKJS_ZIG_HELPERS_H

#include "quickjs.h"

static inline JSValue qjs_undefined(void) { return JS_UNDEFINED; }
static inline JSValue qjs_null(void) { return JS_NULL; }
static inline JSValue qjs_true(void) { return JS_TRUE; }
static inline JSValue qjs_false(void) { return JS_FALSE; }
static inline int qjs_is_exception(JSValue v) { return JS_IsException(v); }
static inline int qjs_is_undefined(JSValue v) { return JS_IsUndefined(v); }
static inline int qjs_is_object(JSValue v) { return JS_IsObject(v); }

// Interrupt handler support — stores a pointer to a flag
static volatile int *qjs_shutdown_flag_ptr = NULL;

static inline int qjs_interrupt_handler(JSRuntime *rt, void *opaque) {
    (void)rt;
    volatile int *flag = (volatile int *)opaque;
    return flag ? *flag : 0;
}

static inline void qjs_set_interrupt_flag(JSRuntime *rt, volatile int *flag) {
    qjs_shutdown_flag_ptr = flag;
    JS_SetInterruptHandler(rt, qjs_interrupt_handler, (void *)flag);
}

#endif
