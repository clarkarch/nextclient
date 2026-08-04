#!/usr/bin/env python3
"""Reproduce the app's not-negotiated failure with app-like TIMING.

The app creates the pipeline and calls set_state(PLAYING) at decoder-Configure
time (when WebRTC initializes the decoder), but the first frame only arrives
~2.5s later (ICE + signaling + first keyframe). The first push therefore
happens while the live pipeline is still mid-async PAUSED->PLAYING.

Modes (argv[1]):
  quick    push right after set_state (control)   [expect: decodes]
  delayed  wait 2.5s before first push            [expect: not-negotiated?]
  delayed_pts  delayed + GFN-style PTS (90kHz from 0, ~17ms/frame)
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
PUSH_RES = []


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
    return Gst.FlowReturn.OK


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else 'quick'
    path = sys.argv[2] if len(sys.argv) > 2 else '/tmp/test_annexb.h264'

    with open(path, 'rb') as f:
        data = f.read()
    aus = group_aus(split_nals(data))
    print(f'{len(aus)} AUs (mode={mode})', flush=True)

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

    if mode.startswith('delayed'):
        time.sleep(2.5)
        st = pipeline.get_state(0)
        print(f'after 2.5s state: {st[1].value_nick} '
              f'({st[0].value_nick})', flush=True)

    def pusher():
        for idx, au in enumerate(aus):
            buf = Gst.Buffer.new_allocate(None, len(au), None)
            buf.fill(0, au)
            if mode == 'delayed_pts':
                # GFN-style: 90kHz RTP timestamps starting near 0,
                # ~17ms per frame at 58fps
                rtp_ts = idx * int(90000 / 58)
                buf.pts = rtp_ts * 1000000000 // 90000
            else:
                buf.pts = idx * int(1e9 / 58)
            flow = appsrc.emit('push-buffer', buf)
            PUSH_RES.append(flow)
        appsrc.emit('end-of-stream')

    t = threading.Thread(target=pusher, daemon=True)
    t.start()
    t.join(6)
    time.sleep(2)

    state = pipeline.get_state(0)[1]
    non_ok = [r.value_nick for r in PUSH_RES if r != Gst.FlowReturn.OK]
    print(f'RESULT decoded={DECODED["n"]} state={state.value_nick} '
          f'push_non_ok={non_ok[:5]}', flush=True)

    bus.remove_signal_watch()
    loop.quit()
    pipeline.set_state(Gst.State.NULL)


if __name__ == '__main__':
    main()
