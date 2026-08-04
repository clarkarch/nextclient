#!/usr/bin/env python3
"""Reproduce the app's `not-negotiated` failure.

The app log shows:
  gst_base_src_loop(): /GstPipeline:pipeline0/GstAppSrc:src: streaming stopped,
                       reason not-negotiated (-4)

and WebRTC logs "Found out of band supplied codec parameters" — meaning the
m144 packet buffer EXTRACTS SPS/PPS from the keyframe and delivers the IDR
payload WITHOUT them (out-of-band). h264parse in alignment=au mode then cannot
determine output caps on the first buffer -> not-negotiated.

Modes (argv[1]):
  control   push every AU as-is (SPS/PPS in first AU)        [expect: decodes]
  stripped  strip SPS/PPS from the FIRST AU only             [expect: fail]
"""
import sys
import threading
import time

import gi

gi.require_version('Gst', '1.0')
gi.require_version('GstApp', '1.0')
from gi.repository import Gst, GLib, GstApp  # noqa: E402

Gst.init(None)

DECODED = {'n': 0}


def split_nals(data):
    nals = []
    i = 0
    n = len(data)
    while i < n - 3:
        if data[i:i + 4] == b'\x00\x00\x00\x01':
            sc = 4
        elif data[i:i + 3] == b'\x00\x00\x01':
            sc = 3
        else:
            i += 1
            continue
        j = i + sc
        while j < n - 3:
            if data[j:j + 4] == b'\x00\x00\x00\x01' or data[j:j + 3] == b'\x00\x00\x01':
                break
            j += 1
        nals.append(data[i + sc:j])
        i = j
    return nals


def group_aus(nals):
    aus = []
    cur = []
    for nal in nals:
        t = nal[0] & 0x1f
        if t == 9 and cur:
            aus.append(b''.join(cur))
            cur = []
        cur.append(b'\x00\x00\x00\x01' + nal)
    if cur:
        aus.append(b''.join(cur))
    return aus


def on_sample(sink, _user_data):
    sample = sink.emit('pull-sample')
    if sample:
        DECODED['n'] += 1
        sample.unref()
    return Gst.FlowReturn.OK


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else 'control'
    path = sys.argv[2] if len(sys.argv) > 2 else '/tmp/test_annexb.h264'

    with open(path, 'rb') as f:
        data = f.read()
    nals = split_nals(data)
    aus = group_aus(nals)

    # Strip SPS/PPS (types 7/8) from the first AU only, mimicking WebRTC's
    # out-of-band handling of the initial keyframe.
    if mode == 'stripped':
        first = aus[0]
        out = []
        i = 0
        n = len(first)
        while i < n - 3:
            if first[i:i + 4] == b'\x00\x00\x00\x01':
                sc = 4
            elif first[i:i + 3] == b'\x00\x00\x01':
                sc = 3
            else:
                i += 1
                continue
            hdr = first[i + sc]
            if (hdr & 0x1f) in (7, 8):
                i += sc + 1  # skip this NAL
                continue
            out.append(first[i:])
            i += sc + 1
            break  # only need the next NAL boundary for simplicity
        if out:
            first = out[0]
        aus[0] = first
        print(f'[stripped] first AU now starts with NAL type '
              f'{(first[4] & 0x1f) if len(first) > 4 else -1} '
              f'({len(first)} bytes)', flush=True)
    else:
        print(f'[control] first AU starts with NAL type '
              f'{(aus[0][4] & 0x1f) if len(aus[0]) > 4 else -1} '
              f'({len(aus[0])} bytes)', flush=True)

    print(f'parsed {len(nals)} NALs into {len(aus)} AUs (mode={mode})',
          flush=True)

    pipeline = Gst.parse_launch(
        'appsrc name=src ! h264parse ! vah264dec ! videoconvert '
        '! video/x-raw,format=I420 ! appsink name=sink')
    appsrc = pipeline.get_by_name('src')
    appsink = pipeline.get_by_name('sink')

    caps = Gst.Caps.from_string(
        'video/x-h264,stream-format=byte-stream,alignment=au')
    appsrc.set_property('caps', caps)
    appsrc.set_property('stream-type', GstApp.AppStreamType.STREAM)
    appsrc.set_property('format', Gst.Format.TIME)
    appsrc.set_property('is-live', True)
    appsrc.set_property('do-timestamp', False)
    appsrc.set_property('max-bytes', 2 * 1024 * 1024)
    appsrc.set_property('block', False)

    appsink.set_property('sync', False)
    appsink.set_property('drop', True)
    appsink.set_property('max-buffers', 2)
    appsink.set_property('emit-signals', True)
    appsink.connect('new-sample', on_sample, None)

    bus = pipeline.get_bus()
    bus.add_signal_watch()
    bus.connect('message::error', lambda b, m: print(
        'BUS_ERROR:', m.parse_error()[1].message, flush=True))
    bus.connect('message::warning', lambda b, m: print(
        'BUS_WARN:', m.parse_warning()[1].message, flush=True))

    loop = GLib.MainLoop()
    threading.Thread(target=loop.run, daemon=True).start()

    ret = pipeline.set_state(Gst.State.PLAYING)
    print(f'set_state -> {ret.value_nick}', flush=True)
    time.sleep(0.5)

    push_failures = {'n': 0}

    def pusher():
        for idx, au in enumerate(aus):
            buf = Gst.Buffer.new_allocate(None, len(au), None)
            buf.fill(0, au)
            buf.pts = idx * int(1e9 / 58)
            flow = appsrc.emit('push-buffer', buf)
            if flow != Gst.FlowReturn.OK:
                push_failures['n'] += 1
                if push_failures['n'] <= 3:
                    print(f'push {idx} -> {flow.value_nick}', flush=True)
        appsrc.emit('end-of-stream')

    t = threading.Thread(target=pusher, daemon=True)
    t.start()
    t.join(6)
    time.sleep(2)

    state = pipeline.get_state(0)[1]
    print(f'RESULT decoded={DECODED["n"]} state={state.value_nick} '
          f'push_failures={push_failures["n"]}', flush=True)

    bus.remove_signal_watch()
    loop.quit()
    pipeline.set_state(Gst.State.NULL)


if __name__ == '__main__':
    main()
