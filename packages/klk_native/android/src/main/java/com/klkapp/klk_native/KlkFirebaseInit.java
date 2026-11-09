package com.klkapp.klk_native;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.content.Context;
import android.content.SharedPreferences;
import android.database.Cursor;
import android.net.Uri;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.google.firebase.FirebaseApp;
import com.google.firebase.FirebaseOptions;

/**
 * Arranca Firebase al empezar el proceso (también cuando Android despierta a
 * KLK solo para entregar un aviso de llamada), con los datos que Dart guardó
 * la última vez. Sin esto, con KLK cerrada no llegarían las llamadas.
 */
public class KlkFirebaseInit extends ContentProvider {
    static final String PREFS = "klk_firebase";

    static void save(Context ctx, String apiKey, String appId, String projectId, String senderId) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString("apiKey", apiKey).putString("appId", appId)
                .putString("projectId", projectId).putString("senderId", senderId).apply();
    }

    static void init(Context ctx) {
        try {
            if (!FirebaseApp.getApps(ctx).isEmpty()) return;
            SharedPreferences p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
            String apiKey = p.getString("apiKey", ""), appId = p.getString("appId", "");
            if (apiKey.isEmpty() || appId.isEmpty()) return;
            FirebaseApp.initializeApp(ctx, new FirebaseOptions.Builder()
                    .setApiKey(apiKey)
                    .setApplicationId(appId)
                    .setProjectId(p.getString("projectId", ""))
                    .setGcmSenderId(p.getString("senderId", ""))
                    .build());
        } catch (Exception ignored) {
        }
    }

    @Override
    public boolean onCreate() {
        Context c = getContext();
        if (c != null) init(c.getApplicationContext());
        return true;
    }

    @Nullable @Override
    public Cursor query(@NonNull Uri uri, @Nullable String[] p, @Nullable String s, @Nullable String[] a, @Nullable String o) {
        return null;
    }

    @Nullable @Override
    public String getType(@NonNull Uri uri) {
        return null;
    }

    @Nullable @Override
    public Uri insert(@NonNull Uri uri, @Nullable ContentValues values) {
        return null;
    }

    @Override
    public int delete(@NonNull Uri uri, @Nullable String s, @Nullable String[] a) {
        return 0;
    }

    @Override
    public int update(@NonNull Uri uri, @Nullable ContentValues v, @Nullable String s, @Nullable String[] a) {
        return 0;
    }
}
