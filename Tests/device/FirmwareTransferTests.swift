import Foundation
@main struct FirmwareTransferTests {
 @MainActor static func main() async throws {
  let base = ProcessInfo.processInfo.environment["LOOI_TRANSFER_TEST_URL"]!
  var down: [Double] = []; var up: [Double] = []
  let delegate = LooiReleaseRedirects(progress: { down.append($0) })
  let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
  let (data, _) = try await delegate.download(URL(string: base + "/file")!, session: session)
  try await Task.sleep(for: .milliseconds(100))
  precondition(data.count == 1048576 && down.count > 2 && down.last == 1)
  
  session.finishTasksAndInvalidate()
  let uploader = URLSession(configuration: .ephemeral, delegate: LooiReleaseRedirects(progress: { up.append($0) }), delegateQueue: nil)
  var request = URLRequest(url: URL(string: base + "/upload")!); request.httpMethod = "POST"
  let (_, response) = try await uploader.upload(for: request, from: data)
  try await Task.sleep(for: .milliseconds(100))
  precondition((response as? HTTPURLResponse)?.statusCode == 200 && up.last == 1)
  uploader.finishTasksAndInvalidate()
  let bounded = LooiReleaseRedirects(limit: 512)
  let smallSession = URLSession(configuration: .ephemeral, delegate: bounded, delegateQueue: nil)
  do { _ = try await bounded.download(URL(string: base + "/file")!, session: smallSession); preconditionFailure("Oversized download accepted") }
  catch { /* A response above the allowed bound must fail. */ }
  smallSession.finishTasksAndInvalidate()
  print("Real URLSession download/upload passed: \(down.count) / \(up.count) progress callbacks; bounded download and upload callbacks")
 }
}
