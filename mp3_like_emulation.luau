--!strict
--
-- mp3_like_emulation.luau
--
-- A more practical MP3-like emulator for EditableAudio:
--   1) Uses a fixed sample clock (not frame count).
--   2) Feeds audio in PreSimulation with bounded catch-up.
--   3) Adds lossy-style artifacts: band-limit, soft clip, bit-depth quantization,
--      and optional tiny random packet-loss style dropouts.

local RunService = game:GetService("RunService")

export type BandConfig = {
	hz: number,
	gain: number,
	phase: number,
}

export type Config = {
	sampleRate: number?,
	chunkSamples: number?,
	bitDepth: number?,
	maxCatchUpSeconds: number?,
	dropoutChance: number?,
	inputGain: number?,
	outputGain: number?,
	bands: { BandConfig }?,
}

type Connection = RBXScriptConnection?

local DEFAULT_SAMPLE_RATE = 24000
local DEFAULT_CHUNK_SAMPLES = 960 -- 40ms @ 24kHz
local DEFAULT_BIT_DEPTH = 6
local DEFAULT_MAX_CATCH_UP = 0.12
local TWO_PI = math.pi * 2

local function clamp(v: number, lo: number, hi: number): number
	if v < lo then
		return lo
	end
	if v > hi then
		return hi
	end
	return v
end

local function quantizeSigned(v: number, bitDepth: number): number
	local levels = 2 ^ bitDepth
	local normalized = (clamp(v, -1, 1) + 1) * 0.5
	local stepped = math.floor(normalized * (levels - 1) + 0.5) / (levels - 1)
	return stepped * 2 - 1
end

local Mp3LikeEmitter = {}
Mp3LikeEmitter.__index = Mp3LikeEmitter

function Mp3LikeEmitter.new(parent: Instance, config: Config?)
	local cfg = config or {}
	local sampleRate = cfg.sampleRate or DEFAULT_SAMPLE_RATE
	local chunkSamples = cfg.chunkSamples or DEFAULT_CHUNK_SAMPLES
	local bitDepth = cfg.bitDepth or DEFAULT_BIT_DEPTH

	local editableAudio = Instance.new("EditableAudio")
	editableAudio.Name = "Mp3LikeEmitter"
	editableAudio.Parent = parent

	local bands = cfg.bands or {
		{ hz = 110, gain = 0.36, phase = 0 },
		{ hz = 220, gain = 0.24, phase = 0 },
		{ hz = 440, gain = 0.18, phase = 0 },
		{ hz = 1760, gain = 0.10, phase = 0 },
		{ hz = 3520, gain = 0.05, phase = 0 },
	}

	local self = setmetatable({
		audio = editableAudio,
		bands = bands,
		sampleRate = sampleRate,
		chunkSamples = chunkSamples,
		bitDepth = bitDepth,
		maxCatchUpSeconds = cfg.maxCatchUpSeconds or DEFAULT_MAX_CATCH_UP,
		dropoutChance = cfg.dropoutChance or 0.002,
		inputGain = cfg.inputGain or 1.25,
		outputGain = cfg.outputGain or 0.85,
		timeAccumulator = 0,
		sampleAccumulator = 0,
		writeCursor = 0,
		isRunning = false,
		conn = nil :: Connection,
	}, Mp3LikeEmitter)

	return self
end

function Mp3LikeEmitter:_renderChunk(sampleCount: number): { number }
	local out = table.create(sampleCount)

	for i = 1, sampleCount do
		local mix = 0
		for _, band in self.bands do
			band.phase += (TWO_PI * band.hz) / self.sampleRate
			if band.phase >= TWO_PI then
				band.phase -= TWO_PI
			end
			mix += math.sin(band.phase) * band.gain
		end

		-- crude "mp3-ish" artifacts chain
		mix = math.tanh(mix * self.inputGain) -- transient soft-clip

		if math.random() < self.dropoutChance then
			mix *= 0.2 -- tiny packet-loss style blip
		end

		mix = quantizeSigned(mix, self.bitDepth)
		mix *= self.outputGain
		out[i] = clamp(mix, -1, 1)
	end

	return out
end

function Mp3LikeEmitter:_generateFromDelta(deltaTime: number)
	-- Avoid huge catch-up bursts after pause/tab-out.
	local boundedDelta = math.min(deltaTime, self.maxCatchUpSeconds)
	self.timeAccumulator += boundedDelta

	local expectedSamples = self.timeAccumulator * self.sampleRate
	local toGenerate = math.floor(expectedSamples - self.sampleAccumulator)
	if toGenerate <= 0 then
		return
	end

	self.sampleAccumulator += toGenerate

	while toGenerate > 0 do
		local n = math.min(self.chunkSamples, toGenerate)
		local chunk = self:_renderChunk(n)
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

	self.conn = RunService.PreSimulation:Connect(function(dt)
		self:_generateFromDelta(dt)
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

-- Example:
-- local emitter = Mp3LikeEmitter.new(workspace, {
-- 	sampleRate = 22050,
-- 	bitDepth = 5,
-- 	dropoutChance = 0.003,
-- })
-- emitter:start()

return Mp3LikeEmitter
