import Cocoa
import FlutterMacOS
import WebKit
import webview_flutter_wkwebview

class MainFlutterWindow: NSWindow {
  private var webViewAppearanceChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerWebViewAppearanceChannel(for: flutterViewController)

    super.awakeFromNib()
  }

  private func registerWebViewAppearanceChannel(
    for flutterViewController: FlutterViewController
  ) {
    let channel = FlutterMethodChannel(
      name: "com.subdock/embedded_webview_appearance",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "setAppearance" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard
        let arguments = call.arguments as? [String: Any],
        let identifier = arguments["webViewIdentifier"] as? NSNumber,
        let isDark = arguments["isDark"] as? Bool,
        let trustedOrigin = arguments["trustedOrigin"] as? String,
        let beforeLoad = arguments["beforeLoad"] as? Bool
      else {
        result(
          FlutterError(
            code: "invalid_arguments",
            message: "Invalid embedded WebView appearance arguments.",
            details: nil
          )
        )
        return
      }

      DispatchQueue.main.async { [weak self] in
        guard
          let self,
          let registry = self.contentViewController as? FlutterViewController
        else {
          result(false)
          return
        }
        guard
          let webView = FWFWebViewFlutterWKWebViewExternalAPI.webView(
            forIdentifier: identifier.int64Value,
            withPluginRegistry: registry
          )
        else {
          result(
            FlutterError(
              code: "webview_not_found",
              message: "Embedded WebView is no longer available.",
              details: nil
            )
          )
          return
        }

        if beforeLoad {
          guard webView.url == nil || webView.url?.absoluteString == "about:blank" else {
            result(false)
            return
          }
        } else {
          guard
            let currentURL = webView.url,
            Self.hasOrigin(currentURL, trustedOrigin: trustedOrigin)
          else {
            result(false)
            return
          }
        }

        guard
          let appearance = NSAppearance(
            named: isDark ? .darkAqua : .aqua
          )
        else {
          result(
            FlutterError(
              code: "appearance_unavailable",
              message: "Could not set embedded WebView appearance.",
              details: nil
            )
          )
          return
        }
        webView.appearance = appearance
        result(true)
      }
    }
    webViewAppearanceChannel = channel
  }

  private static func hasOrigin(_ url: URL, trustedOrigin: String) -> Bool {
    guard
      let current = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let trusted = URLComponents(string: trustedOrigin),
      current.scheme?.lowercased() == trusted.scheme?.lowercased(),
      current.host?.lowercased() == trusted.host?.lowercased()
    else {
      return false
    }
    guard
      let currentPort = effectivePort(current),
      let trustedPort = effectivePort(trusted)
    else {
      return false
    }
    return currentPort == trustedPort
  }

  private static func effectivePort(_ components: URLComponents) -> Int? {
    if let port = components.port { return port }
    guard let scheme = components.scheme?.lowercased() else { return nil }
    switch scheme {
    case "http": return 80
    case "https": return 443
    default: return nil
    }
  }
}
