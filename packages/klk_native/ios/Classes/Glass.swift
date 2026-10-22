import Flutter
import UIKit

/// Fondo de «cristal líquido» de Apple (iOS 26) para la barra de abajo de KLK.
/// En iPhones con un iOS anterior se usa el desenfoque clásico del sistema.
final class GlassViewFactory: NSObject, FlutterPlatformViewFactory {
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    GlassPlatformView(frame: frame, args: args as? [String: Any] ?? [:])
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }
}

final class GlassPlatformView: NSObject, FlutterPlatformView {
  private let container: UIView

  init(frame: CGRect, args: [String: Any]) {
    container = UIView(frame: frame)
    container.backgroundColor = .clear
    container.isUserInteractionEnabled = false
    let radius = CGFloat((args["radius"] as? NSNumber)?.doubleValue ?? 34)
    let dark = (args["dark"] as? Bool) ?? true

    let effectView = UIVisualEffectView(effect: GlassPlatformView.effect(dark: dark))
    effectView.frame = container.bounds
    effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    effectView.layer.cornerRadius = radius
    effectView.layer.cornerCurve = .continuous
    effectView.clipsToBounds = true
    container.addSubview(effectView)
    super.init()
  }

  func view() -> UIView { container }

  private static func effect(dark: Bool) -> UIVisualEffect {
    #if compiler(>=6.2)
      if #available(iOS 26.0, *) {
        let glass = UIGlassEffect()
        glass.isInteractive = false
        glass.tintColor = dark ? UIColor(white: 0.08, alpha: 0.35) : UIColor(white: 1, alpha: 0.25)
        return glass
      }
    #endif
    return UIBlurEffect(style: dark ? .systemUltraThinMaterialDark : .systemUltraThinMaterialLight)
  }
}
