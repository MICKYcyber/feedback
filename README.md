# feedback

Includes `mp3_like_emulation.luau`, a Luau module that recreates a low-bitrate
"decoded mp3" style effect with `EditableAudio`.

Highlights:
- fixed sample clock (stable even when frame rate varies)
- `RunService.PreSimulation` buffering loop
- configurable lo-fi artifacts (bit-depth reduction, soft clipping, and small dropouts)
