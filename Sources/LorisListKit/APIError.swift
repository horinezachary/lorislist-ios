import Foundation

/// Every failure the API client can report. Branch on `code`, never on the message text;
/// the server's own messages are for people and may be reworded.
public struct APIError: Error, LocalizedError, Equatable, Sendable {
    public enum Code: String, Sendable {
        // Sent by the server (error.code in the JSON body).
        case invalidRequest = "invalid_request"
        case invalidJSON = "invalid_json"
        case unauthorized
        case invalidCredentials = "invalid_credentials"
        case invalidRefreshToken = "invalid_refresh_token"
        case wrongPassword = "wrong_password"
        case forbidden
        case notFound = "not_found"
        case emailInUse = "email_in_use"
        case usernameTaken = "username_taken"
        case tooLarge = "too_large"
        case tooManyRequests = "too_many_requests"
        case serverError = "server_error"
        case apiNotReady = "api_not_ready"
        // Raised by the client.
        case network
        case sessionExpired
        case unexpectedResponse
        case unknown
    }

    public let code: Code
    /// HTTP status, or 0 when there was no response.
    public let status: Int
    /// The server's message, when it sent one.
    public let message: String?
    /// Seconds to wait, from the Retry-After header of a 429.
    public let retryAfter: Int?

    public init(code: Code, status: Int = 0, message: String? = nil, retryAfter: Int? = nil) {
        self.code = code
        self.status = status
        self.message = message
        self.retryAfter = retryAfter
    }

    public static let sessionExpired = APIError(
        code: .sessionExpired, status: 401, message: "Your session has expired. Please sign in again.")
    public static let network = APIError(code: .network)
    public static let unexpected = APIError(code: .unexpectedResponse)

    /// Text that is fit to show in the app.
    public var errorDescription: String? {
        switch code {
        case .network:
            return "Can't reach Lori's List. Check your connection and try again."
        case .sessionExpired:
            return message ?? "Your session has expired. Please sign in again."
        case .tooManyRequests:
            let base = message ?? "Too many attempts."
            if let seconds = retryAfter, seconds > 0 {
                return "\(base) Try again in \(Self.waitText(seconds))."
            }
            return base
        case .serverError, .apiNotReady, .unexpectedResponse:
            return "Something went wrong on our end. Please try again in a moment."
        case .tooLarge:
            return "That is too much to send at once."
        case .unauthorized:
            return "Please sign in again."
        case .invalidJSON, .unknown, .invalidRequest, .invalidCredentials, .invalidRefreshToken,
             .wrongPassword, .forbidden, .notFound, .emailInUse, .usernameTaken:
            return message ?? "Something went wrong. Please try again."
        }
    }

    static func waitText(_ seconds: Int) -> String {
        if seconds >= 3600 {
            let hours = Int((Double(seconds) / 3600).rounded(.up))
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        if seconds >= 60 {
            let minutes = Int((Double(seconds) / 60).rounded(.up))
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        return seconds == 1 ? "1 second" : "\(seconds) seconds"
    }
}

/// `{"error": {"code": "...", "message": "..."}}`
struct ErrorEnvelope: Decodable {
    struct Body: Decodable {
        let code: String?
        let message: String?
    }

    let error: Body
}
