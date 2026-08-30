// gst_texture_plugin.h — in-tree Linux plugin exposing the gst_bridge frame
// slot as a Flutter GL texture (GPU-texture video path for the webrtcbin
// transport).
#ifndef RUNNER_GST_TEXTURE_PLUGIN_H_
#define RUNNER_GST_TEXTURE_PLUGIN_H_

#include <flutter_linux/flutter_linux.h>

G_BEGIN_DECLS

void gst_texture_plugin_register_with_registrar(FlPluginRegistry* registry);

G_END_DECLS

#endif  // RUNNER_GST_TEXTURE_PLUGIN_H_
