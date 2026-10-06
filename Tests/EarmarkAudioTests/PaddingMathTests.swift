import EarmarkAudio
import Testing

@Suite("PaddingMath")
struct PaddingMathTests {
    /// Тики mach_absolute_time на Apple Silicon: 24 МГц.
    static let ticks = 24_000_000.0

    @Test(
        "silenceFrames: разница host time → кадры, не меньше нуля",
        arguments: [
            (expected: UInt64(1_000), actual: UInt64(1_000), rate: 48_000.0, frames: Int64(0)),
            (expected: 2_000, actual: 1_000, rate: 48_000, frames: 0),  // трек впереди часов — не режем
            (expected: 0, actual: 24_000_000, rate: 48_000, frames: 48_000),  // 1 с
            (expected: 0, actual: 12_000_000, rate: 16_000, frames: 8_000),  // 0.5 с
            (expected: 0, actual: 375, rate: 48_000, frames: 1),  // 0.75 кадра округляется вверх
        ])
    func silenceFrames(expected: UInt64, actual: UInt64, rate: Double, frames: Int64) {
        #expect(
            PaddingMath.silenceFrames(
                expectedHostTime: expected, actualHostTime: actual, sampleRate: rate,
                hostTicksPerSecond: Self.ticks)
                == frames)
    }

    /// Фокус ревью №4: после рестарта устройства дыра закрывается тишиной ровно по host time.
    @Test(
        "gapFrames: дыра после рестарта, дрожание до 50 мс не паддим",
        arguments: [
            // трек начался в t=10 с, записана 1 с, первый новый буфер пришёл в t=11.5 с → 0.5 с тишины
            (written: Int64(48_000), actualSeconds: 11.5, frames: Int64(24_000)),
            (written: 48_000, actualSeconds: 11.04, frames: 0),  // 40 мс — дрожание
            (written: 48_000, actualSeconds: 10.9, frames: 0),  // устройство спешит — не режем
            (written: 0, actualSeconds: 12, frames: 96_000),
        ])
    func gapFrames(written: Int64, actualSeconds: Double, frames: Int64) {
        let start = UInt64(10 * Self.ticks)
        #expect(
            PaddingMath.gapFrames(
                startHostTime: start, framesWritten: written,
                actualHostTime: UInt64(actualSeconds * Self.ticks),
                sampleRate: 48_000, hostTicksPerSecond: Self.ticks) == frames)
    }
}
