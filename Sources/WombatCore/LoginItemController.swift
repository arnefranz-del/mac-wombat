import Combine
import Foundation

public enum LoginItemState: Equatable, Sendable {
    case notRegistered, enabled, requiresApproval, notFound, unknown
    public var isEnabled: Bool { self == .enabled }
}

@MainActor
public protocol LoginItemService {
    var state: LoginItemState { get }
    func register() async throws
    func unregister() async throws
}

/// macOS is the source of truth. Merely constructing/refreshing this controller
/// never registers anything, and no UserDefaults boolean can override OS consent.
@MainActor
public final class LoginItemController: ObservableObject {
    @Published public private(set) var state: LoginItemState
    @Published public private(set) var isBusy = false
    @Published public private(set) var errorMessage: String?
    private let service: any LoginItemService

    public init(service: any LoginItemService) {
        self.service = service
        state = service.state
    }

    public func refresh() { state = service.state }

    public func setEnabled(_ enabled: Bool) async {
        guard !isBusy else { return }
        refresh()
        errorMessage = nil
        if enabled && (state == .enabled || state == .requiresApproval) { return }
        if !enabled && (state == .notRegistered || state == .notFound) { return }
        isBusy = true
        defer { isBusy = false }
        do {
            if enabled { try await service.register() }
            else { try await service.unregister() }
        } catch {
            errorMessage = "Autostart konnte nicht geändert werden: \(error.localizedDescription)"
        }
        refresh()
        // A racing external change may already have reached the desired state.
        if enabled && state == .enabled { errorMessage = nil }
        if !enabled && (state == .notRegistered || state == .notFound) { errorMessage = nil }
    }
}
