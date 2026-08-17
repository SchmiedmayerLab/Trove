//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

#if canImport(Vapor)
@_spi(APISupport) import Grove
import Vapor


/// An empty standard used when configuring Grove without a custom standard.
private actor DefaultStandard: Standard {
    init() {}
}


/// A namespace for configuring and accessing Grove from within a Vapor application.
///
/// `GroveVapor` provides the integration layer between Grove and Vapor.
/// Use it during application startup to configure your Grove standard and modules, and use it at runtime to retrieve configured modules from either the `Application` or `Request` context.
///
/// ## Configuration
///
/// Configure Grove in your Vapor application's `configure` function:
///
/// ```swift
/// func configure(_ app: Application) throws {
///     app.grove.configure(standard: MyStandard()) {
///         ModuleA()
///         ModuleB()
///     }
/// }
/// ```
///
/// ## Accessing Modules
///
/// Modules can be retrieved by type once Grove is configured.
///
/// ### From Application
///
/// ```swift
/// let myModule = app.grove[MyModule.self]
/// ```
///
/// ### From Request
///
/// ```swift
/// let myModule = req.grove[MyModule.self]
/// ```
@available(macOS 26, iOS 26, watchOS 26, tvOS 26, visionOS 26, *)
public struct GroveVapor: Sendable {
    private enum GroveStorageKey: StorageKey {
        typealias Value = Grove
    }

    private let application: Application

    public var grove: Grove {
        guard let grove = application.storage[GroveStorageKey.self] else {
            preconditionFailure("Grove not configured. Ensure Grove is added to Application storage before use.")
        }
        return grove
    }

    init(application: Application) {
        self.application = application
    }

    init(request: Request) {
        self.application = request.application
    }

    /// Configures Grove with a custom standard and a collection of modules.
    ///
    /// Call this method once during application startup to initialize Grove.
    ///
    /// - Parameters:
    ///   - standard: The standard to use for Grove configuration.
    ///   - modules: A result builder closure that returns the modules to configure.
    @MainActor
    public func configure<S: Standard>(standard: S, @ModuleBuilder _ modules: () -> ModuleCollection) {
        application.storage[GroveStorageKey.self] = Grove(from: Configuration(standard: standard, modules))
        Task.immediate {
            await grove.run()
        }
    }

    /// Configures Grove with the default standard and a collection of modules.
    ///
    /// Call this method once during application startup to initialize Grove.
    ///
    /// - Parameter modules: A result builder closure that returns the modules to configure.
    @MainActor
    public func configure(@ModuleBuilder _ modules: () -> ModuleCollection) {
        configure(standard: DefaultStandard(), modules)
    }

    /// Accesses a configured module by its type.
    ///
    /// - Parameter type: The type of the module to retrieve.
    /// - Returns: The configured module instance.
    /// - Precondition: The module must be configured, otherwise a `preconditionFailure` is triggered.
    public subscript<M: Module & Sendable>(_: M.Type) -> M {
        guard let module: M = self[M?.self] else {
            preconditionFailure("Module \(M.self) not configured in Grove.")
        }
        return module
    }

    /// Optionally accesses a configured module by its type.
    ///
    /// - Parameter type: The optional type of the module to retrieve.
    /// - Returns: The configured module instance, or `nil` if not configured.
    public subscript<M: Module & Sendable>(_: M?.Type) -> M? {
        grove.module(M.self)
    }
}
#endif
