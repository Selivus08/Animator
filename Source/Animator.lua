local TweenService = game:GetService("TweenService")

local Parser = animatorRequire("Parser.lua")
local Utility = animatorRequire("Utility.lua")

local Signal = animatorRequire("Nevermore/Signal.lua")
local Maid = animatorRequire("Nevermore/Maid.lua")

function merge(t1, t2)
	for k, v in pairs(t2) do
		if type(v) == "table" then
			if type(t1[k] or false) == "table" then
				merge(t1[k] or {}, t2[k] or {})
			else
				t1[k] = v
			end
		else
			t1[k] = v
		end
	end
	return t1
end

local Animator = {}

local tinsert = table.insert
local format = string.format
local spawn = task.spawn
local wait = task.wait
local clock = os.clock

Animator.__index = Animator
Animator.ClassName = "Animator"

function Animator.isAnimator(value)
	return type(value) == "table" and getmetatable(value) == Animator
end

function Animator.new(Character, AnimationResolvable)
	if typeof(Character) ~= "Instance" then
		error(format("invalid argument 1 to 'new' (Instace expected, got %s)", typeof(Character)))
	end

	local self = setmetatable({
		AnimationData = {},
		BoneIgnoreInList = {},
		MotorIgnoreInList = {},
		BoneIgnoreList = {},
		MotorIgnoreList = {},
		handleVanillaAnimator = true,
		Character = nil,
		Looped = false,
		Length = 0,
		Speed = 1,
		IsPlaying = false,
		_stopFadeTime = 0.100000001,
		_playing = false,
		_stopped = false,
		_isLooping = false,
		_markerSignal = {},
	}, Animator)

	local type = typeof(AnimationResolvable)

	local IsInstance = type == "Instance"
	local IsAnimation = IsInstance and AnimationResolvable.ClassName == "Animation"

	if IsAnimation or type == "string" or type == "number" then
		local keyframeSequence = game:GetObjects(
			"rbxassetid://" .. tostring(IsAnimation and AnimationResolvable.AnimationId or AnimationResolvable)
		)[1]
		if keyframeSequence.ClassName ~= "KeyframeSequence" then
			error(
				IsAnimation and "invalid argument 2 to 'new' (Content inside AnimationId expected)"
					or "invalid argument 2 to 'new' (string,number expected)"
			)
		end
		self.AnimationData = Parser:parseAnimationData(keyframeSequence)
	elseif type == "table" then
		self.AnimationData = AnimationResolvable
	elseif IsInstance then
		if AnimationResolvable.ClassName == "KeyframeSequence" then
			self.AnimationData = Parser:parseAnimationData(AnimationResolvable)
		end
	else
		error(format("invalid argument 2 to 'new' (number,string,table,Instance expected, got %s)", type))
	end

	self.Character = Character

	self.Looped = self.AnimationData.Loop
	self.Length = self.AnimationData.Frames[#self.AnimationData.Frames].Time

	self._maid = Maid.new()

	self.DidLoop = Signal.new()
	self.Stopped = Signal.new()
	self.KeyframeReached = Signal.new()

	self._maid.DidLoop = self.DidLoop
	self._maid.Stopped = self.Stopped
	self._maid.KeyframeReached = self.KeyframeReached
	return self
end

function Animator:IgnoreMotor(inst)
	if typeof(inst) ~= "Instance" then
		error(format("invalid argument 1 to 'IgnoreMotor' (Instance expected, got %s)", typeof(inst)))
	end
	if inst.ClassName ~= "Motor6D" then
		error(format("invalid argument 1 to 'IgnoreMotor' (Motor6D expected, got %s)", inst.ClassName))
	end
	tinsert(self.MotorIgnoreList, inst)
end

function Animator:IgnoreBone(inst)
	if typeof(inst) ~= "Instance" then
		error(format("invalid argument 1 to 'IgnoreBone' (Instance expected, got %s)", typeof(inst)))
	end
	if inst.ClassName ~= "Bone" then
		error(format("invalid argument 1 to 'IgnoreBone' (Bone expected, got %s)", inst.ClassName))
	end
	tinsert(self.BoneIgnoreList, inst)
end

function Animator:IgnoreMotorIn(inst)
	if typeof(inst) ~= "Instance" then
		error(format("invalid argument 1 to 'IgnoreMotorIn' (Instance expected, got %s)", typeof(inst)))
	end
	tinsert(self.MotorIgnoreInList, inst)
end

function Animator:IgnoreBoneIn(inst)
	if typeof(inst) ~= "Instance" then
		error(format("invalid argument 1 to 'IgnoreBoneIn' (Instance expected, got %s)", typeof(inst)))
	end
	tinsert(self.BoneIgnoreInList, inst)
end

function Animator:_playPose(pose, parent, fade)
	if pose.Subpose then
		local SubPose = pose.Subpose
		for count = 1, #SubPose do
			local sp = SubPose[count]
			self:_playPose(sp, pose, fade)
		end
	end
	if not parent then
		return
	end
	local MotorMap = Utility:getMotorMap(self.Character, {
		IgnoreIn = self.MotorIgnoreInList,
		IgnoreList = self.MotorIgnoreList,
	})
	local BoneMap = Utility:getBoneMap(self.Character, {
		IgnoreIn = self.BoneIgnoreInList,
		IgnoreList = self.BoneIgnoreList,
	})
	local TI = TweenInfo.new(fade, pose.EasingStyle, pose.EasingDirection)
	local Target = { Transform = pose.CFrame }
	local M = MotorMap[parent.Name]
	local B = BoneMap[parent.Name]
	local C = {}
	if M then
		local MM = M[pose.Name] or {}
		C = merge(C, MM)
	end
	if B then
		local BB = B[pose.Name] or {}
		C = merge(C, BB)
	end
	for count = 1, #C do
		local obj = C[count]
		if self == nil or self._stopped then
			break
		end
		if fade > 0 then
			TweenService:Create(obj, TI, Target):Play()
		else
			obj.Transform = pose.CFrame
		end
	end
end

function Animator:Play()
    if not self.Character or self.Character.Parent == nil or self._playing then
        return
    end
    self._playing = true
    self.IsPlaying = true

    local RunService = game:GetService("RunService")
    local startTime = tick()

    self._connection = RunService.RenderStepped:Connect(function()
        if self._stopped then
            self._connection:Disconnect()
            self._connection = nil
            self._playing = false
            self.IsPlaying = false
            self.Stopped:Fire()
            return
        end

        local elapsed = tick() - startTime
        local timeInAnimation = elapsed % self.Length

        -- Find two frames to interpolate between
        local prevFrame, nextFrame
        for i = 1, #self.AnimationData.Frames do
            local frame = self.AnimationData.Frames[i]
            if frame.Time > timeInAnimation then
                nextFrame = frame
                prevFrame = self.AnimationData.Frames[i-1] or self.AnimationData.Frames[#self.AnimationData.Frames]
                break
            end
        end
        if not prevFrame then
            prevFrame = self.AnimationData.Frames[#self.AnimationData.Frames]
            nextFrame = self.AnimationData.Frames[1]
        end

        local frameDelta = nextFrame.Time - prevFrame.Time
        if frameDelta < 0 then frameDelta = frameDelta + self.Length end
        local alpha = 0
        if frameDelta > 0 then
            local passed = timeInAnimation - prevFrame.Time
            if passed < 0 then passed = passed + self.Length end
            alpha = passed / frameDelta
        end

        -- Override Motor6D transforms every frame (no tweening)
        for _, pose in pairs(nextFrame.Pose or {}) do
            local motor = self.Character:FindFirstChildOfClass("Humanoid"):FindFirstChildOfClass("Animator") -- just for example
            -- You will want to map pose names to Motor6D names, or get Motor6Ds ahead of time

            -- Pseudocode to override motor transform:
            -- motor.Transform = prevCFrame:Lerp(nextCFrame, alpha)

            -- But to keep it consistent with your actual motor finding, use your utility functions or cache Motor6Ds and set their Transform property here

            -- Example for HumanoidRootPart:
            if pose.Name == "HumanoidRootPart" then
                local hrp = self.Character:FindFirstChild("HumanoidRootPart")
                if hrp then
                    local prevCFrame = prevFrame.Pose and prevFrame.Pose[pose.Name]
                    local nextCFrame = nextFrame.Pose and nextFrame.Pose[pose.Name]
                    if prevCFrame and nextCFrame then
                        hrp.CFrame = prevCFrame:Lerp(nextCFrame, alpha)
                    end
                end
            else
                local motor = self.Character:FindFirstChild("HumanoidRootPart"):FindFirstChild(pose.Name) -- or use your Motor map
                if motor and motor:IsA("Motor6D") then
                    local prevCFrame = prevFrame.Pose and prevFrame.Pose[pose.Name]
                    local nextCFrame = nextFrame.Pose and nextFrame.Pose[pose.Name]
                    if prevCFrame and nextCFrame then
                        motor.Transform = prevCFrame:Lerp(nextCFrame, alpha)
                    end
                end
            end
        end
    end)
end

function Animator:GetTimeOfKeyframe(keyframeName)
	for count = 1, #self.AnimationData.Frames do
		local f = self.AnimationData.Frames[count]
		if f.Name ~= keyframeName then
			continue
		end
		return f.Time
	end
	return 0
end

function Animator:GetMarkerReachedSignal(name)
	local signal = self._markerSignal[name]
	if not signal then
		signal = Signal.new()
		self._markerSignal[name] = signal
		self._maid["M_" .. name] = signal
	end
	return signal
end

function Animator:AdjustSpeed(speed)
	self.Speed = speed
end

function Animator:Stop()
    if self._connection then
        self._connection:Disconnect()
        self._connection = nil
    end
    self._stopped = true
end

function Animator:Destroy()
	if not self._stopped then
		self:Stop(0)
		self.Stopped:Wait()
	end
	self._maid:DoCleaning()
	setmetatable(self, nil)
end

return Animator
