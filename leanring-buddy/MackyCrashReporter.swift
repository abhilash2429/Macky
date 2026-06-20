//
//  MackyCrashReporter.swift
//  leanring-buddy
//
//  Minimal crash-reporting startup wiring around PLCrashReporter.
//
//  PLCrashReporter is resolved transitively in the project's Swift Package graph but
//  is NOT yet linked as a product of the app target. To avoid a project-file edit that
//  can't be verified without an Xcode build, the actual PLCrashReporter call is guarded
//  by `#if canImport(CrashReporter)`: it stays a clean no-op until someone adds the
//  `CrashReporter` package product to the `leanring-buddy` target in Xcode (General ▸
//  Frameworks, Libraries, and Embedded Content ▸ + ▸ CrashReporter), at which point the
//  guard compiles in and crash reports begin on next launch. No other code needs to
//  change. This keeps the wiring in place and discoverable without risking the pbxproj.
//

import Foundation

#if canImport(CrashReporter)
import CrashReporter
#endif

@MainActor
enum MackyCrashReporter {

    /// Enables crash reporting at startup. No-op until the `CrashReporter`
    /// (PLCrashReporter) product is linked to the app target.
    static func start() {
        #if canImport(CrashReporter)
        let config = PLCrashReporterConfig(
            signalHandlerType: .mach,
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
                let text = PLCrashReportTextFormatter.stringValue(for: report, with: .iOS) ?? "unavailable"
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
}
