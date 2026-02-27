--!strict

--
-- Mp3LikeEmulation
--
-- A lightweight "decoded mp3" style effect for EditableAudio sample buffers.
-- It intentionally degrades fidelity by:
-- 1) quantizing frequency bands to preset gains
-- 2) reducing sample rate to a target Hz bucket
-- 3) optionally lowering bit depth
--
-- Designed to run on RunService.PreSimulation with an internal fixed-rate accumulator
-- so processing speed is stable even when visual FPS fluctuates.
--

local RunService = game:GetService("RunService")

export type Band = {
	minHz: number,
	maxHz: number,
	gain: number,
}

export type Config = {
	sampleRate: number,
	channelCount: number,
	frameSize: number,
	lockedProcessHz: number,
	emulatedDecodeHz: number,
	bitDepth: number,
	bands: { Band },
	drive: number,
	mix: number,
}

export type Processor = {
	start: (self: Processor) -> (),
	stop: (self: Processor) -> (),
	processChunk: (self: Processor, monoSamples: { number }) -> { number },
	isRunning: (self: Processor) -> boolean,
}

local DEFAULT_BANDS: { Band } = {
	{ minHz = 20, maxHz = 120, gain = 1.05 },
	{ minHz = 120, maxHz = 450, gain = 0.95 },
	{ minHz = 450, maxHz = 1800, gain = 1.1 },
	{ minHz = 1800, maxHz = 5000, gain = 0.85 },
	{ minHz = 5000, maxHz = 12000, gain = 0.75 },
	{ minHz = 12000, maxHz = 20000, gain = 0.62 },
}

local DEFAULT_CONFIG: Config = {
	sampleRate = 48000,
	channelCount = 1,
	frameSize = 512,
	lockedProcessHz = 120,
	emulatedDecodeHz = 24000,
	bitDepth = 10,
	bands = DEFAULT_BANDS,
	drive = 1.1,
	mix = 1,
}

local Mp3LikeEmulation = {}
Mp3LikeEmulation.__index = Mp3LikeEmulation

local function clamp(v: number, minV: number, maxV: number): number
	if v < minV then
		return minV
	elseif v > maxV then
		return maxV
	end
	return v
end

local function deepCopy<T>(t: T): T
	if type(t) ~= "table" then
		return t
	end
	local clone = {}
	for k, v in t :: any do
		clone[k] = deepCopy(v)
	end
	return clone :: any
end

local function mergeConfig(override: {[string]: any}?): Config
	local config: Config = deepCopy(DEFAULT_CONFIG)
	if override then
		for key, value in override :: any do
			(config :: any)[key] = value
		end
	end
	return config
end

local function quantizeSample(sample: number, bitDepth: number): number
	local levels = 2 ^ bitDepth
	local stepped = math.floor((sample * 0.5 + 0.5) * (levels - 1) + 0.5)
	return (stepped / (levels - 1) - 0.5) * 2
end

local function estimateBandGain(index: number, sampleRate: number, bands: { Band }): number
	local nyquist = sampleRate * 0.5
	local hz = (index / 512) * nyquist
	for _, band in bands do
		if hz >= band.minHz and hz < band.maxHz then
			return band.gain
		end
	end
	return 1
end

function Mp3LikeEmulation.new(configOverride: {[string]: any}?): Processor
	local self = setmetatable({}, Mp3LikeEmulation)
	self._config = mergeConfig(configOverride)
	self._running = false
	self._accumulator = 0
	self._conn = nil
	self._queue = {}
	return self
end

function Mp3LikeEmulation:isRunning(): boolean
	return self._running
end

function Mp3LikeEmulation:_downsampleAndHold(samples: { number }): { number }
	local config: Config = self._config
	local ratio = math.max(1, math.floor(config.sampleRate / config.emulatedDecodeHz))
	if ratio <= 1 then
		return samples
	end

	local out = table.create(#samples)
	local held = 0
	for i = 1, #samples do
		if ((i - 1) % ratio) == 0 then
			held = samples[i]
		end
		out[i] = held
	end
	return out
end

function Mp3LikeEmulation:_applyBandApprox(samples: { number }): { number }
	local config: Config = self._config
	local out = table.create(#samples)
	for i = 1, #samples do
		local gain = estimateBandGain(i, config.sampleRate, config.bands)
		local driven = clamp(samples[i] * gain * config.drive, -1, 1)
		out[i] = driven
	end
	return out
end

function Mp3LikeEmulation:_bitCrush(samples: { number }): { number }
	local config: Config = self._config
	if config.bitDepth >= 16 then
		return samples
	end
	local out = table.create(#samples)
	for i = 1, #samples do
		out[i] = quantizeSample(samples[i], config.bitDepth)
	end
	return out
end

function Mp3LikeEmulation:processChunk(monoSamples: { number }): { number }
	local dry = monoSamples
	local wet = self:_downsampleAndHold(dry)
	wet = self:_applyBandApprox(wet)
	wet = self:_bitCrush(wet)

	local mix = clamp(self._config.mix, 0, 1)
	local out = table.create(#dry)
	for i = 1, #dry do
		out[i] = dry[i] * (1 - mix) + wet[i] * mix
	end
	return out
end

function Mp3LikeEmulation:_tick(_stepSeconds: number)
	-- Intentionally left minimal: this is where game-specific code should
	-- read from EditableAudio buffers, call processChunk, then write back.
	-- The fixed-step loop in start() is the anti-FPS-jitter piece.
end

function Mp3LikeEmulation:start()
	if self._running then
		return
	end

	local config: Config = self._config
	local fixedStep = 1 / math.max(1, config.lockedProcessHz)
	self._running = true
	self._accumulator = 0

	self._conn = RunService.PreSimulation:Connect(function(deltaTime: number)
		self._accumulator += deltaTime
		while self._accumulator >= fixedStep do
			self._accumulator -= fixedStep
			self:_tick(fixedStep)
		end
	end)
end

function Mp3LikeEmulation:stop()
	if not self._running then
		return
	end
	self._running = false
	if self._conn then
		self._conn:Disconnect()
		self._conn = nil
	end
end

return Mp3LikeEmulation
