#include "flutter_webrtc/flutter_web_r_t_c_plugin.h"

#include "flutter_common.h"
#include "flutter_webrtc.h"
#include "task_runner_linux.h"

#if defined(__linux__)
#include <glib.h>
#endif

const char* kChannelName = "FlutterWebRTC.Method";
static flutter_webrtc_plugin::FlutterWebRTC* g_shared_instance = nullptr;
//#if defined(_WINDOWS)

namespace flutter_webrtc_plugin {

#if defined(__linux__)
// Swallow GLib WARNING / MESSAGE / INFO / DEBUG lines (the engine's
// "no frame available yet" and assorted compositor/GTK noise) while preserving
// ERROR / CRITICAL. Installed once at plugin registration.
void QuietGlibLoggingHandler(const gchar*, GLogLevelFlags, const gchar*, gpointer) {}

bool g_quiet_log_installed = false;
#endif

// A webrtc plugin for windows/linux.
class FlutterWebRTCPluginImpl : public FlutterWebRTCPlugin {
 public:
  static void RegisterWithRegistrar(PluginRegistrar* registrar) {
#if defined(__linux__)
    // Silence the engine/compositor warning spam that doesn't route through the
    // app's own log sink or the gated [glrender] prints. One-time, process-wide.
    if (!g_quiet_log_installed) {
      g_quiet_log_installed = true;
      g_log_set_handler(nullptr,
                        static_cast<GLogLevelFlags>(
                            G_LOG_LEVEL_WARNING | G_LOG_LEVEL_MESSAGE |
                            G_LOG_LEVEL_INFO | G_LOG_LEVEL_DEBUG),
                        QuietGlibLoggingHandler, nullptr);
    }
#endif
    auto channel = std::make_unique<MethodChannel>(
        registrar->messenger(), kChannelName,
        &flutter::StandardMethodCodec::GetInstance());

    auto* channel_pointer = channel.get();

    // Uses new instead of make_unique due to private constructor.
    std::unique_ptr<FlutterWebRTCPluginImpl> plugin(
        new FlutterWebRTCPluginImpl(registrar, std::move(channel)));

    channel_pointer->SetMethodCallHandler(
        [plugin_pointer = plugin.get()](const auto& call, auto result) {
          plugin_pointer->HandleMethodCall(call, std::move(result));
        });

    registrar->AddPlugin(std::move(plugin));
  }

  virtual ~FlutterWebRTCPluginImpl() {}

  BinaryMessenger* messenger() { return messenger_; }

  TextureRegistrar* textures() { return textures_; }

  TaskRunner* task_runner() { return task_runner_.get(); }

 private:
  // Creates a plugin that communicates on the given channel.
  FlutterWebRTCPluginImpl(PluginRegistrar* registrar,
                          std::unique_ptr<MethodChannel> channel)
      : channel_(std::move(channel)),
        messenger_(registrar->messenger()),
        textures_(registrar->texture_registrar()),
        task_runner_(std::make_unique<TaskRunnerLinux>()) {
    webrtc_ = std::make_unique<FlutterWebRTC>(this);
    g_shared_instance = webrtc_.get();
  }

  // Called when a method is called on |channel_|;
  void HandleMethodCall(const MethodCall& method_call,
                        std::unique_ptr<MethodResult> result) {
    // handle method call and forward to webrtc native sdk.
    auto method_call_proxy = MethodCallProxy::Create(method_call);
    webrtc_->HandleMethodCall(*method_call_proxy.get(),
                              MethodResultProxy::Create(std::move(result)));
  }

 private:
  std::unique_ptr<MethodChannel> channel_;
  std::unique_ptr<FlutterWebRTC> webrtc_;
  BinaryMessenger* messenger_;
  TextureRegistrar* textures_;
  std::unique_ptr<TaskRunner> task_runner_;
};

}  // namespace flutter_webrtc_plugin

void flutter_web_r_t_c_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  static auto* plugin_registrar = new flutter::PluginRegistrar(registrar);
  flutter_webrtc_plugin::FlutterWebRTCPluginImpl::RegisterWithRegistrar(
      plugin_registrar);
}

flutter_webrtc_plugin::FlutterWebRTC* flutter_webrtc_plugin_get_shared_instance() {
  return g_shared_instance;
} 