# Control finder: detector sidecar

Shep finds controls on a screenshot in three steps. Only the middle one is a model that *finds*; Glimmer only *names*.

1. **Accessibility tree** — the app's own controls (`AXReader`).
2. **Detector** — boxes for icon-like things the tree misses. Default: OmniParser v3 `icon_detect` (MIT). Optional: SAM 3.
3. **Glimmer** — names the boxes left after merging (`GlimmerNamer`), and picks the one a request is about. Schema-constrained JSON, validated, one retry on bad JSON.

The merge is pure Swift (`ControlMerger` / `VisionRepair.candidates`, tested): detector boxes that overlap an Accessibility frame (IoU 0.5), or sit inside a comparable-size one, are dropped (after naming, `RoleResolver` also gives a box overlapping an app control at IoU 0.3 that control's role); boxes from different detectors that are the same control collapse to the best score.

## Run the sidecar

The sidecar is a small Python HTTP server on `127.0.0.1:8765` (override the app's side with `SHEP_DETECTOR_URL`). You create the venv; nothing is installed for you.

```sh
python3 -m venv ~/.shep-venv
~/.shep-venv/bin/pip install torch torchvision pillow numpy huggingface_hub
~/.shep-venv/bin/python scripts/detector-server.py --omni-weights ~/Library/Application\ Support/Shep/models/icon_detect_v3.torchscript
```

Check it: `curl http://127.0.0.1:8765/health`.

`--fake` serves canned boxes with no models and no torch; it exists to test the wiring (`curl` it, or point the app at it).

### OmniParser v3 weights

Weights are never in this repository (`.gitignore` blocks `models/`, `*.torchscript`, `*.safetensors`, `*.pt`).

- Put `icon_detect_v3.torchscript` in `~/Library/Application Support/Shep/models/`, or pass `--omni-weights PATH`, or pass `--omni-repo <huggingface repo>` and the server downloads the file there with `huggingface_hub`.
- Use the **v3** `icon_detect` weights (MIT). The OmniParser **v2** `icon_detect` weights are AGPL-3.0: never use those.
- **Not verified:** which Hugging Face repository hosts `icon_detect_v3.torchscript`. The control-finder benchmark loads the file from a local path and does not record where it came from, so no repo name is baked in here. Read the licence file that ships with the weights before using them.

The decode (letterbox to 1280, three strides, sigmoid scores, NMS 0.45, confidence 0.05) is the benchmark's `omni_v3.py`, which follows the OmniParser README.

### Optional: icon captions

`--captions --trust-remote-code` adds OmniParser's `icon_caption` (a Florence-2 fine-tune, MIT) as a short hint per box. Loading it runs Python code shipped in the model repository, which is why it needs the explicit `--trust-remote-code`. It is a hint for Glimmer only, often wrong, and **not verified** (never run).

### Optional: SAM 3 (off by default)

SAM 3 is by Meta, under the **SAM License** ([text](https://github.com/facebookresearch/sam3/blob/main/LICENSE)). It is not an OSI open-source licence; do not call it open source.

- It is an opt-in provider. Both switches are needed: start the sidecar with `--sam3`, and launch Shep with `SHEP_SAM3=1`.
- The weights (`facebook/sam3`) are in a **gated** Hugging Face repository. Each person needs their own Hugging Face account, accepts the licence on the repository page themselves, and exports their own token (`HF_TOKEN`, or `huggingface-cli login`). Shep never stores, sends or ships a token or the weights; they download into `~/Library/Application Support/Shep/models/hf` at runtime.
- Needs `pip install transformers` in the venv. Prompts: `rounded rectangle`, `button`; threshold 0.2; NMS 0.6.
- The licence has field restrictions (§1.b.v) and Meta can change it (§8). Accept it as an individual. Read the licence text linked above before you accept it; this note is not legal advice.

## Glimmer

Shep talks to any OpenAI-compatible Glimmer server on this Mac:

- Default: the `mlx_vlm` server that `scripts/glimmer-server.sh` starts, at `http://127.0.0.1:8080/v1`.
- Already running one (for example a llama-server)? Reuse it instead of loading a second copy: `SHEP_GLIMMER_URL=http://127.0.0.1:18089/v1`. `SHEP_GLIMMER_MODEL` only matters for mlx_vlm (it must equal that server's `--model` path).
- Requests carry `"reasoning_strength": "none"` (the only switch that turns Glimmer's thinking off), `max_tokens` 1500 and temperature 0. A `json_schema` `response_format` is sent first; a server that answers 400/422 to it gets the same request with the strict prompt alone, and Shep remembers that.
- Glimmer's boxes are `[x0, y0, x1, y1]` on a 0 to 1000 scale relative to the image; Shep converts with `x / 1000 * originalWidth` (`GlimmerBoxes`, tested).

## Verified and not verified

Verified on a Mac: OmniParser v3 with Muse Glimmer, end to end, first on Oct 26, 2026 and in the live Transmission runs on Oct 28. Not verified: SAM 3 inside Shep (never run; it was only benchmarked outside the app), and the `--captions` path. To try the pipeline on one image: start the sidecar, start or reuse Glimmer, then `scripts/e2e-glimmer.sh path/to/window.png`.
