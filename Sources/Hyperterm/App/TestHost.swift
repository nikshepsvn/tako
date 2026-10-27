import Foundation

/// Whether this process is the unit-test host. The tests run inside a real Tako build, so
/// anything with side effects outside the process (notifications, ~/.hyperterm) checks this.
enum TestHost {
    static let isActive = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}
