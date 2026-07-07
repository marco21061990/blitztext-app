import Foundation

enum OpenAIKeyValidationResult: Equatable {
    case success(String)
    case failure(String)
}

private struct OpenAIKeyValidationErrorResponse: Decodable {
    struct APIError: Decodable {
        let message: String?
    }

    let error: APIError?
}

enum OpenAIKeyValidationService {
    static let missingAPIKeyResult: OpenAIKeyValidationResult = .failure("Bitte zuerst OpenAI API Key speichern.")

    private static let modelsURL = URL(string: "https://api.openai.com/v1/models")!

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }()

    static func validateStoredKey() async -> OpenAIKeyValidationResult {
        guard let apiKey = KeychainService.load(key: .openAIAPIKey) else {
            return missingAPIKeyResult
        }

        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure("OpenAI hat keine gueltige HTTP-Antwort geliefert.")
            }
            return validationResult(statusCode: httpResponse.statusCode, data: data)
        } catch {
            return .failure("OpenAI Key konnte nicht getestet werden: \(error.localizedDescription)")
        }
    }

    static func validationResult(statusCode: Int, data: Data) -> OpenAIKeyValidationResult {
        guard (200..<300).contains(statusCode) else {
            return .failure(openAIErrorMessage(from: data) ?? "OpenAI API antwortet mit Status \(statusCode).")
        }

        return .success("OpenAI Key funktioniert.")
    }

    private static func openAIErrorMessage(from data: Data) -> String? {
        (try? JSONDecoder().decode(OpenAIKeyValidationErrorResponse.self, from: data))?.error?.message
    }
}
