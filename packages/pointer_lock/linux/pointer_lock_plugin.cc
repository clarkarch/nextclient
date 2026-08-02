#include "include/pointer_lock/pointer_lock_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <sys/utsname.h>

#include <algorithm>
#include <cstring>

#include "pointer_lock_plugin_private.h"

#if defined(GDK_WINDOWING_WAYLAND) && defined(PLUGIN_HAVE_WAYLAND_CLIENT)
#include <gdk/gdkwayland.h>
#include <wayland-client.h>
#include "wayland/pointer_constraints_client.h"
#include "wayland/relative_pointer_client.h"
#endif

#define POINTER_LOCK_PLUGIN(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), pointer_lock_plugin_get_type(), \
                              PointerLockPlugin))

struct _PointerLockPlugin
{
    GObject parent_instance;
    FlPluginRegistrar* registrar;
    GdkPoint initial_pointer_pos;
    bool cursor_visible;
#if defined(GDK_WINDOWING_WAYLAND) && defined(PLUGIN_HAVE_WAYLAND_CLIENT)
    // Native Wayland pointer lock state (zwp_pointer_constraints + relative
    // pointer). Used on Wayland where gdk_pointer_grab is unavailable.
    FlEventChannel* event_channel;
    struct wl_display* wl_display;
    struct wl_surface* wl_surface;
    struct zwp_pointer_constraints_v1* pointer_constraints;
    struct zwp_relative_pointer_manager_v1* relative_pointer_manager;
    struct wl_seat* seat;
    struct wl_pointer* pointer;
    struct zwp_locked_pointer_v1* locked_pointer;
    struct zwp_relative_pointer_v1* relative_pointer;
    bool wayland_locked;
#endif
};

// Reusable functions

GdkWindow* get_gdk_window(FlPluginRegistrar* registrar)
{
    FlView* fl_view = fl_plugin_registrar_get_view(registrar);
    if (!fl_view)
    {
        return nullptr;
    }
    return gtk_widget_get_window(GTK_WIDGET(fl_view));
}

FlMethodResponse* success_response()
{
    g_autoptr(FlValue) result = fl_value_new_null();
    return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

FlValue* point_value(const double x, const double y)
{
    return fl_value_new_float_list((double[]){x, y}, 2);
}

FlMethodResponse* point_response(const double x, const double y)
{
    g_autoptr(FlValue) result = point_value(x, y);
    return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* error_response(const char* code)
{
    return FL_METHOD_RESPONSE(
        fl_method_error_response_new(code, nullptr, nullptr));
}

FlMethodResponse* no_window_error_response()
{
    return error_response("No window");
}

FlMethodResponse* no_pointer_error_response()
{
    return error_response("No pointer");
}

GdkPoint get_pointer_position_on_screen(GdkDisplay* gdk_display)
{
    GdkSeat* gdk_seat = gdk_display_get_default_seat(gdk_display);
    GdkDevice* gdk_pointer = gdk_seat_get_pointer(gdk_seat);
    if (!gdk_pointer)
    {
        return {0, 0};
    }
    int x, y;
    gdk_device_get_position(gdk_pointer, nullptr, &x, &y);
    return {x, y};
}

#if defined(GDK_WINDOWING_WAYLAND) && defined(PLUGIN_HAVE_WAYLAND_CLIENT)

// Forward declaration: wayland_unlock is defined below but referenced by the
// locked-pointer unlock listener above it.
void wayland_unlock(PointerLockPlugin* plugin);

gboolean is_wayland_display(PointerLockPlugin* plugin)
{
    GdkWindow* gdk_window = get_gdk_window(plugin->registrar);
    if (!gdk_window)
    {
        return FALSE;
    }
    GdkDisplay* gdk_display = gdk_window_get_display(gdk_window);
    return GDK_IS_WAYLAND_DISPLAY(gdk_display) ? TRUE : FALSE;
}

// --- Wayland registry (bind the protocols we need) -------------------------

static void registry_handle_global(void* data, wl_registry* registry,
                                   uint32_t name, const char* interface,
                                   uint32_t version)
{
    PointerLockPlugin* plugin = POINTER_LOCK_PLUGIN(data);
    if (strcmp(interface, zwp_pointer_constraints_v1_interface.name) == 0)
    {
        plugin->pointer_constraints = static_cast<zwp_pointer_constraints_v1*>(
            wl_registry_bind(registry, name,
                             &zwp_pointer_constraints_v1_interface,
                             std::min(version, 1u)));
    }
    else if (strcmp(interface, zwp_relative_pointer_manager_v1_interface.name) == 0)
    {
        plugin->relative_pointer_manager =
            static_cast<zwp_relative_pointer_manager_v1*>(
                wl_registry_bind(registry, name,
                                 &zwp_relative_pointer_manager_v1_interface,
                                 std::min(version, 1u)));
    }
    else if (strcmp(interface, wl_seat_interface.name) == 0)
    {
        // Bind the seat at a version that exposes wl_pointer.release
        // (added in wl_pointer v3). wayland_unlock() releases the pointer it
        // gets from wl_seat_get_pointer(); sending a v3 request on a v1
        // object is a protocol error that makes the compositor kill the
        // connection and the whole app closes.
        plugin->seat = static_cast<wl_seat*>(
            wl_registry_bind(registry, name, &wl_seat_interface,
                             std::min(version, 7u)));
    }
}

static const wl_registry_listener registry_listener = {
    .global = registry_handle_global,
    .global_remove = nullptr,
};

// Called when the compositor reports relative pointer motion. This is the
// Wayland equivalent of the browser's pointer-lock movementX/movementY: raw,
// unbounded deltas that never hit the window edge.
static void relative_pointer_handle_motion(void* data,
                                           zwp_relative_pointer_v1* pointer,
                                           uint32_t utime_hi,
                                           uint32_t utime_lo,
                                           wl_fixed_t dx, wl_fixed_t dy,
                                           wl_fixed_t dx_unaccel,
                                           wl_fixed_t dy_unaccel)
{
    PointerLockPlugin* plugin = POINTER_LOCK_PLUGIN(data);
    if (!plugin->event_channel)
    {
        return;
    }
    // Use the unaccelerated pair: the compositor's raw hardware deltas, not
    // the desktop's pointer-acceleration curve. This matches the raw deltas
    // the macOS/Windows paths send and keeps FPS-style look speed consistent.
    g_autoptr(FlValue) message = point_value(wl_fixed_to_double(dx_unaccel),
                                              wl_fixed_to_double(dy_unaccel));
    g_autoptr(GError) error = nullptr;
    if (!fl_event_channel_send(plugin->event_channel, message, nullptr, &error))
    {
        g_warning("Failed to send pointer motion event: %s",
                  error ? error->message : "unknown error");
    }
}

static const zwp_relative_pointer_v1_listener relative_pointer_listener = {
    .relative_motion = relative_pointer_handle_motion,
};

// Lock activation. We don't need to do anything special: the relative pointer
// starts delivering deltas on its own. A non-null handler is still required
// because libwayland invokes every member of the listener vtable.
static void locked_pointer_handle_locked(void* data,
                                         zwp_locked_pointer_v1* pointer)
{
    (void)data;
    (void)pointer;
}

// Called when the compositor releases the lock on its own (surface lost
// pointer focus, e.g. the user Alt+Tabs away). Mirror the browser behavior by
// releasing the protocol objects (so a later re-lock starts clean) and ending
// the stream so the Dart side restores the chrome.
static void locked_pointer_handle_unlocked(void* data,
                                           zwp_locked_pointer_v1* pointer)
{
    (void)pointer;
    PointerLockPlugin* plugin = POINTER_LOCK_PLUGIN(data);
    wayland_unlock(plugin);
    if (!plugin->event_channel)
    {
        return;
    }
    // End the stream so the Dart side restores the chrome. Sending a null
    // VALUE is just a null event; the EventChannel only closes when the
    // platform sends a null MESSAGE (end-of-stream).
    g_autoptr(GError) error = nullptr;
    if (!fl_event_channel_send_end_of_stream(plugin->event_channel, nullptr,
                                             &error))
    {
        g_warning("Failed to send pointer-lock release event: %s",
                  error ? error->message : "unknown error");
    }
}

static const zwp_locked_pointer_v1_listener locked_pointer_listener = {
    .locked = locked_pointer_handle_locked,
    .unlocked = locked_pointer_handle_unlocked,
};

gboolean wayland_lock(PointerLockPlugin* plugin)
{
    if (plugin->wayland_locked)
    {
        return TRUE;
    }
    GdkWindow* gdk_window = get_gdk_window(plugin->registrar);
    if (!gdk_window)
    {
        return FALSE;
    }
    GdkDisplay* gdk_display = gdk_window_get_display(gdk_window);
    if (!GDK_IS_WAYLAND_DISPLAY(gdk_display))
    {
        return FALSE;
    }
    plugin->wl_display = gdk_wayland_display_get_wl_display(gdk_display);
    plugin->wl_surface = gdk_wayland_window_get_wl_surface(gdk_window);
    if (!plugin->wl_display || !plugin->wl_surface)
    {
        return FALSE;
    }

    // Bind the globals we need (idempotent: only the first call binds).
    if (!plugin->pointer_constraints && !plugin->relative_pointer_manager)
    {
        wl_registry* registry = wl_display_get_registry(plugin->wl_display);
        wl_registry_add_listener(registry, &registry_listener, plugin);
        // Two roundtrips: the first delivers the global list, the second
        // delivers the bind-ack + any events (some compositors defer).
        wl_display_roundtrip(plugin->wl_display);
        wl_display_roundtrip(plugin->wl_display);
        wl_registry_destroy(registry);
    }
    if (!plugin->pointer_constraints || !plugin->relative_pointer_manager ||
        !plugin->seat)
    {
        return FALSE; // Compositor doesn't expose the protocols.
    }

    plugin->pointer = wl_seat_get_pointer(plugin->seat);
    plugin->relative_pointer =
        zwp_relative_pointer_manager_v1_get_relative_pointer(
            plugin->relative_pointer_manager, plugin->pointer);
    zwp_relative_pointer_v1_add_listener(plugin->relative_pointer,
                                         &relative_pointer_listener, plugin);
    plugin->locked_pointer = zwp_pointer_constraints_v1_lock_pointer(
        plugin->pointer_constraints, plugin->wl_surface, plugin->pointer,
        nullptr, ZWP_POINTER_CONSTRAINTS_V1_LIFETIME_PERSISTENT);
    zwp_locked_pointer_v1_add_listener(plugin->locked_pointer,
                                       &locked_pointer_listener, plugin);
    wl_display_flush(plugin->wl_display);

    plugin->wayland_locked = TRUE;
    return TRUE;
}

void wayland_unlock(PointerLockPlugin* plugin)
{
    if (!plugin->wayland_locked)
    {
        return;
    }
    if (plugin->locked_pointer)
    {
        zwp_locked_pointer_v1_destroy(plugin->locked_pointer);
        plugin->locked_pointer = nullptr;
    }
    if (plugin->relative_pointer)
    {
        zwp_relative_pointer_v1_destroy(plugin->relative_pointer);
        plugin->relative_pointer = nullptr;
    }
    if (plugin->pointer)
    {
        wl_pointer_release(plugin->pointer);
        plugin->pointer = nullptr;
    }
    if (plugin->wl_display)
    {
        wl_display_flush(plugin->wl_display);
    }
    plugin->wayland_locked = FALSE;
}

#endif  // GDK_WINDOWING_WAYLAND && PLUGIN_HAVE_WAYLAND_CLIENT

// End reusable functions

G_DEFINE_TYPE(PointerLockPlugin, pointer_lock_plugin, g_object_get_type())

// Called when a method call is received from Flutter.
static void pointer_lock_plugin_handle_method_call(
    PointerLockPlugin* self, FlMethodCall* method_call)
{
    g_autoptr(FlMethodResponse) response = nullptr;

    const gchar* method = fl_method_call_get_name(method_call);

    if (strcmp(method, "flutterRestart") == 0)
    {
        set_pointer_visible(self, true);
        set_pointer_locked(self, false);
        response = success_response();
    }
    else if (strcmp(method, "hidePointer") == 0)
    {
        response = set_pointer_visible(self, false);
    }
    else if (strcmp(method, "showPointer") == 0)
    {
        response = set_pointer_visible(self, true);
    }
    else if (strcmp(method, "lockPointer") == 0)
    {
        response = set_pointer_locked(self, true);
    }
    else if (strcmp(method, "unlockPointer") == 0)
    {
        response = set_pointer_locked(self, false);
    }
    else if (strcmp(method, "lastPointerDelta") == 0)
    {
        response = last_pointer_delta(self);
    }
    else if (strcmp(method, "pointerPositionOnScreen") == 0)
    {
        response = pointer_position_on_screen(self);
    }
    else if (strcmp(method, "isWayland") == 0)
    {
#if defined(GDK_WINDOWING_WAYLAND) && defined(PLUGIN_HAVE_WAYLAND_CLIENT)
        g_autoptr(FlValue) result = fl_value_new_bool(is_wayland_display(self));
        response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
#else
        g_autoptr(FlValue) result = fl_value_new_bool(FALSE);
        response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
#endif
    }
    else
    {
        response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
    }

    fl_method_call_respond(method_call, response, nullptr);
}

FlMethodResponse* pointer_position_on_screen(const PointerLockPlugin* plugin)
{
    GdkWindow* gdk_window = get_gdk_window(plugin->registrar);
    if (!gdk_window)
    {
        return no_window_error_response();
    }
    GdkDisplay* gdk_display = gdk_window_get_display(gdk_window);
    GdkPoint pos = get_pointer_position_on_screen(gdk_display);
    return point_response(pos.x, pos.y);
}

FlMethodResponse* last_pointer_delta(const PointerLockPlugin* plugin)
{
    GdkWindow* gdk_window = get_gdk_window(plugin->registrar);
    if (!gdk_window)
    {
        return no_window_error_response();
    }
    GdkDisplay* gdk_display = gdk_window_get_display(gdk_window);
    GdkPoint new_pointer_pos = get_pointer_position_on_screen(gdk_display);
    GdkScreen* gdk_screen = gdk_display_get_default_screen(gdk_display);
    GdkSeat* gdk_seat = gdk_display_get_default_seat(gdk_display);
    GdkDevice* gdk_pointer = gdk_seat_get_pointer(gdk_seat);
    int initial_x = plugin->initial_pointer_pos.x;
    int initial_y = plugin->initial_pointer_pos.y;
    gdk_device_warp(gdk_pointer, gdk_screen, initial_x, initial_y);
    return point_response(new_pointer_pos.x - initial_x,
                          new_pointer_pos.y - initial_y);
}

FlMethodResponse* set_pointer_visible(PointerLockPlugin* plugin, bool visible)
{
    GdkWindow* gdk_window = get_gdk_window(plugin->registrar);
    if (!gdk_window)
    {
        return no_window_error_response();
    }
    plugin->cursor_visible = visible;
    if (visible)
    {
        gdk_window_set_cursor(gdk_window, nullptr);
    }
    else
    {
        GdkDisplay* gdk_display = gdk_window_get_display(gdk_window);
        GdkCursor* gdk_cursor = gdk_cursor_new_for_display(gdk_display, GDK_BLANK_CURSOR);
        gdk_window_set_cursor(gdk_window, gdk_cursor);
        g_object_unref(gdk_cursor);
    }
    return success_response();
}

FlMethodResponse* set_pointer_locked(PointerLockPlugin* plugin, bool locked)
{
    GdkWindow* gdk_window = get_gdk_window(plugin->registrar);
    if (!gdk_window)
    {
        return no_window_error_response();
    }
    GdkDisplay* gdk_display = gdk_window_get_display(gdk_window);
#if defined(GDK_WINDOWING_WAYLAND) && defined(PLUGIN_HAVE_WAYLAND_CLIENT)
    if (GDK_IS_WAYLAND_DISPLAY(gdk_display))
    {
        // gdk_pointer_grab is X11-only; on Wayland we lock the pointer via
        // the zwp_pointer_constraints + relative pointer protocols.
        if (locked)
        {
            if (!wayland_lock(plugin))
            {
                return error_response("Wayland pointer lock failed");
            }
        }
        else
        {
            wayland_unlock(plugin);
        }
        return success_response();
    }
#endif
    GdkSeat* gdk_seat = gdk_display_get_default_seat(gdk_display);
    if (locked)
    {
        // Memorize initial pointer position
        plugin->initial_pointer_pos = get_pointer_position_on_screen(gdk_display);
        // Grab pointer
        gdk_seat_ungrab(gdk_seat);
        // Always use blank cursor! Otherwise, the warping won't work (at least not on Wayland).
        GdkCursor* gdk_cursor = gdk_cursor_new_for_display(gdk_display, GDK_BLANK_CURSOR);
        // gdk_seat_grab is the replacement of the deprecated gdk_pointer_grab, but unfortunately it doesn't allow
        // confining the cursor to the window. Very fast mouse movements will make the cursor end up outside the window,
        // and then warping to the original position is not possible anymore (at least on Wayland). This could
        // maybe be avoided by *synchronously* warping on pointer move events. At the moment we warp asynchronously:
        // Mouse movement => Native code calls Dart code => Dart code requests last pointer delta => Native code warps.
        // I don't know how to get synchronously informed of mouse events on the native side without hacking the
        // Flutter Engine.
        // GdkGrabStatus result = gdk_seat_grab(gdk_seat, gdk_window, GDK_SEAT_CAPABILITY_ALL_POINTING, TRUE, gdk_cursor, nullptr, nullptr, nullptr);
        auto gdk_event_mask = static_cast<GdkEventMask>(GDK_POINTER_MOTION_MASK | GDK_BUTTON_PRESS_MASK |
            GDK_BUTTON_RELEASE_MASK | GDK_ENTER_NOTIFY_MASK | GDK_LEAVE_NOTIFY_MASK);
        // Use deprecated gdk_pointer_grab in order to confine to a window.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
        GdkGrabStatus result = gdk_pointer_grab(gdk_window, TRUE, gdk_event_mask, gdk_window, gdk_cursor,
                                                GDK_CURRENT_TIME);
#pragma GCC diagnostic pop
        g_object_unref(gdk_cursor);
        if (result != GDK_GRAB_SUCCESS)
        {
            return error_response("gdk_seat_grab failed");
        }
    }
    else
    {
        gdk_seat_ungrab(gdk_seat);
    }
    return success_response();
}

#if defined(GDK_WINDOWING_WAYLAND) && defined(PLUGIN_HAVE_WAYLAND_CLIENT)

// Event channel: the Dart side listens to `pointer_lock_session` (the same
// channel macOS/Windows use). Listening locks the pointer on Wayland;
// cancelling unlocks it. Relative motion deltas are emitted as [dx, dy].
static FlMethodErrorResponse* event_stream_listen(FlEventChannel* channel,
                                                  FlValue* args,
                                                  gpointer user_data)
{
    PointerLockPlugin* plugin = POINTER_LOCK_PLUGIN(user_data);
    if (!wayland_lock(plugin))
    {
        // The compositor doesn't expose the pointer-constraints / relative-
        // pointer protocols (e.g. an unusual or legacy compositor). Don't
        // error out — the app's soft lock (hidden cursor + Flutter deltas)
        // stays active as the fallback, matching how a failed gdk grab on
        // X11 is handled.
        g_warning("Wayland pointer lock unavailable; soft lock remains active");
    }
    return nullptr;
}

static FlMethodErrorResponse* event_stream_cancel(FlEventChannel* channel,
                                                  FlValue* args,
                                                  gpointer user_data)
{
    PointerLockPlugin* plugin = POINTER_LOCK_PLUGIN(user_data);
    wayland_unlock(plugin);
    return nullptr;
}

#endif  // GDK_WINDOWING_WAYLAND && PLUGIN_HAVE_WAYLAND_CLIENT

static void pointer_lock_plugin_dispose(GObject* object)
{
#if defined(GDK_WINDOWING_WAYLAND) && defined(PLUGIN_HAVE_WAYLAND_CLIENT)
    PointerLockPlugin* plugin = POINTER_LOCK_PLUGIN(object);
    wayland_unlock(plugin);
    if (plugin->event_channel)
    {
        g_object_unref(plugin->event_channel);
        plugin->event_channel = nullptr;
    }
#endif
    G_OBJECT_CLASS(pointer_lock_plugin_parent_class)->dispose(object);
}

static void pointer_lock_plugin_class_init(PointerLockPluginClass* klass)
{
    G_OBJECT_CLASS(klass)->dispose = pointer_lock_plugin_dispose;
}

static void pointer_lock_plugin_init(PointerLockPlugin* self)
{
    self->cursor_visible = true;
    self->initial_pointer_pos.x = 0;
    self->initial_pointer_pos.y = 0;
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data)
{
    PointerLockPlugin* plugin = POINTER_LOCK_PLUGIN(user_data);
    pointer_lock_plugin_handle_method_call(plugin, method_call);
}

void pointer_lock_plugin_register_with_registrar(FlPluginRegistrar* registrar)
{
    // Initialize plugin
    PointerLockPlugin* plugin = POINTER_LOCK_PLUGIN(
        g_object_new(pointer_lock_plugin_get_type(), nullptr));
    plugin->registrar = FL_PLUGIN_REGISTRAR(g_object_ref(registrar));
    // Set up channels
    FlBinaryMessenger* messenger = fl_plugin_registrar_get_messenger(registrar);
    g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
    // Set up method channel
    g_autoptr(FlMethodChannel) method_channel =
        fl_method_channel_new(messenger,
                              "pointer_lock",
                              FL_METHOD_CODEC(codec));
    fl_method_channel_set_method_call_handler(method_channel, method_call_cb,
                                              g_object_ref(plugin),
                                              g_object_unref);

#if defined(GDK_WINDOWING_WAYLAND) && defined(PLUGIN_HAVE_WAYLAND_CLIENT)
    // Set up event channel (native-driven sessions, like macOS/Windows).
    g_autoptr(FlStandardMethodCodec) event_codec = fl_standard_method_codec_new();
    plugin->event_channel = fl_event_channel_new(
        messenger, "pointer_lock_session", FL_METHOD_CODEC(event_codec));
    fl_event_channel_set_stream_handlers(plugin->event_channel,
                                         event_stream_listen,
                                         event_stream_cancel,
                                         g_object_ref(plugin),
                                         g_object_unref);
#endif

    g_object_unref(plugin);
}
