//
//  ApiRequest.swift
//  ClashX
//
//  Created by CYC on 2018/7/30.
//  Copyright © 2018年 yichengchen. All rights reserved.
//

import Alamofire
import Cocoa
import Starscream
import SwiftyJSON

protocol ApiRequestStreamDelegate: AnyObject {
	func didUpdateTraffic(up: Int, down: Int)
	func didGetLog(log: String, level: String)
	func didUpdateMemory(memory: Int64)
	func streamStatusChanged()
}

typealias ErrorString = String

struct ClashVersion: Decodable {
	let version: String
	let meta: Bool?
}

class ApiRequest {
    static let shared = ApiRequest()

    private var proxyRespCache: ClashProxyResp?

    private lazy var logQueue = DispatchQueue(label: "com.ClashX.core.log")

    static let clashRequestQueue = DispatchQueue(label: "com.clashx.clashRequestQueue")

    @objc enum ProviderType: Int {
        case rule, proxy

        func apiString() -> String {
            self == .proxy ? "proxies" : "rules"
        }

        func logString() -> String {
            self == .proxy ? "Proxy" : "Rule"
        }
    }

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 604800
        configuration.timeoutIntervalForResource = 604800
        configuration.httpMaximumConnectionsPerHost = 100
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        alamoFireManager = Session(configuration: configuration)
    }

    static func authHeader() -> HTTPHeaders {
        let secret = ConfigManager.shared.overrideSecret ?? ConfigManager.shared.apiSecret
        return (!secret.isEmpty) ? ["Authorization": "Bearer \(secret)"] : [:]
    }

    @discardableResult
    private static func req(
        _ url: String,
        method: HTTPMethod = .get,
        parameters: Parameters? = nil,
        encoding: ParameterEncoding = URLEncoding.default
    )
        -> DataRequest {
        guard ConfigManager.shared.isRunning else {
            return AF.request("")
        }

        return shared.alamoFireManager
            .request(ConfigManager.apiUrl + url,
                     method: method,
                     parameters: parameters,
                     encoding: encoding,
                     headers: authHeader())
    }

    weak var delegate: ApiRequestStreamDelegate?
	weak var dashboardDelegate: ApiRequestStreamDelegate?

	private var trafficWebSocket: WebSocket?
	private var loggingWebSocket: WebSocket?
	private var memoryWebSocket: WebSocket?

	private var trafficWebSocketRetryDelay: TimeInterval = 1
	private var loggingWebSocketRetryDelay: TimeInterval = 1
	private var memoryWebSocketRetryDelay: TimeInterval = 1
	
	private var trafficWebSocketRetryTimer: Timer?
	private var loggingWebSocketRetryTimer: Timer?
	private var memoryWebSocketRetryTimer: Timer?
    
    private var logRateLimiter = LogRateLimiter {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Log system crashed.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Quit", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSApplication.shared.terminate(nil)
        }
    }

	private var alamoFireManager: Session

	static func requestVersion(completeHandler: @escaping ((ClashVersion?) -> Void)) {
		shared.alamoFireManager
			.request(ConfigManager.apiUrl + "/version",
					 method: .get,
					 headers: authHeader())
			.responseDecodable(of: ClashVersion.self) {
				resp in
				switch resp.result {
				case let .success(ver):
					completeHandler(ver)
				case let .failure(err):
					Logger.log("Request Version failed, \(err)", level: .error)
					completeHandler(nil)
				}
			}
	}

    static func requestConfig(completeHandler: @escaping ((ClashConfig) -> Void)) {
        req("/configs").responseDecodable(of: ClashConfig.self) {
            resp in
            switch resp.result {
            case let .success(config):
                completeHandler(config)
            case let .failure(err):
                Logger.log(err.localizedDescription)
				UserNotificationCenter.shared.post(title: "Error", info: err.localizedDescription)
            }
        }
    }

    static func findConfigPath(configName: String, callback: @escaping ((String?) -> Void)) {
        if ICloudManager.shared.useiCloud.value {
            ICloudManager.shared.getUrl { url in
                guard let url = url else {
                    callback(nil)
                    return
                }
                let configPath = url.appendingPathComponent(Paths.configFileName(for: configName)).path
                callback(configPath)
            }
        } else {
            let filePath = Paths.localConfigPath(for: configName)
            callback(filePath)
        }
    }

    static func requestConfigUpdate(configName: String, callback: @escaping ((ErrorString?) -> Void)) {
        findConfigPath(configName: configName) { path in
            guard let path = path else {
                callback("icloud error")
                return
            }
            
            guard ICloudManager.shared.useiCloud.value else {
                requestConfigUpdate(configPath: path, callback: callback)
                return
            }
            
            #warning("icloud operation not permitted")
            
            let tempPath = Paths.localConfigPath(for: kSafeConfigName)
            
            try? FileManager.default.removeItem(atPath: tempPath)
            
            do {
                try FileManager.default.copyItem(atPath: path, toPath: tempPath)
            } catch {
                callback("clashx_meta_config error \(error)")
                return
            }
            
            requestConfigUpdate(configPath: tempPath, callback: callback)
        }
    }

    static func requestConfigUpdate(configPath: String, callback: @escaping ((ErrorString?) -> Void)) {
        let placeHolderErrorDesp = "Error occoured, Please try to fix it by restarting ClashX. "
		req("/configs", method: .put, parameters: ["Path": configPath], encoding: JSONEncoding.default).responseData { res in
            if res.response?.statusCode == 204 {
                ConfigManager.shared.isRunning = true
                callback(nil)
            } else {
				let errorData = try? res.result.get()
                let err = JSON(errorData ?? Data())["message"].string ?? placeHolderErrorDesp
                Logger.log(err)
                callback(err)
            }
        }
    }

    static func updateOutBoundMode(mode: ClashProxyMode, callback: ((Bool) -> Void)? = nil) {
        req("/configs", method: .patch, parameters: ["mode": mode.rawValue], encoding: JSONEncoding.default)
            .responseData { response in
                switch response.result {
                case .success:
                    callback?(true)
                case .failure:
                    callback?(false)
                }
            }
    }

    static func updateLogLevel(level: ClashLogLevel, callback: ((Bool) -> Void)? = nil) {
        req("/configs", method: .patch, parameters: ["log-level": level.rawValue], encoding: JSONEncoding.default).responseData(completionHandler: { response in
            switch response.result {
            case .success:
                callback?(true)
            case .failure:
                callback?(false)
            }
        })
    }

    static func requestProxyGroupList(completeHandler: ((ClashProxyResp) -> Void)? = nil) {
        req("/proxies").responseData {
            res in
            let proxies = ClashProxyResp(try? res.result.get())
            ApiRequest.shared.proxyRespCache = proxies
            completeHandler?(proxies)
        }
    }

    static func requestProxyProviderList(completeHandler: ((ClashProviderResp) -> Void)? = nil) {
        req("/providers/proxies")
            .responseDecodable(of: ClashProviderResp.self, decoder: ClashProviderResp.decoder) { resp in
                switch resp.result {
                case let .success(providerResp):
                    completeHandler?(providerResp)
                case let .failure(err):
                    Logger.log("requestProxyProviderList error \(err.localizedDescription)")
                    completeHandler?(ClashProviderResp())
                }
            }
    }

    static func updateAllowLan(allow: Bool, completeHandler: (() -> Void)? = nil) {
        Logger.log("update allow lan:\(allow)", level: .debug)
        req("/configs",
            method: .patch,
            parameters: ["allow-lan": allow],
            encoding: JSONEncoding.default).response {
            _ in
            completeHandler?()
        }
    }

    static func updateProxyGroup(group: String, selectProxy: String, callback: @escaping ((Bool) -> Void)) {
        req("/proxies/\(group.encoded)",
            method: .put,
            parameters: ["name": selectProxy],
            encoding: JSONEncoding.default)
            .responseData { response in
                callback(response.response?.statusCode == 204)
            }
    }

    static func getAllProxyList(callback: @escaping (([ClashProxyName]) -> Void)) {
        requestProxyGroupList {
            proxyInfo in
            let lists: [ClashProxyName] = proxyInfo.proxiesMap["GLOBAL"]?.all ?? []
            callback(lists)
        }
    }

    static func getMergedProxyData(complete: ((ClashProxyResp?) -> Void)? = nil) {
        let group = DispatchGroup()
        group.enter()
        group.enter()

        var provider: ClashProviderResp?
        var proxyInfo: ClashProxyResp?

        group.notify(queue: .main) {
            guard let proxyInfo = proxyInfo, let proxyprovider = provider else {
                assertionFailure()
                complete?(nil)
                return
            }
            proxyInfo.updateProvider(proxyprovider)
            complete?(proxyInfo)
        }

        ApiRequest.requestProxyProviderList {
            proxyprovider in
            provider = proxyprovider
            group.leave()
        }

        ApiRequest.requestProxyGroupList {
            proxy in
            proxyInfo = proxy
            group.leave()
        }
    }

    static func getProxyDelay(proxyName: String, callback: @escaping ((Int) -> Void)) {
        req("/proxies/\(proxyName.encoded)/delay",
            method: .get,
            parameters: ["timeout": 2500, "url": ConfigManager.shared.benchMarkUrl])
            .responseData { res in
                switch res.result {
                case let .success(value):
                    let json = JSON(value)
                    callback(json["delay"].intValue)
                case .failure:
                    callback(0)
                }
            }
    }

    static func getGroupDelay(groupName: String, callback: @escaping (([String: Int]) -> Void)) {
        req("/group/\(groupName.encoded)/delay",
            method: .get,
            parameters: ["timeout": 2500, "url": ConfigManager.shared.benchMarkUrl])
            .responseData { res in
                switch res.result {
                case let .success(value):
                    let dic = try? JSONDecoder().decode([String: Int].self, from: value)
                    callback(dic ?? [:])
                case .failure:
                    callback([:])
                }
            }
    }

    static func getRules(completeHandler: @escaping ([ClashRule]) -> Void) {
        req("/rules").responseData { res in
            guard let data = try? res.result.get() else { return }
            let rule = ClashRuleResponse.fromData(data)
            completeHandler(rule.rules ?? [])
        }
    }

    static func healthCheck(proxy: ClashProviderName, completeHandler: (() -> Void)? = nil) {
        Logger.log("HeathCheck for \(proxy) started")
        req("/providers/proxies/\(proxy.encoded)/healthcheck").response { res in
            if res.response?.statusCode == 204 {
                Logger.log("HeathCheck for \(proxy) finished")
            } else {
                Logger.log("HeathCheck for \(proxy) failed:\(res.response?.statusCode ?? -1)")
            }
            completeHandler?()
        }
    }
}

// MARK: - Connections

extension ApiRequest {
    static func getConnections(completeHandler: @escaping ([ClashConnectionBaseSnapShot.Connection]) -> Void) {
        req("/connections").responseDecodable(of: ClashConnectionBaseSnapShot.self) { resp in
            switch resp.result {
            case let .success(snapshot):
                completeHandler(snapshot.connections)
            case .failure:
                assertionFailure()
                completeHandler([])
            }
        }
    }

    static func closeConnection(_ id: String) {
        req("/connections/\(id)", method: .delete).response { _ in }
    }
	
	static func getConnections(completeHandler: @escaping (DBConnectionSnapShot) -> Void) {
		
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .formatted(DateFormatter.js)
		
		req("/connections").responseDecodable(of: DBConnectionSnapShot.self, decoder: decoder) { resp in
			switch resp.result {
			case let .success(snapshot):
				completeHandler(snapshot)
			case .failure:
				return
//                assertionFailure()
//                completeHandler(DBConnectionSnapShot())
			}
		}
	}

	static func closeConnection(_ conn: ClashConnectionSnapShot.Connection) {
		req("/connections/".appending(conn.id), method: .delete).response { _ in }
	}

	static func closeAllConnection() {
		req("/connections", method: .delete).response { _ in }
	}
}

// MARK: - Meta

extension ApiRequest {
    static func updateAllProviders(for type: ProviderType, completeHandler: ((Int) -> Void)? = nil) {
        var failuresCount = 0

        let group = DispatchGroup()
        group.enter()

        if type == .proxy {
            requestProxyProviderList { resp in
                resp.allProviders.filter {
                    $0.value.vehicleType == .HTTP
                }.forEach {
                    group.enter()
                    updateProvider(for: .proxy, name: $0.key) {
                        if !$0 {
                            failuresCount += 1
                        }
                        group.leave()
                    }
                }
                group.leave()
            }
        } else {
            requestRuleProviderList { resp in
                resp.allProviders.forEach {
                    group.enter()
                    updateProvider(for: .rule, name: $0.key) {
                        if !$0 {
                            failuresCount += 1
                        }
                        group.leave()
                    }
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completeHandler?(failuresCount)
        }
    }

    static func updateProvider(for type: ProviderType, name: String, completeHandler: ((Bool) -> Void)? = nil) {
        let s = "Update \(type.logString()) Provider"

        Logger.log("\(s) \(name)")
        req("/providers/\(type.apiString())/\(name)", method: .put).response {
            let re = $0.response?.statusCode == 204
            Logger.log("\(s) \(name) \(re ? "success" : "failed")")
            completeHandler?(re)
        }
    }

    static func requestRuleProviderList(completeHandler: @escaping (ClashRuleProviderResp) -> Void) {
        req("/providers/rules")
            .responseDecodable(of: ClashRuleProviderResp.self, decoder: ClashProviderResp.decoder) { resp in
            switch resp.result {
            case let .success(providerResp):
                completeHandler(providerResp)
            case let .failure(err):
                Logger.log("Get Rule providers error \(err.errorDescription ?? "unknown")" )
                completeHandler(ClashRuleProviderResp())
            }
        }
    }

    static func updateGEO(completeHandler: ((Bool) -> Void)? = nil) {
        Logger.log("UpdateGEO")
        req("/configs/geo", method: .post).response {
            let re = $0.response?.statusCode == 204

            completeHandler?(re)
//            Logger.log("UpdateGEO \(re ? "success" : "failed")")
            Logger.log("Updating GEO Databases...")
        }
    }

    static func updateTun(enable: Bool, completeHandler: (() -> Void)? = nil) {
        Logger.log("update tun:\(enable)", level: .debug)

        // 当启用TUN模式时，检查是否需要同时添加DNS配置
        if enable {
            // 首先检查当前配置是否有DNS - 通过获取原始配置数据
            req("/configs").responseJSON { response in
                switch response.result {
                case let .success(json):
                    if let dict = json as? [String: Any] {
                        let needsDnsConfig = dict["dns"] == nil

                        if needsDnsConfig {
                            Logger.log("Adding DNS config for TUN mode", level: .info)
                            // 同时更新TUN和DNS配置
                            let parameters: [String: Any] = [
                                "tun": ["enable": enable],
                                "dns": [
                                    "enable": true,
                                    "prefer-h3": true,
                                    "ipv6": false,
                                    "enhanced-mode": "fake-ip",
                                    "fake-ip-range": "198.18.0.1/16",
                                    "respect-rules": true,
                                    "nameserver": [
                                        "system",
                                        "https://223.5.5.5/dns-query",
                                        "https://doh.pub/dns-query",
                                    ],
                                    "proxy-server-nameserver": [
                                        "https://223.5.5.5/dns-query",
                                        "https://doh.pub/dns-query",
                                    ],
                                ],
                            ]
                            self.req(
                                "/configs",
                                method: .patch,
                                parameters: parameters,
                                encoding: JSONEncoding.default
                            ).response { _ in
                                completeHandler?()
                            }
                        } else {
                            // 只更新TUN配置
                            self.req(
                                "/configs",
                                method: .patch,
                                parameters: ["tun": ["enable": enable]],
                                encoding: JSONEncoding.default
                            ).response { _ in
                                completeHandler?()
                            }
                        }
                    } else {
                        // JSON解析失败，只更新TUN配置
                        self.req(
                            "/configs",
                            method: .patch,
                            parameters: ["tun": ["enable": enable]],
                            encoding: JSONEncoding.default
                        ).response { _ in
                            completeHandler?()
                        }
                    }
                case .failure(_):
                    // 请求失败，只更新TUN配置
                    self.req(
                        "/configs",
                        method: .patch,
                        parameters: ["tun": ["enable": enable]],
                        encoding: JSONEncoding.default
                    ).response { _ in
                        completeHandler?()
                    }
                }
            }
        } else {
            // 禁用TUN模式时，只更新TUN配置
            req(
                "/configs",
                method: .patch,
                parameters: ["tun": ["enable": enable]],
                encoding: JSONEncoding.default
            ).response { _ in
                completeHandler?()
            }
        }
    }

    static func updateSniffing(enable: Bool, completeHandler: (() -> Void)? = nil) {
        Logger.log("update sniffing:\(enable)", level: .debug)
        req("/configs",
            method: .patch,
            parameters: ["sniffing": enable],
            encoding: JSONEncoding.default).response {
            _ in
            completeHandler?()
        }
    }
    
    static func flushDNSCache() {
        let group = DispatchGroup()
        
        var flushFakeipCacheResult = false
        var flushDNSCacheResult = false
        
        group.enter()
        ApiRequest.flushFakeipCache {
            flushFakeipCacheResult = $0
            group.leave()
        }
        
        group.enter()
        ApiRequest.flushDNSCache {
            flushDNSCacheResult = $0
            group.leave()
        }
        
        group.notify(queue: .main) {
            let info = (flushFakeipCacheResult && flushDNSCacheResult) ? "Success" : "Failed"
            UserNotificationCenter.shared.post(title: NSLocalizedString("Flush dns cache", comment: ""), info: info)
        }
    }

    private static func flushFakeipCache(completeHandler: ((Bool) -> Void)? = nil) {
        Logger.log("FlushFakeipCache")
        req("/cache/fakeip/flush",
            method: .post).response {
            let re = $0.response?.statusCode == 204
            completeHandler?(re)
            Logger.log("FlushFakeipCache \(re ? "success" : "failed")")
        }
    }
    
    private static func flushDNSCache(completeHandler: ((Bool) -> Void)? = nil) {
        Logger.log("FlushDNSCache")
        req("/cache/dns/flush",
            method: .post).response {
            let re = $0.response?.statusCode == 204
            completeHandler?(re)
            Logger.log("FlushDNSCache \(re ? "success" : "failed")")
        }
    }

    // MARK: - Providers

    struct AllProviders {
        var proxies = [String]()
        var rules = [String]()
    }

    static func requestExternalProviderNames(completeHandler: @escaping (AllProviders) -> Void) {
        var providers = AllProviders()
        let group = DispatchGroup()
        group.enter()
        ApiRequest.req("/providers/proxies").responseData { resp in
            switch resp.result {
            case let .success(res):
                let json = JSON(res)
                let provoders = json["providers"].dictionaryValue
                    .filter { $0.value["vehicleType"] == "HTTP" }.map(\.key)
                providers.proxies = provoders
            case let .failure(err):
                Logger.log(err.localizedDescription, level: .warning)
            }
            group.leave()
        }

        #if PRO_VERSION
            group.enter()
            ApiRequest.req("/providers/rules").responseData { resp in
                switch resp.result {
                case let .success(res):
                    let json = JSON(res)
                    let provoders = json["providers"].dictionaryValue
                        .filter { $0.value["vehicleType"] == "HTTP" }.map(\.key)
                    providers.rules = provoders
                case let .failure(err):
                    Logger.log(err.localizedDescription, level: .warning)
                }
                group.leave()
            }
        #endif
        group.notify(queue: .main) {
            completeHandler(providers)
        }
    }

	/*
    enum ProviderType {
        case proxy
        case rule
    }
	 */

    static func updateProvider(name: String, type: ProviderType, completeHandler: @escaping (Bool) -> Void) {
        let url: String
        switch type {
        case .proxy:
            url = "/providers/proxies/\(name.encoded)"
        case .rule:
            url = "/providers/rules/\(name.encoded)"
        }
        ApiRequest.req(url, method: .put).response { resp in
            if resp.response?.statusCode == 204 {
                completeHandler(true)
            } else {
                completeHandler(false)
            }
        }
    }

    static func resetFakeIpCache() {
        ApiRequest.req("/cache/fakeip/flush", method: .post).response { resp in
            Logger.log("flush fake ip: \(resp.response?.statusCode ?? -1)")
        }
    }
}

// MARK: - Stream Apis

extension ApiRequest {
	func resetStreamApis() {
		resetLogStreamApi()
		resetTrafficStreamApi()
		resetMemoryStreamApi()
	}

    func resetLogStreamApi() {
        loggingWebSocketRetryTimer?.invalidate()
        loggingWebSocketRetryTimer = nil
        loggingWebSocketRetryDelay = 1
        requestLog()
    }

    func resetTrafficStreamApi() {
        trafficWebSocketRetryTimer?.invalidate()
        trafficWebSocketRetryTimer = nil
        trafficWebSocketRetryDelay = 1
        requestTrafficInfo()
    }
	
	func resetMemoryStreamApi() {
		memoryWebSocketRetryTimer?.invalidate()
		memoryWebSocketRetryTimer = nil
		memoryWebSocketRetryDelay = 1
		requestMemoryInfo()
	}

    private func requestTrafficInfo() {
        trafficWebSocketRetryTimer?.invalidate()
        trafficWebSocketRetryTimer = nil
        trafficWebSocket?.disconnect(forceTimeout: 0.5)

        let socket = WebSocket(url: URL(string: ConfigManager.apiUrl.appending("/traffic"))!)

        for header in ApiRequest.authHeader() {
            socket.request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        socket.delegate = self
        socket.connect()
        trafficWebSocket = socket
    }

    private func requestLog() {
        loggingWebSocketRetryTimer?.invalidate()
        loggingWebSocketRetryTimer = nil
        loggingWebSocket?.disconnect(forceTimeout: 1)

        let uriString = "/logs?level=".appending(ConfigManager.selectLoggingApiLevel.rawValue)
        let socket = WebSocket(url: URL(string: ConfigManager.apiUrl.appending(uriString))!)
        for header in ApiRequest.authHeader() {
            socket.request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        socket.delegate = self
        socket.callbackQueue = logQueue
        socket.connect()
        loggingWebSocket = socket
    }
	
	private func requestMemoryInfo() {
		memoryWebSocketRetryTimer?.invalidate()
		memoryWebSocketRetryTimer = nil
		memoryWebSocket?.disconnect(forceTimeout: 1)
		
		let socket = WebSocket(url: URL(string: ConfigManager.apiUrl.appending("/memory"))!)
		for header in ApiRequest.authHeader() {
			socket.request.setValue(header.value, forHTTPHeaderField: header.name)
		}
		socket.delegate = self
		socket.connect()
		memoryWebSocket = socket
	}
}

extension ApiRequest: WebSocketDelegate {
	func websocketDidConnect(socket: WebSocketClient) {
		guard let webSocket = socket as? WebSocket else { return }
		switch webSocket {
		case trafficWebSocket:
			trafficWebSocketRetryDelay = 1
			Logger.log("trafficWebSocket did Connect", level: .debug)
			
			ConfigManager.shared.isRunning = true
			delegate?.streamStatusChanged()
			dashboardDelegate?.streamStatusChanged()
		case loggingWebSocket:
			loggingWebSocketRetryDelay = 1
			Logger.log("loggingWebSocket did Connect", level: .debug)
		case memoryWebSocket:
			memoryWebSocketRetryDelay = 1
			Logger.log("memoryWebSocket did Connect", level: .debug)
		default:
			return
		}
	}

	func websocketDidDisconnect(socket: WebSocketClient, error: Error?) {
		
		if (socket as? WebSocket) == trafficWebSocket {
			ConfigManager.shared.isRunning = false
			delegate?.streamStatusChanged()
			dashboardDelegate?.streamStatusChanged()
		}
		
		guard let err = error else {
			return
		}

		Logger.log(err.localizedDescription, level: .error)

		guard let webSocket = socket as? WebSocket else { return }

		switch webSocket {
		case trafficWebSocket:
			Logger.log("trafficWebSocket did disconnect", level: .debug)
			
			trafficWebSocketRetryTimer?.invalidate()
			trafficWebSocketRetryTimer =
				Timer.scheduledTimer(withTimeInterval: trafficWebSocketRetryDelay, repeats: false, block: {
					[weak self] _ in
					if self?.trafficWebSocket?.isConnected == true { return }
					self?.requestTrafficInfo()
				})
			trafficWebSocketRetryDelay *= 2
		case loggingWebSocket:
			Logger.log("loggingWebSocket did disconnect", level: .debug)
			loggingWebSocketRetryTimer =
				Timer.scheduledTimer(withTimeInterval: loggingWebSocketRetryDelay, repeats: false, block: {
					[weak self] _ in
					if self?.loggingWebSocket?.isConnected == true { return }
					self?.requestLog()
				})
			loggingWebSocketRetryDelay *= 2
		case memoryWebSocket:
			Logger.log("memoryWebSocket did disconnect", level: .debug)
			
			memoryWebSocketRetryTimer =
				Timer.scheduledTimer(withTimeInterval: memoryWebSocketRetryDelay, repeats: false, block: {
					[weak self] _ in
					if self?.memoryWebSocket?.isConnected == true { return }
					self?.requestMemoryInfo()
				})
			
			memoryWebSocketRetryDelay *= 2
		default:
			return
		}
	}

	func websocketDidReceiveMessage(socket: WebSocketClient, text: String) {
		guard let webSocket = socket as? WebSocket else { return }
		let json = JSON(parseJSON: text)
		
		
		switch webSocket {
		case trafficWebSocket:
			delegate?.didUpdateTraffic(up: json["up"].intValue, down: json["down"].intValue)
			dashboardDelegate?.didUpdateTraffic(up: json["up"].intValue, down: json["down"].intValue)
		case loggingWebSocket:
            Task {
                guard await logRateLimiter.processLog() else { return }
                delegate?.didGetLog(log: json["payload"].stringValue, level: json["type"].string ?? "info")
                dashboardDelegate?.didGetLog(log: json["payload"].stringValue, level: json["type"].string ?? "info")
            }
		case memoryWebSocket:
			delegate?.didUpdateMemory(memory: json["inuse"].int64Value)
			dashboardDelegate?.didUpdateMemory(memory: json["inuse"].int64Value)
		default:
			return
		}
	}

	func websocketDidReceiveData(socket: WebSocketClient, data: Data) {}
}
