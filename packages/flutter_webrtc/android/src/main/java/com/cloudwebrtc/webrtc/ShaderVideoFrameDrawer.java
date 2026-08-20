package com.cloudwebrtc.webrtc;

import android.opengl.GLES20;
import android.util.Log;

import org.webrtc.RendererCommon;
import org.webrtc.VideoFrame;
import org.webrtc.VideoFrameDrawer;

import android.graphics.Matrix;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;

/**
 * VideoFrameDrawer subclass that adds a GPU post-processing pass (video shader
 * filter) after the standard rendering.
 */
public class ShaderVideoFrameDrawer extends VideoFrameDrawer {
    private static final String TAG = "ShaderVideoFD";

    private int fbo = 0;
    private int fboTexture = 0;
    private int postProgram = 0;
    private int quadVbo = 0;
    private int fboWidth = 0;
    private int fboHeight = 0;
    private boolean glInitialized = false;

    private int uFrameLoc = -1;
    private int uTexelSizeLoc = -1;
    private int uSharpenLoc = -1;
    private int uSharpenAdaptiveLoc = -1;
    private int uSaturationLoc = -1;
    private int uContrastLoc = -1;
    private int uBrightnessLoc = -1;
    private int uVibranceLoc = -1;
    private int uGrainLoc = -1;
    private int uTimeLoc = -1;
    private int aPosLoc = -1;
    private int aTexcoordLoc = -1;

    private static final long startTimeNs = System.nanoTime();

    private static final float[] QUAD_VERTICES = {
        -1f, -1f, 0f, 0f,
         1f, -1f, 1f, 0f,
        -1f,  1f, 0f, 1f,
         1f,  1f, 1f, 1f,
    };

    private static final String VERTEX_SHADER =
        "attribute vec2 in_pos;\n" +
        "attribute vec2 in_tc;\n" +
        "varying vec2 tc;\n" +
        "void main() {\n" +
        "  gl_Position = vec4(in_pos, 0.0, 1.0);\n" +
        "  tc = in_tc;\n" +
        "}\n";

    private static final String POST_FRAGMENT_SHADER =
        "precision mediump float;\n" +
        "uniform sampler2D u_frame;\n" +
        "uniform vec2 u_texel_size;\n" +
        "uniform float u_sharpen;\n" +
        "uniform float u_sharpen_adaptive;\n" +
        "uniform float u_saturation;\n" +
        "uniform float u_contrast;\n" +
        "uniform float u_brightness;\n" +
        "uniform float u_vibrance;\n" +
        "uniform float u_grain;\n" +
        "uniform float u_time;\n" +
        "varying vec2 tc;\n" +
        "float luma(vec3 c) {\n" +
        "  return dot(c, vec3(0.2126, 0.7152, 0.0722));\n" +
        "}\n" +
        "float hash(vec2 p) {\n" +
        "  vec3 p3 = fract(vec3(p.xyx) * 0.1031);\n" +
        "  p3 += dot(p3, p3.yzx + 33.33);\n" +
        "  return fract((p3.x + p3.y) * p3.z);\n" +
        "}\n" +
        "vec3 cas_sharpen(vec2 uv, vec3 center, float amount) {\n" +
        "  vec3 n = texture2D(u_frame, uv + vec2(0.0, -u_texel_size.y)).rgb;\n" +
        "  vec3 s = texture2D(u_frame, uv + vec2(0.0,  u_texel_size.y)).rgb;\n" +
        "  vec3 w = texture2D(u_frame, uv + vec2(-u_texel_size.x, 0.0)).rgb;\n" +
        "  vec3 e = texture2D(u_frame, uv + vec2( u_texel_size.x, 0.0)).rgb;\n" +
        "  vec3 mn = min(center, min(min(n, s), min(w, e)));\n" +
        "  vec3 mx = max(center, max(max(n, s), max(w, e)));\n" +
        "  vec3 amp = clamp(min(mn, 1.0 - mx) / max(mx, vec3(1e-5)), 0.0, 1.0);\n" +
        "  amp = sqrt(amp);\n" +
        "  float peak = mix(-0.16, -0.24, amount);\n" +
        "  vec3 weight = amp * peak;\n" +
        "  vec3 result = (center + (n + s + w + e) * weight) / (1.0 + 4.0 * weight);\n" +
        "  return clamp(result, 0.0, 1.0);\n" +
        "}\n" +
        "vec3 sharpen_uniform(vec2 uv, vec3 center, float amount) {\n" +
        "  vec3 n = texture2D(u_frame, uv + vec2(0.0, -u_texel_size.y)).rgb;\n" +
        "  vec3 s = texture2D(u_frame, uv + vec2(0.0,  u_texel_size.y)).rgb;\n" +
        "  vec3 w = texture2D(u_frame, uv + vec2(-u_texel_size.x, 0.0)).rgb;\n" +
        "  vec3 e = texture2D(u_frame, uv + vec2( u_texel_size.x, 0.0)).rgb;\n" +
        "  vec3 blur = (n + s + w + e) * 0.25;\n" +
        "  float k = 1.0 + 3.0 * amount;\n" +
        "  return clamp(center + (center - blur) * k, 0.0, 1.0);\n" +
        "}\n" +
        "void main() {\n" +
        "  vec3 color = texture2D(u_frame, tc).rgb;\n" +
        "  if (u_sharpen > 0.001) {\n" +
        "    if (u_sharpen_adaptive > 0.5) {\n" +
        "      color = cas_sharpen(tc, color, u_sharpen);\n" +
        "    } else {\n" +
        "      color = sharpen_uniform(tc, color, u_sharpen);\n" +
        "    }\n" +
        "  }\n" +
        "  color *= u_brightness;\n" +
        "  color = (color - 0.5) * u_contrast + 0.5;\n" +
        "  float l = luma(color);\n" +
        "  color = mix(vec3(l), color, u_saturation);\n" +
        "  if (u_vibrance > 0.001) {\n" +
        "    float maxC = max(color.r, max(color.g, color.b));\n" +
        "    float minC = min(color.r, min(color.g, color.b));\n" +
        "    float sat = maxC - minC;\n" +
        "    float boost = u_vibrance * (1.0 - sat);\n" +
        "    color = mix(vec3(luma(color)), color, 1.0 + boost);\n" +
        "  }\n" +
        "  if (u_grain > 0.001) {\n" +
        "    float g = hash(gl_FragCoord.xy + fract(u_time) * 1024.0) - 0.5;\n" +
        "    color += g * u_grain * 0.12 * (0.3 + 0.7 * luma(color));\n" +
        "  }\n" +
        "  gl_FragColor = vec4(clamp(color, 0.0, 1.0), 1.0);\n" +
        "}\n";

    // ---- Overrides ----

    @Override
    public void drawFrame(VideoFrame frame, RendererCommon.GlDrawer drawer,
                          Matrix drawMatrix, int x, int y, int width, int height) {
        VideoShaderState.Settings s = VideoShaderState.snapshot();
        if (!s.isActive()) {
            super.drawFrame(frame, drawer, drawMatrix, x, y, width, height);
            return;
        }

        if (!ensureGl() || width <= 0 || height <= 0) {
            super.drawFrame(frame, drawer, drawMatrix, x, y, width, height);
            return;
        }

        int[] savedFbo = new int[1];
        GLES20.glGetIntegerv(GLES20.GL_FRAMEBUFFER_BINDING, savedFbo, 0);

        if (!ensureFbo(width, height)) {
            super.drawFrame(frame, drawer, drawMatrix, x, y, width, height);
            return;
        }

        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo);
        GLES20.glViewport(0, 0, width, height);
        super.drawFrame(frame, drawer, drawMatrix, x, y, width, height);

        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, savedFbo[0]);
        GLES20.glViewport(x, y, width, height);

        // Post-processing pass
        resetGlState();
        GLES20.glUseProgram(postProgram);

        GLES20.glActiveTexture(GLES20.GL_TEXTURE0);
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, fboTexture);
        GLES20.glUniform1i(uFrameLoc, 0);
        GLES20.glUniform2f(uTexelSizeLoc, 1f / width, 1f / height);
        GLES20.glUniform1f(uSharpenLoc, s.sharpen / 100f);
        if (uSharpenAdaptiveLoc >= 0) GLES20.glUniform1f(uSharpenAdaptiveLoc, s.sharpenAdaptive ? 1f : 0f);
        GLES20.glUniform1f(uSaturationLoc, s.saturation / 100f);
        GLES20.glUniform1f(uContrastLoc, s.contrast / 100f);
        GLES20.glUniform1f(uBrightnessLoc, s.brightness / 100f);
        if (uVibranceLoc >= 0) GLES20.glUniform1f(uVibranceLoc, s.vibrance / 100f);
        if (uGrainLoc >= 0) GLES20.glUniform1f(uGrainLoc, s.grain / 100f);
        if (uTimeLoc >= 0) GLES20.glUniform1f(uTimeLoc, (float) ((System.nanoTime() - startTimeNs) / 1e9));

        drawQuad();
        GLES20.glUseProgram(0);
    }

    @Override
    public void release() {
        super.release();
        deleteGlResources();
    }

    private void deleteGlResources() {
        if (fbo != 0) { GLES20.glDeleteFramebuffers(1, new int[]{fbo}, 0); fbo = 0; }
        if (fboTexture != 0) { GLES20.glDeleteTextures(1, new int[]{fboTexture}, 0); fboTexture = 0; }
        if (quadVbo != 0) { GLES20.glDeleteBuffers(1, new int[]{quadVbo}, 0); quadVbo = 0; }
        if (postProgram != 0) { GLES20.glDeleteProgram(postProgram); postProgram = 0; }
        fboWidth = 0; fboHeight = 0; glInitialized = false;
    }

    private boolean ensureGl() {
        if (glInitialized) return postProgram != 0;
        glInitialized = true;

        postProgram = createProgram(VERTEX_SHADER, POST_FRAGMENT_SHADER);
        if (postProgram == 0) {
            Log.e(TAG, "Shader compile/link failed");
            return false;
        }

        uFrameLoc = GLES20.glGetUniformLocation(postProgram, "u_frame");
        uTexelSizeLoc = GLES20.glGetUniformLocation(postProgram, "u_texel_size");
        uSharpenLoc = GLES20.glGetUniformLocation(postProgram, "u_sharpen");
        uSharpenAdaptiveLoc = GLES20.glGetUniformLocation(postProgram, "u_sharpen_adaptive");
        uSaturationLoc = GLES20.glGetUniformLocation(postProgram, "u_saturation");
        uContrastLoc = GLES20.glGetUniformLocation(postProgram, "u_contrast");
        uBrightnessLoc = GLES20.glGetUniformLocation(postProgram, "u_brightness");
        uVibranceLoc = GLES20.glGetUniformLocation(postProgram, "u_vibrance");
        uGrainLoc = GLES20.glGetUniformLocation(postProgram, "u_grain");
        uTimeLoc = GLES20.glGetUniformLocation(postProgram, "u_time");
        aPosLoc = GLES20.glGetAttribLocation(postProgram, "in_pos");
        aTexcoordLoc = GLES20.glGetAttribLocation(postProgram, "in_tc");

        ByteBuffer bb = ByteBuffer.allocateDirect(QUAD_VERTICES.length * 4);
        bb.order(ByteOrder.nativeOrder());
        FloatBuffer fb = bb.asFloatBuffer();
        fb.put(QUAD_VERTICES);
        fb.position(0);

        int[] bufs = new int[1];
        GLES20.glGenBuffers(1, bufs, 0);
        quadVbo = bufs[0];
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, quadVbo);
        GLES20.glBufferData(GLES20.GL_ARRAY_BUFFER,
                QUAD_VERTICES.length * 4, fb, GLES20.GL_STATIC_DRAW);
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, 0);

        return true;
    }

    private boolean ensureFbo(int width, int height) {
        if (fbo != 0 && fboWidth == width && fboHeight == height) return true;

        if (fbo != 0) { GLES20.glDeleteFramebuffers(1, new int[]{fbo}, 0); fbo = 0; }
        if (fboTexture != 0) { GLES20.glDeleteTextures(1, new int[]{fboTexture}, 0); fboTexture = 0; }

        int[] prevFbo = new int[1];
        GLES20.glGetIntegerv(GLES20.GL_FRAMEBUFFER_BINDING, prevFbo, 0);

        int[] texs = new int[1];
        GLES20.glGenTextures(1, texs, 0);
        fboTexture = texs[0];
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, fboTexture);
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR);
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR);
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE);
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE);
        GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA,
                width, height, 0, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null);

        int[] fbos = new int[1];
        GLES20.glGenFramebuffers(1, fbos, 0);
        fbo = fbos[0];
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo);
        GLES20.glFramebufferTexture2D(GLES20.GL_FRAMEBUFFER,
                GLES20.GL_COLOR_ATTACHMENT0, GLES20.GL_TEXTURE_2D, fboTexture, 0);

        int status = GLES20.glCheckFramebufferStatus(GLES20.GL_FRAMEBUFFER);
        if (status != GLES20.GL_FRAMEBUFFER_COMPLETE) {
            GLES20.glDeleteFramebuffers(1, fbos, 0);
            GLES20.glDeleteTextures(1, texs, 0);
            fbo = 0; fboTexture = 0;
            return false;
        }

        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, prevFbo[0]);
        fboWidth = width; fboHeight = height;
        return true;
    }

    private void resetGlState() {
        GLES20.glDisable(GLES20.GL_BLEND);
        GLES20.glDisable(GLES20.GL_DEPTH_TEST);
        GLES20.glDisable(GLES20.GL_CULL_FACE);
        GLES20.glDisable(GLES20.GL_SCISSOR_TEST);
        GLES20.glColorMask(true, true, true, true);
        GLES20.glDepthMask(false);

        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, quadVbo);
        GLES20.glEnableVertexAttribArray(aPosLoc);
        GLES20.glVertexAttribPointer(aPosLoc, 2, GLES20.GL_FLOAT, false, 16, 0);
        GLES20.glEnableVertexAttribArray(aTexcoordLoc);
        GLES20.glVertexAttribPointer(aTexcoordLoc, 2, GLES20.GL_FLOAT, false, 16, 8);
    }

    private void drawQuad() {
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4);
        GLES20.glDisableVertexAttribArray(aPosLoc);
        GLES20.glDisableVertexAttribArray(aTexcoordLoc);
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, 0);
        GLES20.glDepthMask(true);
    }

    private static int createProgram(String vertexSrc, String fragmentSrc) {
        int vs = compileShader(GLES20.GL_VERTEX_SHADER, vertexSrc);
        if (vs == 0) return 0;
        int fs = compileShader(GLES20.GL_FRAGMENT_SHADER, fragmentSrc);
        if (fs == 0) { GLES20.glDeleteShader(vs); return 0; }
        int program = GLES20.glCreateProgram();
        GLES20.glAttachShader(program, vs);
        GLES20.glAttachShader(program, fs);
        GLES20.glLinkProgram(program);
        int[] linkStatus = new int[1];
        GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, linkStatus, 0);
        if (linkStatus[0] == 0) {
            GLES20.glDeleteProgram(program); program = 0;
        }
        GLES20.glDeleteShader(vs); GLES20.glDeleteShader(fs);
        return program;
    }

    private static int compileShader(int type, String source) {
        int shader = GLES20.glCreateShader(type);
        GLES20.glShaderSource(shader, source);
        GLES20.glCompileShader(shader);
        int[] compiled = new int[1];
        GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, compiled, 0);
        if (compiled[0] == 0) {
            GLES20.glDeleteShader(shader); return 0;
        }
        return shader;
    }
}
