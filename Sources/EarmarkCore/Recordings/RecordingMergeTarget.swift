import Foundation

extension RecordingStore {
    /// Окно склейки: предыдущая запись должна закончиться не раньше чем за столько до старта этой.
    public static let mergeWindow: TimeInterval = 600

    /// Запись, к которой можно приклеить `id` (спека merge-and-fast-panel.md, п. 5): самая свежая из
    /// начатых строго раньше `startedAt`, законченная, с audio.m4a и закончившаяся не раньше чем за
    /// `window` до него. Самая свежая не подходит — nil: дальше в прошлое не ищем, склейка через
    /// голову соседней записи переставила бы звонки местами.
    /// `startedAt` — старт записи id: в момент стопа её meta ещё нет.
    public func mergeTarget(id: String, startedAt: Date, window: TimeInterval = RecordingStore.mergeWindow)
        throws(EarmarkError) -> RecordingFolder?
    {
        let earlier: [RecordingFolder]
        do {
            // until исключает границу: начатая в ту же секунду не «раньше».
            earlier = try list(RecordingFilter(until: startedAt))
        } catch {
            throw .operationFailed("cannot read recordings: \(error.localizedDescription)")
        }
        guard let previous = earlier.first(where: { $0.id != id }),
            !previous.isRecording, previous.isComplete, let meta = previous.meta, meta.audio != nil,
            let endedAt = meta.endedAt, endedAt >= startedAt.addingTimeInterval(-window)
        else { return nil }
        return previous
    }
}
