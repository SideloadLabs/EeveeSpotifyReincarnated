import Foundation

func check(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
func pump(_ condition: () -> Bool) {
    let end = Date().addingTimeInterval(5)
    while !condition() && Date()<end { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
    check(condition(), "asynchronous lyrics relay did not finish")
}
struct Source { var isReplacingLyrics = true }
extension UserDefaults { static var lyricsSource = Source() }
extension URL { var isLyrics: Bool { path.contains("color-lyrics/v2") } }
func extractTrackId(from path: String) -> String? { path.split(separator:"/").last.map(String.init) }
struct Lyrics {
    let bytes: Data
    init(serializedBytes: Data) throws { bytes=serializedBytes }
    func serializedData() throws -> Data { bytes }
}
final class URLSessionHelper {
    static let shared = URLSessionHelper()
    var bodies: [ObjectIdentifier:Data] = [:]
    func obtainData(for task: URLSessionTask) -> Data? { bodies.removeValue(forKey:ObjectIdentifier(task)) }
}
final class NativeOfflineLyrics {
    static let shared = NativeOfflineLyrics()
    var markers = 0
    func markNoLyrics(trackId: String, reason: String) { markers += 1 }
}
final class KaraokePlaybackTracker {
    static let shared = KaraokePlaybackTracker()
    var signals = 0
    func updateTrackIdFromLyricsFetch(_ id: String) { signals += 1 }
}
var savedLyrics: Lyrics?
func cachedOfflineLyrics(trackId: String, offline: Bool) -> Lyrics? { savedLyrics }
enum ProviderError: Error { case unavailable }
let fetchLock=NSLock()
var fetches=0, fail=false
let custom=Data("custom lyrics".utf8)
func eeveeLyricsData(_ path:String, originalLyrics:Lyrics? = nil) throws -> Data {
    fetchLock.lock(); fetches += 1; let failed=fail; fetchLock.unlock()
    Thread.sleep(forTimeInterval:0.02)
    if failed { throw ProviderError.unavailable }
    return custom
}
let session=URLSession(configuration:.ephemeral)
func task(_ download:Bool=false)->URLSessionDataTask {
    session.dataTask(with:URL(string:"https://spotify.example/color-lyrics/v2/\(download ? "download/" : "")track/test")!)
}
func relay(_ task:URLSessionDataTask, error:Error? = nil, received:@escaping(Data?,Error?)->Void) {
    check(finishEeveeLyricsTask(task:task,delegate:"outer",error:error) { _,data,error in
        check(Thread.isMainThread,"native lyrics delivered off main")
        // Model the native delegate chain: the second hook buffers the body's
        // relay and then gets the same task's completion. It must reuse the fetch.
        URLSessionHelper.shared.bodies[ObjectIdentifier(task)]=data
        check(finishEeveeLyricsTask(task:task,delegate:"inner",error:error) { _,data,error in
            check(Thread.isMainThread,"inner delegate delivered off main")
            received(data,error)
        },"inner declined lyrics")
    },"outer declined lyrics")
}

let denied=task();var header=false,done=false,deliveries=0
let forbidden=HTTPURLResponse(url:denied.currentRequest!.url!,statusCode:403,httpVersion:nil,headerFields:nil)!
check(prepareEeveeLyricsResponse(task:denied,response:forbidden) { replacement in
    check(replacement.statusCode==200,"successful provider did not replace 403")
    header=true
},"403 not handled")
pump { header }
check(fetches==1 && deliveries==0,"response handler completed the task prematurely")
URLSessionHelper.shared.bodies[ObjectIdentifier(denied)]=Data("Forbidden".utf8)
relay(denied) { data,error in check(data==custom && error==nil,"wrong relayed result");deliveries+=1;done=true }
pump { done }
check(fetches==1 && deliveries==1,"403 response/completion/delegate chain fetched twice")
check(finishEeveeLyricsTask(task:denied,delegate:"outer",error:nil) { _,_,_ in fatalError("duplicate completion delivered") },"duplicate not claimed")

let next=task();done=false
URLSessionHelper.shared.bodies[ObjectIdentifier(next)]=Data("Spotify".utf8)
relay(next) { data,error in check(data==custom,"new task lost lyrics");done=true }
pump { done }
check(fetches==2,"different task for same URL reused stale online data")

fail=true
let failed=task();header=false;done=false
check(prepareEeveeLyricsResponse(task:failed,response:forbidden) { response in
    check(response.statusCode==403,"failed provider hid Spotify error");header=true
},"failed response declined")
pump { header }
URLSessionHelper.shared.bodies[ObjectIdentifier(failed)]=Data("Forbidden".utf8)
relay(failed) { data,error in check(data==Data("Forbidden".utf8),"original body lost after provider failure");done=true }
pump { done }
check(fetches==3,"provider failure was retried again at completion")

savedLyrics=try Lyrics(serializedBytes:Data("offline".utf8));done=false
relay(task(true),error:URLError(.notConnectedToInternet)) { data,error in
    check(data==savedLyrics?.bytes && error==nil,"offline download fallback failed");done=true
}
pump { done }
check(KaraokePlaybackTracker.shared.signals==0,"background plugin request changed karaoke track")
check(fetches==3,"offline relay started another provider request in the inner delegate")
done=false
relay(task(),error:URLError(.cancelled)) { data,error in
    check(data==nil && (error as? URLError)?.code == .cancelled,"cancelled task delivered lyrics");done=true
}
pump { done }
print("Lyrics task lifecycle: 403 + real completion, chained delegates, failures, fresh tasks, offline background and cancellation passed")

UserDefaults.lyricsSource.isReplacingLyrics = false
let switched = task()
URLSessionHelper.shared.bodies[ObjectIdentifier(switched)] = Data("original".utf8)
done = false
relay(switched, error: URLError(.networkConnectionLost)) { data, error in
    check(data == Data("original".utf8) && (error as? URLError)?.code == .networkConnectionLost,
          "switching to Spotify lost buffered data or its completion error")
    done = true
}
pump { done }
