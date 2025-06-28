-- Full patched Animator.lua

local TweenService = game:GetService("TweenService")

local Parser = animatorRequire("Parser.lua")
local Utility = animatorRequire("Utility.lua")

local Signal = animatorRequire("Nevermore/Signal.lua")
local Maid = animatorRequire("Nevermore/Maid.lua")

-- Deep-merge helper for tables
local function merge(t1, t2)
    for k, v in pairs(t2) do
        if type(v) == "table" then
            if type(t1[k] or false) == "table" then
                merge(t1[k], v)
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
Animator.__index = Animator
Animator.ClassName = "Animator"

local format = string.format
local spawn = task.spawn
local wait = task.wait
local clock = os.clock

-- Type-check for Animator
function Animator.isAnimator(value)
    return type(value) == "table" and getmetatable(value) == Animator
end

-- Constructor
function Animator.new(Character, AnimationResolvable)
    if typeof(Character) ~= "Instance" then
        error(format("invalid argument 1 to 'new' (Instance expected, got %s)", typeof(Character)))
    end

    local self = setmetatable({
        AnimationData = {},
        BoneIgnoreInList = {},
        MotorIgnoreInList = {},
        BoneIgnoreList = {},
        MotorIgnoreList = {},
        handleVanillaAnimator = true,
        Character = Character,
        Looped = false,
        Length = 0,
        Speed = 1,
        IsPlaying = false,
        _stopFadeTime = 0.1,
        _playing = false,
        _stopped = false,
        _isLooping = false,
        _markerSignal = {},
    }, Animator)

    local ttype = typeof(AnimationResolvable)
    local IsInstance = ttype == "Instance"
    local IsAnimation = IsInstance and AnimationResolvable.ClassName == "Animation"

    if IsAnimation or ttype == "string" or ttype == "number" then
        local keyframeSequence = game:GetObjects(
            "rbxassetid://" .. tostring(IsAnimation and AnimationResolvable.AnimationId or AnimationResolvable)
        )[1]
        if not keyframeSequence or keyframeSequence.ClassName ~= "KeyframeSequence" then
            error("Invalid AnimationResolvable content; expected KeyframeSequence")
        end
        self.AnimationData = Parser:parseAnimationData(keyframeSequence)
    elseif ttype == "table" then
        self.AnimationData = AnimationResolvable
    elseif IsInstance and AnimationResolvable.ClassName == "KeyframeSequence" then
        self.AnimationData = Parser:parseAnimationData(AnimationResolvable)
    else
        error(format("invalid argument 2 to 'new' (number,string,table,Instance expected, got %s)", ttype))
    end

    self.Looped = self.AnimationData.Loop
    self.Length = self.AnimationData.Frames[#self.AnimationData.Frames].Time

    -- Maid and signals
    self._maid = Maid.new()
    self.DidLoop = Signal.new()
    self.Stopped = Signal.new()
    self.KeyframeReached = Signal.new()

    self._maid.DidLoop = self.DidLoop
    self._maid.Stopped = self.Stopped
    self._maid.KeyframeReached = self.KeyframeReached

    return self
end

-- Ignore lists APIs
function Animator:IgnoreMotor(inst)
    assert(typeof(inst) == "Instance" and inst.ClassName == "Motor6D", "Motor6D expected")
    table.insert(self.MotorIgnoreList, inst)
end

function Animator:IgnoreBone(inst)
    assert(typeof(inst) == "Instance" and inst.ClassName == "Bone", "Bone expected")
    table.insert(self.BoneIgnoreList, inst)
end

function Animator:IgnoreMotorIn(inst)
    assert(typeof(inst) == "Instance", "Instance expected")
    table.insert(self.MotorIgnoreInList, inst)
end

function Animator:IgnoreBoneIn(inst)
    assert(typeof(inst) == "Instance", "Instance expected")
    table.insert(self.BoneIgnoreInList, inst)
end

-- Internal: apply a single pose
function Animator:_playPose(pose, parent, fade)
    if pose.Subpose then
        for _, sub in ipairs(pose.Subpose) do
            self:_playPose(sub, pose, fade)
        end
    end
    if not parent then return end

    local MotorMap = Utility:getMotorMap(self.Character, {IgnoreIn = self.MotorIgnoreInList, IgnoreList = self.MotorIgnoreList})
    local BoneMap  = Utility:getBoneMap(self.Character, {IgnoreIn = self.BoneIgnoreInList, IgnoreList = self.BoneIgnoreList})
    local TI = TweenInfo.new(fade, pose.EasingStyle, pose.EasingDirection)
    local props = {Transform = pose.CFrame}

    local Mlist = MotorMap[parent.Name] or {}
    local Blist = BoneMap[parent.Name] or {}
    local candidates = merge({}, Mlist[pose.Name] or {})
    merge(candidates, Blist[pose.Name] or {})

    for _, obj in ipairs(candidates) do
        if self._stopped then break end
        if fade > 0 then
            TweenService:Create(obj, TI, props):Play()
        else
            obj.Transform = pose.CFrame
        end
    end
end

-- Play the custom animation
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

-- Returns time for named keyframe
function Animator:GetTimeOfKeyframe(name)
    for _, f in ipairs(self.AnimationData.Frames) do
        if f.Name == name then return f.Time end
    end
    return 0
end

-- Provides a signal for markers
function Animator:GetMarkerReachedSignal(name)
    if not self._markerSignal[name] then
        local sig = Signal.new()
        self._markerSignal[name] = sig
        self._maid["Marker_"..name] = sig
    end
    return self._markerSignal[name]
end

-- Adjust playback speed
function Animator:AdjustSpeed(speed)
    self.Speed = speed
end

-- Stops playback gracefully
function Animator:Stop()
    if self._connection then
        self._connection:Disconnect()
        self._connection = nil
    end
    self._stopped = true
end

-- Cleans up the Animator
function Animator:Destroy()
    if not self._stopped then
        self:Stop(0)
        self.Stopped:Wait()
    end
    self._maid:DoCleaning()
    setmetatable(self, nil)
end

return Animator
