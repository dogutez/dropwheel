import Foundation

/// Progress for long jobs, carried as a task-local so engines can report it without every
/// function taking a callback. The app binds a handler around a conversion; cancellation is
/// ordinary task cancellation.
public enum ConversionProgress {
    @TaskLocal public static var handler: (@Sendable (Double) -> Void)?

    static func report(_ fraction: Double) {
        handler?(min(max(fraction, 0), 1))
    }
}
