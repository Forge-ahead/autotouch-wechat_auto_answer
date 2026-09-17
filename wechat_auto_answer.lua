--[[
  AutoTouch：微信视频/语音来电自动接听 + 日历/时钟 App 常驻
  ---------------------------------------------------------------
  功能：
    1. 平时保持指定日历/时钟 App 在前台显示（默认系统日历）
    2. 每 10 秒检测一次微信来电（前台全屏 / 后台横幅 / 锁屏来电），自动点击“接听”
    3. 每 5 分钟检查一次前台：前台是日历/微信/FaceTime 时不操作，三者都不是时才把日历打开
    4. 微信通话挂断后不立即切回日历，1 小时后再切回（期间不做任何拉回操作）
    5. 远程自动更新：每天 0 点（本地时间）+ 启动时各检查一次更新源，发现新版自动下载、覆盖、
       重启 SpringBoard 生效（全程无人值守）
    6. 失败自动回退：若更新后的新版本未能正常运行（连续 2 次未通过健康检测，或主循环抛异常），
       自动恢复 .bak 备份的上一版本并跳过该坏版本号
    7. 可选：开机自启、屏幕防休眠

  运行方式：
    在 AutoTouch 播放设置(Play Settings)中打开 "Run as Daemon" 后再运行。
    长按音量减键可呼出控制面板/强制停止脚本。

  需要的素材（3 张 PNG，与本脚本放在同一目录）：
    answer_full.png    微信全屏来电界面（前台来电/锁屏来电）中的绿色圆形接听按钮
    answer_banner.png  微信在后台时，屏幕顶部横幅通知里的绿色接听按钮
    hangup.png         通话界面底部的红色挂断按钮
  （iPhone 和 iPad 屏幕分辨率不同，请分别在各自设备上截图裁剪。）
--]]

-- ==================== 配置区 ====================
local CALENDAR_APP_ID      = "com.apple.mobilecal"  -- 日历/时钟 App 的 Bundle ID（系统日历默认）
local WECHAT_APP_ID        = "com.tencent.xin"      -- 微信 Bundle ID
local FACETIME_APP_ID      = "com.apple.facetime"   -- FaceTime Bundle ID（前台为 FaceTime 时同样豁免切换）
local ANSWER_FULL_IMG      = "answer_full.png"      -- 全屏接听按钮图
local ANSWER_BANNER_IMG    = "answer_banner.png"    -- 横幅接听按钮图
local HANGUP_IMG           = "hangup.png"           -- 挂断按钮图
local POLL_MS              = 10000                  -- 微信来电检测间隔（毫秒），默认 10 秒一次
local RELAUNCH_S           = 300                    -- 每多少秒检查一次前台（默认 5 分钟 = 300 秒）
local POST_CALL_DELAY_S    = 3600                   -- 微信通话挂断后多少秒才切回日历（默认 3600 = 1 小时；期间不做任何拉回操作）
local MATCH_THRESHOLD      = 0.90                   -- 找图匹配度（0~1，越大越严格）
local CONNECT_TIMEOUT_S    = 20                     -- 点击接听后等待接通的最长秒数
local CALL_POLL_MS         = 2000                   -- 通话中检测间隔（毫秒）
local MAX_CALL_S           = 3 * 3600               -- 单次通话最长监测秒数（超出则放弃监测）
local HANGUP_MISS_LIMIT    = 3                      -- 连续 N 次找不到挂断按钮才判定通话结束
local REVEAL_CONTROLS_TAP  = true                   -- 通话中找不到挂断按钮时，轻点屏幕中央唤出控制条
local FORCE_FOREGROUND     = true                   -- true=每5分钟检查，前台不是日历/微信/FaceTime 时才打开日历；false=仅在启动/通话结束后打开
local AUTO_LAUNCH_ON_BOOT  = true                   -- true=首次运行时注册开机自启
local DEBUG                = true                   -- 输出详细日志；检测到来电时截图存证
local IDENTIFY_APP_MODE    = false                  -- true=循环显示当前前台 App 的 Bundle ID（用于查找 App ID）
local VERSION              = 1                      -- 当前脚本版本号（整数）。发新版时 +1，并同步更新服务器上的 version.txt
local UPDATE_BASE_URL      = ""                      -- 更新源目录地址（末尾带 /）。留空=关闭更新功能。示例："https://你的域名/autotouch/"
local CHECK_ON_STARTUP     = true                   -- true=脚本启动时也检查一次更新（方便验证新版）
local HEALTH_GRACE_S       = 60                     -- 启动后连续正常运行多少秒算"健康运行"（用于失败自动回退判定）
local SCRIPT_NAME          = "wechat_auto_answer.lua"  -- 本脚本文件名（更新覆盖/回退备份用）
local STATE_FILE           = "wechat_auto_answer.state" -- 运行状态文件名（记录版本、健康标记、待跳过版本）
-- ==================== 配置区结束 ====================

-- 因运行失败被自动跳过的版本号（0=无）。启动时从状态文件读出；被跳过的版本不会再次被自动更新
local currentBlocked = 0

-- 微信通话挂断后的“切回日历”延迟截止时间（os.time 秒）。nil=无延迟任务；通话挂断时被设为一小时后
local calendarReturnAt = nil

local function sleepMs(ms)
    usleep(math.floor(ms * 1000))
end

local function tap(x, y)
    touchDown(0, x, y)
    usleep(80000)
    touchUp(0, x, y)
end

-- 在指定区域找图，返回中心坐标；找不到返回 nil。region 为 {x, y, width, height} 或 nil(全屏)
local function findButton(imgPath, region)
    local ok, res = pcall(findImage, imgPath, 1, MATCH_THRESHOLD, region, false)
    if ok and type(res) == "table" and #res > 0 and res[1][1] ~= nil then
        return res[1][1], res[1][2]
    end
    return nil, nil
end

local function openCalendarApp()
    pcall(appRun, CALENDAR_APP_ID)
    sleepMs(1200)
end

-- 找接听按钮：先找全屏来电界面的接听按钮（限屏幕下半区，避免误点聊天页的绿色按钮），再找顶部横幅按钮
local function findAnswerButton()
    local w, h = getScreenResolution()
    local x, y = findButton(ANSWER_FULL_IMG, {0, math.floor(h * 0.35), w, math.floor(h * 0.65)})
    if x then return x, y end
    local bx, by = findButton(ANSWER_BANNER_IMG, {0, 0, w, math.floor(h * 0.30)})
    if bx then return bx, by end
    return nil, nil
end

-- 连续两次检测到接听按钮才返回坐标，避免瞬时误判
local function confirmAnswer()
    local x, y = findAnswerButton()
    if not x then return nil, nil end
    sleepMs(300)
    return findAnswerButton()
end

local function handleIncomingCall(x, y)
    log("[auto-answer] 检测到微信来电，自动接听")
    if DEBUG then
        pcall(screenshot, "debug_incoming_" .. tostring(os.time()) .. ".PNG")
    end
    tap(x, y)

    -- 等待进入通话界面（出现红色挂断按钮）
    local t0 = os.time()
    local connected = false
    while os.time() - t0 < CONNECT_TIMEOUT_S do
        local hx, hy = findButton(HANGUP_IMG, nil)
        if hx then connected = true break end
        sleepMs(500)
    end

    if not connected then
        log("[auto-answer] 警告：未检测到通话界面，可能未接通，回到主循环")
        sleepMs(2000)
        return
    end

    log("[auto-answer] 通话已接通，监测通话状态")
    local callStart = os.time()
    local missCount = 0
    local w, h = getScreenResolution()
    while true do
        if os.time() - callStart >= MAX_CALL_S then
            log("[auto-answer] 达到最大监测时长，放弃监测")
            break
        end
        local hx, hy = findButton(HANGUP_IMG, nil)
        if not hx and REVEAL_CONTROLS_TAP then
            -- 视频通话中控制条会自动隐藏，轻点屏幕中央唤出，再找一次挂断按钮
            tap(math.floor(w / 2), math.floor(h * 0.45))
            sleepMs(600)
            hx, hy = findButton(HANGUP_IMG, nil)
        end
        if hx then
            missCount = 0
        else
            missCount = missCount + 1
            if missCount >= HANGUP_MISS_LIMIT then
                log("[auto-answer] 通话已结束")
                break
            end
        end
        sleepMs(CALL_POLL_MS)
    end

    -- 通话挂断：不立即切回日历，由主循环在 POST_CALL_DELAY_S 秒后切回（期间不做任何拉回操作）
    calendarReturnAt = os.time() + POST_CALL_DELAY_S
    log("[auto-answer] 通话结束，将于 " .. tostring(POST_CALL_DELAY_S) .. " 秒后切换回日历")
end

local function checkAssets()
    local ok, lfs = pcall(require, "lfs")
    if not ok then return end
    local dir = currentDir()
    for _, name in ipairs({ ANSWER_FULL_IMG, ANSWER_BANNER_IMG, HANGUP_IMG }) do
        local attr = lfs.attributes(dir .. "/" .. name)
        if not attr then
            local msg = "[auto-answer] 缺少素材文件: " .. name .. "（请放在脚本同目录）"
            log(msg)
            toast(msg, 4)
        end
    end
end

-- ==================== 更新功能 ====================

-- HTTP GET：依次尝试 lcurl / LuaSec(HTTPS) / LuaSocket，返回响应正文；全部失败返回 nil
local function httpGet(url)
    local okCurl, curl = pcall(require, "lcurl")
    if okCurl and curl then
        local ok, body = pcall(function()
            local chunks = {}
            local h = curl.easy{
                url = url,
                timeout = 30,
                followlocation = 1,
                writefunction = function(chunk)
                    table.insert(chunks, chunk)
                    return #chunk
                end,
            }
            h:perform()
            h:close()
            return table.concat(chunks)
        end)
        if ok and body and #body > 0 then return body end
    end
    local okHttps, https = pcall(require, "ssl.https")
    if okHttps then
        local ok, body = pcall(function()
            local b, code = https.request(url)
            if code == 200 and b then return b end
            return nil
        end)
        if ok and body then return body end
    end
    local okHttp, http = pcall(require, "socket.http")
    if okHttp then
        local ok, body = pcall(function()
            local b, code = http.request(url)
            if code == 200 and b then return b end
            return nil
        end)
        if ok and body then return body end
    end
    return nil
end

-- 距下一个 00:00 的秒数（按设备本地时间）；失败时退化为 1 小时检查一次
local function secondsUntilMidnight()
    local ok, t = pcall(os.date, "*t")
    if not ok or not t then
        log("[update] 警告：无法获取系统时间，更新检查退化为每小时一次")
        return 3600
    end
    return (23 - t.hour) * 3600 + (59 - t.min) * 60 + (60 - t.sec)
end

-- 复制文件（io 实现，不依赖外部命令）
local function copyFile(src, dst)
    local inF = io.open(src, "rb")
    if not inF then return false end
    local content = inF:read("*a")
    inF:close()
    local outF = io.open(dst, "wb")
    if not outF then return false end
    outF:write(content)
    outF:close()
    return true
end

-- ==================== 失败自动回退 ====================

local function fileExists(path)
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

-- 状态文件格式：一行 5 个数字：<version> <healthy> <updated> <retries> <blocked>
local function readState()
    local f = io.open(currentDir() .. "/" .. STATE_FILE, "r")
    if not f then return nil end
    local line = f:read("*l") or ""
    f:close()
    local ver, healthy, updated, retries, blocked = string.match(line, "^(%d+) (%d+) (%d+) (%d+) (%d+)$")
    if not ver then
        log("[rollback] 状态文件格式异常，按全新启动处理")
        return nil
    end
    return {
        version = tonumber(ver),
        healthy = tonumber(healthy),
        updated = tonumber(updated),
        retries = tonumber(retries),
        blocked = tonumber(blocked),
    }
end

local function writeState(version, healthy, updated, retries, blocked)
    local f = io.open(currentDir() .. "/" .. STATE_FILE, "w")
    if not f then
        log("[rollback] 无法写入状态文件，失败自动回退可能失效")
        return false
    end
    f:write(table.concat({ tostring(version), tostring(healthy), tostring(updated), tostring(retries), tostring(blocked) }, " "))
    f:close()
    return true
end

-- 回退到 .bak 备份的上一版本并重启 SpringBoard；调用后请紧跟 stop() 结束本次运行
local function doRollback(reason)
    local dir = currentDir()
    local mainPath = dir .. "/" .. SCRIPT_NAME
    local bakPath = mainPath .. ".bak"
    if not fileExists(bakPath) then
        log("[rollback] 没有可回退的备份（.bak 不存在），无法回退")
        return
    end
    local chunk, err = loadfile(bakPath)
    if not chunk then
        log("[rollback] 备份文件语法异常，放弃回退: " .. tostring(err))
        return
    end
    if not copyFile(bakPath, mainPath) then
        log("[rollback] 回退失败：无法恢复备份文件")
        return
    end
    -- 记录被跳过版本（当前 VERSION 即失败版本），防止随后又自动更新回这个坏版本
    writeState(0, 0, 0, 0, VERSION)
    log("[rollback] " .. reason .. "，已恢复上一版本并重启生效")
    sleepMs(1000)
    pcall(respring)
end

-- 检查更新：读版本清单 -> 有新版则下载 -> 语法预检 -> 备份 -> 覆盖 -> respring 自动生效
local function checkForUpdate()
    if UPDATE_BASE_URL == "" then return end
    local dir = currentDir()
    local tmpPath = dir .. "/wechat_auto_answer.new.lua"
    local bakPath = dir .. "/" .. SCRIPT_NAME .. ".bak"

    local verText = httpGet(UPDATE_BASE_URL .. "version.txt")
    if not verText then
        log("[update] 获取版本清单失败: " .. UPDATE_BASE_URL .. "version.txt")
        return
    end
    local remoteVer = tonumber(string.match(verText, "%d+"))
    if not remoteVer then
        log("[update] 版本清单解析失败: " .. verText)
        return
    end
    if remoteVer <= VERSION then
        log("[update] 已是最新版本 (v" .. tostring(VERSION) .. ")")
        return
    end
    if currentBlocked ~= 0 and remoteVer == currentBlocked then
        log("[update] v" .. tostring(remoteVer) .. " 此前运行失败已被自动跳过，请发布更高版本号")
        return
    end

    log("[update] 发现新版本 v" .. tostring(remoteVer) .. "（当前 v" .. tostring(VERSION) .. "），开始下载")
    local code = httpGet(UPDATE_BASE_URL .. scriptName)
    if not code then
        log("[update] 下载新脚本失败: " .. UPDATE_BASE_URL .. scriptName)
        return
    end

    -- 写入临时文件并做语法预检
    local tmpF = io.open(tmpPath, "wb")
    if not tmpF then
        log("[update] 无法写入临时文件")
        return
    end
    tmpF:write(code)
    tmpF:close()
    local chunk, err = loadfile(tmpPath)
    if not chunk then
        log("[update] 新脚本语法预检未通过，放弃更新: " .. tostring(err))
        os.remove(tmpPath)
        return
    end

    -- 备份旧版
    if not copyFile(dir .. "/" .. scriptName, bakPath) then
        log("[update] 备份旧版失败，放弃更新")
        os.remove(tmpPath)
        return
    end

    -- 覆盖（优先原子重命名，失败则复制覆盖）
    local renamed = pcall(os.rename, tmpPath, dir .. "/" .. scriptName)
    if not renamed then
        if not copyFile(tmpPath, dir .. "/" .. scriptName) then
            log("[update] 覆盖新脚本失败，请检查权限")
            os.remove(tmpPath)
            return
        end
        os.remove(tmpPath)
    end

    log("[update] 新版本已写入，准备重启生效")
    -- 标记即将运行的新版本为"待证明"（用于失败自动回退：新版本连续 2 次未健康运行则回退）
    writeState(remoteVer, 0, 1, 0, currentBlocked)
    -- 确保开机自启已注册，否则 respring 后不会自动运行新版
    local okP, p = pcall(botPath)
    if okP and type(p) == "string" and #p > 0 then
        pcall(setAutoLaunch, p, true)
    end
    sleepMs(1000)
    local okR = pcall(respring)
    if not okR then
        log("[update] respring 失败，请手动停止并重新运行脚本")
    end
end

-- ==================== 主流程 ====================
keepAutoTouchAwake(true)
local w, h = getScreenResolution()
log("[auto-answer] 脚本启动，分辨率 " .. tostring(w) .. "x" .. tostring(h)
    .. "，日历App=" .. CALENDAR_APP_ID .. "，微信=" .. WECHAT_APP_ID .. "，FaceTime=" .. FACETIME_APP_ID)

if AUTO_LAUNCH_ON_BOOT then
    local ok, p = pcall(botPath)
    if ok and type(p) == "string" and #p > 0 then
        local ok2 = pcall(setAutoLaunch, p, true)
        if ok2 then log("[auto-answer] 已注册开机自启: " .. p) end
    end
end

if IDENTIFY_APP_MODE then
    log("[auto-answer] 识别模式：将循环显示当前前台 App 的 Bundle ID")
    for i = 1, 20 do
        local ok, id = pcall(frontMostAppId)
        if not ok or not id then id = "unknown" end
        log("[identify] 前台 App: " .. tostring(id))
        toast("前台App: " .. tostring(id), 2)
        sleepMs(3000)
    end
    stop()
end

checkAssets()

-- ============ 失败自动回退：状态读取与判定 ============
local state = readState()
if not state then
    state = { version = 0, healthy = 1, updated = 0, retries = 0, blocked = 0 }
end
currentBlocked = state.blocked or 0

if state.updated == 1 and state.healthy == 0 then
    -- 当前版本来自更新且尚未健康运行：连续 2 次未通过健康检测则判定运行失败并回退
    local retries = state.retries + 1
    if retries >= 2 then
        doRollback("更新后的版本连续两次未能正常运行")
        stop()   -- respring 已发起；若失败则结束本次运行，下次运行即为回退后的旧版
    else
        writeState(VERSION, 0, 1, retries, currentBlocked)
        log("[rollback] 本次为更新后的第 " .. tostring(retries) .. " 次启动，连续正常运行 "
            .. tostring(HEALTH_GRACE_S) .. " 秒后视为健康")
    end
else
    writeState(VERSION, 0, 0, 0, currentBlocked)
end

local runHealthy = false   -- 本次运行是否已通过健康检测

if UPDATE_BASE_URL == "" then
    log("[update] 更新功能未启用（UPDATE_BASE_URL 为空，填入地址后生效）")
else
    log("[update] 更新源: " .. UPDATE_BASE_URL .. "，当前版本 v" .. tostring(VERSION))
end

if CHECK_ON_STARTUP then
    checkForUpdate()   -- 若发现新版会自动下载并 respring，脚本在此结束，新版由开机自启拉起
end

openCalendarApp()

-- ============ 主循环（pcall 包裹：运行异常时自动回退） ============
local function mainLoop()
    local lastRelaunch = os.time()
    local nextUpdateCheck = os.time() + secondsUntilMidnight()
    local healthStart = os.time()
    while true do
        -- 连续运行满 HEALTH_GRACE_S 秒后标记健康（证明本版本可稳定运行）
        if not runHealthy and os.time() - healthStart >= HEALTH_GRACE_S then
            local newBlocked = currentBlocked
            if newBlocked ~= 0 and newBlocked < VERSION then
                newBlocked = 0   -- 已有更新版本健康运行，解除对旧失败版本的屏蔽
            end
            writeState(VERSION, 1, 0, 0, newBlocked)
            currentBlocked = newBlocked
            runHealthy = true
            log("[auto-answer] 运行正常，健康标记已写入")
        end

        local ax, ay = confirmAnswer()
        if ax then
            handleIncomingCall(ax, ay)
            lastRelaunch = os.time()
        elseif FORCE_FOREGROUND and os.time() - lastRelaunch >= RELAUNCH_S then
            local now = os.time()
            if calendarReturnAt and now >= calendarReturnAt then
                -- 微信通话挂断后的延迟到期：切回日历（FaceTime 例外，避免打断 FaceTime 通话）
                local ok, front = pcall(frontMostAppId)
                if ok then
                    if front ~= CALENDAR_APP_ID and front ~= FACETIME_APP_ID then
                        log("[auto-answer] 通话结束延迟到期，切换回日历（前台 " .. tostring(front) .. "）")
                        openCalendarApp()
                    end
                    calendarReturnAt = nil
                end
            elseif not calendarReturnAt then
                -- 常规检查：前台是日历/微信/FaceTime 时不操作，三者都不是才打开日历
                local ok, front = pcall(frontMostAppId)
                if ok and front ~= CALENDAR_APP_ID and front ~= WECHAT_APP_ID and front ~= FACETIME_APP_ID then
                    log("[auto-answer] 前台 " .. tostring(front) .. " -> 打开 " .. CALENDAR_APP_ID)
                    openCalendarApp()
                end
            end
            lastRelaunch = os.time()
        end
        if os.time() >= nextUpdateCheck then
            checkForUpdate()
            nextUpdateCheck = os.time() + secondsUntilMidnight()
        end
        sleepMs(POLL_MS)
    end
end

local okLoop, errLoop = pcall(mainLoop)
if not okLoop then
    log("[auto-answer] 主循环异常: " .. tostring(errLoop))
    if state.updated == 1 and not runHealthy
        and fileExists(currentDir() .. "/" .. SCRIPT_NAME .. ".bak") then
        doRollback("主循环异常，自动回退到上一版本")
        stop()
    else
        log("[auto-answer] 5 秒后重试主循环")
        sleepMs(5000)
        local ok2, err2 = pcall(mainLoop)
        if not ok2 then
            log("[auto-answer] 主循环再次异常: " .. tostring(err2) .. "，脚本停止")
        end
    end
end
