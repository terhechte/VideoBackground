import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class ReplicateImageUpscaler: @unchecked Sendable {
    typealias FrameCompletion = @Sendable (UpscaledFrame) async throws -> Void

    struct ImageFrame: Sendable {
        let index: Int
        let imageURL: URL

        init(index: Int, imageURL: URL) {
            self.index = index
            self.imageURL = imageURL
        }
    }

    struct UpscaledFrame: Sendable {
        let index: Int
        let sourceURL: URL?
        let predictionID: String
        let outputURL: URL
        let pngData: Data
    }

    private let apiBaseURL = URL(string: "https://api.replicate.com/v1")!
    private let apiKey: String
    private let session: URLSession
    private let pollInterval: Duration
    private let requestTimeout: TimeInterval
    private let onFrameUpscaled: FrameCompletion?
    private let cachedVersionIDLock = NSLock()
    private var cachedVersionID: String?

    init(
        apiKey: String? = nil,
        environmentFileURL: URL? = nil,
        session: URLSession = .shared,
        pollInterval: Duration = .milliseconds(750),
        requestTimeout: TimeInterval = 120,
        onFrameUpscaled: FrameCompletion? = nil
    ) throws {
        self.apiKey = try Self.resolveAPIKey(
            explicitAPIKey: apiKey,
            environmentFileURL: environmentFileURL
        )
        self.session = session
        self.pollInterval = pollInterval
        self.requestTimeout = requestTimeout
        self.onFrameUpscaled = onFrameUpscaled
    }

    func prepare() async throws {
        _ = try await modelVersionID()
    }

    @discardableResult
    func upscaleFrames(_ frames: [ImageFrame]) async throws -> [UpscaledFrame] {
        var upscaledFrames: [UpscaledFrame] = []
        upscaledFrames.reserveCapacity(frames.count)

        for frame in frames {
            try Task.checkCancellation()
            let upscaledFrame = try await upscaleFrame(at: frame.imageURL, index: frame.index)
            upscaledFrames.append(upscaledFrame)
        }

        return upscaledFrames
    }

    @discardableResult
    func upscaleFrame(at imageURL: URL, index: Int) async throws -> UpscaledFrame {
        let imageInput: String

        if imageURL.isFileURL {
            let data = try Data(contentsOf: imageURL)
            imageInput = dataURI(for: data, mimeType: mimeType(for: imageURL))
        } else {
            imageInput = imageURL.absoluteString
        }

        return try await upscaleFrame(
            imageInput: imageInput,
            index: index,
            sourceURL: imageURL
        )
    }

    @discardableResult
    func upscaleFrame(
        imageData: Data,
        mimeType: String = "image/png",
        index: Int,
        sourceURL: URL? = nil
    ) async throws -> UpscaledFrame {
        try await upscaleFrame(
            imageInput: dataURI(for: imageData, mimeType: mimeType),
            index: index,
            sourceURL: sourceURL
        )
    }

    @discardableResult
    func upscaleFrame(
        _ image: CGImage,
        index: Int,
        sourceURL: URL? = nil
    ) async throws -> UpscaledFrame {
        try await upscaleFrame(
            imageData: pngData(from: image),
            mimeType: "image/png",
            index: index,
            sourceURL: sourceURL
        )
    }

    private func upscaleFrame(
        imageInput: String,
        index: Int,
        sourceURL: URL?
    ) async throws -> UpscaledFrame {
        let prediction = try await createPrediction(imageInput: imageInput)
        let completedPrediction = try await waitForCompletion(prediction)
        let outputURL = try outputURL(from: completedPrediction)
        let pngData = try await downloadOutput(from: outputURL)

        let upscaledFrame = UpscaledFrame(
            index: index,
            sourceURL: sourceURL,
            predictionID: completedPrediction.id ?? prediction.id ?? "",
            outputURL: outputURL,
            pngData: pngData
        )

        try await onFrameUpscaled?(upscaledFrame)

        return upscaledFrame
    }

    private func createPrediction(imageInput: String) async throws -> PredictionResponse {
        let versionID = try await modelVersionID()
        let body = CreatePredictionRequest(
            version: versionID,
            input: PredictionInput(image: imageInput)
        )
        var request = authorizedRequest(
            url: apiBaseURL.appendingPathComponent("predictions"),
            method: "POST"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("wait", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONEncoder().encode(body)

        let data = try await checkedData(for: request)
        return try JSONDecoder().decode(PredictionResponse.self, from: data)
    }

    private func waitForCompletion(_ initialPrediction: PredictionResponse) async throws -> PredictionResponse {
        var prediction = initialPrediction

        do {
            while true {
                try Task.checkCancellation()

                switch prediction.status {
                case "succeeded":
                    return prediction
                case "failed":
                    throw ReplicateImageUpscalerError.predictionFailed(
                        prediction.error ?? prediction.logs ?? "The upscaling prediction failed."
                    )
                case "canceled":
                    throw ReplicateImageUpscalerError.predictionCanceled
                default:
                    break
                }

                guard let getURL = prediction.urls?.get else {
                    throw ReplicateImageUpscalerError.missingPredictionURL
                }

                try await Task.sleep(for: pollInterval)
                prediction = try await fetchPrediction(at: getURL)
            }
        } catch is CancellationError {
            if let cancelURL = prediction.urls?.cancel {
                try? await cancelPrediction(at: cancelURL)
            }

            throw CancellationError()
        }
    }

    private func fetchPrediction(at url: URL) async throws -> PredictionResponse {
        let request = authorizedRequest(url: url, method: "GET")
        let data = try await checkedData(for: request)
        return try JSONDecoder().decode(PredictionResponse.self, from: data)
    }

    private func cancelPrediction(at url: URL) async throws {
        let request = authorizedRequest(url: url, method: "POST")
        _ = try await checkedData(for: request)
    }

    private func modelVersionID() async throws -> String {
        if let cachedVersionID = lockedCachedVersionID() {
            return cachedVersionID
        }

        let modelURL = apiBaseURL
            .appendingPathComponent("models")
            .appendingPathComponent("prunaai")
            .appendingPathComponent("p-image-upscale")
        let request = authorizedRequest(url: modelURL, method: "GET")
        let data = try await checkedData(for: request)
        let model = try JSONDecoder().decode(ModelResponse.self, from: data)

        guard let versionID = Self.nonEmpty(model.latestVersion?.id) else {
            throw ReplicateImageUpscalerError.missingModelVersion
        }

        return lockCachedVersionID(versionID)
    }

    private func lockedCachedVersionID() -> String? {
        cachedVersionIDLock.lock()
        defer { cachedVersionIDLock.unlock() }

        return cachedVersionID
    }

    private func lockCachedVersionID(_ versionID: String) -> String {
        cachedVersionIDLock.lock()
        defer { cachedVersionIDLock.unlock() }

        if let cachedVersionID {
            return cachedVersionID
        }

        cachedVersionID = versionID
        return versionID
    }

    private func outputURL(from prediction: PredictionResponse) throws -> URL {
        guard let output = prediction.output?.firstURLString else {
            throw ReplicateImageUpscalerError.missingOutput
        }

        guard let url = URL(string: output) else {
            throw ReplicateImageUpscalerError.invalidOutputURL(output)
        }

        return url
    }

    private func downloadOutput(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        return try await checkedData(for: request)
    }

    private func authorizedRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func checkedData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ReplicateImageUpscalerError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ReplicateImageUpscalerError.requestFailed(
                statusCode: httpResponse.statusCode,
                message: Self.errorMessage(from: data)
            )
        }

        return data
    }

    private func dataURI(for data: Data, mimeType: String) -> String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    private func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mimeType = type.preferredMIMEType {
            return mimeType
        }

        return "image/png"
    }

    private func pngData(from image: CGImage) throws -> Data {
        let data = NSMutableData()

        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ReplicateImageUpscalerError.cannotEncodePNG
        }

        CGImageDestinationAddImage(destination, image, nil)

        guard CGImageDestinationFinalize(destination) else {
            throw ReplicateImageUpscalerError.cannotEncodePNG
        }

        return data as Data
    }

    private static func resolveAPIKey(
        explicitAPIKey: String?,
        environmentFileURL: URL?
    ) throws -> String {
        if let explicitAPIKey = nonEmpty(explicitAPIKey) {
            return explicitAPIKey
        }

        if let environmentAPIKey = nonEmpty(ProcessInfo.processInfo.environment["REPLICATE_API_KEY"]) {
            return environmentAPIKey
        }

        if let environmentFileURL,
           let fileAPIKey = try apiKey(from: environmentFileURL) {
            return fileAPIKey
        }

        for candidate in defaultEnvironmentFileCandidates() {
            guard FileManager.default.fileExists(atPath: candidate.path) else {
                continue
            }

            if let fileAPIKey = try apiKey(from: candidate) {
                return fileAPIKey
            }
        }

        throw ReplicateImageUpscalerError.missingAPIKey
    }

    private static func apiKey(from url: URL) throws -> String? {
        let contents = try String(contentsOf: url, encoding: .utf8)

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !line.isEmpty, !line.hasPrefix("#") else {
                continue
            }

            let assignment = line.hasPrefix("export ")
                ? String(line.dropFirst("export ".count))
                : line

            guard let equalsIndex = assignment.firstIndex(of: "=") else {
                continue
            }

            let key = assignment[..<equalsIndex]
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard key == "REPLICATE_API_KEY" else {
                continue
            }

            let valueStart = assignment.index(after: equalsIndex)
            return nonEmpty(unquoted(String(assignment[valueStart...])))
        }

        return nil
    }

    private static func defaultEnvironmentFileCandidates() -> [URL] {
        let fileManager = FileManager.default
        var candidates: [URL] = [
            URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent(".env")
        ]

        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent(".env"))
        }

        if let executableURL = Bundle.main.executableURL {
            candidates.append(
                executableURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(".env")
            )
        }

        var seenPaths = Set<String>()
        return candidates.filter { seenPaths.insert($0.standardizedFileURL.path).inserted }
    }

    private static func unquoted(_ value: String) -> String {
        var cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.count >= 2,
           let first = cleaned.first,
           let last = cleaned.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            cleaned.removeFirst()
            cleaned.removeLast()
        }

        return cleaned
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned?.isEmpty == false ? cleaned : nil
    }

    private static func errorMessage(from data: Data) -> String {
        let rawMessage = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let rawMessage, !rawMessage.isEmpty else {
            return "No response body."
        }

        if rawMessage.count > 1_000 {
            return String(rawMessage.prefix(1_000))
        }

        return rawMessage
    }
}

private struct ModelResponse: Decodable {
    let latestVersion: ModelVersion?

    enum CodingKeys: String, CodingKey {
        case latestVersion = "latest_version"
    }
}

private struct ModelVersion: Decodable {
    let id: String
}

private struct CreatePredictionRequest: Encodable {
    let version: String
    let input: PredictionInput
}

private struct PredictionInput: Encodable {
    let image: String
    let upscaleMode = "target"
    let target = 4
    let outputFormat = "png"
    let enhanceDetails = false
    let enhanceRealism = false

    enum CodingKeys: String, CodingKey {
        case image
        case upscaleMode = "upscale_mode"
        case target
        case outputFormat = "output_format"
        case enhanceDetails = "enhance_details"
        case enhanceRealism = "enhance_realism"
    }
}

private struct PredictionResponse: Decodable {
    let id: String?
    let status: String
    let output: PredictionOutput?
    let error: String?
    let logs: String?
    let urls: PredictionURLs?
}

private struct PredictionURLs: Decodable {
    let get: URL?
    let cancel: URL?
}

private enum PredictionOutput: Decodable {
    case string(String)
    case strings([String])

    var firstURLString: String? {
        switch self {
        case .string(let value):
            value
        case .strings(let values):
            values.first
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }

        self = .strings(try container.decode([String].self))
    }
}

enum ReplicateImageUpscalerError: LocalizedError {
    case missingAPIKey
    case missingModelVersion
    case invalidResponse
    case requestFailed(statusCode: Int, message: String)
    case predictionFailed(String)
    case predictionCanceled
    case missingPredictionURL
    case missingOutput
    case invalidOutputURL(String)
    case cannotEncodePNG

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Missing REPLICATE_API_KEY. Add it to the process environment or to a .env file."
        case .missingModelVersion:
            "Could not resolve the latest prunaai/p-image-upscale model version."
        case .invalidResponse:
            "Replicate returned an invalid response."
        case .requestFailed(let statusCode, let message):
            "Replicate request failed with HTTP \(statusCode). \(message)"
        case .predictionFailed(let message):
            "Replicate image upscaling failed. \(message)"
        case .predictionCanceled:
            "Replicate image upscaling was canceled."
        case .missingPredictionURL:
            "Replicate did not return a prediction status URL."
        case .missingOutput:
            "Replicate did not return an upscaled image URL."
        case .invalidOutputURL(let output):
            "Replicate returned an invalid upscaled image URL: \(output)"
        case .cannotEncodePNG:
            "Could not encode the frame as PNG."
        }
    }
}
