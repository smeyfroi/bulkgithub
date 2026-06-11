#!/usr/bin/env swift
// Standalone check that the dlsym-bound JSC execution watchdog actually
// terminates a runaway script. Exit codes: 0 = works, 2 = symbol missing,
// 3 = bound but never fired (hang would occur in-app).
import Foundation
import JavaScriptCore

typealias ShouldTerminate = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
typealias SetLimitFn = @convention(c) (JSContextGroupRef?, Double, ShouldTerminate?, UnsafeMutableRawPointer?) -> Void

guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "JSContextGroupSetExecutionTimeLimit") else {
    print("SYMBOL MISSING")
    exit(2)
}
let setLimit = unsafeBitCast(symbol, to: SetLimitFn.self)

let context = JSContext()!
let group = JSContextGetGroup(context.jsGlobalContextRef)
// Multi-fire semantics check: return false twice (continue), true on the
// third fire. If "return false" fails to re-arm the timer, the third fire
// never happens and the backstop reports a hang.
nonisolated(unsafe) var fires = 0
nonisolated(unsafe) var rearm: (() -> Void)?
let callback: ShouldTerminate = { _, _ in
    fires += 1
    print("watchdog fired #\(fires)")
    if fires >= 3 { return true }
    rearm?()   // returning false does NOT re-arm the timer — do it explicitly
    return false
}
rearm = { setLimit(group, 0.5, callback, nil) }
setLimit(group, 0.5, callback, nil)

DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
    print("HANG — watchdog never fired")
    exit(3)
}

let start = Date()
context.evaluateScript("while (true) {}")
let elapsed = Date().timeIntervalSince(start)
print(String(format: "terminated after %.2fs; exception: %@", elapsed,
             context.exception?.toString() ?? "none"))
exit(0)
