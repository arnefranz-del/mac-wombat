import Foundation
import Testing
@testable import WombatCore

@MainActor
private final class TestLoginItemService: LoginItemService {
    var state: LoginItemState = .notRegistered
    var registerCalls = 0
    var unregisterCalls = 0
    var registrationResult: LoginItemState = .enabled
    var fail = false
    func register() async throws {
        registerCalls += 1
        if fail { throw CocoaError(.fileWriteNoPermission) }
        state = registrationResult
    }
    func unregister() async throws {
        unregisterCalls += 1
        if fail { throw CocoaError(.fileWriteNoPermission) }
        state = .notRegistered
    }
}

@MainActor
struct LoginItemTests {
    @Test func newInstallAndRefreshNeverRegisterImplicitly() {
        let service = TestLoginItemService()
        let controller = LoginItemController(service: service)
        controller.refresh()
        #expect(controller.state == .notRegistered)
        #expect(service.registerCalls == 0 && service.unregisterCalls == 0)
    }

    @Test func userCanEnableAndDisable() async {
        let service = TestLoginItemService()
        let controller = LoginItemController(service: service)
        await controller.setEnabled(true)
        #expect(controller.state.isEnabled && service.registerCalls == 1)
        await controller.setEnabled(false)
        #expect(controller.state == .notRegistered && service.unregisterCalls == 1)
    }

    @Test func failedRegistrationDoesNotPretendToBeEnabled() async {
        let service = TestLoginItemService()
        service.fail = true
        let controller = LoginItemController(service: service)
        await controller.setEnabled(true)
        #expect(!controller.state.isEnabled)
        #expect(controller.errorMessage != nil)
        #expect(!controller.isBusy)
    }

    @Test func failedDisableRetainsActualEnabledStatus() async {
        let service = TestLoginItemService()
        service.state = .enabled
        service.fail = true
        let controller = LoginItemController(service: service)
        await controller.setEnabled(false)
        #expect(controller.state.isEnabled)
        #expect(controller.errorMessage != nil)
    }

    @Test func approvalStateDoesNotTriggerARegistrationLoop() async {
        let service = TestLoginItemService()
        service.registrationResult = .requiresApproval
        let controller = LoginItemController(service: service)
        await controller.setEnabled(true)
        #expect(controller.state == .requiresApproval && !controller.state.isEnabled)
        await controller.setEnabled(true)
        #expect(service.registerCalls == 1)
        await controller.setEnabled(false)
        #expect(controller.state == .notRegistered)
    }

    @Test func externalSystemChangeIsRespectedRatherThanOverwritten() async {
        let service = TestLoginItemService()
        let controller = LoginItemController(service: service)
        await controller.setEnabled(true)
        service.state = .requiresApproval
        controller.refresh()
        #expect(!controller.state.isEnabled && service.registerCalls == 1)
        service.state = .notRegistered
        controller.refresh()
        #expect(controller.state == .notRegistered)
    }

    @Test func repeatedSameSettingIsIdempotent() async {
        let service = TestLoginItemService()
        let controller = LoginItemController(service: service)
        await controller.setEnabled(false)
        await controller.setEnabled(true)
        await controller.setEnabled(true)
        #expect(service.registerCalls == 1 && service.unregisterCalls == 0)
    }
}
