//
//  MackyCrashReporter.swift
//  leanring-buddy
//
//  Minimal crash-reporting startup wiring around PLCrashReporter.
//
//  The actual PLCrashReporter call is guarded by `#if canImport(CrashReporter)` so the
//  file compiles whether or not the `CrashReporter` SPM product is linked to the target.
//  It is linked in this project, so crash reporting is active on release runs.
//
//  IMPORTANT — debugger conflict: PLCrashReporter's exception handler fights the Xcode
//  debugger (LLDB), which already owns the process's Mach exception ports. Arming it
//  while a debugger is attached trips an immediate SIGTRAP (signal 5) at launch. So we
//  (a) skip enabling entirely when a debugger is attached — crash reports aren't useful
//  there anyway, the debugger catches the crash — and (b) use the BSD signal handler
//  rather than the Mach one, which is the debugger-friendlier of the two.
//

import Foundation

#if canImport(CrashReporter)
import CrashReporter
#endif

@MainActor
enum MackyCrashReporter {

    /// Enables crash reporting at startup. No-op when a debugger is attached (the
    /// debugger handles crashes and PLCrashReporter's handler would SIGTRAP on launch),
    /// and a no-op if the `CrashReporter` product isn't linked.
    static func start() {
        #if canImport(CrashReporter)
        // Skip while running under the debugger to avoid the Mach/BSD handler conflict
        // that terminates the app with SIGTRAP at launch.
        if isDebuggerAttached() {
            print("ℹ️ MackyCrashReporter: debugger attached — crash reporting skipped")
            return
        }

        // BSD signal handler (not Mach): coexists with the debugger far better and is
        // sufficient for the crashes we care about.
        let config = PLCrashReporterConfig(
            signalHandlerType: .BSD,
            symbolicationStrategy: .all
        )
        guard let reporter = PLCrashReporter(configuration: config) else {
            print("⚠️ MackyCrashReporter: failed to create PLCrashReporter")
            return
        }

        // If a report from a previous crashed session is pending, surface it before
        // arming the handler again. (Upload wiring is intentionally left to a future
        // pass — for now we at least persist + clear so reports don't pile up.)
        if reporter.hasPendingCrashReport() {
            if let data = try? reporter.loadPendingCrashReportDataAndReturnError(),
               let report = try? PLCrashReport(data: data) {
                // PLCrashReportTextFormat has a single case, imported from the C constant
                // `PLCrashReportTextFormatiOS`; the formatter API is the class method
                // `stringValueForCrashReport(_:withTextFormat:)`.
                let text = PLCrashReportTextFormatter.stringValue(
                    for: report,
                    with: PLCrashReportTextFormatiOS
                ) ?? "unavailable"
                print("💥 MackyCrashReporter: recovered crash report from previous session:\n\(text)")
            }
            reporter.purgePendingCrashReport()
        }

        do {
            try reporter.enableAndReturnError()
            print("🛡 MackyCrashReporter: PLCrashReporter enabled")
        } catch {
            print("⚠️ MackyCrashReporter: enable failed: \(error)")
        }
        #else
        print("ℹ️ MackyCrashReporter: CrashReporter product not linked — crash reporting disabled")
        #endif
    }

    /// Whether a debugger (LLDB) is currently attached to this process. Uses the
    /// documented `sysctl(KERN_PROC_PID)` `P_TRACED` check — App Store-safe, no private
    /// API. We skip arming PLCrashReporter when true so its handler doesn't conflict with
    /// the debugger and SIGTRAP the app at launch.
    private static func isDebuggerAttached() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }
}
