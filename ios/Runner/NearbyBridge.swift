// v4: automatic Bluetooth link with Google Nearby Connections
// (Swift package github.com/google/nearby, pinned in the Xcode project).
// Mirrors android/.../NearbyBridge.kt: same service id, cluster strategy,
// advertise + discover at once, auto-accept, bytes payloads only.
// Mediums: BLE and Wi-Fi LAN only. Wi-Fi Hotspot / wifi-info entitlements
// are not available to a free Apple account, so they are not used.
import Flutter
import Foundation
import NearbyConnections

final class NearbyBridge: NSObject {
  static let shared = NearbyBridge()

  private var channel: FlutterMethodChannel?
  private var manager: ConnectionManager?
  private var advertiser: Advertiser?
  private var discoverer: Discoverer?
  private var info = Data()
  private var running = false
  private var connected = Set<String>()
  private let mediums: Set<Medium> = [.ble, .wifiLAN]

  func attach(messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: "planechat/nearby", binaryMessenger: messenger)
    ch.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    channel = ch
  }

  private func emit(_ method: String, _ args: [String: Any]) {
    DispatchQueue.main.async { self.channel?.invokeMethod(method, arguments: args) }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "start":
      let serviceId = args["serviceId"] as? String ?? "il.planechat.plane_chat"
      info = (args["info"] as? String ?? "").data(using: .utf8) ?? Data()
      running = true
      let m = ConnectionManager(serviceID: serviceId, strategy: .cluster)
      m.delegate = self
      manager = m
      let a = Advertiser(connectionManager: m)
      a.delegate = self
      advertiser = a
      let d = Discoverer(connectionManager: m)
      d.delegate = self
      discoverer = d
      startBoth(result)
    case "stop":
      running = false
      advertiser?.stopAdvertising()
      discoverer?.stopDiscovery()
      for id in connected { manager?.disconnect(from: id) }
      connected.removeAll()
      advertiser = nil
      discoverer = nil
      manager = nil
      result(nil)
    case "connect":
      guard let id = args["id"] as? String, let d = discoverer else {
        result(FlutterError(code: "error", message: "not started", details: nil))
        return
      }
      d.requestConnection(to: id, using: info, mediums: mediums) { error in
        DispatchQueue.main.async {
          if let error = error {
            result(FlutterError(code: "error", message: error.localizedDescription, details: nil))
          } else {
            result(nil)
          }
        }
      }
    case "send":
      guard let id = args["id"] as? String,
        let bytes = args["bytes"] as? FlutterStandardTypedData, let m = manager
      else {
        result(FlutterError(code: "error", message: "bad send", details: nil))
        return
      }
      _ = m.send(bytes.data, to: [id]) { error in
        DispatchQueue.main.async {
          if let error = error {
            result(FlutterError(code: "error", message: error.localizedDescription, details: nil))
          } else {
            result(nil)
          }
        }
      }
    case "disconnect":
      if let id = args["id"] as? String {
        manager?.disconnect(from: id)
        connected.remove(id)
        if running && connected.isEmpty { restart() }
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Advertise and discover; succeed if at least one of them starts.
  private func startBoth(_ result: FlutterResult?) {
    guard let a = advertiser, let d = discoverer else {
      result?(FlutterError(code: "error", message: "not started", details: nil))
      return
    }
    var pending = 2
    var ok = false
    var firstError: Error?
    let done: (Error?) -> Void = { error in
      DispatchQueue.main.async {
        if error == nil { ok = true } else if firstError == nil { firstError = error }
        pending -= 1
        if pending == 0, let result = result {
          if ok {
            result(nil)
          } else {
            result(FlutterError(code: "error",
              message: firstError?.localizedDescription ?? "Bluetooth start failed", details: nil))
          }
        }
      }
    }
    a.startAdvertising(using: info, mediums: mediums, completionHandler: done)
    d.startDiscovery(mediums: mediums, completionHandler: done)
  }

  private func restart() {
    advertiser?.stopAdvertising()
    discoverer?.stopDiscovery()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self = self, self.running else { return }
      self.startBoth(nil)
    }
  }
}

extension NearbyBridge: AdvertiserDelegate {
  func advertiser(
    _ advertiser: Advertiser, didReceiveConnectionRequestFrom endpointID: EndpointID,
    with context: Data, connectionRequestHandler: @escaping (Bool) -> Void
  ) {
    emit("initiated", ["id": endpointID, "incoming": true])
    connectionRequestHandler(true)
  }
}

extension NearbyBridge: DiscovererDelegate {
  func discoverer(_ discoverer: Discoverer, didFind endpointID: EndpointID, with context: Data) {
    emit("found", ["id": endpointID, "info": String(data: context, encoding: .utf8) ?? ""])
  }

  func discoverer(_ discoverer: Discoverer, didLose endpointID: EndpointID) {
    emit("lost", ["id": endpointID])
  }
}

extension NearbyBridge: ConnectionManagerDelegate {
  func connectionManager(
    _ connectionManager: ConnectionManager, didReceive verificationCode: String,
    from endpointID: EndpointID, verificationHandler: @escaping (Bool) -> Void
  ) {
    verificationHandler(true)
  }

  func connectionManager(
    _ connectionManager: ConnectionManager, didReceive data: Data, withID payloadID: PayloadID,
    from endpointID: EndpointID
  ) {
    emit("data", ["id": endpointID, "bytes": FlutterStandardTypedData(bytes: data)])
  }

  func connectionManager(
    _ connectionManager: ConnectionManager, didReceive stream: InputStream,
    withID payloadID: PayloadID, from endpointID: EndpointID,
    cancellationToken token: CancellationToken
  ) {}

  func connectionManager(
    _ connectionManager: ConnectionManager, didStartReceivingResourceWithID payloadID: PayloadID,
    from endpointID: EndpointID, at localURL: URL, withName name: String,
    cancellationToken token: CancellationToken
  ) {}

  func connectionManager(
    _ connectionManager: ConnectionManager, didReceiveTransferUpdate update: TransferUpdate,
    from endpointID: EndpointID, forPayload payloadID: PayloadID
  ) {}

  func connectionManager(
    _ connectionManager: ConnectionManager, didChangeTo state: ConnectionState,
    for endpointID: EndpointID
  ) {
    switch state {
    case .connecting:
      emit("initiated", ["id": endpointID])
    case .connected:
      connected.insert(endpointID)
      advertiser?.stopAdvertising()
      discoverer?.stopDiscovery()
      emit("connected", ["id": endpointID])
    case .disconnected:
      let was = connected.remove(endpointID) != nil
      emit("disconnected", ["id": endpointID])
      if running && connected.isEmpty && was { restart() }
    case .rejected:
      emit("rejected", ["id": endpointID, "reason": "rejected"])
    }
  }
}
