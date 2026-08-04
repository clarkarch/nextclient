// vaapi_h264_bitstream.h
//
// Converts H.264 access units into Annex-B framing (00 00 00 01 start codes)
// for a raw GStreamer pipeline.
//
// WebRTC hands decoders two possible framings depending on version:
//   * AVCC:    each NAL is prefixed by a 4-byte big-endian length.
//   * Annex-B: each NAL is prefixed by a 3- or 4-byte start code.
// Modern libwebrtc (m1xx) produces Annex-B via H26xPacketBuffer (which inserts
// start codes and re-injects SPS/PPS from sprop-parameter-sets), so this
// converter auto-detects the input framing and normalizes either to Annex-B.
//
// WebRTC typically strips SPS/PPS out of the bitstream (they travel in
// sprop-parameter-sets in the SDP), so this converter also tracks parameter
// sets and re-injects them ahead of every IDR keyframe, mirroring what
// Chromium's VaapiVideoDecoder does with its H264Parser.
//
// This header is deliberately dependency-free (no WebRTC, no GStreamer) so it
// can be unit-tested standalone.
#ifndef LIBWEBRTC_SRC_VAAPI_H264_BITSTREAM_H_
#define LIBWEBRTC_SRC_VAAPI_H264_BITSTREAM_H_

#include <cstddef>
#include <cstdint>
#include <vector>

namespace libwebrtc {

class AvccToAnnexB {
 public:
  // Converts one access unit. `out` receives the Annex-B byte stream
  // (4-byte start-code prefixed NALs). `is_keyframe` is set when the access
  // unit contains an IDR NAL. Returns false on malformed input.
  bool Convert(const uint8_t* data, size_t size, std::vector<uint8_t>* out,
               bool* is_keyframe) {
    out->clear();
    *is_keyframe = false;
    if (data == nullptr || size == 0) return false;
    if (StartsWithStartCode(data, size)) {
      return ConvertAnnexB(data, size, out, is_keyframe);
    }
    return ConvertAvcc(data, size, out, is_keyframe);
  }

  // True once both SPS and PPS have been captured from the stream (whether
  // in-band or supplied earlier). The decoder uses this to hold access units
  // until parameter sets are known, so a first keyframe without SPS/PPS can't
  // kill the pipeline with not-negotiated.
  bool HasParameterSets() const { return !sps_.empty() && !pps_.empty(); }

  // Clears captured parameter sets so a reused decoder instance starts clean
  // for a new stream (stale SPS/PPS from a previous session would otherwise
  // be prepended to the new stream's keyframes).
  void Reset() {
    sps_.clear();
    pps_.clear();
  }

 private:
  static bool StartsWithStartCode(const uint8_t* data, size_t size) {
    if (size >= 4 && data[0] == 0 && data[1] == 0 && data[2] == 0 &&
        data[3] == 1) {
      return true;
    }
    return size >= 3 && data[0] == 0 && data[1] == 0 && data[2] == 1;
  }

  // Length (3 or 4) of the start code at `data`, or 0 if there is none.
  static size_t StartCodeLength(const uint8_t* data, size_t size) {
    if (size >= 4 && data[0] == 0 && data[1] == 0 && data[2] == 0 &&
        data[3] == 1) {
      return 4;
    }
    if (size >= 3 && data[0] == 0 && data[1] == 0 && data[2] == 1) {
      return 3;
    }
    return 0;
  }

  // Byte offset of the next start code in `data`, or SIZE_MAX if none.
  // A 4-byte start code is matched before a 3-byte one (which would otherwise
  // match inside it).
  static size_t FindNextStartCode(const uint8_t* data, size_t size) {
    for (size_t i = 0; i + 3 <= size; ++i) {
      if (data[i] == 0 && data[i + 1] == 0) {
        if (data[i + 2] == 1) return i;
        if (i + 4 <= size && data[i + 2] == 0 && data[i + 3] == 1) return i;
      }
    }
    return SIZE_MAX;
  }

  static void AppendStartCode(std::vector<uint8_t>* v) {
    v->push_back(0x00);
    v->push_back(0x00);
    v->push_back(0x00);
    v->push_back(0x01);
  }

  // Annex-B input: split NALs on start codes, cache SPS/PPS, and re-inject
  // cached parameter sets ahead of every IDR keyframe (a single canonical
  // copy, whether they arrived in-band in this AU or in a previous one).
  // Parameter sets MUST precede the IDR NAL, so they are prepended to the
  // front of the output; in-band copies are captured above and not emitted in
  // place so the stream keeps exactly one copy.
  bool ConvertAnnexB(const uint8_t* data, size_t size,
                     std::vector<uint8_t>* out, bool* is_keyframe) {
    size_t offset = 0;
    while (offset < size) {
      const size_t code_len = StartCodeLength(data + offset, size - offset);
      if (code_len == 0) return false;  // NAL not preceded by a start code.
      offset += code_len;

      const size_t next = FindNextStartCode(data + offset, size - offset);
      const size_t nal_end = next == SIZE_MAX ? size : offset + next;
      if (nal_end <= offset) return false;  // Empty NAL.
      const uint8_t* nal = data + offset;
      const size_t nal_len = nal_end - offset;
      const uint8_t nal_type = nal[0] & 0x1F;
      if (nal_type == 7) {  // SPS
        sps_.assign(nal, nal + nal_len);
      } else if (nal_type == 8) {  // PPS
        pps_.assign(nal, nal + nal_len);
      } else {
        if (nal_type == 5) *is_keyframe = true;  // IDR
        AppendStartCode(out);
        out->insert(out->end(), nal, nal + nal_len);
      }
      offset = nal_end;
    }

    // Re-inject SPS/PPS ahead of keyframes — mirrors ConvertAvcc. Without
    // this, an in-band keyframe ([SPS, PPS, IDR]) is stripped to [IDR] only,
    // and h264parse downstream cannot negotiate (not-negotiated), killing the
    // pipeline. GFN sends SPS/PPS in-band (sps-pps-idr-in-keyframe=1), so
    // this path is the normal one, not an edge case.
    if (*is_keyframe) {
      std::vector<uint8_t> prefix;
      if (!sps_.empty()) {
        AppendStartCode(&prefix);
        prefix.insert(prefix.end(), sps_.begin(), sps_.end());
      }
      if (!pps_.empty()) {
        AppendStartCode(&prefix);
        prefix.insert(prefix.end(), pps_.begin(), pps_.end());
      }
      out->insert(out->begin(), prefix.begin(), prefix.end());
    }
    return true;
  }

  // AVCC input: 4-byte big-endian NAL length prefixes.
  bool ConvertAvcc(const uint8_t* data, size_t size,
                   std::vector<uint8_t>* out, bool* is_keyframe) {
    size_t offset = 0;
    while (offset + 4 <= size) {
      const uint32_t len =
          (static_cast<uint32_t>(data[offset]) << 24) |
          (static_cast<uint32_t>(data[offset + 1]) << 16) |
          (static_cast<uint32_t>(data[offset + 2]) << 8) |
          static_cast<uint32_t>(data[offset + 3]);
      offset += 4;
      if (len == 0 || offset + len > size) return false;
      const uint8_t* nal = data + offset;
      const uint8_t nal_type = nal[0] & 0x1F;
      if (nal_type == 7) {  // SPS
        sps_.assign(nal, nal + len);
      } else if (nal_type == 8) {  // PPS
        pps_.assign(nal, nal + len);
      } else {
        if (nal_type == 5) *is_keyframe = true;  // IDR
        AppendStartCode(out);
        out->insert(out->end(), nal, nal + len);
      }
      offset += len;
    }
    if (offset != size) return false;
    // Re-inject SPS/PPS ahead of keyframes. Parameter sets must PRECEDE the
    // IDR NAL, so they are prepended to the front of the output. We use the
    // most recently seen copies (whether they arrived in-band earlier in this
    // same AU or in a previous AU) — in-band SPS/PPS were captured above and
    // not emitted in place, so prepending keeps a single canonical copy.
    if (*is_keyframe) {
      std::vector<uint8_t> prefix;
      if (!sps_.empty()) {
        AppendStartCode(&prefix);
        prefix.insert(prefix.end(), sps_.begin(), sps_.end());
      }
      if (!pps_.empty()) {
        AppendStartCode(&prefix);
        prefix.insert(prefix.end(), pps_.begin(), pps_.end());
      }
      out->insert(out->begin(), prefix.begin(), prefix.end());
    }
    return true;
  }

  std::vector<uint8_t> sps_;
  std::vector<uint8_t> pps_;
};

}  // namespace libwebrtc

#endif  // LIBWEBRTC_SRC_VAAPI_H264_BITSTREAM_H_
