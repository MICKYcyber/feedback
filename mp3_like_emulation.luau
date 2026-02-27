--!strict
--
-- mp3_like_emulation.luau
-- Demo of a "decoded mp3" style effect in Luau using a fixed sample clock.
--
-- Why this pattern:
--   * RunService frame rate is unstable.
--   * Audio drivers run much faster than the render loop.
--   * We keep a fixed sample-step accumulator so generated audio is stable even when FPS dips.
--
-- This script assumes your experience has EditableAudio enabled.

local RunService = game:GetService("RunService")

export type BandConfig = {
	hz: number,
	gain: number,
	phase: number,
}

local SAMPLE_RATE = 22050 -- Low sample rate gives a compressed/retro feel.
local CHANNELS = 1
local CHUNK_SAMPLES = 1024

-- Quantizing sample amplitude adds a lossy-compression flavor.
local function quantize(v: number, levels: number): number
	local clamped = math.clamp(v, -1, 1)
	local scaled = (clamped + 1) * 0.5
	local stepped = math.floor(scaled * (levels - 1) + 0.5) / (levels - 1)
	return stepped * 2 - 1
end

local Mp3LikeEmitter = {}
Mp3LikeEmitter.__index = Mp3LikeEmitter

function Mp3LikeEmitter.new(parent: Instance)
	local editableAudio = Instance.new("EditableAudio")
	editableAudio.Name = "Mp3LikeEmitter"
	editableAudio.Parent = parent

	local self = setmetatable({
		audio = editableAudio,
		bands = {
			{ hz = 110, gain = 0.35, phase = 0 },
			{ hz = 220, gain = 0.25, phase = 0 },
			{ hz = 440, gain = 0.2, phase = 0 },
			{ hz = 1760, gain = 0.1, phase = 0 },
		},
		timeAccumulator = 0,
		sampleAccumulator = 0,
		writeCursor = 0,
		isRunning = false,
		conn = nil,
	}, Mp3LikeEmitter)

	return self
end

function Mp3LikeEmitter:_synthesizeChunk(sampleCount: number): {number}
	local out = table.create(sampleCount * CHANNELS)
	for i = 1, sampleCount do
		local mixed = 0
		for _, band: BandConfig in self.bands do
			band.phase += (2 * math.pi * band.hz) / SAMPLE_RATE
			if band.phase > 2 * math.pi then
				band.phase -= 2 * math.pi
			end
			mixed += math.sin(band.phase) * band.gain
		end

		-- Simple transient clipping + quantization to imitate low bitrate decode artifacts.
		mixed = math.tanh(mixed * 1.25)
		mixed = quantize(mixed, 48)
		out[i] = mixed
	end
	return out
end

function Mp3LikeEmitter:_pushAvailableSamples(deltaTime: number)
	self.timeAccumulator += deltaTime
	local expectedSamples = self.timeAccumulator * SAMPLE_RATE
	local toGenerate = math.floor(expectedSamples - self.sampleAccumulator)

	if toGenerate <= 0 then
		return
	end

	self.sampleAccumulator += toGenerate
	while toGenerate > 0 do
		local n = math.min(CHUNK_SAMPLES, toGenerate)
		local chunk = self:_synthesizeChunk(n)

		-- EditableAudio:WriteSamples(offsetInSamples, samplesArray)
		-- Offset must move forward continuously.
		self.audio:WriteSamples(self.writeCursor, chunk)
		self.writeCursor += n
		toGenerate -= n
	end
end

function Mp3LikeEmitter:start()
	if self.isRunning then
		return
	end
	self.isRunning = true

	-- PreSimulation tends to run before physics/render; good place to keep audio buffer fed.
	self.conn = RunService.PreSimulation:Connect(function(dt)
		self:_pushAvailableSamples(dt)
	end)
end

function Mp3LikeEmitter:stop()
	if not self.isRunning then
		return
	end
	self.isRunning = false

	if self.conn then
		self.conn:Disconnect()
		self.conn = nil
	end
end

-- Example usage:
-- local emitter = Mp3LikeEmitter.new(workspace)
-- emitter:start()

return Mp3LikeEmitter
