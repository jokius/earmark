import EarmarkCore
import Foundation
import Testing

/// vad и language отменяются флагом shouldAbort так же, как full: опрос не реже раза в 200 мс всё время
/// запроса, включая отправку тела. Таймауты здесь длинные: быстрый исход даёт только флаг.
@Suite("RemoteWhisperClient: shouldAbort на /v1/vad и /v1/language")
struct RemoteWhisperClientAbortTests {
    enum Endpoint: String, CaseIterable { case vad, language }

    private static let patient = RemoteWhisperClient.Timeouts(health: 30, request: 10, idle: 10, stall: 30)

    private func call(
        _ endpoint: Endpoint, _ server: FakeWhisperServer, _ samples: ArraySlice<Float>, abort: AbortFlag
    ) async throws(EarmarkError) {
        let client = FakeWhisper.client(server, timeouts: Self.patient)
        switch endpoint {
        case .vad: _ = try await client.vad(samples, threads: 4, shouldAbort: { abort.isRaised })
        case .language: _ = try await client.language(samples, threads: 4, shouldAbort: { abort.isRaised })
        }
    }

    @Test(
        "сервер принял запрос и молчит — interrupted (75) быстро, а не таймаут", arguments: Endpoint.allCases)
    func abortWhileWaiting(endpoint: Endpoint) async throws {
        let server = try FakeWhisperServer { _, connection in connection.hang() }
        defer { server.stop() }
        let abort = AbortFlag.after(0.3)
        let start = Date()

        let error = await #expect(throws: EarmarkError.self) {
            try await call(endpoint, server, [0.5, -0.5, 0.25][...], abort: abort)
        }

        #expect(error == .interrupted)
        #expect(error?.exitCode == 75)
        #expect(Date().timeIntervalSince(start) < 2.3)
    }

    @Test("отправка тела упёрлась в нечитающий сервер — interrupted быстро", arguments: Endpoint.allCases)
    func abortWhileUploading(endpoint: Endpoint) async throws {
        let server = try FakeWhisperServer(readsBody: false) { _, connection in connection.hang() }
        defer { server.stop() }
        // 32 MB — заметно больше буферов loopback-сокета: отправка упирается в нечитающий сервер.
        let big = [Float](repeating: 0.25, count: 8_000_000)
        let abort = AbortFlag.after(0.3)
        let start = Date()

        let error = await #expect(throws: EarmarkError.self) {
            try await call(endpoint, server, big[...], abort: abort)
        }

        #expect(error == .interrupted)
        #expect(Date().timeIntervalSince(start) < 2.5)
    }
}
