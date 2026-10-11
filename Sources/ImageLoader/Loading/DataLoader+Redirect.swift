import Foundation

extension DataLoader {
    static func redirectRequest(_ request: URLRequest, originalRequest: URLRequest?) -> URLRequest {
        guard let originalRequest,
            let injectedHeaders = originalRequest.allHTTPHeaderFields,
            !injectedHeaders.isEmpty,
            shouldStripInjectedHeaders(from: originalRequest.url, to: request.url)
        else {
            return request
        }
        var request = request
        for name in injectedHeaders.keys {
            request.setValue(nil, forHTTPHeaderField: name)
        }
        return request
    }

    static func shouldStripInjectedHeaders(from originalURL: URL?, to redirectURL: URL?) -> Bool {
        guard let originalHost = normalizedHost(of: originalURL),
            let redirectHost = normalizedHost(of: redirectURL),
            originalHost == redirectHost
        else {
            return true
        }
        if effectivePort(of: originalURL) != effectivePort(of: redirectURL), !(usesDefaultPort(originalURL) && usesDefaultPort(redirectURL)) {
            return true
        }
        return isSecure(originalURL) && !isSecure(redirectURL)
    }

    private static func effectivePort(of url: URL?) -> Int? {
        url?.port ?? defaultPort(of: url)
    }

    private static func usesDefaultPort(_ url: URL?) -> Bool {
        url?.port == nil || url?.port == defaultPort(of: url)
    }

    private static func defaultPort(of url: URL?) -> Int? {
        switch url?.scheme?.lowercased() {
        case "https": 443
        case "http": 80
        default: nil
        }
    }

    private static func normalizedHost(of url: URL?) -> String? {
        guard let host = url?.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        return host
    }

    private static func isSecure(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == "https"
    }
}
