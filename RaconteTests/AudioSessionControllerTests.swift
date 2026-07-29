import XCTest
@testable import Raconte
#if os(iOS)
import AVFAudio
#endif

final class AudioSessionControllerTests: XCTestCase {

    // MARK: - Pure mapper (cross-platform; mirrors the iOS notification payloads)

    func testInterruptionBeganMapsToInterrupted() {
        XCTAssertEqual(SessionEventMapper.interruption(typeRaw: 1, optionRaw: 0), .interrupted)
    }

    func testInterruptionEndedWithShouldResume() {
        XCTAssertEqual(SessionEventMapper.interruption(typeRaw: 0, optionRaw: 1),
                       .resumeAvailable(shouldResume: true))
    }

    func testInterruptionEndedWithoutShouldResume() {
        XCTAssertEqual(SessionEventMapper.interruption(typeRaw: 0, optionRaw: 0),
                       .resumeAvailable(shouldResume: false))
    }

    func testInterruptionUnknownTypeIsIgnored() {
        XCTAssertNil(SessionEventMapper.interruption(typeRaw: 99, optionRaw: 0))
    }

    func testRouteOldDeviceUnavailableMapsToRouteLost() {
        XCTAssertEqual(SessionEventMapper.routeChange(reasonRaw: 2), .routeLost)
    }

    func testRouteOtherReasonsIgnored() {
        XCTAssertNil(SessionEventMapper.routeChange(reasonRaw: 1)) // newDeviceAvailable
        XCTAssertNil(SessionEventMapper.routeChange(reasonRaw: 3)) // categoryChange
    }

    // MARK: - Platform controllers via injected NotificationCenter

    #if os(macOS)
    func testMacConfigChangeEmitsRouteLost() async {
        let center = NotificationCenter()
        let controller = MacAudioSessionController(center: center)
        var iterator = controller.events.makeAsyncIterator()
        center.post(name: .AVAudioEngineConfigurationChange, object: nil)
        let event = await iterator.next()
        XCTAssertEqual(event, .routeLost)
    }
    #endif

    #if os(iOS)
    func testIOSInterruptionBeganEmitsInterrupted() async {
        let center = NotificationCenter()
        let controller = IOSAudioSessionController(center: center)
        var iterator = controller.events.makeAsyncIterator()
        center.post(name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: [AVAudioSessionInterruptionTypeKey: NSNumber(value: 1)])
        let event = await iterator.next()
        XCTAssertEqual(event, .interrupted)
    }

    func testIOSRouteLostEmitted() async {
        let center = NotificationCenter()
        let controller = IOSAudioSessionController(center: center)
        var iterator = controller.events.makeAsyncIterator()
        center.post(name: AVAudioSession.routeChangeNotification, object: nil,
                    userInfo: [AVAudioSessionRouteChangeReasonKey: NSNumber(value: 2)])
        let event = await iterator.next()
        XCTAssertEqual(event, .routeLost)
    }

    func testIOSMediaServicesResetEmitted() async {
        let center = NotificationCenter()
        let controller = IOSAudioSessionController(center: center)
        var iterator = controller.events.makeAsyncIterator()
        center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        let event = await iterator.next()
        XCTAssertEqual(event, .mediaServicesReset)
    }
    #endif
}
