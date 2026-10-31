package com.klkapp.klk_native;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;

import androidx.annotation.NonNull;

import com.android.billingclient.api.BillingClient;
import com.android.billingclient.api.BillingClientStateListener;
import com.android.billingclient.api.BillingFlowParams;
import com.android.billingclient.api.BillingResult;
import com.android.billingclient.api.PendingPurchasesParams;
import com.android.billingclient.api.ProductDetails;
import com.android.billingclient.api.Purchase;
import com.android.billingclient.api.PurchasesUpdatedListener;
import com.android.billingclient.api.QueryProductDetailsParams;
import com.android.billingclient.api.QueryPurchasesParams;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import io.flutter.plugin.common.MethodChannel;

/**
 * KLK Plus con Google Play Billing. Google cobra; nosotros solo recibimos el
 * «purchase token» de la compra y el servidor se lo pregunta a Google (y la
 * confirma). Mismos métodos que la parte de iPhone (StoreKit).
 */
final class PlusStore implements PurchasesUpdatedListener {
    private final Context context;
    private final Handler main = new Handler(Looper.getMainLooper());
    private BillingClient billing;
    private final List<Runnable> waiting = new ArrayList<>();
    private final List<MethodChannel.Result> waitingResults = new ArrayList<>();
    private boolean connecting;
    private final Map<String, ProductDetails> details = new HashMap<>();
    private final Map<String, String> offers = new HashMap<>(); // producto → offerToken elegido
    private MethodChannel.Result pendingBuy;
    private String pendingProduct;

    PlusStore(Context context) {
        this.context = context;
    }

    // ---------- Conexión ----------

    private interface Ready {
        void run(BillingClient client);
    }

    private void withClient(MethodChannel.Result result, Ready job) {
        if (billing == null) {
            billing = BillingClient.newBuilder(context)
                    .setListener(this)
                    .enablePendingPurchases(PendingPurchasesParams.newBuilder().enableOneTimeProducts().build())
                    .build();
        }
        if (billing.isReady()) {
            job.run(billing);
            return;
        }
        waiting.add(() -> job.run(billing));
        waitingResults.add(result);
        if (connecting) return;
        connecting = true;
        billing.startConnection(new BillingClientStateListener() {
            @Override
            public void onBillingSetupFinished(@NonNull BillingResult r) {
                main.post(() -> {
                    connecting = false;
                    List<Runnable> jobs = new ArrayList<>(waiting);
                    List<MethodChannel.Result> results = new ArrayList<>(waitingResults);
                    waiting.clear();
                    waitingResults.clear();
                    if (r.getResponseCode() == BillingClient.BillingResponseCode.OK) {
                        for (Runnable j : jobs) j.run();
                    } else {
                        // Sin Google Play (o sin cuenta): se avisa a todos los que esperaban.
                        for (MethodChannel.Result w : results) {
                            w.error("store", "No se pudo conectar con Google Play", null);
                        }
                    }
                });
            }

            @Override
            public void onBillingServiceDisconnected() {
                main.post(() -> connecting = false);
            }
        });
    }

    // ---------- Productos ----------

    void products(List<String> ids, MethodChannel.Result result) {
        if (ids == null || ids.isEmpty()) {
            result.success(Collections.emptyList());
            return;
        }
        withClient(result, client -> {
            List<QueryProductDetailsParams.Product> list = new ArrayList<>();
            for (String id : ids) {
                list.add(QueryProductDetailsParams.Product.newBuilder()
                        .setProductId(id).setProductType(BillingClient.ProductType.SUBS).build());
            }
            client.queryProductDetailsAsync(QueryProductDetailsParams.newBuilder().setProductList(list).build(),
                    (r, found) -> main.post(() -> {
                        if (r.getResponseCode() != BillingClient.BillingResponseCode.OK || found == null) {
                            result.success(Collections.emptyList());
                            return;
                        }
                        List<Map<String, Object>> out = new ArrayList<>();
                        for (ProductDetails p : found) {
                            Map<String, Object> m = describe(p);
                            if (m != null) out.add(m);
                        }
                        result.success(out);
                    }));
        });
    }

    /** Elige la oferta (con prueba gratis si la hay) y la describe como en iPhone. */
    private Map<String, Object> describe(ProductDetails p) {
        List<ProductDetails.SubscriptionOfferDetails> offerList = p.getSubscriptionOfferDetails();
        if (offerList == null || offerList.isEmpty()) return null;
        ProductDetails.SubscriptionOfferDetails chosen = null;
        ProductDetails.PricingPhase trial = null;
        for (ProductDetails.SubscriptionOfferDetails o : offerList) {
            ProductDetails.PricingPhase free = null;
            for (ProductDetails.PricingPhase ph : o.getPricingPhases().getPricingPhaseList()) {
                if (ph.getPriceAmountMicros() == 0) free = ph;
            }
            if (free != null && trial == null) {
                chosen = o;
                trial = free;
            }
        }
        if (chosen == null) {
            for (ProductDetails.SubscriptionOfferDetails o : offerList) {
                if (o.getOfferId() == null) chosen = o; // plan base
            }
        }
        if (chosen == null) chosen = offerList.get(0);
        List<ProductDetails.PricingPhase> phases = chosen.getPricingPhases().getPricingPhaseList();
        ProductDetails.PricingPhase base = phases.get(phases.size() - 1); // el precio normal va al final

        details.put(p.getProductId(), p);
        offers.put(p.getProductId(), chosen.getOfferToken());

        Map<String, Object> m = new HashMap<>();
        m.put("id", p.getProductId());
        m.put("title", p.getName());
        m.put("price", base.getFormattedPrice());
        m.put("amount", base.getPriceAmountMicros() / 1_000_000.0);
        Object[] period = period(base.getBillingPeriod());
        m.put("unit", period[0]);
        m.put("count", period[1]);
        if (trial != null) {
            Object[] t = period(trial.getBillingPeriod());
            m.put("trialUnit", t[0]);
            m.put("trialCount", t[1]);
        }
        return m;
    }

    /** "P1M" → {"month", 1}; "P1Y" → {"year", 1}; "P7D" → {"day", 7}; "P1W" → {"week", 1}. */
    private static Object[] period(String iso) {
        if (iso == null || iso.length() < 3 || iso.charAt(0) != 'P') return new Object[]{"month", 1};
        String num = iso.substring(1, iso.length() - 1);
        int n;
        try {
            n = Integer.parseInt(num);
        } catch (NumberFormatException e) {
            n = 1;
        }
        switch (iso.charAt(iso.length() - 1)) {
            case 'D':
                return new Object[]{"day", n};
            case 'W':
                return new Object[]{"week", n};
            case 'Y':
                return new Object[]{"year", n};
            default:
                return new Object[]{"month", n};
        }
    }

    // ---------- Comprar ----------

    void buy(Activity activity, String productId, String accountId, MethodChannel.Result result) {
        if (activity == null) {
            result.error("store", "Abre KLK para comprar", null);
            return;
        }
        if (pendingBuy != null) {
            result.error("busy", "Ya hay una compra en curso", null);
            return;
        }
        ProductDetails p = details.get(productId);
        String offer = offers.get(productId);
        if (p == null || offer == null) {
            result.error("not_found", "Esta suscripción aún no está disponible", null);
            return;
        }
        withClient(result, client -> {
            BillingFlowParams.Builder b = BillingFlowParams.newBuilder()
                    .setProductDetailsParamsList(Collections.singletonList(
                            BillingFlowParams.ProductDetailsParams.newBuilder()
                                    .setProductDetails(p).setOfferToken(offer).build()));
            // La compra queda atada a la cuenta de KLK (el servidor lo comprueba).
            if (accountId != null && !accountId.isEmpty() && accountId.length() <= 64) {
                b.setObfuscatedAccountId(accountId);
            }
            pendingBuy = result;
            pendingProduct = productId;
            BillingResult r = client.launchBillingFlow(activity, b.build());
            if (r.getResponseCode() != BillingClient.BillingResponseCode.OK) {
                finishBuy(null, r);
            }
        });
    }

    @Override
    public void onPurchasesUpdated(@NonNull BillingResult r, List<Purchase> purchases) {
        main.post(() -> {
            Purchase found = null;
            if (r.getResponseCode() == BillingClient.BillingResponseCode.OK && purchases != null) {
                for (Purchase p : purchases) {
                    if (pendingProduct == null || p.getProducts().contains(pendingProduct)) found = p;
                }
            }
            finishBuy(found, r);
        });
    }

    private void finishBuy(Purchase p, BillingResult r) {
        MethodChannel.Result res = pendingBuy;
        pendingBuy = null;
        pendingProduct = null;
        if (res == null) return;
        int code = r.getResponseCode();
        if (code == BillingClient.BillingResponseCode.USER_CANCELED) {
            res.error("cancelled", "Compra cancelada", null);
        } else if (code == BillingClient.BillingResponseCode.ITEM_ALREADY_OWNED) {
            res.error("owned", "Ya tienes esta suscripción: pulsa «Restaurar compras»", null);
        } else if (p == null) {
            res.error("store", "No se pudo comprar (" + code + ")", null);
        } else if (p.getPurchaseState() == Purchase.PurchaseState.PENDING) {
            res.error("pending", "La compra está pendiente de pago", null);
        } else {
            res.success(p.getPurchaseToken());
        }
    }

    // ---------- Suscripciones activas ----------

    void entitlements(MethodChannel.Result result) {
        withClient(result, client -> client.queryPurchasesAsync(
                QueryPurchasesParams.newBuilder().setProductType(BillingClient.ProductType.SUBS).build(),
                (r, purchases) -> main.post(() -> {
                    List<String> out = new ArrayList<>();
                    if (r.getResponseCode() == BillingClient.BillingResponseCode.OK && purchases != null) {
                        for (Purchase p : purchases) {
                            if (p.getPurchaseState() == Purchase.PurchaseState.PURCHASED) out.add(p.getPurchaseToken());
                        }
                    }
                    result.success(out);
                })));
    }

    // ---------- Gestionar ----------

    void manage(Activity activity, MethodChannel.Result result) {
        Uri uri = Uri.parse("https://play.google.com/store/account/subscriptions?package=" + context.getPackageName());
        Intent i = new Intent(Intent.ACTION_VIEW, uri);
        try {
            if (activity != null) {
                activity.startActivity(i);
            } else {
                i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                context.startActivity(i);
            }
        } catch (Exception ignored) {
        }
        result.success(null);
    }
}
