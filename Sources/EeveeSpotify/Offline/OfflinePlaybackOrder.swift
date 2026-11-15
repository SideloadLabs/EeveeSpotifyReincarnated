enum OfflinePlaybackOrder {
    static func next(count: Int, current: Int, history: [Int], shuffle: Bool) -> [Int] {
        guard count > 0, (0..<count).contains(current) else { return [] }
        if shuffle {
            let played = Set(history + [current])
            return (0..<count).filter { !played.contains($0) }.shuffled()
        }
        return Array((current + 1)..<count)
    }
}
