// vaapi_h264_bitstream_test.cc
// Standalone unit test for AvccToAnnexB. Compile with plain g++ (no deps):
//   g++ -std=c++17 -I. vaapi_h264_bitstream_test.cc -o /tmp/avcc_test && /tmp/avcc_test
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

#include "vaapi_h264_bitstream.h"

using libwebrtc::AvccToAnnexB;

namespace {

// Builds an AVCC access unit from a list of (nal_type, payload) NALs.
void AppendNal(std::vector<uint8_t>* au, uint8_t nal_type, size_t payload_len,
               uint8_t payload_fill) {
  const uint32_t len = static_cast<uint32_t>(1 + payload_len);
  au->push_back((len >> 24) & 0xFF);
  au->push_back((len >> 16) & 0xFF);
  au->push_back((len >> 8) & 0xFF);
  au->push_back(len & 0xFF);
  au->push_back(nal_type);  // NAL header byte: type in low 5 bits
  for (size_t i = 0; i < payload_len; ++i) {
    au->push_back(payload_fill);
  }
}

// Appends an Annex-B NAL (start code + type + payload) to `au`.
void AppendAnnexBNal(std::vector<uint8_t>* au, uint8_t nal_type,
                     size_t payload_len, uint8_t payload_fill,
                     bool four_byte_code = true) {
  au->push_back(0x00);
  au->push_back(0x00);
  if (four_byte_code) au->push_back(0x00);
  au->push_back(0x01);
  au->push_back(nal_type);  // NAL header byte: type in low 5 bits
  for (size_t i = 0; i < payload_len; ++i) {
    au->push_back(payload_fill);
  }
}

// Returns the list of NAL types in an Annex-B stream (walking start codes).
std::vector<uint8_t> NalTypes(const std::vector<uint8_t>& annexb) {
  std::vector<uint8_t> types;
  size_t i = 0;
  while (i < annexb.size()) {
    // Find start code.
    if (i + 4 <= annexb.size() && annexb[i] == 0 && annexb[i + 1] == 0 &&
        annexb[i + 2] == 0 && annexb[i + 3] == 1) {
      i += 4;
      if (i < annexb.size()) types.push_back(annexb[i] & 0x1F);
    }
    ++i;
  }
  return types;
}

void ExpectTypes(const std::vector<uint8_t>& expected,
                 const std::vector<uint8_t>& actual, const char* label) {
  if (expected != actual) {
    std::printf("FAIL %s: expected [", label);
    for (auto t : expected) std::printf("%u ", t);
    std::printf("] got [");
    for (auto t : actual) std::printf("%u ", t);
    std::printf("]\n");
    std::exit(1);
  }
  std::printf("ok   %s\n", label);
}

}  // namespace

int main() {
  // 1. Keyframe AU with in-band SPS(7), PPS(8), then IDR(5), P(1).
  {
    std::vector<uint8_t> au;
    AppendNal(&au, 7, 10, 0xAB);  // SPS
    AppendNal(&au, 8, 4, 0xCD);   // PPS
    AppendNal(&au, 5, 32, 0x11);  // IDR
    AppendNal(&au, 1, 16, 0x22);  // P slice

    std::vector<uint8_t> out;
    bool keyframe = false;
    AvccToAnnexB conv;
    assert(conv.Convert(au.data(), au.size(), &out, &keyframe));
    assert(keyframe);
    ExpectTypes({7, 8, 5, 1}, NalTypes(out), "in-band sps/pps + idr");
  }

  // 2. Keyframe without SPS/PPS (WebRTC strips them) — must be re-injected
  //    from the previous call's cached parameter sets.
  {
    std::vector<uint8_t> au;
    AppendNal(&au, 5, 32, 0x11);  // IDR only
    std::vector<uint8_t> out;
    bool keyframe = false;
    AvccToAnnexB conv;
    assert(conv.Convert(au.data(), au.size(), &out, &keyframe));
    assert(keyframe);
    // No params cached yet -> just the IDR.
    ExpectTypes({5}, NalTypes(out), "first keyframe, no cached params");
  }
  {
    // Prime the cache with SPS+PPS, then send an IDR-only AU.
    std::vector<uint8_t> prime;
    AppendNal(&prime, 7, 10, 0xAB);
    AppendNal(&prime, 8, 4, 0xCD);
    std::vector<uint8_t> out;
    bool keyframe = false;
    AvccToAnnexB conv;
    assert(conv.Convert(prime.data(), prime.size(), &out, &keyframe));

    std::vector<uint8_t> idr;
    AppendNal(&idr, 5, 32, 0x11);
    out.clear();
    assert(conv.Convert(idr.data(), idr.size(), &out, &keyframe));
    assert(keyframe);
    ExpectTypes({7, 8, 5}, NalTypes(out),
                "cached sps/pps injected before idr");
  }

  // 3. P-frame after a keyframe — should be untouched.
  {
    std::vector<uint8_t> au;
    AppendNal(&au, 1, 16, 0x22);
    std::vector<uint8_t> out;
    bool keyframe = true;
    AvccToAnnexB conv;
    assert(conv.Convert(au.data(), au.size(), &out, &keyframe));
    assert(!keyframe);
    ExpectTypes({1}, NalTypes(out), "p-frame passthrough");
  }

  // 4. Malformed input: zero length prefix.
  {
    const uint8_t data[] = {0x00, 0x00, 0x00, 0x00};
    std::vector<uint8_t> out;
    bool keyframe = false;
    AvccToAnnexB conv;
    assert(!conv.Convert(data, sizeof(data), &out, &keyframe));
    std::printf("ok   zero-length prefix rejected\n");
  }

  // 5. Malformed input: length prefix exceeds buffer.
  {
    const uint8_t data[] = {0x00, 0x00, 0x00, 0x64, 0x65};
    std::vector<uint8_t> out;
    bool keyframe = false;
    AvccToAnnexB conv;
    assert(!conv.Convert(data, sizeof(data), &out, &keyframe));
    std::printf("ok   truncated NAL rejected\n");
  }

  // 6. Annex-B keyframe with in-band SPS/PPS — what WebRTC m144 actually
  //    hands decoders (H26xPacketBuffer inserts 4-byte start codes).
  {
    std::vector<uint8_t> au;
    AppendAnnexBNal(&au, 7, 10, 0xAB);  // SPS
    AppendAnnexBNal(&au, 8, 4, 0xCD);   // PPS
    AppendAnnexBNal(&au, 5, 32, 0x11);  // IDR
    AppendAnnexBNal(&au, 1, 16, 0x22);  // P slice

    std::vector<uint8_t> out;
    bool keyframe = false;
    AvccToAnnexB conv;
    assert(conv.Convert(au.data(), au.size(), &out, &keyframe));
    assert(keyframe);
    ExpectTypes({7, 8, 5, 1}, NalTypes(out), "annexb in-band sps/pps + idr");
  }

  // 7. Annex-B IDR-only keyframe — cached SPS/PPS must be re-injected.
  {
    std::vector<uint8_t> prime;
    AppendAnnexBNal(&prime, 7, 10, 0xAB);
    AppendAnnexBNal(&prime, 8, 4, 0xCD);
    std::vector<uint8_t> out;
    bool keyframe = false;
    AvccToAnnexB conv;
    assert(conv.Convert(prime.data(), prime.size(), &out, &keyframe));

    std::vector<uint8_t> idr;
    AppendAnnexBNal(&idr, 5, 32, 0x11);
    out.clear();
    assert(conv.Convert(idr.data(), idr.size(), &out, &keyframe));
    assert(keyframe);
    ExpectTypes({7, 8, 5}, NalTypes(out),
                "annexb cached sps/pps injected before idr");
  }

  // 8. Annex-B 3-byte start codes are normalized to 4-byte.
  {
    std::vector<uint8_t> au;
    AppendAnnexBNal(&au, 5, 8, 0x11, /*four_byte_code=*/false);
    std::vector<uint8_t> out;
    bool keyframe = false;
    AvccToAnnexB conv;
    assert(conv.Convert(au.data(), au.size(), &out, &keyframe));
    assert(keyframe);
    ExpectTypes({5}, NalTypes(out), "annexb 3-byte start code normalized");
  }

  // 9. Annex-B P-frame passthrough.
  {
    std::vector<uint8_t> au;
    AppendAnnexBNal(&au, 1, 16, 0x22);
    std::vector<uint8_t> out;
    bool keyframe = true;
    AvccToAnnexB conv;
    assert(conv.Convert(au.data(), au.size(), &out, &keyframe));
    assert(!keyframe);
    ExpectTypes({1}, NalTypes(out), "annexb p-frame passthrough");
  }

  std::printf("ALL PASS\n");
  return 0;
}
