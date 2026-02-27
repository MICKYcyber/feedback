# Roblox Sound Testing

This repo now includes a Luau processor that mimics the "decoded mp3" style effect described in your chat:

- preset frequency-band shaping (`bands` table)
- decode-rate emulation (`emulatedDecodeHz` downsample + hold)
- optional bit crush (`bitDepth`)
- fixed-step processing loop on `RunService.PreSimulation` to reduce frame jitter impact

## File

- `src/Mp3LikeEmulation.lua`

## Quick usage

```lua
local Mp3LikeEmulation = require(path.to.Mp3LikeEmulation)

local processor = Mp3LikeEmulation.new({
	sampleRate = 48000,
	emulatedDecodeHz = 22050,
	lockedProcessHz = 120,
	bitDepth = 10,
	mix = 1,
})

processor:start()

-- In your own audio pipeline:
-- local processed = processor:processChunk(monoSamples)
-- write processed samples back into your EditableAudio buffer
```

## Notes

- `PreSimulation` is still tied to engine updates, but the internal accumulator makes processing run at a **locked step** (`lockedProcessHz`) so it does not directly depend on fluctuating render FPS.
- `_tick` is intentionally left as integration glue for your specific EditableAudio read/write flow.
