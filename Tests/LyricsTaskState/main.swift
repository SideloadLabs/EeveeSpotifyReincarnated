import Foundation

func check(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
enum ProviderError: Error { case unavailable }

// The response callback, the completion callback and both delegates ask for the
// same task at once: one provider request, one shared answer.
let task = URLSession.shared.dataTask(with: URL(string: "https://example.invalid/color-lyrics/v2/download/track/1")!)
let lock = NSLock()
var fetches = 0
let group = DispatchGroup()
var answers: [Data] = []
for _ in 0..<4 {
    group.enter()
    DispatchQueue.global().async {
        let data = try! LyricsTaskState.forTask(task).result {
            lock.lock(); fetches += 1; lock.unlock()
            Thread.sleep(forTimeInterval: 0.05)
            return Data("lyrics".utf8)
        }
        lock.lock(); answers.append(data); lock.unlock()
        group.leave()
    }
}
check(group.wait(timeout: .now() + 5) == .success, "callers did not finish")
check(fetches == 1 && answers.count == 4 && Set(answers) == [Data("lyrics".utf8)], "one task fetched more than once")

// A failure is shared too: the second callback does not ask the provider again.
let failed = URLSession.shared.dataTask(with: URL(string: "https://example.invalid/color-lyrics/v2/download/track/2")!)
var failures = 0
for _ in 0..<2 {
    do {
        _ = try LyricsTaskState.forTask(failed).result { failures += 1; throw ProviderError.unavailable }
        fatalError("failure became lyrics")
    } catch ProviderError.unavailable {}
}
check(failures == 1, "a failed task asked the provider again")

// Another task for the same URL is a fresh request.
let next = URLSession.shared.dataTask(with: failed.originalRequest!)
let fresh = try LyricsTaskState.forTask(next).result { Data("new".utf8) }
check(fresh == Data("new".utf8), "a new task reused an old answer")
print("Lyrics task state: one provider answer per Spotify task, shared by every callback")
