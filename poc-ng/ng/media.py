"""FFmpeg/PyAV owns codecs, conversion and file demuxing; only wire adaptation lives here."""
from dataclasses import replace
from fractions import Fraction
import hashlib
from pathlib import Path
import re
import time

import av

from .wire import Config, Frame, length_prefixed, nals, require, us


def annexb_units(data: bytes) -> list[bytes]:
    return [part for part in re.split(b"\x00\x00\x00?\x01", data) if part]


def pixel_hash(frame: av.VideoFrame) -> str:
    # Hash visible samples only: FFmpeg plane padding is not image content.
    digest = hashlib.sha256()
    for plane in frame.planes:
        data = bytes(plane)
        for row in range(plane.height):
            digest.update(data[row * plane.line_size:row * plane.line_size + plane.width])
    return digest.hexdigest()


class Decoder:
    def __init__(self) -> None:
        self.context = av.CodecContext.create("hevc", "r")
        self.context.thread_count = 1

    def decode(self, frame: Frame) -> av.VideoFrame:
        data = b"".join(b"\0\0\0\1" + nal for nal in nals(frame.codec) + nals(frame.payload))
        decoded = self.context.decode(av.Packet(data))
        require(len(decoded) == 1, "expected one immediately decoded HEVC picture (no B frames)")
        return decoded[0]


class Encoder:
    def __init__(self, config: Config, input_path: Path):
        self.config = config
        self.source = av.open(str(input_path))
        self.frames = self.source.decode(video=0)
        self.context = av.CodecContext.create("libx265", "w")
        self.context.width, self.context.height = config.width, config.height
        self.context.pix_fmt = "yuv420p"
        self.context.time_base = Fraction(1, config.fps)
        self.context.framerate = Fraction(config.fps, 1)
        self.context.bit_rate = config.bitrate
        self.context.options = {"preset": "ultrafast", "tune": "zerolatency", "forced-idr": "1", "x265-params": "bframes=0:ref=1:open-gop=0:keyint=10000:min-keyint=1:scenecut=0:repeat-headers=1:annexb=1:pools=none:frame-threads=1:log-level=error"}
        self.context.open()
        self.oracle = Decoder()
        self.index = 0

    def close(self) -> None:
        self.source.close()

    def encode(self, force_idr: bool) -> tuple[Frame, str, dict[str, float]]:
        try:
            source = next(self.frames)
        except StopIteration:
            self.source.seek(0)
            self.frames = self.source.decode(video=0)
            source = next(self.frames)
        config = replace(self.config)
        source = source.reformat(width=config.width, height=config.height, format="yuv420p")
        source.pts = self.index
        source.time_base = self.context.time_base
        source.pict_type = av.video.frame.PictureType.I if force_idr else av.video.frame.PictureType.NONE
        capture = time.monotonic()
        timestamp = us()
        packets = self.context.encode(source)
        encoded_at = time.monotonic()
        require(len(packets) == 1, "encoder must produce one access unit immediately")
        units = annexb_units(bytes(packets[0]))
        sets = {unit[0] >> 1 & 63: unit for unit in units if unit[0] >> 1 & 63 in (32, 33, 34)}
        idr = any(unit[0] >> 1 & 63 in (19, 20) for unit in units)
        require(not force_idr or idr, "encoder did not honor forced IDR")
        payload = [unit for unit in units if unit[0] >> 1 & 63 not in (32, 33, 34, 35)]
        codec = length_prefixed([sets[kind] for kind in (32, 33, 34)]) if idr else b""
        frame = Frame(0 if idr else 1, 0 if idr else 1, config.generation, timestamp, length_prefixed(payload), codec)
        expected = pixel_hash(self.oracle.decode(frame))
        self.index += 1
        return frame, expected, {"capture": capture, "encoded": encoded_at, "encode_ms": (encoded_at - capture) * 1000}
