import Foundation

/// Сколько тишины вставить в трек после дыры в захвате (рестарт микрофона, пересборка tap).
///
/// Дыру меряем по host time (mach_absolute_time) первого сэмпла, пришедшего после неё, а не по моменту
/// рестарта: устройство стартует сотни миллисекунд, и паддинг «до старта» оставлял их за бортом —
/// у amanu mic уезжал вперёд на 0.37–0.75 с за пару рестартов.
///
/// Чистая арифметика без аллокаций: `gapFrames` зовётся и из IOProc.
public enum PaddingMath {
    /// frames = round((actual − expected) / hostTicksPerSecond × sampleRate), никогда не меньше нуля.
    public static func silenceFrames(
        expectedHostTime: UInt64, actualHostTime: UInt64, sampleRate: Double, hostTicksPerSecond: Double
    ) -> Int64 {
        guard actualHostTime > expectedHostTime, sampleRate > 0, hostTicksPerSecond > 0 else { return 0 }
        let seconds = Double(actualHostTime - expectedHostTime) / hostTicksPerSecond
        return Int64((seconds * sampleRate).rounded())
    }

    /// Дыра перед буфером, чей первый сэмпл пришёл в `actualHostTime`, если трек начался в
    /// `startHostTime` и в нём уже `framesWritten` кадров с частотой `sampleRate`.
    ///
    /// Расхождение до `tolerance` секунд не паддим: это дрожание и дрейф часов, и паддинг дрейфа сам
    /// уводил бы трек (amanu MicRecorder.silenceFrames, порог 50 мс).
    public static func gapFrames(
        startHostTime: UInt64, framesWritten: Int64, actualHostTime: UInt64, sampleRate: Double,
        hostTicksPerSecond: Double, tolerance: Double = 0.05
    ) -> Int64 {
        guard sampleRate > 0, hostTicksPerSecond > 0, framesWritten >= 0 else { return 0 }
        let elapsedTicks = (Double(framesWritten) / sampleRate * hostTicksPerSecond).rounded()
        let expected = startHostTime &+ UInt64(elapsedTicks)
        let frames = silenceFrames(
            expectedHostTime: expected, actualHostTime: actualHostTime, sampleRate: sampleRate,
            hostTicksPerSecond: hostTicksPerSecond)
        return Double(frames) / sampleRate > tolerance ? frames : 0
    }
}
