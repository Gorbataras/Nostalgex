import Foundation

/// What we actually know about a stored token after a request came back 401/403.
enum TokenValidity: Equatable {
    /// An identity authority independent of the media server confirmed the token still works.
    case valid
    /// That authority rejected the token.
    case invalid
    /// No answer available: offline, timed out, or this backend has no authority separate
    /// from the server that just rejected us.
    case unknown
}
