package com.klkapp.klk_native;

import androidx.annotation.NonNull;

import com.google.firebase.messaging.FirebaseMessagingService;
import com.google.firebase.messaging.RemoteMessage;

import java.util.Map;

/**
 * Recibe los avisos de Firebase. Los de mensajes los enseña Android solo; los de
 * llamada («klk»: «call») llegan como datos y aquí se convierten en la pantalla
 * de llamada a pantalla completa, aunque KLK esté cerrada o el móvil bloqueado.
 */
public class KlkCallService extends FirebaseMessagingService {
    @Override
    public void onMessageReceived(@NonNull RemoteMessage message) {
        Map<String, String> d = message.getData();
        if (!"call".equals(d.get("klk"))) return;
        String id = d.get("id");
        if (id == null || id.isEmpty()) return;
        String name = d.get("name");
        String handle = d.get("handle");
        String who = name != null && !name.isEmpty() ? name : (handle != null && !handle.isEmpty() ? handle : "");
        KlkCallNotifier.show(getApplicationContext(), id, "1".equals(d.get("video")), d.get("from"), who);
    }

    @Override
    public void onNewToken(@NonNull String token) {
        // El token se vuelve a pedir desde Dart al abrir KLK.
    }
}
