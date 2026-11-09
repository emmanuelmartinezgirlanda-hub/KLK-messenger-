package com.klkapp.klk_native;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** «Rechazar» en la pantalla de llamada: quita el aviso y, si KLK está viva, cuelga. */
public class KlkCallReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context ctx, Intent intent) {
        String id = intent.getStringExtra(KlkCallNotifier.EXTRA_ID);
        if (id == null) return;
        KlkCallNotifier.cancel(ctx, id);
        KlkNativePlugin p = KlkCallNotifier.plugin;
        if (p != null) p.callDeclined(id);
    }
}
