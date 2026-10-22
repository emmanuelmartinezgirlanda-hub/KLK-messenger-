import Flutter
import StoreKit
import UIKit

/// KLK Plus con las compras de Apple (StoreKit 2). Apple cobra; nosotros solo
/// recibimos la compra firmada (JWS) y el servidor la comprueba.
enum PlusStore {
  static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) -> Bool {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "storeProducts":
      let ids = args["ids"] as? [String] ?? []
      if #available(iOS 15.0, *) {
        Task {
          do {
            let products = try await Product.products(for: ids)
            let list: [[String: Any]] = products.map { p in
              var m: [String: Any] = [
                "id": p.id, "price": p.displayPrice, "title": p.displayName,
                "amount": NSDecimalNumber(decimal: p.price).doubleValue,
              ]
              if let s = p.subscription {
                m["unit"] = unitName(s.subscriptionPeriod.unit)
                m["count"] = s.subscriptionPeriod.value
                if let intro = s.introductoryOffer, intro.paymentMode == .freeTrial {
                  m["trialUnit"] = unitName(intro.period.unit)
                  m["trialCount"] = intro.period.value
                }
              }
              return m
            }
            done(result, list)
          } catch {
            done(result, FlutterError(code: "store", message: error.localizedDescription, details: nil))
          }
        }
      } else {
        result([])
      }
    case "storeBuy":
      guard let id = args["id"] as? String else {
        result(FlutterError(code: "bad_args", message: "Falta el producto", details: nil))
        return true
      }
      if #available(iOS 15.0, *) {
        Task {
          do {
            guard let product = try await Product.products(for: [id]).first else {
              done(result, FlutterError(code: "not_found", message: "Esta suscripción aún no está disponible", details: nil))
              return
            }
            var options: Set<Product.PurchaseOption> = []
            if let acc = args["account"] as? String, let uuid = UUID(uuidString: acc) {
              options.insert(.appAccountToken(uuid))
            }
            switch try await product.purchase(options: options) {
            case .success(let verification):
              if case .verified(let tx) = verification {
                await tx.finish()
              }
              done(result, verification.jwsRepresentation)
            case .userCancelled:
              done(result, FlutterError(code: "cancelled", message: "Compra cancelada", details: nil))
            case .pending:
              done(result, FlutterError(code: "pending", message: "La compra está pendiente de aprobación", details: nil))
            @unknown default:
              done(result, FlutterError(code: "store", message: "No se pudo comprar", details: nil))
            }
          } catch {
            done(result, FlutterError(code: "store", message: error.localizedDescription, details: nil))
          }
        }
      } else {
        result(FlutterError(code: "unsupported", message: "Necesitas iOS 15 o más nuevo", details: nil))
      }
    case "storeEntitlements":
      // Suscripciones activas (para restaurar y para las renovaciones).
      if #available(iOS 15.0, *) {
        Task {
          if args["sync"] as? Bool == true { try? await AppStore.sync() }
          var out: [String] = []
          for await v in Transaction.currentEntitlements {
            if case .verified(let tx) = v, tx.productType == .autoRenewable { out.append(v.jwsRepresentation) }
          }
          done(result, out)
        }
      } else {
        result([])
      }
    case "storeManage":
      if #available(iOS 15.0, *),
         let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
        Task {
          try? await AppStore.showManageSubscriptions(in: scene)
          done(result, nil)
        }
      } else if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
        UIApplication.shared.open(url)
        result(nil)
      }
    default:
      return false
    }
    return true
  }

  private static func done(_ result: @escaping FlutterResult, _ value: Any?) {
    DispatchQueue.main.async { result(value) }
  }

  @available(iOS 15.0, *)
  private static func unitName(_ u: Product.SubscriptionPeriod.Unit) -> String {
    switch u {
    case .day: return "day"
    case .week: return "week"
    case .month: return "month"
    case .year: return "year"
    @unknown default: return "month"
    }
  }
}
