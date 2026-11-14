#if canImport(XCTest)
import XCTest
#endif
import CoreAudio
@testable import RecorderCore

final class SelectionAndStateTests: XCTestCase {
    func device(_ uid: String, id: UInt32 = 1, name: String = "Microphone", count: Int = 1, transport: UInt32 = kAudioDeviceTransportTypeBuiltIn) -> InputDevice {
        InputDevice(objectID: id, uid: uid, name: name, channels: (1...count).map { "Channel \($0)" }, bufferChannels: [UInt32(count)], sampleRate: 48_000, transport: transport)
    }
    func testDefaultResolvedAtEachStartAndFrozenInputDoesNotChange() throws {
        let a = device("a"), b = device("b", id: 2)
        let frozen = ResolvedInput(device: try DeviceSelection.resolve(.systemDefault, devices: [a,b], defaultID: 1), channel: 0, selection: .systemDefault)
        XCTAssertEqual(try DeviceSelection.resolve(.systemDefault, devices: [a,b], defaultID: 2).uid, "b")
        XCTAssertEqual(frozen.device.uid, "a")
        XCTAssertEqual(frozen.selection, .systemDefault)
    }
    func testExplicitIdentitySurvivesRenameAndMissingDoesNotFallback() throws {
        let a = device("a", name: "Renamed"), b = device("b", id: 2, name: "Old name")
        let saved = try JSONDecoder().decode(MicrophoneSelection.self, from: JSONEncoder().encode(MicrophoneSelection.device(uid: "a")))
        XCTAssertEqual(try DeviceSelection.resolve(saved, devices: [a,b], defaultID: 2).name, "Renamed")
        XCTAssertThrowsError(try DeviceSelection.resolve(saved, devices: [b], defaultID: 2))
        XCTAssertThrowsError(try DeviceSelection.resolve(.systemDefault, devices: [a], defaultID: 0))
    }
    func testDuplicateNamesHaveDistinctLabels() {
        let a = device("a"), b = device("b", id: 2)
        XCTAssertNotEqual(DeviceSelection.displayName(a, in: [a,b]), DeviceSelection.displayName(b, in: [a,b]))
    }
    func testChannelsArePerUIDAndLayoutMustBeReconfirmed() {
        let a = device("a", count: 8), b = device("b", count: 8)
        XCTAssertNil(DeviceSelection.channel(for: a, preferences: [:]))
        let choices = ["a": ChannelPreference(index: 6, layout: a.layout)]
        XCTAssertEqual(DeviceSelection.channel(for: a, preferences: choices), 6)
        XCTAssertNil(DeviceSelection.channel(for: b, preferences: choices))
        XCTAssertNil(DeviceSelection.channel(for: device("a", count: 2), preferences: choices))
        XCTAssertNil(DeviceSelection.channel(for: device("a", count: 1), preferences: choices))
        XCTAssertEqual(DeviceSelection.channel(for: device("single"), preferences: [:]), 0)
        XCTAssertNil(DeviceSelection.channel(for: device("virtual", transport: kAudioDeviceTransportTypeVirtual), preferences: [:]))
    }
    func testLifecycleRejectsDuplicatesAndStopDuringPreparation() {
        var lifecycle = Lifecycle()
        XCTAssertTrue(lifecycle.begin()); XCTAssertFalse(lifecycle.begin())
        XCTAssertTrue(lifecycle.stop()); XCTAssertFalse(lifecycle.stop())
        XCTAssertFalse(lifecycle.started(preview: false)); XCTAssertEqual(lifecycle.state, .finalizing)
        lifecycle.finish(); XCTAssertTrue(lifecycle.begin()); XCTAssertTrue(lifecycle.started(preview: false))
        XCTAssertFalse(lifecycle.begin()); XCTAssertTrue(lifecycle.stop()); lifecycle.finish(.recoverable)
        XCTAssertTrue(lifecycle.begin()); XCTAssertTrue(lifecycle.started(preview: true)); XCTAssertEqual(lifecycle.state, .previewing)
    }
    func testRecordingToggleRespectsBusyStates() {
        var lifecycle = Lifecycle()
        XCTAssertEqual(lifecycle.state.toggleAction, .start)
        XCTAssertTrue(lifecycle.begin())
        XCTAssertEqual(lifecycle.state.toggleAction, .stop)
        XCTAssertTrue(lifecycle.stop())
        XCTAssertEqual(lifecycle.state.toggleAction, .none)
        XCTAssertFalse(lifecycle.started(preview: false))
        lifecycle.finish()
        XCTAssertTrue(lifecycle.begin()); XCTAssertTrue(lifecycle.started(preview: false))
        XCTAssertEqual(lifecycle.state.toggleAction, .stop)
        XCTAssertTrue(lifecycle.stop()); XCTAssertEqual(lifecycle.state.toggleAction, .none)
        lifecycle.finish()
        XCTAssertTrue(lifecycle.begin()); XCTAssertTrue(lifecycle.started(preview: true))
        XCTAssertEqual(lifecycle.state.toggleAction, .stop)
        for state: RecordingState in [.needsPermission, .error, .recoverable] {
            lifecycle.finish(state)
            XCTAssertEqual(lifecycle.state.toggleAction, .start)
            XCTAssertTrue(lifecycle.begin())
        }
    }
}
