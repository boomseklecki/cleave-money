import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

/// Builds the generated `Client` with the URLSession transport, the configured base URL, the
/// fractional-seconds-tolerant date transcoder, and the bearer-auth middleware. Single place that
/// assembles the API client for repositories.
enum APIClientFactory {
    /// `requestTimeout` is the per-request inactivity timeout. The default 60s is fine for normal calls,
    /// but the Splitwise cold-backfill import can run for minutes with no data flowing until it finishes - 
    /// so that client is built with a longer timeout to avoid a spurious NSURLErrorTimedOut.
    static func makeClient(
        baseURL: URL = APIConfig.baseURL,
        tokenStore: KeychainTokenStore = .forServer(APIConfig.baseURL),  // per-server slot, never the legacy global one
        requestTimeout: TimeInterval = 60
    ) -> Client {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        let session = URLSession(configuration: configuration)
        return Client(
            serverURL: baseURL,
            configuration: Configuration(dateTranscoder: FlexibleDateTranscoder()),
            transport: URLSessionTransport(configuration: .init(session: session)),
            middlewares: [AuthMiddleware(tokenProvider: { tokenStore.load() }),
                          IdempotencyMiddleware(), ResponseErrorMiddleware()]
        )
    }
}
