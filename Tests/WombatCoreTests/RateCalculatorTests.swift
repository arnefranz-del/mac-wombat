import Testing
@testable import WombatCore

struct RateCalculatorTests {
    private func counter(_ name: String = "en1", index: UInt32 = 6, rx: UInt64, tx: UInt64) -> InterfaceCounters {
        InterfaceCounters(name: name, index: index, received: rx, sent: tx)
    }

    private func snapshot(_ time: Double, _ counters: InterfaceCounters...) -> CounterSnapshot {
        CounterSnapshot(timestamp: time, interfaces: counters)
    }

    @Test func testFirstSampleIsOnlyABaseline() {
        var calculator = RateCalculator()
        let result = calculator.update(snapshot(100, counter(rx: 9_000_000, tx: 8_000_000)))
        #expect((result.state) == (.warmingUp))
        #expect((result.download) == (0))
        #expect((result.upload) == (0))
    }

    @Test func testRatesUseActualElapsedTimeAnd64BitDeltas() {
        var calculator = RateCalculator()
        let base: UInt64 = 100_000_000_000
        _ = calculator.update(snapshot(10, counter(rx: base, tx: base)))
        let result = calculator.update(snapshot(12, counter(rx: base + 24_800_000, tx: base + 1_640_000)))
        #expect((result.state) == (.measuring))
        #expect((result.download) == (12_400_000))
        #expect((result.upload) == (820_000))
        #expect((result.receivedDelta) == (24_800_000))
        #expect((result.interval) == (2))
    }

    @Test func testSimultaneousWifiAndEthernetAreAddedOnce() {
        var calculator = RateCalculator()
        _ = calculator.update(snapshot(1, counter(rx: 100, tx: 100), counter("en0", index: 5, rx: 20, tx: 20)))
        // Reordering must not reset the calculation.
        let result = calculator.update(snapshot(2,
            counter("en0", index: 5, rx: 220, tx: 70), counter(rx: 400, tx: 200)))
        #expect((result.download) == (500))
        #expect((result.upload) == (150))
    }

    @Test func testCounterResetIsNotAnUnderflowAndRecoversNextSample() {
        var calculator = RateCalculator()
        _ = calculator.update(snapshot(1, counter(rx: 50_000, tx: 9_000)))
        let reset = calculator.update(snapshot(2, counter(rx: 10, tx: 10)))
        #expect((reset.state) == (.resynchronizing))
        #expect((reset.download) == (0))
        let recovered = calculator.update(snapshot(3, counter(rx: 1_010, tx: 510)))
        #expect((recovered.download) == (1_000))
        #expect((recovered.upload) == (500))
    }

    @Test func testResetCannotBeMaskedByAnotherInterfaceIncreasing() {
        var calculator = RateCalculator()
        _ = calculator.update(snapshot(1, counter(rx: 900, tx: 900), counter("en0", index: 5, rx: 0, tx: 0)))
        let result = calculator.update(snapshot(2,
            counter(rx: 1, tx: 1), counter("en0", index: 5, rx: 10_000, tx: 10_000)))
        #expect((result.state) == (.resynchronizing))
    }

    @Test func testUploadOnlyCounterResetAlsoResynchronizes() {
        var calculator = RateCalculator()
        _ = calculator.update(snapshot(1, counter(rx: 100, tx: 100)))
        #expect((calculator.update(snapshot(2, counter(rx: 200, tx: 0))).state) == (.resynchronizing))
    }

    @Test func testNetworkSwitchAndHotPlugStartNewBaseline() {
        var calculator = RateCalculator()
        _ = calculator.update(snapshot(1, counter(rx: 1_000, tx: 100)))
        let switched = calculator.update(snapshot(2, counter("en0", index: 5, rx: 99_000_000, tx: 200)))
        #expect((switched.state) == (.warmingUp))
        #expect((switched.download) == (0))
        #expect((calculator.update(snapshot(3,
            counter("en0", index: 5, rx: 99_001_000, tx: 300))).download) == (1_000))
        #expect((calculator.update(snapshot(4,
            counter("en0", index: 5, rx: 99_002_000, tx: 400), counter(rx: 2_000, tx: 200))).state) == (.warmingUp))
    }

    @Test func testReusedNameWithDifferentIndexStartsNewBaseline() {
        var calculator = RateCalculator()
        _ = calculator.update(snapshot(1, counter(rx: 100, tx: 100)))
        #expect((calculator.update(snapshot(2, counter(index: 8, rx: 1_000_000, tx: 100))).state) == (.warmingUp))
    }

    @Test func testOfflineAndReconnectDoNotAccumulateDisconnectedTraffic() {
        var calculator = RateCalculator()
        _ = calculator.update(snapshot(1, counter(rx: 100, tx: 100)))
        #expect((calculator.update(snapshot(2)).state) == (.offline))
        #expect((calculator.update(snapshot(3, counter(rx: 1_000_000, tx: 100))).state) == (.warmingUp))
    }

    @Test func testInvalidIntervalsNeverProduceSpikes() {
        for interval in [0.0, -1.0, 0.001, 4.0, 3_600.0] {
            var calculator = RateCalculator()
            _ = calculator.update(snapshot(100, counter(rx: 0, tx: 0)))
            let result = calculator.update(snapshot(100 + interval, counter(rx: 1_000_000, tx: 1_000_000)))
            #expect((result.state) == (.resynchronizing), "interval \(interval)")
            #expect((result.download) == (0))
            #expect((calculator.update(snapshot(101 + interval,
                counter(rx: 1_001_000, tx: 1_001_000))).download) == (1_000))
        }
    }

    @Test func testNonFiniteTimestampDropsBaseline() {
        for timestamp in [Double.nan, .infinity, -.infinity] {
            var calculator = RateCalculator()
            _ = calculator.update(snapshot(1, counter(rx: 0, tx: 0)))
            #expect((calculator.update(snapshot(timestamp, counter(rx: 1_000, tx: 1_000))).state) == (.resynchronizing))
            #expect((calculator.update(snapshot(2, counter(rx: 2_000, tx: 2_000))).state) == (.warmingUp))
        }
    }

    @Test func testExplicitSleepWakeResetDiscardsTrafficDuringSleep() {
        var calculator = RateCalculator()
        _ = calculator.update(snapshot(1, counter(rx: 100, tx: 100)))
        calculator.reset()
        #expect((calculator.update(snapshot(2, counter(rx: 99_000_000, tx: 100))).state) == (.warmingUp))
        #expect((calculator.update(snapshot(3, counter(rx: 99_001_000, tx: 200))).download) == (1_000))
    }

    @Test func testOverflowingAggregateAndDuplicateInterfacesAreRejected() {
        var calculator = RateCalculator()
        _ = calculator.update(snapshot(1, counter(rx: 0, tx: 0), counter("en0", index: 5, rx: 0, tx: 0)))
        #expect((calculator.update(snapshot(2,
            counter(rx: .max, tx: .max), counter("en0", index: 5, rx: .max, tx: .max))).state) == (.resynchronizing))
        calculator.reset()
        _ = calculator.update(snapshot(1, counter(rx: 0, tx: 0), counter(rx: 0, tx: 0)))
        #expect((calculator.update(snapshot(2, counter(rx: 1, tx: 1), counter(rx: 1, tx: 1))).state) == (.warmingUp))
    }

    @Test func testIdleIsMeasuredZero() {
        var calculator = RateCalculator()
        _ = calculator.update(snapshot(1, counter(rx: 100, tx: 100)))
        let idle = calculator.update(snapshot(2, counter(rx: 100, tx: 100)))
        #expect((idle.state) == (.measuring))
        #expect((idle.download) == (0))
        #expect((idle.upload) == (0))
    }
}
