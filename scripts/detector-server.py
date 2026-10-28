#!/usr/bin/env python3
"""Shep detector sidecar: finds control-like boxes on a screenshot and returns them as JSON over localhost HTTP.

  OmniParser v3 `icon_detect` (MIT weights; never the AGPL icon_detect), always on.
  SAM 3 (SAM License, gated Hugging Face repo): OFF unless started with --sam3 AND the request asks for it.
  Optional OmniParser `icon_caption` hints with --captions (needs --trust-remote-code, see docs/detector.md).

Run it from a venv you create (docs/detector.md). Nothing here is imported by the Shep app; it only speaks HTTP:

  GET  /health  -> {"ok": true, "detectors": ["omniparser-v3", ...]}
  POST /detect  {"image": "<base64 png/jpeg>", "sam3": false}
       -> {"width": W, "height": H, "boxes": [{"box": [x0, y0, x1, y1], "score": 0.9, "source": "omniparser-v3",
            "kind": "icon", "caption": ""}], "notes": [...], "seconds": 1.2}      (pixels of the image sent)

It binds to loopback only, rejects browser requests (Origin header) and foreign Host headers, and never writes the
screenshot to disk. Weights live under ~/Library/Application Support/Shep/models (or the Hugging Face cache): never in the repo.
`--fake` serves canned boxes with no models and no torch, to test the wiring.
"""
import argparse
import base64
import binascii
import io
import json
import os
import struct
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEFAULT_PORT = 8765
MAX_BODY = 96 * 1024 * 1024
OMNI_IMGSZ, OMNI_STRIDES = 1280, (8, 16, 32)
SAM3_PROMPTS = ("rounded rectangle", "button")
SAM3_THRESHOLD, SAM3_NMS_IOU = 0.2, 0.6
DEFAULT_MODELS_DIR = os.path.expanduser("~/Library/Application Support/Shep/models")
OMNI_FILE = "icon_detect_v3.torchscript"


# ---------------------------------------------------------------- image helpers

def image_size(data):
    """(width, height) of a PNG/JPEG without PIL, for --fake; None when unknown."""
    if data[:8] == b"\x89PNG\r\n\x1a\n" and len(data) >= 24:
        return struct.unpack(">II", data[16:24])
    return None


def load_image(data):
    from PIL import Image  # real mode only
    return Image.open(io.BytesIO(data)).convert("RGB")


# ---------------------------------------------------------------- detectors

class FakeDetector:
    name = "omniparser-v3"

    def detect(self, image_bytes, want_sam3):
        size = image_size(image_bytes) or (800, 600)
        w, h = size
        boxes = [
            {"box": [w * 0.10, h * 0.05, w * 0.15, h * 0.10], "score": 0.9, "source": "omniparser-v3", "kind": "icon", "caption": "fake"},
            {"box": [w * 0.50, h * 0.50, w * 0.60, h * 0.58], "score": 0.8, "source": "omniparser-v3", "kind": "icon", "caption": ""},
        ]
        if want_sam3:
            boxes.append({"box": [w * 0.70, h * 0.10, w * 0.80, h * 0.16], "score": 0.7, "source": "sam3", "kind": "rounded rectangle", "caption": ""})
        return size, boxes, ["fake detector: canned boxes"]


class OmniParserV3:
    """icon_detect_v3 TorchScript decode, after microsoft/OmniParser-v2.0's README (MIT) and the Shep benchmark's omni_v3.py.
    torch only, no ultralytics."""
    name = "omniparser-v3"

    def __init__(self, weights_path, conf=0.05, iou=0.45):
        import torch
        self.torch = torch
        self.model = torch.jit.load(weights_path, map_location="cpu").eval()
        self.conf, self.iou = conf, iou

    def detect_boxes(self, image):
        import numpy as np
        from PIL import Image
        from torchvision.ops import nms
        torch = self.torch
        w, h = image.size
        s = min(OMNI_IMGSZ / w, OMNI_IMGSZ / h)
        canvas = Image.new("RGB", (OMNI_IMGSZ, OMNI_IMGSZ), (114, 114, 114))
        canvas.paste(image.resize((round(w * s), round(h * s)), Image.BILINEAR), (0, 0))
        x = torch.from_numpy(np.array(canvas)).permute(2, 0, 1).float()[None] / 255.0
        with torch.no_grad():
            out = self.model(x)
        boxes, scores = [], []
        for i, stride in enumerate(OMNI_STRIDES):
            conf = out[2 * i].sigmoid()[0, 0]
            l, t, r, b = out[2 * i + 1][0]
            g = conf.shape[-1]
            gy, gx = torch.meshgrid(torch.arange(g, dtype=torch.float32), torch.arange(g, dtype=torch.float32), indexing="ij")
            cx, cy = gx + 0.5, gy + 0.5
            boxes.append(torch.stack([(cx - l) * stride, (cy - t) * stride, (cx + r) * stride, (cy + b) * stride], -1).reshape(-1, 4))
            scores.append(conf.reshape(-1))
        boxes, scores = torch.cat(boxes), torch.cat(scores)
        keep = scores > self.conf
        boxes, scores = boxes[keep], scores[keep]
        keep = nms(boxes, scores, self.iou)
        boxes, scores = boxes[keep] / s, scores[keep]
        boxes[:, 0::2] = boxes[:, 0::2].clamp(0, w)
        boxes[:, 1::2] = boxes[:, 1::2].clamp(0, h)
        return [([float(v) for v in b], float(sc)) for b, sc in zip(boxes.tolist(), scores.tolist())]


class IconCaptioner:
    """Optional OmniParser icon_caption (a Florence-2 fine-tune, MIT). Hints only; loading it runs the model repo's
    own Python code, so it needs --trust-remote-code."""

    def __init__(self, caption_dir, models_dir, device="cpu"):
        import torch
        from transformers import AutoModelForCausalLM, AutoProcessor
        self.torch, self.device = torch, device
        self.processor = AutoProcessor.from_pretrained("microsoft/Florence-2-base", trust_remote_code=True, cache_dir=os.path.join(models_dir, "hf"))
        self.model = AutoModelForCausalLM.from_pretrained(caption_dir, torch_dtype=torch.float32, trust_remote_code=True).to(device).eval()

    def captions(self, image, boxes, limit=24):
        crops = []
        for (x0, y0, x1, y1), _ in boxes[:limit]:
            crops.append(image.crop((int(x0), int(y0), max(int(x1), int(x0) + 1), max(int(y1), int(y0) + 1))).resize((64, 64)))
        if not crops:
            return []
        inputs = self.processor(images=crops, text=["<CAPTION>"] * len(crops), return_tensors="pt", do_resize=False)
        with self.torch.no_grad():
            ids = self.model.generate(input_ids=inputs["input_ids"].to(self.device), pixel_values=inputs["pixel_values"].to(self.device),
                                      max_new_tokens=20, num_beams=1, do_sample=False)
        return [t.strip() for t in self.processor.batch_decode(ids, skip_special_tokens=True)]


class Sam3:
    """facebook/sam3 text-prompted boxes ('rounded rectangle', 'button'), threshold 0.2, NMS 0.6. Gated repo: the
    person's own Hugging Face token (HF_TOKEN or `huggingface-cli login`) is used to download the weights at runtime."""
    name = "sam3"

    def __init__(self, models_dir):
        import torch
        from transformers import Sam3Model, Sam3Processor
        self.torch = torch
        self.device = "mps" if torch.backends.mps.is_available() else "cpu"
        cache = os.path.join(models_dir, "hf")
        token = os.environ.get("HF_TOKEN") or None
        self.processor = Sam3Processor.from_pretrained("facebook/sam3", cache_dir=cache, token=token)
        self.model = Sam3Model.from_pretrained("facebook/sam3", cache_dir=cache, token=token).to(self.device).eval()

    def detect_boxes(self, image):
        from torchvision.ops import nms
        torch = self.torch
        found = []
        for prompt in SAM3_PROMPTS:
            inputs = self.processor(images=image, text=prompt, return_tensors="pt").to(self.device)
            with torch.no_grad():
                outputs = self.model(**inputs)
            res = self.processor.post_process_instance_segmentation(
                outputs, threshold=SAM3_THRESHOLD, mask_threshold=0.5, target_sizes=inputs.get("original_sizes").tolist())[0]
            for b, sc in zip(res["boxes"].tolist(), res["scores"].tolist()):
                found.append(([float(v) for v in b], float(sc), prompt))
        if not found:
            return []
        keep = nms(torch.tensor([f[0] for f in found]), torch.tensor([f[1] for f in found]), SAM3_NMS_IOU).tolist()
        return [found[i] for i in keep]


class RealDetector:
    def __init__(self, args):
        self.omni = OmniParserV3(resolve_omni_weights(args))
        self.sam3 = Sam3(args.models_dir) if args.sam3 else None
        self.captioner = None
        if args.captions:
            if not args.trust_remote_code:
                raise SystemExit("--captions loads the model repo's own Python code; add --trust-remote-code to allow that.")
            self.captioner = IconCaptioner(resolve_caption_dir(args), args.models_dir)
        self.lock = threading.Lock()   # one inference at a time

    name = "omniparser-v3"

    def detect(self, image_bytes, want_sam3):
        image = load_image(image_bytes)
        notes = []
        with self.lock:
            omni = self.omni.detect_boxes(image)
            captions = self.captioner.captions(image, omni) if self.captioner else []
            boxes = []
            for i, (b, sc) in enumerate(omni):
                boxes.append({"box": b, "score": sc, "source": "omniparser-v3", "kind": "icon",
                              "caption": captions[i] if i < len(captions) else ""})
            if want_sam3:
                if self.sam3 is None:
                    notes.append("sam3 not enabled (start the sidecar with --sam3); omniparser only")
                else:
                    for b, sc, prompt in self.sam3.detect_boxes(image):
                        boxes.append({"box": b, "score": sc, "source": "sam3", "kind": prompt, "caption": ""})
        return image.size, boxes, notes


# ---------------------------------------------------------------- weights

def resolve_omni_weights(args):
    path = args.omni_weights or os.path.join(args.models_dir, OMNI_FILE)
    if os.path.isfile(path):
        return path
    if args.omni_repo:
        from huggingface_hub import hf_hub_download
        os.makedirs(args.models_dir, exist_ok=True)
        print(f"downloading {OMNI_FILE} from {args.omni_repo} into {args.models_dir}", flush=True)
        return hf_hub_download(args.omni_repo, args.omni_file or OMNI_FILE, local_dir=args.models_dir)
    raise SystemExit(f"OmniParser v3 weights not found at {path}.\nPut {OMNI_FILE} there, pass --omni-weights PATH, or pass "
                     f"--omni-repo HF_REPO to download it (see docs/detector.md; check the weights' licence first).")


def resolve_caption_dir(args):
    if args.caption_dir and os.path.isdir(args.caption_dir):
        return args.caption_dir
    repo = args.caption_repo or "microsoft/OmniParser-v2.0"
    from huggingface_hub import snapshot_download
    print(f"downloading icon_caption from {repo}", flush=True)
    root = snapshot_download(repo, allow_patterns=["icon_caption/*"], local_dir=os.path.join(args.models_dir, "omniparser"))
    return os.path.join(root, "icon_caption")


# ---------------------------------------------------------------- HTTP

def make_handler(detector, enabled, port):
    allowed_hosts = {f"127.0.0.1:{port}", f"localhost:{port}"}
    if port == 80:
        allowed_hosts |= {"127.0.0.1", "localhost"}

    class Handler(BaseHTTPRequestHandler):
        server_version = "ShepDetector/1"

        def log_message(self, fmt, *a):  # no request bodies, no image data in logs
            sys.stderr.write("detector: " + (fmt % a) + "\n")

        def _json(self, status, obj):
            body = json.dumps(obj).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _local_only(self):
            if self.headers.get("Origin"):
                self._json(403, {"error": "browser requests are refused"})
                return False
            if self.headers.get("Host", "") not in allowed_hosts:
                self._json(403, {"error": "unexpected Host header"})
                return False
            return True

        def do_GET(self):
            if not self._local_only():
                return
            if self.path == "/health":
                self._json(200, {"ok": True, "detectors": enabled})
            else:
                self._json(404, {"error": "not found"})

        def do_POST(self):
            if not self._local_only():
                return
            if self.path != "/detect":
                return self._json(404, {"error": "not found"})
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                return self._json(400, {"error": "bad Content-Length"})
            if length <= 0 or length > MAX_BODY:
                return self._json(413, {"error": "body missing or too large"})
            try:
                req = json.loads(self.rfile.read(length))
                data = base64.b64decode(req["image"], validate=True)
                want_sam3 = bool(req.get("sam3", False))
            except (ValueError, KeyError, TypeError, binascii.Error):
                return self._json(400, {"error": "expected JSON {\"image\": <base64>, \"sam3\": bool}"})
            started = time.time()
            try:
                (w, h), boxes, notes = detector.detect(data, want_sam3)
            except PermissionError as e:
                return self._json(503, {"error": str(e)})
            except Exception as e:  # report, never crash the server on one bad image
                return self._json(500, {"error": f"{type(e).__name__}: {e}"[:300]})
            self._json(200, {"width": w, "height": h, "boxes": boxes, "notes": notes, "seconds": round(time.time() - started, 3)})

    return Handler


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--host", default="127.0.0.1", help="loopback only")
    p.add_argument("--port", type=int, default=DEFAULT_PORT)
    p.add_argument("--models-dir", default=DEFAULT_MODELS_DIR)
    p.add_argument("--omni-weights", help=f"path to {OMNI_FILE}")
    p.add_argument("--omni-repo", help="Hugging Face repo to download the OmniParser v3 detect weights from")
    p.add_argument("--omni-file", help=f"file name inside --omni-repo (default {OMNI_FILE})")
    p.add_argument("--sam3", action="store_true", help="also load SAM 3 (SAM License; gated; your own HF token; not open source)")
    p.add_argument("--captions", action="store_true", help="add OmniParser icon_caption hints (needs --trust-remote-code)")
    p.add_argument("--trust-remote-code", action="store_true")
    p.add_argument("--caption-dir")
    p.add_argument("--caption-repo")
    p.add_argument("--fake", action="store_true", help="canned boxes, no models, no torch (wiring test)")
    args = p.parse_args()
    if args.host not in ("127.0.0.1", "localhost"):
        raise SystemExit("refusing to bind anywhere but loopback")
    if args.port == 11234:
        raise SystemExit("port 11234 belongs to another local server")
    detector = FakeDetector() if args.fake else RealDetector(args)
    enabled = ["omniparser-v3"] + (["sam3"] if args.fake or args.sam3 else [])
    server = ThreadingHTTPServer((args.host, args.port), make_handler(detector, enabled, args.port))
    print(f"detector ready on http://{args.host}:{args.port} ({', '.join(enabled)}{' [fake]' if args.fake else ''})", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
