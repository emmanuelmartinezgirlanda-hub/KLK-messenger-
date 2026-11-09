package com.klkapp.klk_native;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.media.AudioAttributes;
import android.media.RingtoneManager;
import android.net.Uri;
import android.os.Build;

import java.util.HashMap;
import java.util.Map;

/** La pantalla de llamada entrante de Android (aviso a pantalla completa con Contestar/Rechazar). */
public final class KlkCallNotifier {
    static final String CHANNEL = "klk_calls_v1";
    static final String EXTRA_ID = "klk_call_id";
    static final String EXTRA_ACTION = "klk_call_action"; // open | answer
    static final String EXTRA_VIDEO = "klk_call_video";
    static final String EXTRA_FROM = "klk_call_from";
    static final String ACTION_DECLINE = "com.klkapp.klk_native.DECLINE_CALL";

    /** Llamadas sonando ahora mismo: id -> [video, from]. */
    static final Map<String, Object[]> ringing = new HashMap<>();

    /** Para avisar a Dart si KLK está abierta (o en segundo plano). */
    static KlkNativePlugin plugin;

    private KlkCallNotifier() {}

    static int notifId(String id) {
        return 0x4B4C0000 | (id.hashCode() & 0xFFFF);
    }

    private static void ensureChannel(Context ctx) {
        if (Build.VERSION.SDK_INT < 26) return;
        NotificationManager nm = (NotificationManager) ctx.getSystemService(Context.NOTIFICATION_SERVICE);
        if (nm == null || nm.getNotificationChannel(CHANNEL) != null) return;
        NotificationChannel ch = new NotificationChannel(CHANNEL, "Llamadas", NotificationManager.IMPORTANCE_HIGH);
        ch.setDescription("Llamadas entrantes de KLK");
        Uri ring = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE);
        ch.setSound(ring, new AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build());
        ch.enableVibration(true);
        ch.setVibrationPattern(new long[]{0, 900, 700, 900, 700, 900});
        ch.setLockscreenVisibility(Notification.VISIBILITY_PUBLIC);
        ch.setBypassDnd(false);
        nm.createNotificationChannel(ch);
    }

    private static int piFlags() {
        return PendingIntent.FLAG_UPDATE_CURRENT | (Build.VERSION.SDK_INT >= 23 ? PendingIntent.FLAG_IMMUTABLE : 0);
    }

    private static Intent openApp(Context ctx, String id, String action, boolean video, String from) {
        Intent i = ctx.getPackageManager().getLaunchIntentForPackage(ctx.getPackageName());
        if (i == null) i = new Intent();
        i.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        i.putExtra(EXTRA_ID, id);
        i.putExtra(EXTRA_ACTION, action);
        i.putExtra(EXTRA_VIDEO, video);
        i.putExtra(EXTRA_FROM, from == null ? "" : from);
        return i;
    }

    static void show(Context ctx, String id, boolean video, String from, String who) {
        synchronized (ringing) {
            if (ringing.containsKey(id)) return;
            ringing.put(id, new Object[]{video, from == null ? "" : from});
        }
        ensureChannel(ctx);
        String title = who == null || who.isEmpty() ? "KLK messenger" : who;
        String text = video ? "Videollamada de KLK" : "Llamada de KLK";

        int n = notifId(id);
        PendingIntent full = PendingIntent.getActivity(ctx, n, openApp(ctx, id, "open", video, from), piFlags());
        PendingIntent answer = PendingIntent.getActivity(ctx, n + 1, openApp(ctx, id, "answer", video, from), piFlags());
        Intent dec = new Intent(ctx, KlkCallReceiver.class).setAction(ACTION_DECLINE).putExtra(EXTRA_ID, id);
        PendingIntent decline = PendingIntent.getBroadcast(ctx, n + 2, dec, piFlags());

        Notification.Builder b = Build.VERSION.SDK_INT >= 26 ? new Notification.Builder(ctx, CHANNEL) : new Notification.Builder(ctx);
        int icon = ctx.getApplicationInfo().icon;
        b.setSmallIcon(icon != 0 ? icon : android.R.drawable.sym_call_incoming)
                .setContentTitle(title)
                .setContentText(text)
                .setCategory(Notification.CATEGORY_CALL)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .setOngoing(true)
                .setAutoCancel(false)
                .setContentIntent(full)
                .setFullScreenIntent(full, true)
                .addAction(new Notification.Action.Builder(null, "Rechazar", decline).build())
                .addAction(new Notification.Action.Builder(null, video ? "Contestar 🎥" : "Contestar", answer).build());
        if (Build.VERSION.SDK_INT >= 26) b.setTimeoutAfter(45_000);
        if (Build.VERSION.SDK_INT < 26) {
            b.setPriority(Notification.PRIORITY_MAX)
                    .setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE))
                    .setVibrate(new long[]{0, 900, 700, 900});
        }
        Notification notif = b.build();
        notif.flags |= Notification.FLAG_INSISTENT; // que siga sonando hasta que conteste

        NotificationManager nm = (NotificationManager) ctx.getSystemService(Context.NOTIFICATION_SERVICE);
        try {
            if (nm != null) nm.notify(n, notif);
        } catch (SecurityException ignored) {
            // Sin permiso de avisos: no hay nada que enseñar.
        }
        KlkNativePlugin p = plugin;
        if (p != null) p.callIncoming(id, video, from == null ? "" : from);

        // Si en 45 s no contestó, se quita (también en Android < 8).
        new android.os.Handler(android.os.Looper.getMainLooper()).postDelayed(() -> cancel(ctx, id), 46_000);
    }

    static boolean has(String id) {
        synchronized (ringing) {
            return ringing.containsKey(id);
        }
    }

    static void cancel(Context ctx, String id) {
        synchronized (ringing) {
            ringing.remove(id);
        }
        NotificationManager nm = (NotificationManager) ctx.getSystemService(Context.NOTIFICATION_SERVICE);
        if (nm != null) nm.cancel(notifId(id));
    }
}
