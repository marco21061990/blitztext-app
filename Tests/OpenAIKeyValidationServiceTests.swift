import Foundation

@main
struct OpenAIKeyValidationServiceTests {
    static func main() throws {
        try assertSuccessMessage()
        try assertErrorMessage()
        try assertMissingKeyMessage()
    }

    private static func assertSuccessMessage() throws {
        let result = OpenAIKeyValidationService.validationResult(
            statusCode: 200,
            data: Data(#"{"object":"list","data":[]}"#.utf8)
        )

        guard result == .success("OpenAI Key funktioniert.") else {
            throw TestFailure("Expected success message, got \(result)")
        }
    }

    private static func assertErrorMessage() throws {
        let result = OpenAIKeyValidationService.validationResult(
            statusCode: 401,
            data: Data(#"{"error":{"message":"Incorrect API key provided"}}"#.utf8)
        )

        guard result == .failure("Incorrect API key provided") else {
            throw TestFailure("Expected decoded API error, got \(result)")
        }
    }

    private static func assertMissingKeyMessage() throws {
        let result = OpenAIKeyValidationService.missingAPIKeyResult

        guard result == .failure("Bitte zuerst OpenAI API Key speichern.") else {
            throw TestFailure("Expected missing key error, got \(result)")
        }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
