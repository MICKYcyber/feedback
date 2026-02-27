--!strict

--
-- Mp3LikeEmulation
--
-- Roblox does not expose real-time PCM sample read/write APIs in standard experiences.
-- This module therefore focuses on:
--   1) processing plain Luau sample arrays (for custom audio pipelines/tools), and
--   2) providing a fixed-step scheduler on PreSimulation so updates run at a stable rate.
--
-- If you are using normal Sound instances, use this as a *parameter generator* for
-- sound effects rather than direct PCM mutation.
--

local RunService = game:GetService("RunService")

export type Band = {
	minHz: number,
	maxHz: number,
	gain: number,
}

export type Config = {
	sampleRate: number,
	lockedProcessHz: number,
	emulatedDecodeHz: number,
	bitDepth: number,
	bands: { Band },
	drive: number,
	mix: number,
}

export type LoFiParams = {
	eqHighGain: number,
	eqMidGain: number,
	eqLowGain: number,
	distortionLevel: number,
}

export type Processor = {
	start: (self: Processor, onStep: ((dt: number) -> ())?) -> (),
	stop: (self: Processor) -> (),
	isRunning: (self: Processor) -> boolean,
	processChunk: (self: Processor, monoSamples: { number }) -> { number },
	getSuggestedSoundEffectParams: (self: Processor) -> LoFiParams,
}

local DEFAULT_BANDS: { Band } = {
	{ minHz = 20, maxHz = 120, gain = 1.05 },
	{ minHz = 120, maxHz = 450, gain = 0.92 },
	{ minHz = 450, maxHz = 1800, gain = 1.08 },
	{ minHz = 1800, maxHz = 5000, gain = 0.8 },
	{ minHz = 5000, maxHz = 12000, gain = 0.68 },
	{ minHz = 12000, maxHz = 20000, gain = 0.55 },
}

local DEFAULT_CONFIG: Config = {
	sampleRate = 48000,
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

local function mergeConfig(override: { [string]: any }?): Config
	local config: Config = deepCopy(DEFAULT_CONFIG)
	if override then
		for key, value in override do
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

local function estimateBandGain(sampleIndex: number, chunkSize: number, sampleRate: number, bands: { Band }): number
	local nyquist = sampleRate * 0.5
	local hz = (sampleIndex / math.max(1, chunkSize)) * nyquist
	for _, band in bands do
		if hz >= band.minHz and hz < band.maxHz then
			return band.gain
		end
	end
	return 1
end

function Mp3LikeEmulation.new(configOverride: { [string]: any }?): Processor
	local self = setmetatable({}, Mp3LikeEmulation)
	self._config = mergeConfig(configOverride)
	self._running = false
	self._accumulator = 0
	self._conn = nil
	self._onStep = nil
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
		local gain = estimateBandGain(i, #samples, config.sampleRate, config.bands)
		out[i] = clamp(samples[i] * gain * config.drive, -1, 1)
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

function Mp3LikeEmulation:getSuggestedSoundEffectParams(): LoFiParams
	local c: Config = self._config
	local topBand = c.bands[#c.bands]
	local midBand = c.bands[math.max(1, math.floor(#c.bands / 2))]
	local lowBand = c.bands[1]

	return {
		eqHighGain = clamp((topBand and topBand.gain or 1) * -15, -80, 10),
		eqMidGain = clamp(((midBand and midBand.gain or 1) - 1) * 10, -80, 10),
		eqLowGain = clamp(((lowBand and lowBand.gain or 1) - 1) * 10, -80, 10),
		distortionLevel = clamp((16 - c.bitDepth) / 16 + (c.drive - 1) * 0.25, 0, 1),
	}
end

function Mp3LikeEmulation:start(onStep: ((dt: number) -> ())?)
	if self._running then
		return
	end

	local fixedStep = 1 / math.max(1, self._config.lockedProcessHz)
	self._running = true
	self._accumulator = 0
	self._onStep = onStep

	self._conn = RunService.PreSimulation:Connect(function(deltaTime: number)
		self._accumulator += deltaTime
		while self._accumulator >= fixedStep do
			self._accumulator -= fixedStep
			if self._onStep then
				self._onStep(fixedStep)
			end
		end
	end)
end

function Mp3LikeEmulation:stop()
	if not self._running then
		return
	end
	self._running = false
	self._onStep = nil
	if self._conn then
		self._conn:Disconnect()
		self._conn = nil
	end
end

return Mp3LikeEmulation
