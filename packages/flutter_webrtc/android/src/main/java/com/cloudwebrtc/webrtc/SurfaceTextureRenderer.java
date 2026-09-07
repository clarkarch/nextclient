package com.cloudwebrtc.webrtc;

import android.graphics.SurfaceTexture;
import android.view.Surface;

import org.webrtc.EglBase;
import org.webrtc.EglRenderer;
import org.webrtc.GlRectDrawer;
import org.webrtc.RendererCommon;
import org.webrtc.ThreadUtils;
import org.webrtc.VideoFrame;
import org.webrtc.VideoFrameDrawer;

import java.util.concurrent.CountDownLatch;

import io.flutter.view.TextureRegistry;

/**
 * Display the video stream on a Surface.
 * renderFrame() is asynchronous to avoid blocking the calling thread.
 * This class is thread safe and handles access from potentially three different threads:
 * Interaction from the main app in init, release and setMirror.
 * Interaction from C++ rtc::VideoSinkInterface in renderFrame.
 * Interaction from SurfaceHolder lifecycle in surfaceCreated, surfaceChanged, and surfaceDestroyed.
 */
public class SurfaceTextureRenderer extends EglRenderer {
  // Callback for reporting renderer events. Read-only after initilization so no lock required.
  private RendererCommon.RendererEvents rendererEvents;
  private final Object layoutLock = new Object();
  private boolean isRenderingPaused;
  private boolean isFirstFrameRendered;
  private int rotatedFrameWidth;
  private int rotatedFrameHeight;
  private int frameRotation;

  /**
   * In order to render something, you must first call init().
   */
  public SurfaceTextureRenderer(String name) {
    super(name);
  }

  public SurfaceTextureRenderer(String name, VideoFrameDrawer frameDrawer) {
    super(name, frameDrawer);
  }

  public void init(final EglBase.Context sharedContext,
                   RendererCommon.RendererEvents rendererEvents) {
    // Use default GlRectDrawer — shader post-processing is handled by
    // ShaderVideoFrameDrawer at the VideoFrameDrawer level.
    init(sharedContext, rendererEvents, EglBase.CONFIG_PLAIN,
         new GlRectDrawer());
  }

  /**
   * Initialize this class, sharing resources with |sharedContext|. The custom |drawer| will be used
   * for drawing frames on the EGLSurface. This class is responsible for calling release() on
   * |drawer|. It is allowed to call init() to reinitialize the renderer after a previous
   * init()/release() cycle.
   */
  public void init(final EglBase.Context sharedContext,
                   RendererCommon.RendererEvents rendererEvents, final int[] configAttributes,
                   RendererCommon.GlDrawer drawer) {
    ThreadUtils.checkIsOnMainThread();
    this.rendererEvents = rendererEvents;
    synchronized (layoutLock) {
      isFirstFrameRendered = false;
      rotatedFrameWidth = 0;
      rotatedFrameHeight = 0;
      frameRotation = -1;
    }
    super.init(sharedContext, configAttributes, drawer);
  }
  @Override
  public void init(final EglBase.Context sharedContext, final int[] configAttributes,
                   RendererCommon.GlDrawer drawer) {
    init(sharedContext, null /* rendererEvents */, configAttributes, drawer);
  }
  /**
   * Limit render framerate.
   *
   * @param fps Limit render framerate to this value, or use Float.POSITIVE_INFINITY to disable fps
   *            reduction.
   */
  @Override
  public void setFpsReduction(float fps) {
    synchronized (layoutLock) {
      isRenderingPaused = fps == 0f;
    }
    super.setFpsReduction(fps);
  }
  @Override
  public void disableFpsReduction() {
    synchronized (layoutLock) {
      isRenderingPaused = false;
    }
    super.disableFpsReduction();
  }
  @Override
  public void pauseVideo() {
    synchronized (layoutLock) {
      isRenderingPaused = true;
    }
    super.pauseVideo();
  }
  // VideoSink interface.
  @Override
  public void onFrame(VideoFrame frame) {
    synchronized (surfaceLock) {
      if(surface == null) {
        producer.setSize(frame.getRotatedWidth(),frame.getRotatedHeight());
        surface = producer.getSurface();
        createEglSurface(surface);
        lastSurfaceRecreateNs = System.nanoTime();
        pendingRecreateW = 0;
        pendingRecreateH = 0;
      } else if (frameSizeChanged(frame)) {
        // The producer's backing buffers are fixed-size: setSize() only takes
        // effect for a Surface obtained afterwards. Without recreating the EGL
        // surface here, a simulcast layer upgrade keeps rendering into the old
        // low-resolution buffer and the video stays blurry.
        //
        // Debounce: during simulcast adaptation several sizes can arrive in
        // quick succession; each recreation tears down + rebuilds the EGL
        // surface (a visible hitch). Upgrades apply immediately (blurry video
        // is the worse artifact); downgrades within MIN_RECREATE_INTERVAL_NS
        // of the last recreation are coalesced — the pending size is applied
        // on the next frame after the interval elapses.
        final int newW = frame.getRotatedWidth();
        final int newH = frame.getRotatedHeight();
        final long nowNs = System.nanoTime();
        final boolean upgrade = (long) newW * newH > (long) rotatedFrameWidth * rotatedFrameHeight;
        if (upgrade || nowNs - lastSurfaceRecreateNs >= MIN_RECREATE_INTERVAL_NS) {
          recreateSurface(newW, newH);
          lastSurfaceRecreateNs = nowNs;
          pendingRecreateW = 0;
          pendingRecreateH = 0;
        } else {
          // Coalesce: remember the latest size; it is applied once frames
          // arrive with a stable size after the interval (outer else-branch
          // below) or when the next change exits the interval.
          pendingRecreateW = newW;
          pendingRecreateH = newH;
        }
      } else if (pendingRecreateW != 0
          && System.nanoTime() - lastSurfaceRecreateNs >= MIN_RECREATE_INTERVAL_NS) {
        // Size settled back (or a further change arrived): flush the coalesced
        // downgrade so the backing buffer does not stay oversized forever.
        recreateSurface(pendingRecreateW, pendingRecreateH);
        lastSurfaceRecreateNs = System.nanoTime();
        pendingRecreateW = 0;
        pendingRecreateH = 0;
      }
    }
    updateFrameDimensionsAndReportEvents(frame);
    super.onFrame(frame);
  }

  private void recreateSurface(int w, int h) {
    releaseEglSurface(() -> {});
    // Clear the field before re-obtaining: if getSurface() throws, the
    // next frame takes the surface == null path and recreates cleanly
    // rather than rendering into the already-released surface.
    surface = null;
    producer.setSize(w, h);
    surface = producer.getSurface();
    createEglSurface(surface);
  }

  private boolean frameSizeChanged(VideoFrame frame) {
    synchronized (layoutLock) {
      return !isRenderingPaused
          && (rotatedFrameWidth != frame.getRotatedWidth()
              || rotatedFrameHeight != frame.getRotatedHeight());
    }
  }

  // Guards surface lifecycle transitions: creation/recreation happens on the
  // frame delivery thread while destruction arrives on the main thread via
  // the producer's onSurfaceCleanup callback. Serializing the two prevents a
  // frame from re-creating the EGL surface against a Surface the producer is
  // concurrently invalidating. surfaceDestroyed() blocks on the EGL release
  // while holding this lock; the latch is signaled by the EglRenderer render
  // thread, which never acquires it, so the wait cannot deadlock.
  private final Object surfaceLock = new Object();
  private Surface surface = null;
  // Coalesced surface size awaiting recreation (0 = none). See onFrame.
  private int pendingRecreateW = 0;
  private int pendingRecreateH = 0;
  private long lastSurfaceRecreateNs = 0;
  private static final long MIN_RECREATE_INTERVAL_NS = 250_000_000L;

  private TextureRegistry.SurfaceProducer producer;

  public void surfaceCreated(final TextureRegistry.SurfaceProducer producer) {
    ThreadUtils.checkIsOnMainThread();
    this.producer = producer;
    this.producer.setCallback(
            new TextureRegistry.SurfaceProducer.Callback() {
              @Override
              public void onSurfaceAvailable() {
                // Do surface initialization here, and draw the current frame.
              }

              @Override
              public void onSurfaceCleanup() {
                surfaceDestroyed();
              }
            }
    );
  }

  public void surfaceDestroyed() {
    ThreadUtils.checkIsOnMainThread();
    synchronized (surfaceLock) {
      final CountDownLatch completionLatch = new CountDownLatch(1);
      releaseEglSurface(completionLatch::countDown);
      ThreadUtils.awaitUninterruptibly(completionLatch);
      surface = null;
      pendingRecreateW = 0;
      pendingRecreateH = 0;
    }
  }

  // Update frame dimensions and report any changes to |rendererEvents|.
  private void updateFrameDimensionsAndReportEvents(VideoFrame frame) {
    synchronized (layoutLock) {
      if (isRenderingPaused) {
        return;
      }
      if (!isFirstFrameRendered) {
        isFirstFrameRendered = true;
        if (rendererEvents != null) {
          rendererEvents.onFirstFrameRendered();
        }
      }
      if (rotatedFrameWidth != frame.getRotatedWidth()
              || rotatedFrameHeight != frame.getRotatedHeight()
              || frameRotation != frame.getRotation()) {
        if (rendererEvents != null) {
          rendererEvents.onFrameResolutionChanged(
                  frame.getBuffer().getWidth(), frame.getBuffer().getHeight(), frame.getRotation());
        }
        rotatedFrameWidth = frame.getRotatedWidth();
        rotatedFrameHeight = frame.getRotatedHeight();
        frameRotation = frame.getRotation();
      }
    }
  }
}
