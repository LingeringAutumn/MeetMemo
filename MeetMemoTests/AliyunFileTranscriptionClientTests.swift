import Foundation
import XCTest
@testable import MeetMemo

final class AliyunFileTranscriptionClientTests: XCTestCase {
    override func tearDown() {
        AliyunStubURLProtocol.handler = nil
        super.tearDown()
    }

    func testOfficialTemporaryUploadAndDualChannelWorkflowUsesExpectedRequests() async throws {
        let recorder = AliyunRequestRecorder()
        AliyunStubURLProtocol.handler = { request in
            recorder.append(request)
            let path = request.url?.path ?? ""
            let method = request.httpMethod ?? ""

            if path == "/api/v1/uploads", method == "GET" {
                return Self.response(
                    request,
                    json: """
                    {"data":{
                      "policy":"policy-value","signature":"signature-value",
                      "upload_dir":"dashscope-instant/test","upload_host":"https://upload.example.test",
                      "max_file_size_mb":1000,"oss_access_key_id":"temporary-access-key",
                      "x_oss_object_acl":"private","x_oss_forbid_overwrite":"true"
                    }}
                    """
                )
            }
            if request.url?.host == "upload.example.test", method == "POST" {
                return Self.response(request, status: 200, json: "{}")
            }
            if path == "/api/v1/services/audio/asr/transcription", method == "POST" {
                return Self.response(
                    request,
                    json: """
                    {"output":{"task_status":"PENDING","task_id":"task-123"},"request_id":"request-1"}
                    """
                )
            }
            if path == "/api/v1/tasks/task-123", method == "GET" {
                return Self.response(
                    request,
                    json: """
                    {"output":{"task_id":"task-123","task_status":"SUCCEEDED","results":[{
                      "transcription_url":"https://result.example.test/result.json",
                      "subtask_status":"SUCCEEDED"
                    }]}}
                    """
                )
            }
            if request.url?.host == "result.example.test", method == "GET" {
                return Self.response(
                    request,
                    json: """
                    {"properties":{"original_duration_in_milliseconds":7000},"transcripts":[
                      {"channel_id":0,"text":"我的回答","sentences":[
                        {"begin_time":2000,"end_time":3000,"text":"我的回答"}
                      ]},
                      {"channel_id":1,"text":"面试官提问","sentences":[
                        {"begin_time":500,"end_time":1500,"text":"面试官提问"}
                      ]}
                    ]}
                    """
                )
            }
            throw URLError(.badServerResponse)
        }

        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let audioURL = temporaryDirectory.appendingPathComponent("interview.wav")
        try Data("fake-wave-data".utf8).write(to: audioURL)
        let client = makeClient(multipartDirectory: temporaryDirectory)

        let policy = try await client.requestUploadPolicy(apiKey: "test-api-key")
        let uploaded = try await client.upload(fileURL: audioURL, using: policy)
        XCTAssertTrue(uploaded.ossURL.hasPrefix("oss://dashscope-instant/test/"))

        let submission = try await client.submit(
            uploadedFile: uploaded,
            apiKey: "test-api-key",
            options: AliyunFileTranscriptionOptions(
                context: String(repeating: "技", count: 450),
                vocabulary: ["KV Cache": 5]
            )
        )
        XCTAssertEqual(submission.taskID, "task-123")

        let snapshot = try await client.query(taskID: submission.taskID, apiKey: "test-api-key")
        XCTAssertEqual(snapshot.state, .succeeded)
        let resultURL = try XCTUnwrap(snapshot.result?.transcriptionURL)
        let meetingStart = Date(timeIntervalSince1970: 1_700_000_000)
        let result = try await client.downloadResult(
            from: resultURL,
            meetingStart: meetingStart,
            timelineBaseOffsetMilliseconds: 60_000
        )

        XCTAssertEqual(result.chunks.map(\.source), [.system, .mic])
        XCTAssertEqual(result.chunks.map(\.startTime), [60_500, 62_000])
        XCTAssertEqual(result.chunks.map(\.text), ["面试官提问", "我的回答"])
        XCTAssertEqual(result.speakerNameMappings["MIC:candidate"], "候选人")
        XCTAssertEqual(result.speakerNameMappings["SYS:interviewer"], "面试官")

        let requests = recorder.requests
        XCTAssertEqual(requests.count, 5)
        XCTAssertTrue(requests[0].url?.query?.contains("action=getPolicy") == true)
        XCTAssertTrue(requests[0].url?.query?.contains("model=qwen-audio-3.0-asr-flash-filetrans") == true)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer test-api-key")
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "X-DashScope-Async"), "enable")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "X-DashScope-OssResourceResolve"), "enable")

        let submitBody = try XCTUnwrap(requests[2].httpBody)
        let submitJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: submitBody) as? [String: Any])
        let parameters = try XCTUnwrap(submitJSON["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["channel_id"] as? [Int], [0, 1])
        XCTAssertEqual(parameters["diarization_enabled"] as? Bool, false)
        XCTAssertEqual((parameters["vocabulary"] as? [String: Int])?["KV Cache"], 5)
        let input = try XCTUnwrap(submitJSON["input"] as? [String: Any])
        let context = try XCTUnwrap(input["context"] as? [[String: Any]])
        let content = try XCTUnwrap(context.first?["content"] as? [[String: Any]])
        XCTAssertEqual((content.first?["text"] as? String)?.count, 400)
        XCTAssertNil(requests[4].value(forHTTPHeaderField: "Authorization"))

        let leftovers = try FileManager.default.contentsOfDirectory(at: temporaryDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "multipart" }
        XCTAssertTrue(leftovers.isEmpty, "Multipart staging files must be removed after upload")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path), "Original recording must be retained")
    }

    func testMultipartWriterStreamsFileAndPlacesFileFieldLast() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let inputURL = temporaryDirectory.appendingPathComponent("audio.wav")
        let outputURL = temporaryDirectory.appendingPathComponent("body.multipart")
        try Data("AUDIO-MARKER".utf8).write(to: inputURL)

        try AliyunMultipartFormWriter.write(
            to: outputURL,
            boundary: "fixed-boundary",
            fields: [("key", "safe/object.wav"), ("policy", "test-policy")],
            fileFieldName: "file",
            fileURL: inputURL,
            contentType: "audio/wav"
        )

        let body = try String(contentsOf: outputURL, encoding: .utf8)
        let keyRange = try XCTUnwrap(body.range(of: "name=\"key\""))
        let policyRange = try XCTUnwrap(body.range(of: "name=\"policy\""))
        let fileRange = try XCTUnwrap(body.range(of: "name=\"file\""))
        XCTAssertLessThan(keyRange.lowerBound, fileRange.lowerBound)
        XCTAssertLessThan(policyRange.lowerBound, fileRange.lowerBound)
        XCTAssertTrue(body.contains("AUDIO-MARKER"))
        XCTAssertTrue(body.hasSuffix("--fixed-boundary--\r\n"))
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: outputURL.path)[.posixPermissions]
                as? NSNumber
        ).intValue & 0o777
        XCTAssertEqual(permissions, 0o600)
    }

    func testCancelUsesOfficialPendingTaskEndpoint() async throws {
        let recorder = AliyunRequestRecorder()
        AliyunStubURLProtocol.handler = { request in
            recorder.append(request)
            guard request.url?.path == "/api/v1/tasks/task-123/cancel",
                  request.httpMethod == "POST" else {
                throw URLError(.badURL)
            }
            return Self.response(request, json: #""request-id""#)
        }

        try await makeClient().cancel(taskID: "task-123", apiKey: "test-api-key")

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-api-key")
        XCTAssertEqual(request.url?.path, "/api/v1/tasks/task-123/cancel")
    }

    func testRejectsUntrustedUploadAndResultHosts() async throws {
        AliyunStubURLProtocol.handler = { request in
            Self.response(
                request,
                json: """
                {"data":{
                  "policy":"p","signature":"s","upload_dir":"d",
                  "upload_host":"http://not-secure.example.test","max_file_size_mb":"1000",
                  "oss_access_key_id":"a","x_oss_object_acl":"private","x_oss_forbid_overwrite":"true"
                }}
                """
            )
        }
        let client = makeClient()
        do {
            _ = try await client.requestUploadPolicy(apiKey: "test")
            XCTFail("Expected an untrusted-host failure")
        } catch let error as AliyunFileTranscriptionError {
            XCTAssertEqual(error, .untrustedUploadHost)
        }

        do {
            _ = try await client.downloadResult(
                from: URL(string: "https://attacker.invalid/result.json")!,
                meetingStart: Date()
            )
            XCTFail("Expected an untrusted result-host failure")
        } catch let error as AliyunFileTranscriptionError {
            XCTAssertEqual(error, .untrustedResultHost)
        }
    }

    func testServiceResponseCannotMoveToSiblingAliyunHost() async throws {
        let body = Data("""
        {"data":{
          "policy":"p","signature":"s","upload_dir":"d",
          "upload_host":"https://example.aliyuncs.com","max_file_size_mb":1000,
          "oss_access_key_id":"a","x_oss_object_acl":"private","x_oss_forbid_overwrite":"true"
        }}
        """.utf8)
        let response = HTTPURLResponse(
            url: URL(string: "https://unexpected.aliyuncs.com/api/v1/uploads")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        let client = AliyunFileTranscriptionClient(
            transport: AliyunFixedTransport(response: response, data: body)
        )

        do {
            _ = try await client.requestUploadPolicy(apiKey: "test")
            XCTFail("Expected exact service-host validation to fail")
        } catch let error as AliyunFileTranscriptionError {
            XCTAssertEqual(error, .invalidEndpoint)
        }
    }

    private func makeClient(multipartDirectory: URL? = nil) -> AliyunFileTranscriptionClient {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [AliyunStubURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let configuration = AliyunDashScopeConfiguration(
            model: AliyunFileTranscriptionOptions.defaultModel,
            uploadPolicyURL: URL(string: "https://api.example.test/api/v1/uploads")!,
            transcriptionURL: URL(string: "https://api.example.test/api/v1/services/audio/asr/transcription")!,
            taskBaseURL: URL(string: "https://api.example.test/api/v1/tasks")!,
            allowedUploadHostSuffixes: ["example.test"],
            allowedResultHostSuffixes: ["example.test"]
        )
        return AliyunFileTranscriptionClient(
            transport: URLSessionAliyunHTTPTransport(session: session),
            configuration: configuration,
            multipartDirectory: multipartDirectory ?? FileManager.default.temporaryDirectory
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AliyunFileTranscriptionClientTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func response(
        _ request: URLRequest,
        status: Int = 200,
        json: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(json.utf8))
    }
}

private struct AliyunFixedTransport: AliyunHTTPTransport {
    let response: HTTPURLResponse
    let data: Data

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        _ = request
        return (data, response)
    }

    func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, HTTPURLResponse) {
        _ = request
        _ = fileURL
        throw URLError(.unsupportedURL)
    }
}

private final class AliyunStubURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class AliyunRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var requests: [URLRequest] {
        lock.withLock { storage }
    }

    func append(_ request: URLRequest) {
        lock.withLock { storage.append(request) }
    }
}
