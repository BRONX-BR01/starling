package io.github.juanluci.starling;

import android.content.Context;
import android.util.AtomicFile;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import org.json.JSONObject;

/** Persist each attempt before native loading; offer recovery once per interrupted attempt. */
final class StartupRecovery {
    static final String RECOVERY = "io.github.juanluci.starling.INTERRUPTED_START";
    private static File marker(Context context) { return new File(context.getFilesDir(), "starling-starting"); }
    static void begin(Context context) {
        try { new FileOutputStream(marker(context)).close(); }
        catch (java.io.IOException error) { android.util.Log.w("starling", "Cannot record startup", error); }
    }
    static void shown(Context context) { marker(context).delete(); }
    static void offered(Context context) {
        // Keep the session's evidence for export, but do not route this attempt again.
        marker(context).delete();
        File session = new File(context.getFilesDir(), "performance/current-session.json");
        AtomicFile file = new AtomicFile(session);
        FileOutputStream output = null;
        try {
            JSONObject json = new JSONObject(new String(file.readFully(), "UTF-8"));
            json.put("recovery_offered", true);
            output = file.startWrite();
            output.write(json.toString().getBytes("UTF-8"));
            file.finishWrite(output);
        } catch (Exception error) {
            if (output != null) file.failWrite(output);
            if (session.exists()) android.util.Log.w("starling", "Cannot acknowledge recovery", error);
        }
    }
    static boolean interrupted(Context context) {
        if (marker(context).exists()) return true;
        File session = new File(context.getFilesDir(), "performance/current-session.json");
        try (FileInputStream stream = new FileInputStream(session)) {
            byte[] data = new byte[16384];
            int size = stream.read(data);
            if (size <= 0) return false;
            JSONObject json = new JSONObject(new String(data, 0, size, "UTF-8"));
            String phase = json.optString("phase");
            return !json.optBoolean("recovery_offered") && !json.optBoolean("clean_exit") && ("native_start".equals(phase)
                    || "renderer_init".equals(phase) || "resource_loading".equals(phase));
        } catch (Exception ignored) { return false; }
    }
}
