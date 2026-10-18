-- ====== PENGATURAN (beda tiap akun) ======
local ALT_NAME = "twoastw"   -- username akun LAINNYA
local HOP_ON_ALT = true            -- true di salah satu akun saja (lihat catatan)
-- =========================================

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local LP = Players.LocalPlayer
local PlaceID = game.PlaceId
local FILE = "NotSameServers_" .. LP.Name .. ".json"

-- jalankan ulang script ini setelah teleport (kalau tidak pakai autoexec)
if queue_on_teleport then
    queue_on_teleport([[
        loadstring(game:HttpGet("URL_SCRIPT_KAMU"))()
    ]])
end

-- daftar server yang sudah dikunjungi, reset tiap jam
local hour = os.date("!*t").hour
local visited = {}
pcall(function()
    local data = HttpService:JSONDecode(readfile(FILE))
    if data.hour == hour then visited = data.ids end
end)

local function save()
    pcall(function()
        writefile(FILE, HttpService:JSONEncode({hour = hour, ids = visited}))
    end)
end

local function isVisited(id)
    for _, v in ipairs(visited) do
        if v == id then return true end
    end
    return false
end

local hopping = false
local cursor = ""

local function hop()
    if hopping then return end
    hopping = true
    visited[#visited + 1] = game.JobId
    save()

    while true do
        local ok, site = pcall(function()
            local url = "https://games.roblox.com/v1/games/" .. PlaceID
                .. "/servers/Public?sortOrder=Asc&limit=100"
            if cursor ~= "" then url = url .. "&cursor=" .. cursor end
            return HttpService:JSONDecode(game:HttpGet(url))
        end)

        if ok and site and site.data then
            cursor = site.nextPageCursor or ""
            for _, v in ipairs(site.data) do
                if v.playing < v.maxPlayers and v.id ~= game.JobId and not isVisited(v.id) then
                    visited[#visited + 1] = v.id
                    save()
                    pcall(function()
                        TeleportService:TeleportToPlaceInstance(PlaceID, v.id, LP)
                    end)
                    task.wait(5)
                end
            end
        else
            task.wait(3) -- kena rate limit / error, tunggu dulu
        end
        task.wait(1)
    end
end

-- ====== DETEKSI AKUN KEDUA ======
local function altPresent()
    return Players:FindFirstChild(ALT_NAME) ~= nil
end

if HOP_ON_ALT then
    task.wait(3) -- beri waktu daftar player termuat
    if altPresent() then
        hop()
    end

    Players.PlayerAdded:Connect(function(plr)
        if plr.Name == ALT_NAME then
            hop()
        end
    end)
end

-- taruh kode farming/logika kamu di sini