// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics
import Foundation
import os

/// Production restoration and transaction bodies, with in-memory IOKit,
/// CoreGraphics, preferences and a manually drained main queue. No device writes.
enum DisplayRestorationTests {
    typealias CGDisplayConfigRef = Int
    typealias IONotificationPortRef = Int
    typealias io_object_t = UInt32
    static let kIOMainPortDefault: UInt32 = 0
    static let kIOGeneralInterest = "IOGeneralInterest"
    static let KERN_SUCCESS: Int32 = 0

    final class Queue {
        var jobs: [() -> Void] = []
        func async(execute work: @escaping () -> Void) { jobs.append(work) }
        func drain() {
            var count = 0
            while !jobs.isEmpty {
                count += 1
                precondition(count < 20, "recovery must not loop on its own notifications")
                jobs.removeFirst()()
            }
        }
    }
    enum DispatchQueue { static var main = Queue() }
    enum Hardware {
        static var lid: Bool? = true
        static var succeeds = true
        static var transactions = 0
        static var registrations = 0
        static var destroyedPorts = 0
        static var released: [UInt32] = []
        static var callback: (() -> Void)?
        static var onSubscribe: (() -> Void)?
    }
    enum DefaultsKey { static let displaysSwitchedOff = "off" }
    final class UserDefaults {
        static var standard = UserDefaults()
        var stored: [Int] = []
        func array(forKey: String) -> [Any]? { stored }
    }
    struct BrightnessDisplay {
        let id: UInt32
        var method: Int? = 1
        var isActive = false
    }
    enum DisplayConfigurationBridge {
        static var configureEnabled: ((Int, UInt32, Bool) -> Int32)? = { _, _, _ in 0 }
    }
    static func CGDisplayIsBuiltin(_ id: UInt32) -> UInt32 { id == 1 ? 1 : 0 }
    static func CGBeginDisplayConfiguration(_ reference: inout Int?) -> CGError {
        Hardware.transactions += 1
        reference = 1
        return .success
    }
    static func CGCancelDisplayConfiguration(_ reference: Int) {}
    static func CGCompleteDisplayConfiguration(_ reference: Int, _ option: CGConfigureOption) -> CGError {
        Hardware.callback?()
        return Hardware.succeeds ? .success : .failure
    }
    static func IOServiceMatching(_ name: String) -> Int { 1 }
    static func IOServiceGetMatchingService(_ port: UInt32, _ matching: Int) -> UInt32 { 2 }
    static func IOObjectRelease(_ object: UInt32) { Hardware.released.append(object) }
    static func IONotificationPortCreate(_ port: UInt32) -> Int? { 3 }
    static func IONotificationPortDestroy(_ port: Int) {
        Hardware.destroyedPorts += 1
        Hardware.callback = nil
    }
    static func IONotificationPortSetDispatchQueue(_ port: Int, _ queue: Queue) {}
    static func IOServiceAddInterestNotification(
        _ port: Int, _ root: UInt32, _ interest: String,
        _ callback: @escaping (UnsafeMutableRawPointer?, UInt32, UInt32, UnsafeMutableRawPointer?) -> Void,
        _ context: UnsafeMutableRawPointer?, _ notification: inout UInt32
    ) -> Int32 {
        Hardware.registrations += 1
        notification = 4
        Hardware.callback = { callback(context, root, 0, nil) }
        Hardware.onSubscribe?()
        return KERN_SUCCESS
    }

    class Fixture {
        static let log = Logger(subsystem: "vorssaint.tests", category: "restoration")
        var deferredRestoration = BrightnessSupport.DeferredDisplayRestoration()
        var lidNotificationPort: IONotificationPortRef?
        var lidNotification: io_object_t = 0
        let stateLock = NSLock()
        var managedDisabledIDs = Set<UInt32>()
        var managedDisabledDisplays: [UInt32: BrightnessDisplay] = [:]
        var pendingLevels: [UInt32: Double] = [:]
        var knownActiveTopology = Set<UInt32>()
        var failure: BrightnessService.DisplayControlFailure?
        var refreshes = 0
        static func lidClosed() -> Bool? { Hardware.lid }
        static func rememberDisplaySwitchedOff(_ id: UInt32) { UserDefaults.standard.stored.append(Int(id)) }
        static func forgetDisplaySwitchedOff(_ id: UInt32) { UserDefaults.standard.stored.removeAll { $0 == Int(id) } }
        func refresh(force: Bool = false) { refreshes += 1 }
        func finishDisplayToggle(id: UInt32, enabled: Bool, failure: BrightnessService.DisplayControlFailure?) {
            self.failure = failure
        }
    }

    static func run(_ suite: TestSuite) {
        func make() -> BrightnessService {
            DispatchQueue.main = Queue()
            UserDefaults.standard = UserDefaults()
            Hardware.lid = true
            Hardware.succeeds = true
            Hardware.transactions = 0
            Hardware.registrations = 0
            Hardware.destroyedPorts = 0
            Hardware.released = []
            Hardware.callback = nil
            Hardware.onSubscribe = nil
            return BrightnessService()
        }
        var service = make()
        UserDefaults.standard.stored = [1]
        service.restoreDisplaysLeftOff()
        service.restoreDisplaysLeftOff()
        DispatchQueue.main.drain()
        suite.expect(Hardware.transactions == 0 && Hardware.registrations == 1
                     && UserDefaults.standard.stored == [1],
                     "closed startup retains its record and owns only one observer without starting the feature")
        Hardware.lid = false
        Hardware.callback?()
        suite.expect(Hardware.transactions == 0, "IOKit callback never configures displays inline")
        DispatchQueue.main.drain()
        suite.expect(Hardware.transactions == 1 && UserDefaults.standard.stored.isEmpty
                     && Hardware.destroyedPorts == 1 && Hardware.released.contains(4),
                     "lid-open notification alone restores startup intent and releases observation")

        service = make()
        UserDefaults.standard.stored = [1]
        service.managedDisabledIDs = [1]
        service.managedDisabledDisplays[1] = BrightnessDisplay(id: 1)
        service.restoreManagedDisplays()
        Hardware.lid = false
        Hardware.succeeds = false
        DispatchQueue.main.drain()
        suite.expect(Hardware.transactions == 1 && service.managedDisabledIDs == [1]
                     && UserDefaults.standard.stored == [1] && Hardware.destroyedPorts == 0,
                     "feature-stop recovery retains failed intent without looping on transaction notifications")
        Hardware.lid = true
        Hardware.callback?()
        DispatchQueue.main.drain()
        Hardware.lid = false
        Hardware.succeeds = true
        Hardware.callback?()
        DispatchQueue.main.drain()
        suite.expect(service.managedDisabledIDs.isEmpty && service.managedDisabledDisplays.isEmpty
                     && UserDefaults.standard.stored.isEmpty && Hardware.destroyedPorts == 1,
                     "later opening clears managed snapshots and persisted recovery after success")

        service = make()
        UserDefaults.standard.stored = [1]
        Hardware.onSubscribe = { Hardware.lid = false }
        service.restoreDisplaysLeftOff()
        DispatchQueue.main.drain()
        suite.expect(Hardware.transactions == 1 && UserDefaults.standard.stored.isEmpty,
                     "subscribe-then-recheck catches an opening during observer registration")

        service = make()
        service.managedDisabledIDs = [1]
        Hardware.lid = false
        service.restoreDeferredDisplays()
        suite.expect(Hardware.transactions == 0,
                     "an intentionally disabled display without deferred intent remains disabled")
        DispatchQueue.main.async { [weak service] in
            service?.commitDisplayToggle(BrightnessDisplay(id: 1), enabled: true)
        }
        Hardware.lid = true
        DispatchQueue.main.drain()
        suite.expect(service.failure == .closedLid && Hardware.transactions == 0
                     && service.deferredRestoration.ids.isEmpty,
                     "manual enable uses transaction-time closed reason without enrolling a deferred request")
        Hardware.lid = false
        Hardware.succeeds = false
        service.commitDisplayToggle(BrightnessDisplay(id: 1), enabled: true)
        suite.expect(service.failure == .failed, "an open-lid transaction failure remains generic")

        service = make()
        UserDefaults.standard.stored = [1]
        service.restoreDisplaysLeftOff()
        Hardware.lid = false
        service.commitDisplayToggle(BrightnessDisplay(id: 1, isActive: true), enabled: false)
        DispatchQueue.main.drain()
        suite.expect(service.deferredRestoration.ids.isEmpty && Hardware.transactions == 1
                     && Hardware.destroyedPorts == 1 && service.managedDisabledIDs == [1],
                     "new explicit disable cancels older deferred recovery before queued recheck")
    }
}
