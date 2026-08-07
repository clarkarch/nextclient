// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef FLUTTER_SHELL_PLATFORM_COMMON_CLIENT_WRAPPER_TEXTURE_REGISTRAR_IMPL_H_
#define FLUTTER_SHELL_PLATFORM_COMMON_CLIENT_WRAPPER_TEXTURE_REGISTRAR_IMPL_H_

#include "include/flutter/texture_registrar.h"

struct FlTextureProxy;

namespace flutter {

// Wrapper around a FlTextureRegistrar that implements the
// TextureRegistrar API.
class TextureRegistrarImpl : public TextureRegistrar {
 public:
  explicit TextureRegistrarImpl(FlTextureRegistrar* texture_registrar_ref);
  virtual ~TextureRegistrarImpl();

  // Prevent copying.
  TextureRegistrarImpl(TextureRegistrarImpl const&) = delete;
  TextureRegistrarImpl& operator=(TextureRegistrarImpl const&) = delete;

  // |flutter::TextureRegistrar|
  int64_t RegisterTexture(TextureVariant* texture) override;

  // |flutter::TextureRegistrar|
  bool MarkTextureFrameAvailable(int64_t texture_id) override;

  // |flutter::TextureRegistrar|
  bool UnregisterTexture(int64_t texture_id) override;

  // Returns the raw GObject FlTextureRegistrar this wrapper talks to. Needed
  // to register FlTextureGL textures (GPU-resident, no CPU readback) directly
  // through the engine's C API, which the client-wrapper TextureVariant does
  // not expose.
  FlTextureRegistrar* raw_texture_registrar() const {
    return texture_registrar_ref_;
  }

 private:
  // Handle for interacting with the C API.
  FlTextureRegistrar* texture_registrar_ref_;
  std::map<int64_t, FlTextureProxy*> textures_;
};

}  // namespace flutter

#endif  // FLUTTER_SHELL_PLATFORM_COMMON_CLIENT_WRAPPER_TEXTURE_REGISTRAR_IMPL_H_
