local Lovarip = {}

-- Services
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Determine if running on server or client
local isServer = RunService:IsServer()
local isClient = RunService:IsClient()

-- ============================================
-- CONFIGURATION
-- ============================================
Lovarip.config = {
	clearEachFrame = true,      -- Auto-clear graphics each frame
	smoothInput = true,         -- Smooth input handling
	
	-- Anti-Cheat Configuration
	antiCheat = {
		enabled = true,                    -- Master toggle
		maxWalkSpeed = 20,                 -- Maximum allowed walk speed
		maxJumpPower = 50,                 -- Maximum allowed jump power
		maxPositionDelta = 100,            -- Max studs per second movement
		maxHealth = 100,                   -- Maximum health allowed
		maxScore = 999999999,              -- Maximum score allowed
		maxCurrency = 999999999,           -- Maximum currency allowed
		remoteRateLimit = 10,              -- Max remote calls per second
		speedHackThreshold = 1.5,          -- Time acceleration threshold
		flyDetection = true,               -- Enable fly hack detection
		noclipDetection = true,            -- Enable noclip detection
		godModeDetection = true,           -- Enable god mode detection
		banOnDetection = false,            -- Ban players on detection (set true for production)
		kickOnDetection = true,            -- Kick players on detection
		logDetections = true,              -- Log detections to console
		warningThreshold = 3,              -- Warnings before action
	}
}

-- ============================================
-- INTERNAL STATE
-- ============================================
local screenGui, canvas
local callbacks = {}
local objects = {}
local keysDown = {}
local mousePos = Vector2.new(0, 0)
local mouseButtons = {}
local deltaTime = 0
local isRunning = false
local objectPool = {}
local poolIndex = 0

-- ============================================
-- ANTI-CHEAT SYSTEM
-- ============================================
Lovarip.antiCheat = {}

-- Anti-cheat internal state
local acState = {
	warnings = {},           -- Player warnings
	lastPositions = {},      -- Last known positions
	lastHealth = {},         -- Last known health
	lastUpdate = {},         -- Last update time
	remoteCalls = {},        -- Remote call timestamps
	detections = {},         -- Detection log
	playerData = {},         -- Trusted player data
}

-- Detection types
local DetectionType = {
	SPEED_HACK = "SpeedHack",
	FLY_HACK = "FlyHack",
	NOCLIP = "Noclip",
	GOD_MODE = "GodMode",
	HEALTH_MANIPULATION = "HealthManipulation",
	POSITION_MANIPULATION = "PositionManipulation",
	REMOTE_SPAM = "RemoteSpam",
	INVALID_DATA = "InvalidData",
	TIME_MANIPULATION = "TimeManipulation",
	MEMORY_MANIPULATION = "MemoryManipulation",
}

-- Log detection (internal)
local function logDetection(player, detectionType, details)
	if not Lovarip.config.antiCheat.logDetections then return end
	
	local entry = {
		player = player and player.Name or "Unknown",
		type = detectionType,
		details = details or "",
		time = os.date("%H:%M:%S"),
		timestamp = tick(),
	}
	
	table.insert(acState.detections, entry)
	
	-- Print to console
	print(string.format("[Lovarip AC] %s detected for %s: %s", detectionType, entry.player, details))
end

-- Issue warning to player
local function issueWarning(player, detectionType)
	if not player then return end
	
	local userId = player.UserId
	acState.warnings[userId] = (acState.warnings[userId] or 0) + 1
	
	local warnings = acState.warnings[userId]
	local threshold = Lovarip.config.antiCheat.warningThreshold
	
	logDetection(player, detectionType, string.format("Warning %d/%d", warnings, threshold))
	
	-- Take action if threshold exceeded
	if warnings >= threshold then
		if Lovarip.config.antiCheat.kickOnDetection then
			player:Kick("[Lovarip Anti-Cheat] Suspicious activity detected")
		elseif Lovarip.config.antiCheat.banOnDetection then
			-- Custom ban logic would go here
			player:Kick("[Lovarip Anti-Cheat] Banned for suspicious activity")
		end
		acState.warnings[userId] = nil
	end
end

-- ============================================
-- CLIENT-SIDE ANTI-CHEAT
-- ============================================
if isClient then
	
	-- Validate local player data before sending to server
	function Lovarip.antiCheat.validateData(data)
		if type(data) ~= "table" then return false end
		
		local config = Lovarip.config.antiCheat
		
		-- Check score
		if data.score and (data.score < 0 or data.score > config.maxScore) then
			return false, "Invalid score"
		end
		
		-- Check currency
		if data.currency and (data.currency < 0 or data.currency > config.maxCurrency) then
			return false, "Invalid currency"
		end
		
		-- Check health
		if data.health and (data.health < 0 or data.health > config.maxHealth) then
			return false, "Invalid health"
		end
		
		-- Check position (basic bounds)
		if data.position then
			if math.abs(data.position.X) > 10000 or 
			   math.abs(data.position.Y) > 10000 or 
			   math.abs(data.position.Z) > 10000 then
				return false, "Position out of bounds"
			end
		end
		
		return true
	end
	
	-- Check for time manipulation
	local lastRealTime = tick()
	local lastGameTime = os.clock()
	
	function Lovarip.antiCheat.checkTimeManipulation()
		local currentRealTime = tick()
		local currentGameTime = os.clock()
		
		local realDelta = currentRealTime - lastRealTime
		local gameDelta = currentGameTime - lastGameTime
		
		lastRealTime = currentRealTime
		lastGameTime = currentGameTime
		
		-- If game time is significantly faster than real time
		if gameDelta > realDelta * Lovarip.config.antiCheat.speedHackThreshold then
			return true, "Time acceleration detected"
		end
		
		return false
	end
	
	-- Monitor character properties
	function Lovarip.antiCheat.monitorCharacter(character)
		if not character then return end
		
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		
		if humanoid then
			-- Detect walk speed changes
			humanoid:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
				if humanoid.WalkSpeed > Lovarip.config.antiCheat.maxWalkSpeed then
					humanoid.WalkSpeed = Lovarip.config.antiCheat.maxWalkSpeed
					logDetection(Players.LocalPlayer, DetectionType.SPEED_HACK, "WalkSpeed reset")
				end
			end)
			
			-- Detect jump power changes
			humanoid:GetPropertyChangedSignal("JumpPower"):Connect(function()
				if humanoid.JumpPower > Lovarip.config.antiCheat.maxJumpPower then
					humanoid.JumpPower = Lovarip.config.antiCheat.maxJumpPower
					logDetection(Players.LocalPlayer, DetectionType.SPEED_HACK, "JumpPower reset")
				end
			end)
			
			-- Detect god mode attempts
			if Lovarip.config.antiCheat.godModeDetection then
				humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(function()
					if humanoid.MaxHealth > Lovarip.config.antiCheat.maxHealth then
						humanoid.MaxHealth = Lovarip.config.antiCheat.maxHealth
						logDetection(Players.LocalPlayer, DetectionType.GOD_MODE, "MaxHealth reset")
					end
				end)
				
				humanoid:GetPropertyChangedSignal("Health"):Connect(function()
					if humanoid.Health > humanoid.MaxHealth then
						humanoid.Health = humanoid.MaxHealth
						logDetection(Players.LocalPlayer, DetectionType.HEALTH_MANIPULATION, "Health reset")
					end
				end)
			end
		end
		
		-- Monitor for noclip
		if rootPart and Lovarip.config.antiCheat.noclipDetection then
			rootPart:GetPropertyChangedSignal("CanCollide"):Connect(function()
				if not rootPart.CanCollide then
					rootPart.CanCollide = true
					logDetection(Players.LocalPlayer, DetectionType.NOCLIP, "CanCollide reset")
				end
			end)
			
			rootPart:GetPropertyChangedSignal("Transparency"):Connect(function()
				if rootPart.Transparency > 0.5 then
					rootPart.Transparency = 0
					logDetection(Players.LocalPlayer, DetectionType.NOCLIP, "Transparency reset")
				end
			end)
		end
	end
	
	-- Rate limit remote calls
	function Lovarip.antiCheat.canCallRemote(remoteName)
		local now = tick()
		local calls = acState.remoteCalls[remoteName] or {}
		
		-- Remove old calls
		local recentCalls = {}
		for _, time in ipairs(calls) do
			if now - time < 1 then
				table.insert(recentCalls, time)
			end
		end
		
		-- Check rate limit
		if #recentCalls >= Lovarip.config.antiCheat.remoteRateLimit then
			return false
		end
		
		-- Record this call
		table.insert(recentCalls, now)
		acState.remoteCalls[remoteName] = recentCalls
		
		return true
	end
	
	-- Initialize client-side anti-cheat
	function Lovarip.antiCheat.initClient()
		local player = Players.LocalPlayer
		
		-- Monitor character when it spawns
		player.CharacterAdded:Connect(function(character)
			Lovarip.antiCheat.monitorCharacter(character)
		end)
		
		-- Monitor existing character
		if player.Character then
			Lovarip.antiCheat.monitorCharacter(player.Character)
		end
		
		-- Periodic time check
		task.spawn(function()
			while isRunning do
				local detected, reason = Lovarip.antiCheat.checkTimeManipulation()
				if detected then
					logDetection(player, DetectionType.TIME_MANIPULATION, reason)
				end
				task.wait(1)
			end
			end)
	end
end

-- ============================================
-- SERVER-SIDE ANTI-CHEAT
-- ============================================
if isServer then
	
	-- Validate player position
	function Lovarip.antiCheat.validatePosition(player, newPosition)
		if not player or not newPosition then return false end
		
		local userId = player.UserId
		local now = tick()
		local config = Lovarip.config.antiCheat
		
		-- Get last position
		local lastPos = acState.lastPositions[userId]
		local lastTime = acState.lastUpdate[userId] or now
		
		if lastPos then
			local delta = now - lastTime
			local distance = (newPosition - lastPos).Magnitude
			local speed = distance / math.max(delta, 0.001)
			
			-- Check for teleportation/speed hack
			if speed > config.maxPositionDelta then
				logDetection(player, DetectionType.POSITION_MANIPULATION, 
					string.format("Speed: %.1f studs/s (max: %d)", speed, config.maxPositionDelta))
				return false
			end
			
			-- Check for flying (if enabled)
			if config.flyDetection and player.Character then
				local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
				if humanoid and humanoid:GetState() ~= Enum.HumanoidStateType.Freefall then
					local heightDiff = newPosition.Y - lastPos.Y
					if heightDiff > 10 and math.abs(newPosition.X - lastPos.X) < 5 then
						logDetection(player, DetectionType.FLY_HACK, 
							string.format("Height gain: %.1f studs", heightDiff))
						return false
					end
				end
			end
		end
		
		-- Update tracking
		acState.lastPositions[userId] = newPosition
		acState.lastUpdate[userId] = now
		
		return true
	end
	
	-- Validate health changes
	function Lovarip.antiCheat.validateHealth(player, newHealth)
		if not player then return false end
		
		local userId = player.UserId
		local config = Lovarip.config.antiCheat
		
		-- Check bounds
		if newHealth < 0 or newHealth > config.maxHealth then
			logDetection(player, DetectionType.HEALTH_MANIPULATION, 
				string.format("Health: %.1f (max: %d)", newHealth, config.maxHealth))
			return false
		end
		
		-- Check for health increase without reason (god mode)
		local lastHealth = acState.lastHealth[userId]
		if lastHealth and newHealth > lastHealth then
			-- Could add healing item validation here
			-- For now, just track the change
		end
		
		acState.lastHealth[userId] = newHealth
		return true
	end
	
	-- Validate game data (score, currency, etc.)
	function Lovarip.antiCheat.validateGameData(player, data)
		if not player or type(data) ~= "table" then return false end
		
		local config = Lovarip.config.antiCheat
		
		-- Validate score
		if data.score then
			if data.score < 0 or data.score > config.maxScore then
				logDetection(player, DetectionType.INVALID_DATA, "Invalid score: " .. data.score)
				return false
			end
		end
		
		-- Validate currency
		if data.currency then
			if data.currency < 0 or data.currency > config.maxCurrency then
				logDetection(player, DetectionType.INVALID_DATA, "Invalid currency: " .. data.currency)
				return false
			end
		end
		
		-- Validate any numeric values
		for key, value in pairs(data) do
			if type(value) == "number" then
				if math.abs(value) > 1e9 then
					logDetection(player, DetectionType.INVALID_DATA, "Suspicious value: " .. key)
					return false
				end
				if value ~= value then -- NaN check
					logDetection(player, DetectionType.INVALID_DATA, "NaN detected: " .. key)
					return false
				end
			end
		end
		
		return true
	end
	
	-- Rate limit remote calls from player
	function Lovarip.antiCheat.rateLimitRemote(player, remoteName)
		local userId = player.UserId
		local now = tick()
		local key = userId .. "_" .. remoteName
		
		local calls = acState.remoteCalls[key] or {}
		
		-- Remove old calls
		local recentCalls = {}
		for _, time in ipairs(calls) do
			if now - time < 1 then
				table.insert(recentCalls, time)
			end
		end
		
		-- Check rate limit
		if #recentCalls >= Lovarip.config.antiCheat.remoteRateLimit then
			logDetection(player, DetectionType.REMOTE_SPAM, remoteName)
			issueWarning(player, DetectionType.REMOTE_SPAM)
			return false
		end
		
		-- Record this call
		table.insert(recentCalls, now)
		acState.remoteCalls[key] = recentCalls
		
		return true
	end
	
	-- Monitor player character on server
	local function monitorPlayerCharacter(player, character)
		if not character then return end
		
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		
		if humanoid then
			-- Monitor WalkSpeed
			humanoid:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
				if humanoid.WalkSpeed > Lovarip.config.antiCheat.maxWalkSpeed then
					humanoid.WalkSpeed = Lovarip.config.antiCheat.maxWalkSpeed
					logDetection(player, DetectionType.SPEED_HACK, "Server reset WalkSpeed")
					issueWarning(player, DetectionType.SPEED_HACK)
				end
			end)
			
			-- Monitor JumpPower
			humanoid:GetPropertyChangedSignal("JumpPower"):Connect(function()
				if humanoid.JumpPower > Lovarip.config.antiCheat.maxJumpPower then
					humanoid.JumpPower = Lovarip.config.antiCheat.maxJumpPower
					logDetection(player, DetectionType.SPEED_HACK, "Server reset JumpPower")
					issueWarning(player, DetectionType.SPEED_HACK)
				end
			end)
			
			-- Monitor health for god mode
			if Lovarip.config.antiCheat.godModeDetection then
				humanoid:GetPropertyChangedSignal("Health"):Connect(function()
					if humanoid.Health > humanoid.MaxHealth then
						humanoid.Health = humanoid.MaxHealth
						logDetection(player, DetectionType.GOD_MODE, "Server reset Health")
						issueWarning(player, DetectionType.GOD_MODE)
					end
				end)
			end
		end
		
		-- Track position for fly/teleport detection
		if rootPart then
			task.spawn(function()
				while character and character.Parent do
					Lovarip.antiCheat.validatePosition(player, rootPart.Position)
					task.wait(0.5)
				end
			end)
		end
	end
	
	-- Initialize server-side anti-cheat
	function Lovarip.antiCheat.initServer()
		-- Monitor all players
		local function onPlayerAdded(player)
			player.CharacterAdded:Connect(function(character)
				monitorPlayerCharacter(player, character)
			end)
			
			if player.Character then
				monitorPlayerCharacter(player, player.Character)
			end
		end
		
		-- Handle existing players
		for _, player in ipairs(Players:GetPlayers()) do
			onPlayerAdded(player)
		end
		
		-- Handle new players
		Players.PlayerAdded:Connect(onPlayerAdded)
		
		-- Clean up when players leave
		Players.PlayerRemoving:Connect(function(player)
			local userId = player.UserId
			acState.warnings[userId] = nil
			acState.lastPositions[userId] = nil
			acState.lastHealth[userId] = nil
			acState.lastUpdate[userId] = nil
			acState.playerData[userId] = nil
			
			-- Clean up remote call tracking
			for key, _ in pairs(acState.remoteCalls) do
				if key:sub(1, #tostring(userId)) == tostring(userId) then
					acState.remoteCalls[key] = nil
				end
			end
		end)
		
		print("[Lovarip] Anti-Cheat initialized on server")
	end
	
	-- Get detection log
	function Lovarip.antiCheat.getDetections()
		return acState.detections
	end
	
	-- Clear detection log
	function Lovarip.antiCheat.clearDetections()
		acState.detections = {}
	end
	
	-- Get player warnings
	function Lovarip.antiCheat.getWarnings(player)
		return acState.warnings[player.UserId] or 0
	end
	
	-- Reset player warnings
	function Lovarip.antiCheat.resetWarnings(player)
		acState.warnings[player.UserId] = 0
	end
end

-- ============================================
-- SHARED ANTI-CHEAT UTILITIES
-- ============================================

-- Sanitize input (remove potentially dangerous characters)
function Lovarip.antiCheat.sanitizeInput(input)
	if type(input) == "string" then
		-- Remove script tags and other dangerous patterns
		local sanitized = input:gsub("<script.->.-</script>", "")
		sanitized = sanitized:gsub("[<>\"']", "")
		return sanitized:sub(1, 1000) -- Limit length
	end
	return input
end

-- Hash data for integrity check
local hashKey = "LovaripAC_" .. tostring(math.random(100000, 999999))
function Lovarip.antiCheat.hashData(data)
	local str = tostring(data) .. hashKey
	local hash = 0
	for i = 1, #str do
		hash = (hash * 31 + string.byte(str, i)) % 2147483647
	end
	return hash
end

-- Verify data integrity
function Lovarip.antiCheat.verifyIntegrity(data, expectedHash)
	return Lovarip.antiCheat.hashData(data) == expectedHash
end

-- Initialize anti-cheat based on context
function Lovarip.antiCheat.init()
	if not Lovarip.config.antiCheat.enabled then
		return false
	end
	
	if isServer then
		Lovarip.antiCheat.initServer()
	elseif isClient then
		Lovarip.antiCheat.initClient()
	end
	
	return true
end

-- ============================================
-- COLORS (Easy access)
-- ============================================
Lovarip.colors = setmetatable({}, {
	__index = function(_, name)
		local colors = {
			white = Color3.new(1, 1, 1),
			black = Color3.new(0, 0, 0),
			red = Color3.new(1, 0, 0),
			green = Color3.new(0, 1, 0),
			blue = Color3.new(0, 0, 1),
			yellow = Color3.new(1, 1, 0),
			cyan = Color3.new(0, 1, 1),
			magenta = Color3.new(1, 0, 1),
			orange = Color3.new(1, 0.5, 0),
			purple = Color3.new(0.5, 0, 0.5),
			gray = Color3.new(0.5, 0.5, 0.5),
			lightGray = Color3.new(0.75, 0.75, 0.75),
			darkGray = Color3.new(0.25, 0.25, 0.25),
			pink = Color3.new(1, 0.75, 0.8),
			brown = Color3.new(0.6, 0.4, 0.2),
		}
		return colors[name] or Color3.new(1, 1, 1)
	end
})

-- ============================================
-- GRAPHICS MODULE
-- ============================================
Lovarip.graphics = {}

-- Get or create object from pool (optimization)
local function getObject(className)
	poolIndex = poolIndex + 1
	local obj = objectPool[poolIndex]
	
	if not obj or obj.ClassName ~= className then
		obj = Instance.new(className)
		objectPool[poolIndex] = obj
	end
	
	obj.Parent = canvas
	return obj
end

-- Set background color
function Lovarip.graphics.setBackgroundColor(r, g, b)
	if not canvas then return end
	canvas.BackgroundColor3 = type(r) == "number" and Color3.new(r, g, b) or r
end

-- Draw rectangle: rect(x, y, w, h, color, radius)
function Lovarip.graphics.rect(x, y, w, h, color, radius)
	local frame = getObject("Frame")
	frame.Name = "rect"
	frame.Size = UDim2.fromOffset(w, h)
	frame.Position = UDim2.fromOffset(x, y)
	frame.BackgroundColor3 = color or Lovarip.colors.white
	frame.BorderSizePixel = 0
	frame.BackgroundTransparency = 0
	
	if radius and radius > 0 then
		local corner = frame:FindFirstChildOfClass("UICorner") or Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, radius)
		corner.Parent = frame
	end
	
	table.insert(objects, frame)
	return frame
end

-- Draw outlined rectangle
function Lovarip.graphics.rectOutline(x, y, w, h, color, thickness)
	local frame = getObject("Frame")
	frame.Name = "rectOutline"
	frame.Size = UDim2.fromOffset(w, h)
	frame.Position = UDim2.fromOffset(x, y)
	frame.BackgroundColor3 = Color3.new(1, 1, 1)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = thickness or 2
	frame.BorderColor3 = color or Lovarip.colors.white
	
	table.insert(objects, frame)
	return frame
end

-- Draw circle: circle(x, y, radius, color)
function Lovarip.graphics.circle(x, y, radius, color)
	local frame = getObject("Frame")
	frame.Name = "circle"
	frame.Size = UDim2.fromOffset(radius * 2, radius * 2)
	frame.Position = UDim2.fromOffset(x - radius, y - radius)
	frame.BackgroundColor3 = color or Lovarip.colors.white
	frame.BorderSizePixel = 0
	
	local corner = frame:FindFirstChildOfClass("UICorner") or Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = frame
	
	table.insert(objects, frame)
	return frame
end

-- Draw text: print(text, x, y, size, color)
function Lovarip.graphics.print(text, x, y, size, color)
	local label = getObject("TextLabel")
	label.Name = "text"
	label.Size = UDim2.fromOffset(2000, size or 24)
	label.Position = UDim2.fromOffset(x, y)
	label.BackgroundTransparency = 1
	label.Text = tostring(text)
	label.TextColor3 = color or Lovarip.colors.white
	label.TextSize = size or 24
	label.Font = Enum.Font.SourceSans
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	
	table.insert(objects, label)
	return label
end

-- Draw centered text
function Lovarip.graphics.printCentered(text, x, y, size, color)
	local label = getObject("TextLabel")
	label.Name = "textCenter"
	label.Size = UDim2.fromOffset(2000, size or 24)
	label.Position = UDim2.fromOffset(x - 1000, y)
	label.BackgroundTransparency = 1
	label.Text = tostring(text)
	label.TextColor3 = color or Lovarip.colors.white
	label.TextSize = size or 24
	label.Font = Enum.Font.SourceSans
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextYAlignment = Enum.TextYAlignment.Center
	
	table.insert(objects, label)
	return label
end

-- Draw image: image(assetId, x, y, w, h)
function Lovarip.graphics.image(assetId, x, y, w, h)
	local img = getObject("ImageLabel")
	img.Name = "image"
	img.Size = UDim2.fromOffset(w or 100, h or 100)
	img.Position = UDim2.fromOffset(x, y)
	img.BackgroundTransparency = 1
	img.Image = type(assetId) == "number" and "rbxassetid://" .. assetId or assetId
	
	table.insert(objects, img)
	return img
end

-- Draw line (horizontal or vertical)
function Lovarip.graphics.line(x1, y1, x2, y2, color, thickness)
	thickness = thickness or 2
	local isHorizontal = math.abs(x2 - x1) > math.abs(y2 - y1)
	
	local frame = getObject("Frame")
	frame.Name = "line"
	frame.BackgroundColor3 = color or Lovarip.colors.white
	frame.BorderSizePixel = 0
	
	if isHorizontal then
		frame.Size = UDim2.fromOffset(math.abs(x2 - x1), thickness)
		frame.Position = UDim2.fromOffset(math.min(x1, x2), y1 - thickness/2)
	else
		frame.Size = UDim2.fromOffset(thickness, math.abs(y2 - y1))
		frame.Position = UDim2.fromOffset(x1 - thickness/2, math.min(y1, y2))
	end
	
	table.insert(objects, frame)
	return frame
end

-- Clear all drawn objects
function Lovarip.graphics.clear()
	for i = #objects, 1, -1 do
		objects[i].Parent = nil
		objects[i] = nil
	end
end

-- Get screen dimensions
function Lovarip.graphics.getDimensions()
	if not canvas then return 1920, 1080 end
	return canvas.AbsoluteSize.X, canvas.AbsoluteSize.Y
end

-- Get screen width
function Lovarip.graphics.getWidth()
	return canvas and canvas.AbsoluteSize.X or 1920
end

-- Get screen height
function Lovarip.graphics.getHeight()
	return canvas and canvas.AbsoluteSize.Y or 1080
end

-- ============================================
-- INPUT MODULE
-- ============================================
Lovarip.keyboard = {}
Lovarip.mouse = {}

-- Check if key is down (supports multiple keys)
function Lovarip.keyboard.isDown(...)
	for _, key in ipairs({...}) do
		if keysDown[key] then return true end
	end
	return false
end

-- Get all pressed keys
function Lovarip.keyboard.getKeysDown()
	local pressed = {}
	for key, down in pairs(keysDown) do
		if down then table.insert(pressed, key) end
	end
	return pressed
end

-- Get mouse position
function Lovarip.mouse.getPosition()
	return mousePos.X, mousePos.Y
end

-- Get mouse X
function Lovarip.mouse.getX()
	return mousePos.X
end

-- Get mouse Y
function Lovarip.mouse.getY()
	return mousePos.Y
end

-- Check if mouse button is down (1=left, 2=right, 3=middle)
function Lovarip.mouse.isDown(button)
	return mouseButtons[button or 1] or false
end

-- ============================================
-- AUDIO MODULE
-- ============================================
Lovarip.audio = {}

-- Create sound
function Lovarip.audio.new(soundId, looped)
	local sound = Instance.new("Sound")
	sound.SoundId = type(soundId) == "number" and "rbxassetid://" .. soundId or soundId
	sound.Looped = looped or false
	sound.Parent = canvas
	return sound
end

-- Play sound
function Lovarip.audio.play(sound)
	if sound then sound:Play() end
	return sound
end

-- Stop sound
function Lovarip.audio.stop(sound)
	if sound then sound:Stop() end
	return sound
end

-- ============================================
-- TIMER MODULE
-- ============================================
Lovarip.timer = {}

function Lovarip.timer.getDelta() return deltaTime end
function Lovarip.timer.getTime() return tick() end
function Lovarip.timer.getFPS() return 1 / math.max(deltaTime, 0.001) end

-- ============================================
-- MATH HELPERS
-- ============================================
Lovarip.math = {}

function Lovarip.math.random(min, max) return math.random(min, max) end
function Lovarip.math.distance(x1, y1, x2, y2) return math.sqrt((x2-x1)^2 + (y2-y1)^2) end
function Lovarip.math.lerp(a, b, t) return a + (b - a) * t end
function Lovarip.math.clamp(v, min, max) return math.clamp(v, min, max) end
function Lovarip.math.round(v) return math.round(v) end
function Lovarip.math.sign(v) return v > 0 and 1 or v < 0 and -1 or 0 end

-- ============================================
-- WINDOW MODULE
-- ============================================
Lovarip.window = {}

function Lovarip.window.setTitle(title)
	if screenGui then screenGui.Name = title end
end

-- ============================================
-- CALLBACK REGISTRATION
-- ============================================
function Lovarip.load(fn) callbacks.load = fn end
function Lovarip.update(fn) callbacks.update = fn end
function Lovarip.draw(fn) callbacks.draw = fn end
function Lovarip.keypressed(fn) callbacks.keypressed = fn end
function Lovarip.keyreleased(fn) callbacks.keyreleased = fn end
function Lovarip.mousepressed(fn) callbacks.mousepressed = fn end
function Lovarip.mousereleased(fn) callbacks.mousereleased = fn end
function Lovarip.mousemoved(fn) callbacks.mousemoved = fn end

-- ============================================
-- INITIALIZE
-- ============================================
function Lovarip.init(parent)
	if Lovarip.config.antiCheat.enabled then
		Lovarip.antiCheat.init()
	end
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "Lovarip_Canvas"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.IgnoreGuiInset = true
	
	-- Create canvas
	canvas = Instance.new("Frame")
	canvas.Name = "Canvas"
	canvas.Size = UDim2.fromScale(1, 1)
	canvas.Position = UDim2.fromScale(0, 0)
	canvas.BackgroundColor3 = Color3.new(0.1, 0.1, 0.12)
	canvas.BorderSizePixel = 0
	canvas.Parent = screenGui
	
	screenGui.Parent = parent or game.Players.LocalPlayer:WaitForChild("PlayerGui")
	
	-- Input handlers
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then return end
		
		if input.UserInputType == Enum.UserInputType.Keyboard then
			keysDown[input.KeyCode.Name] = true
			if callbacks.keypressed then
				callbacks.keypressed(input.KeyCode.Name)
			end
		elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
			mouseButtons[1] = true
			if callbacks.mousepressed then callbacks.mousepressed(mousePos.X, mousePos.Y, 1) end
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
			mouseButtons[2] = true
			if callbacks.mousepressed then callbacks.mousepressed(mousePos.X, mousePos.Y, 2) end
		elseif input.UserInputType == Enum.UserInputType.MouseButton3 then
			mouseButtons[3] = true
			if callbacks.mousepressed then callbacks.mousepressed(mousePos.X, mousePos.Y, 3) end
		end
	end)
	
	UserInputService.InputEnded:Connect(function(input, processed)
		if processed then return end
		
		if input.UserInputType == Enum.UserInputType.Keyboard then
			keysDown[input.KeyCode.Name] = false
			if callbacks.keyreleased then callbacks.keyreleased(input.KeyCode.Name) end
		elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
			mouseButtons[1] = false
			if callbacks.mousereleased then callbacks.mousereleased(mousePos.X, mousePos.Y, 1) end
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
			mouseButtons[2] = false
			if callbacks.mousereleased then callbacks.mousereleased(mousePos.X, mousePos.Y, 2) end
		elseif input.UserInputType == Enum.UserInputType.MouseButton3 then
			mouseButtons[3] = false
			if callbacks.mousereleased then callbacks.mousereleased(mousePos.X, mousePos.Y, 3) end
		end
	end)
	
	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			mousePos = Vector2.new(input.Position.X, input.Position.Y)
			if callbacks.mousemoved then callbacks.mousemoved(mousePos.X, mousePos.Y) end
		end
	end)
	
	-- Call load callback
	if callbacks.load then callbacks.load() end
	
	-- Game loop
	isRunning = true
	local lastTime = tick()
	
	RunService.RenderStepped:Connect(function()
		if not isRunning then return end
		
		local currentTime = tick()
		deltaTime = currentTime - lastTime
		lastTime = currentTime
		
		if Lovarip.config.clearEachFrame then
			Lovarip.graphics.clear()
		end
		
		if callbacks.update then callbacks.update(deltaTime) end
		if callbacks.draw then callbacks.draw() end
		
		poolIndex = 0 -- Reset pool index for next frame
	end)
	
	return screenGui
end

-- Stop the engine
function Lovarip.stop()
	isRunning = false
	if screenGui then screenGui:Destroy() end
end

return Lovarip