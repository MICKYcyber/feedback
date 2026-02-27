# Roblox Sound Testing

This repo includes a Luau **MP3-like lo-fi emulation** module.

> Correction: Roblox does **not** currently provide general real-time PCM read/write for `Sound` in normal experiences, so this module does not depend on a non-existent `EditableAudio` API.

## File

- `src/Mp3LikeEmulation.lua`

## What it does

- Emulates decoded-MP3-ish degradation for numeric sample arrays:
  - decode-rate downsample + hold (`emulatedDecodeHz`)
  - rough band shaping (`bands`)
  - bit-crush quantization (`bitDepth`)
  - dry/wet mix (`mix`)
- Provides a fixed-step scheduler on `RunService.PreSimulation` (`lockedProcessHz`) to avoid tying updates directly to fluctuating visual FPS.
- Exposes `getSuggestedSoundEffectParams()` for mapping the lo-fi character onto Roblox `EqualizerSoundEffect`/`DistortionSoundEffect` settings when using ordinary `Sound` playback.

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

-- 1) If you have your own sample arrays:
local processed = processor:processChunk({0.0, 0.2, -0.1, 0.6})

-- 2) If you're using regular Sound instances, map the character to effects:
local params = processor:getSuggestedSoundEffectParams()
-- Apply params.eqHighGain / eqMidGain / eqLowGain / distortionLevel to your effect instances.

-- 3) Optional fixed-rate loop for stable updates:
processor:start(function(dt)
	-- update effect parameters, automation, or other timing-sensitive logic
end)
```
