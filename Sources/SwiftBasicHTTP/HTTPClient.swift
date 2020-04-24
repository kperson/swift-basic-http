import Foundation
import NIOOpenSSL
import NIOHTTP1
import NIO
import NIOFoundationCompat

extension URL {
    
    var removeSchemeHostPort: String? {
        if let s = scheme, let h = host {
            let target = port.map { p in "\(s)://\(h):\(p)" } ?? "\(s)://\(h)"
            if let range = absoluteString.range(of: target) {
                return absoluteString.replacingCharacters(in: range, with: "")
            }
            else {
                return nil
            }
        }
        else {
            return nil
        }
        
    }
    
}

public enum RequestMethod : String {
    
    case POST = "POST"
    case GET = "GET"
    case DELETE = "DELETE"
    case PUT = "PUT"
    case OPTIONS = "OPTIONS"
    case CONNECT = "CONNECT"
    case TRACE = "TRACE"
    case HEAD = "HEAD"
    case PATCH = "PATCH"
    
}


extension RequestMethod {
    
    var httpMethod: HTTPMethod {
        switch self {
        case .POST: return .POST
        case .GET: return .GET
        case .DELETE: return .DELETE
        case .PUT: return .PUT
        case .OPTIONS: return .OPTIONS
        case .CONNECT: return .CONNECT
        case .TRACE: return .TRACE
        case .PATCH: return .PATCH
        case .HEAD: return .HEAD
        }
    }
    
}

public struct HttpRequest {
    
    public let requestMethod: RequestMethod
    public let url: URL
    public let body: Data?
    public let headers: Dictionary<String, String>?
    
    public init(
        requestMethod: RequestMethod,
        url: URL,
        body: Data?,
        headers: Dictionary<String, String>?
    ) {
        self.requestMethod = requestMethod
        self.url = url
        self.body = body
        self.headers = headers
    }
    
    public func withNewURL(newURL: URL) -> HttpRequest {
        return HttpRequest(requestMethod: requestMethod, url: newURL, body: body, headers: headers)
    }
    
}

public struct HttpResponse {
    
    public let statusCode: UInt
    public let body: Data
    public let headers: Dictionary<String, String>
    
}

public extension HttpResponse {
    
    var bodyAsText: String {
        return String(data: body, encoding: .utf8) ?? ""
    }
}

public enum HTTPRequestError: Error {
    case malformedHead, malformedBody, malformedURL, tooManyRedirects, error(Error)
}


private enum HTTPClientState {
    case ready
    case parsingBody(HTTPResponseHead, Data?)
}

private class HTTPClientResponseHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HttpResponse

    private var receiveds: [HTTPClientResponsePart] = []
    private var state: HTTPClientState = .ready
    private var promise: EventLoopPromise<HttpResponse>

    public init(promise: EventLoopPromise<HttpResponse>) {
        self.promise = promise
    }

    func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        promise.fail(error: HTTPRequestError.error(error))
        ctx.fireErrorCaught(error)
    }
    
    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            switch state {
            case .ready: state = .parsingBody(head, nil)
            case .parsingBody: assert(false, "Unexpected HTTPClientResponsePart.head when body was being parsed.")
            }
        case .body(var body):
            switch state {
            case .ready: assert(false, "Unexpected HTTPClientResponsePart.body when awaiting request head.")
            case .parsingBody(let head, let existingData):
                let data: Data
                if var existing = existingData {
                    existing += body.readData(length: body.readableBytes) ?? Data()
                    data = existing
                } else {
                    data = body.readData(length: body.readableBytes) ?? Data()
                }
                state = .parsingBody(head, data)
            }
        case .end(let tailHeaders):
            assert(tailHeaders == nil, "Unexpected tail headers")
            switch state {
            case .ready: assert(false, "Unexpected HTTPClientResponsePart.end when awaiting request head.")
            case .parsingBody(let head, let data):
                var responseHeaders: [String : String] = [:]
                head.headers.forEach { k, v in
                    responseHeaders[k.lowercased()] = v
                }
                let res = HttpResponse(statusCode: head.status.code, body: data ?? Data(), headers: responseHeaders)
                ctx.fireChannelRead(wrapOutboundOut(res))
                promise.succeed(result: res)
                state = .ready
            }
        }
    }

}

private class RequestInvoker {
   
    let hostname: String
    let headerHostname: String
    let port: Int
    let request: HttpRequest
    let eventGroup: EventLoopGroup
    let remainingAttempts: Int
    let isSecure: Bool

    init(
        request: HttpRequest,
        eventGroup: EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount),
        remainingAttempts: Int = 4
    ) {
        self.request = request
        self.eventGroup = eventGroup
        self.remainingAttempts = remainingAttempts
        let scheme = request.url.scheme!
        self.hostname = request.url.host!
        self.isSecure = scheme == "https"
        if let port = request.url.port {
            self.port = port
            self.headerHostname = "\(hostname):\(port)"
        }
        else {
            self.port = isSecure ? 443 : 80
            self.headerHostname = self.hostname
        }
    }
    

    public func run() -> EventLoopFuture<HttpResponse> {
        let uri = request.url.removeSchemeHostPort!
        var head = HTTPRequestHead(
            version: .init(major: 1, minor: 1),
            method: request.requestMethod.httpMethod,
            uri: uri.isEmpty ? "/" : uri
        )
        let body = request.body ?? Data()
        head.headers.replaceOrAdd(name: "Host", value: headerHostname)
        head.headers.replaceOrAdd(name: "User-Agent", value: "SwiftBasicHTTP")
        head.headers.replaceOrAdd(name: "Content-Length", value: String(body.count))
        head.headers.replaceOrAdd(name: "Connection", value: "Close")
        
        if let additionalHeaders = request.headers {
            for (k, v) in additionalHeaders {
                head.headers.replaceOrAdd(name: k, value: v)
            }
        }

        var preHandlers = [ChannelHandler]()
        if isSecure {
            do {
                let tlsConfiguration = TLSConfiguration.forClient()
                let sslContext = try SSLContext(configuration: tlsConfiguration)
                let tlsHandler = try OpenSSLClientHandler(context: sslContext, serverHostname: hostname)
                preHandlers.append(tlsHandler)
            } catch {
                print("Unable to setup TLS: \(error)")
            }
        }
        let response: EventLoopPromise<HttpResponse> = eventGroup.next().newPromise()

        _ = ClientBootstrap(group: eventGroup)
            .connectTimeout(TimeAmount.seconds(10))
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelInitializer { channel in
                let accumulation = HTTPClientResponseHandler(promise: response)
                let results = preHandlers.map { channel.pipeline.add(handler: $0) }
                return EventLoopFuture<Void>.andAll(results, eventLoop: channel.eventLoop).then {
                    channel.pipeline.addHTTPClientHandlers().then {
                        channel.pipeline.add(handler: accumulation)
                    }
                }
            }
            .connect(host: hostname, port: port)
            .then { channel -> EventLoopFuture<Void> in
                channel.write(NIOAny(HTTPClientRequestPart.head(head)), promise: nil)
                if !body.isEmpty {
                    var buffer = ByteBufferAllocator().buffer(capacity: body.count)
                    buffer.write(bytes: body)
                    channel.write(NIOAny(HTTPClientRequestPart.body(.byteBuffer(buffer))), promise: nil)
                }
                return channel.writeAndFlush(NIOAny(HTTPClientRequestPart.end(nil)))
            }
            .whenFailure { error in
                response.fail(error: error)
            }
        return response.futureResult.then { res in
            if res.statusCode == 301 || res.statusCode == 302 || res.statusCode == 307 {
                if self.remainingAttempts <= 1 {
                    return self.eventGroup.next().newFailedFuture(error: HTTPRequestError.tooManyRedirects)
                }
                else if let location = res.headers["location"], let url = URL(string: location) {
                    let invoker = RequestInvoker(
                        request:
                        self.request.withNewURL(newURL: url),
                        eventGroup: self.eventGroup,
                        remainingAttempts: self.remainingAttempts - 1
                    )
                    return invoker.run()
                }
            }
            return self.eventGroup.next().newSucceededFuture(result: res)
        }
    }
}

public class HttpClient {
        
    public static let shared: HttpClient = HttpClient()
    public let eventGroup: EventLoopGroup

    public init(eventGroup: EventLoopGroup? = nil) {
        self.eventGroup = eventGroup ?? MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    }
    
    public func runRequest(
        request: HttpRequest
    ) -> EventLoopFuture<HttpResponse> {
        let invoker = RequestInvoker(request: request, eventGroup: eventGroup)
        return invoker.run()
    }
    
    public func close() {
        try? eventGroup.syncShutdownGracefully()
    }
}

public extension HttpClient {

    func get(url: URL, headers: [String : String] = [:]) -> EventLoopFuture<HttpResponse> {
        let request = HttpRequest(
            requestMethod: .GET,
            url: url,
            body: nil,
            headers: headers
        )
        return self.runRequest(request: request)
    }
    
    func get(urlString: String, headers: [String : String] = [:]) -> EventLoopFuture<HttpResponse> {
        return get(url: URL(string: urlString)!, headers: headers)
    }
    
    func post(url: URL, body: Data?, headers: [String : String] = [:]) -> EventLoopFuture<HttpResponse> {
        let request = HttpRequest(
            requestMethod: .POST,
            url: url,
            body: body,
            headers: headers
        )
        return self.runRequest(request: request)
    }
    
    func post(urlString: String, body: Data?, headers: [String : String] = [:]) -> EventLoopFuture<HttpResponse> {
        return post(url: URL(string: urlString)!, body: body, headers: headers)
    }
    
    func put(url: URL, body: Data? = nil, headers: [String : String] = [:]) -> EventLoopFuture<HttpResponse> {
        let request = HttpRequest(
            requestMethod: .PUT,
            url: url,
            body: body,
            headers: headers
        )
        return self.runRequest(request: request)
    }
    
    func put(urlString: String, body: Data?, headers: [String : String] = [:]) -> EventLoopFuture<HttpResponse> {
        return put(url: URL(string: urlString)!, body: body, headers: headers)
    }
    
    func patch(url: URL, body: Data? = nil, headers: [String : String] = [:]) -> EventLoopFuture<HttpResponse> {
        let request = HttpRequest(
            requestMethod: .PATCH,
            url: url,
            body: body,
            headers: headers
        )
        return self.runRequest(request: request)
    }
    
    func patch(urlString: String, body: Data?, headers: [String : String] = [:]) -> EventLoopFuture<HttpResponse> {
        return patch(url: URL(string: urlString)!, body: body, headers: headers)
    }
    
    func delete(url: URL, body: Data? = nil, headers: [String : String] = [:]) -> EventLoopFuture<HttpResponse> {
        let request = HttpRequest(
            requestMethod: .DELETE,
            url: url,
            body: body,
            headers: headers
        )
        return self.runRequest(request: request)
    }
    
    func delete(urlString: String, body: Data?, headers: [String : String] = [:]) -> EventLoopFuture<HttpResponse> {
        return delete(url: URL(string: urlString)!, body: body, headers: headers)
    }
    
}
