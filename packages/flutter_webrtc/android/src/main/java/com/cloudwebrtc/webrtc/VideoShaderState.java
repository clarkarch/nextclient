package com.cloudwebrtc.webrtc;

/**
 * Thread-safe static holder for video shader filter settings.
 * Set from the platform thread (method channel handler), read on the
 * render thread by {@link ShaderFilterDrawer}. Uses a single volatile
 * reference for safe cross-thread publication (same pattern as the
 * Linux C++ implementation).
 */
public class VideoShaderState {

    public static class Settings {
        public final boolean enabled;
        public final int sharpen;
        public final boolean sharpenAdaptive;
        public final int saturation;
        public final int contrast;
        public final int brightness;
        public final int vibrance;
        public final int grain;

        public Settings(boolean enabled, int sharpen, boolean sharpenAdaptive,
                int saturation, int contrast, int brightness, int vibrance, int grain) {
            this.enabled = enabled;
            this.sharpen = sharpen;
            this.sharpenAdaptive = sharpenAdaptive;
            this.saturation = saturation;
            this.contrast = contrast;
            this.brightness = brightness;
            this.vibrance = vibrance;
            this.grain = grain;
        }

        /** True when the post-processing pass would visibly change the image. */
        public boolean isActive() {
            return enabled && (sharpen > 0 || saturation != 100 || contrast != 100
                    || brightness != 100 || vibrance > 0 || grain > 0);
        }
    }

    private static volatile Settings current =
            new Settings(false, 0, true, 100, 100, 100, 0, 0);

    /** Replace the process-wide shader filter settings (platform thread). */
    public static void set(boolean enabled, int sharpen, boolean sharpenAdaptive,
            int saturation, int contrast, int brightness, int vibrance, int grain) {
        current = new Settings(enabled, sharpen, sharpenAdaptive,
                saturation, contrast, brightness, vibrance, grain);
    }

    /** Thread-safe snapshot of the current settings (render thread). */
    public static Settings snapshot() {
        return current;
    }

    /** Quick check whether the post-processing pass is needed. */
    public static boolean isActive() {
        return current.isActive();
    }
}
