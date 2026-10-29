package com.klkapp.klk_native;

import android.Manifest;
import android.app.Activity;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Build;

import androidx.annotation.NonNull;

import com.google.firebase.FirebaseApp;
import com.google.firebase.FirebaseOptions;
import com.google.firebase.messaging.FirebaseMessaging;

import java.util.Map;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;

/** Funciones nativas de KLK en Android: avisos push con Firebase Cloud Messaging. */
public class KlkNativePlugin implements FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
        PluginRegistry.RequestPermissionsResultListener {
    private static final int PERMISSION_CODE = 7301;
    private static final String CHANNEL_ID = "klk_messages";

    private MethodChannel channel;
    private Context context;
    private ActivityPluginBinding activityBinding;
    private MethodChannel.Result pendingPush;
    private Map<String, Object> pendingArgs;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        context = binding.getApplicationContext();
        channel = new MethodChannel(binding.getBinaryMessenger(), "klk/native");
        channel.setMethodCallHandler(this);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        channel.setMethodCallHandler(null);
        channel = null;
    }

    @Override
    @SuppressWarnings("unchecked")
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        switch (call.method) {
            case "registerPush":
                registerPush((Map<String, Object>) call.arguments, result);
                break;
            case "isTestFlight":
                result.success(false);
                break;
            default:
                result.notImplemented();
        }
    }

    private void registerPush(Map<String, Object> args, MethodChannel.Result result) {
        if (args == null || str(args, "appId").isEmpty() || str(args, "apiKey").isEmpty()) {
            result.success(null); // sin datos de Firebase en esta versión
            return;
        }
        // Android 13+: hay que pedir permiso para mostrar avisos.
        if (Build.VERSION.SDK_INT >= 33
                && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            Activity activity = activityBinding == null ? null : activityBinding.getActivity();
            if (activity == null) {
                result.success(null);
                return;
            }
            if (pendingPush != null) {
                pendingPush.error("replaced", "Otra petición en curso", null);
            }
            pendingPush = result;
            pendingArgs = args;
            activity.requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, PERMISSION_CODE);
            return;
        }
        fetchToken(args, result);
    }

    @Override
    public boolean onRequestPermissionsResult(int requestCode, @NonNull String[] permissions, @NonNull int[] grantResults) {
        if (requestCode != PERMISSION_CODE || pendingPush == null) return false;
        MethodChannel.Result r = pendingPush;
        Map<String, Object> args = pendingArgs;
        pendingPush = null;
        pendingArgs = null;
        if (grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            fetchToken(args, r);
        } else {
            r.success(null);
        }
        return true;
    }

    private void fetchToken(Map<String, Object> args, MethodChannel.Result result) {
        try {
            createChannel();
            if (FirebaseApp.getApps(context).isEmpty()) {
                FirebaseOptions options = new FirebaseOptions.Builder()
                        .setApiKey(str(args, "apiKey"))
                        .setApplicationId(str(args, "appId"))
                        .setProjectId(str(args, "projectId"))
                        .setGcmSenderId(str(args, "senderId"))
                        .build();
                FirebaseApp.initializeApp(context, options);
            }
            FirebaseMessaging.getInstance().getToken().addOnCompleteListener(task -> {
                if (task.isSuccessful()) {
                    result.success(task.getResult());
                } else {
                    Exception e = task.getException();
                    result.error("push", "No se pudieron activar los avisos: " + (e == null ? "" : e.getMessage()), null);
                }
            });
        } catch (Exception e) {
            result.error("push", "No se pudieron activar los avisos: " + e.getMessage(), null);
        }
    }

    private void createChannel() {
        if (Build.VERSION.SDK_INT < 26) return;
        NotificationManager nm = (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
        if (nm == null || nm.getNotificationChannel(CHANNEL_ID) != null) return;
        NotificationChannel ch = new NotificationChannel(CHANNEL_ID, "Mensajes", NotificationManager.IMPORTANCE_HIGH);
        ch.setDescription("Avisos de mensajes nuevos de KLK");
        nm.createNotificationChannel(ch);
    }

    private static String str(Map<String, Object> m, String k) {
        Object v = m.get(k);
        return v == null ? "" : v.toString();
    }

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
        activityBinding = binding;
        binding.addRequestPermissionsResultListener(this);
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        onDetachedFromActivity();
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
        onAttachedToActivity(binding);
    }

    @Override
    public void onDetachedFromActivity() {
        if (activityBinding != null) activityBinding.removeRequestPermissionsResultListener(this);
        activityBinding = null;
    }
}
