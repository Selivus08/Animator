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
function Animator:Play(fadeTime, weight, speed)
    fadeTime = fadeTime or 0.1
    if not self.Character or not self.Character.Parent or (self._playing and not self._isLooping) then return end

    self._playing = true
    self._isLooping = false
    self.IsPlaying = true
    self._stopped = false

    local Humanoid = self.Character:FindFirstChild("Humanoid")
    self._disabledAnimator = false
    self._disabledAnimateScript = nil

    -- Disconnect on death
    local deathConn
    if Humanoid then
        deathConn = Humanoid.Died:Connect(function()
            self:Destroy()
        end)
    end

    -- Handle default Animator
    if self.handleVanillaAnimator then
        local AnimateScript = self.Character:FindFirstChild("Animate")
        if AnimateScript and not AnimateScript.Disabled then
            AnimateScript.Disabled = true
            self._disabledAnimateScript = AnimateScript
        end
        if Humanoid then
            local defaultAnim = Humanoid:FindFirstChild("Animator")
            if defaultAnim then
                for _, track in ipairs(defaultAnim:GetPlayingAnimationTracks()) do track:Stop() end
                defaultAnim:Destroy()
                self._disabledAnimator = true
            end
        end
    end

    -- Clean up if parent removed
    local parentConn = self.Character:GetPropertyChangedSignal("Parent"):Connect(function()
        if not self.Character.Parent then self:Destroy() end
    end)

    local startTime = clock()
    spawn(function()
        for i, frame in ipairs(self.AnimationData.Frames) do
            if self._stopped then break end

            local t = frame.Time / (speed or self.Speed)
            if frame.Name ~= "Keyframe" then
                self.KeyframeReached:Fire(frame.Name)
            end
            if frame.Marker then
                for mName, markers in pairs(frame.Marker) do
                    if self._markerSignal[mName] then
                        for _, mk in ipairs(markers) do self._markerSignal[mName]:Fire(mk) end
                    end
                end
            end
            if frame.Pose then
                for _, p in ipairs(frame.Pose) do
                    local ft = (i > 1) and ((t * (speed or self.Speed) - self.AnimationData.Frames[i-1].Time) / (speed or self.Speed)) or fadeTime
                    self:_playPose(p, nil, ft)
                end
            end
            if t > clock() - startTime then repeat wait() until self._stopped or clock() - startTime >= t end
        end

        -- Disconnect above connections
        if deathConn then deathConn:Disconnect() end
        if parentConn then parentConn:Disconnect() end

        -- Loop handling
        if self.Looped and not self._stopped then
            self.DidLoop:Fire()
            self._isLooping = true
            return self:Play(fadeTime, weight, speed)
        end

        -- Reset transforms on all driven objects
        local motorMap = Utility:getMotorMap(self.Character, {IgnoreIn=self.MotorIgnoreInList, IgnoreList=self.MotorIgnoreList})
        local boneMap  = Utility:getBoneMap(self.Character, {IgnoreIn=self.BoneIgnoreInList, IgnoreList=self.BoneIgnoreList})
        for _, grp in pairs(motorMap) do for _, lst in pairs(grp) do for _, m in ipairs(lst) do m.Transform = CFrame.new() end end end
        for _, grp in pairs(boneMap)  do for _, lst in pairs(grp) do for _, b in ipairs(lst) do b.Transform = CFrame.new() end end end

                        -- Delay then restore default Animator and Animate if we disabled them
        task.delay(0.05, function()
            if self.Character and self.handleVanillaAnimator then
                local H = self.Character:FindFirstChild("Humanoid")
                -- Recreate Animator if needed
                if self._disabledAnimator and H and not H:FindFirstChildOfClass("Animator") then
                    Instance.new("Animator").Parent = H
                end
                -- Re-enable Animate script
                if self._disabledAnimateScript and self._disabledAnimateScript.Parent then
                    self._disabledAnimateScript.Disabled = false
                end
                -- Force a state change to kickstart default animations
                if H then
                    H:ChangeState(Enum.HumanoidStateType.Running)
                end
            end
        end)

        -- Final state reset
        self._stopped = false
        self._playing = false
        self.IsPlaying = false
        self.Stopped:Fire()
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
function Animator:Stop(fadeTime)
    -- set fade time and mark stopped
    self._stopFadeTime = fadeTime or self._stopFadeTime
    self._stopped = true

    -- Immediately reset transforms on any driven Motor6Ds and Bones
    local motorMap = Utility:getMotorMap(self.Character, {IgnoreIn=self.MotorIgnoreInList, IgnoreList=self.MotorIgnoreList})
    local boneMap  = Utility:getBoneMap(self.Character, {IgnoreIn=self.BoneIgnoreInList,  IgnoreList=self.BoneIgnoreList})
    for _, grp in pairs(motorMap) do
        for _, lst in pairs(grp) do
            for _, m in ipairs(lst) do m.Transform = CFrame.new() end
        end
    end
    for _, grp in pairs(boneMap) do
        for _, lst in pairs(grp) do
            for _, b in ipairs(lst) do b.Transform = CFrame.new() end
        end
    end

    -- Immediately restore default Animator and Animate if we disabled them
    if self.handleVanillaAnimator and self.Character then
        local H = self.Character:FindFirstChild("Humanoid")
        if H then
            -- recreate Animator if missing
            if self._disabledAnimator and not H:FindFirstChildOfClass("Animator") then
                Instance.new("Animator").Parent = H
            end
            -- re-enable the Animate script
            if self._disabledAnimateScript and self._disabledAnimateScript.Parent then
                self._disabledAnimateScript.Disabled = false
            end
        end
    end
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
