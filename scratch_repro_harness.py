#!/usr/bin/env python3
"""Faithful reproduction of the app's GStreamer VAAPI decoder pipeline.

Builds the EXACT pipeline from vaapi_video_decoder.cc:
  appsrc (is-live=TRUE, do-timestamp=FALSE, format=TIME, stream-type=STREAM,
          max-bytes=2MB, block=FALSE, caps byte-stream/au)
    -> h264parse -> vah264dec -> videoconvert -> video/x-raw,format=I420
    -> appsink (sync=FALSE, drop=TRUE, max-buffers=2, emit-signals)

Pushes correctly framed access units (each buffer = one complete picture:
AUD+SPS+PPS+SEI+IDR together, or AUD+slice), mimicking what the app's
AvccToAnnexB converter emits.

Modes (argv):
  1. mainloop=(0|1)   run a GMainLoop on a background thread
  2. pts_offset_ns    add this to every PTS (default 0; real RTP timestamps
                      start near 2^31*1e9/90000 ~= 23.8 billion ns)
  3. file             path to Annex-B H.264 file (default /tmp/test_annexb.h264)
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
PUSH_FAILURES = {'n': 0}


def split_nals(data):
    """Split Annex-B byte stream into NAL payloads (without start codes)."""
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
        # advance to next start code
        while j < n - 3:
            if data[j:j + 4] == b'\x00\x00\x00\x01' or data[j:j + 3] == b'\x00\x00\x01':
                break
            j += 1
        nals.append(data[i + sc:j])
        i = j
    return nals


def group_aus(nals):
    """Group NALs into complete access units (one picture per AU).

    This stream uses AUD (type 9) to delimit pictures. Each AU therefore is
    [AUD, SPS, PPS, SEI, IDR] or [AUD, slice]. This mirrors the complete-AU
    buffers the app's converter produces.
    """
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
    mainloop_on = len(sys.argv) > 1 and sys.argv[1] == '1'
    pts_offset = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    path = sys.argv[3] if len(sys.argv) > 3 else '/tmp/test_annexb.h264'

    with open(path, 'rb') as f:
        data = f.read()
    nals = split_nals(data)
    aus = group_aus(nals)
    print(f'parsed {len(nals)} NALs into {len(aus)} complete AUs '
          f'(mainloop={mainloop_on}, pts_offset_ns={pts_offset})', flush=True)

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

    loop = None
    thread = None
    if mainloop_on:
        loop = GLib.MainLoop()
        def run_loop():
            loop.run()
        thread = threading.Thread(target=run_loop, daemon=True)
        thread.start()
        bus.add_signal_watch()
        bus.connect('message::error', lambda b, m: print(
            'BUS_ERROR:', m.parse_error()[1].message, flush=True))
        bus.connect('message::warning', lambda b, m: print(
            'BUS_WARN:', m.parse_warning()[1].message, flush=True))
        bus.connect('message::state-changed',
                    lambda b, m: (lambda o, n, p: print(
                        f'STATE {o.value_nick}->{n.value_nick} ({p.value_nick})',
                        flush=True)
                        if m.src == pipeline else None)(*m.parse_state_changed())
                    if m.has_name('state-changed') else None)

    ret = pipeline.set_state(Gst.State.PLAYING)
    print(f'set_state -> {ret.value_nick}', flush=True)
    time.sleep(0.5)

    # Push all AUs from a worker thread so a blocking appsrc push doesn't
    # freeze the test — the main thread watches with a timeout.
    push_result = {}

    def pusher():
        for idx, au in enumerate(aus):
            buf = Gst.Buffer.new_allocate(None, len(au), None)
            buf.fill(0, au)
            buf.pts = (idx * int(1e9 / 58) + pts_offset)
            flow = appsrc.emit('push-buffer', buf)
            if flow != Gst.FlowReturn.OK:
                PUSH_FAILURES['n'] += 1
                if PUSH_FAILURES['n'] <= 5:
                    print(f'push {idx} -> {flow.value_nick}', flush=True)
        appsrc.emit('end-of-stream')
        push_result['done'] = True
        print(f'pusher finished: {len(aus)} pushed, '
              f'{PUSH_FAILURES["n"]} failures', flush=True)

    t = threading.Thread(target=pusher, daemon=True)
    t.start()

    # Watchdog: does the pusher finish within 4s?
    t.join(4)
    if t.is_alive():
        print('WATCHDOG: pusher thread STILL BLOCKED after 4s '
              '(live appsrc waiting on clock?)', flush=True)
    else:
        print('pusher completed normally', flush=True)

    time.sleep(2)

    state = pipeline.get_state(0)[1]
    print(f'RESULT decoded={DECODED["n"]} state={state.value_nick} '
          f'push_failures={PUSH_FAILURES["n"]}', flush=True)

    if mainloop_on:
        bus.remove_signal_watch()
        loop.quit()
    pipeline.set_state(Gst.State.NULL)


if __name__ == '__main__':
    main()
