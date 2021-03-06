playermgr = playermgr or {}

--/*
-- 管理在线玩家
--*/
function playermgr.init()
	playermgr.onlinenum = 0
	playermgr.onlinelimit = tonumber(skynet.getenv("onlinelimit")) or 10240
	playermgr.players = ccontainer.new()

	playermgr.starttimer_log_status()
end

function playermgr.getplayer(pid)
	return playermgr.players:get(pid)
end

function playermgr.addplayer(player)
	local pid = assert(player.pid)
	playermgr.players:add(player,pid)
	playermgr.onlinenum = playermgr.onlinenum + 1
	player.savename = string.format("player.%s",pid)
	savemgr.autosave(player)
end

-- 在线玩家删除不能调用该接口,用playermgr.kick代替
function playermgr.delplayer(pid)
	local player = playermgr.getplayer(pid)
	if player then
		playermgr.onlinenum = playermgr.onlinenum - 1
		--player:savetodatabase()
		savemgr.nowsave(player)
		savemgr.closesave(player)
		playermgr.players:del(pid)
	end
	return player
end

-- 返回在线玩家对象(不包括托管对象)
function playermgr.getonlineplayer(pid)
	local player = playermgr.getplayer(pid)
	if player then
		if playermgr.isonline(player) then
			return player
		end
	end
end

function playermgr.isonline(player)
	return player.linkobj and true or false
end

function playermgr.bind_linkobj(player,linkobj)
	--logger.log("info","playermgr","op=bind_linkobj,pid=%s,linkid=%s,linktype=%s,ip=%s,port=%s",
	--	player.pid,linkobj.linkid,linkobj.linktype,linkobj.ip,linkobj.port)
	linkobj:bind(player.pid)
	player.linkobj = linkobj
	playermgr.transfer_mark(player,linkobj)
end

function playermgr.unbind_linkobj(player)
	local linkobj = assert(player.linkobj)
	--logger.log("info","playermgr","op=unbind_linkobj,pid=%s,linkid=%s,linktype=%s,ip=%s,port=%s",
	--	player.pid,linkobj.linkid,linkobj.linktype,linkobj.ip,linkobj.port)
	player.linkobj:unbind()
	player.linkobj = nil
end

function playermgr.allplayer()
	return table.keys(playermgr.players.objs)
end

function playermgr.kick(pid,reason)
	reason = reason or "kick"
	local player = playermgr.getplayer(pid)
	if not player then
		return
	end
	player.bforce_exitgame = true
	player:exitgame(reason)
	player.bforce_exitgame = nil
	return player
end

function playermgr.kickall(reason)
	--loginqueue.clear()
	for _,pid in ipairs(playermgr.allplayer()) do
		playermgr.kick(pid,reason)
	end
end

function playermgr.createplayer(pid,conf)
	--logger.log("info","playermgr","op=createplayer,pid=%d,player=%s",pid,conf)
	local player = cplayer.new(pid)
	player:create(conf)
	--player:savetodatabase()
	player.savename = string.format("player.%s",pid)
	savemgr.oncesave(player)
	savemgr.nowsave(player)
	savemgr.closesave(player)
	return player
end

function playermgr._loadplayer(pid)
	local player = cplayer.new(pid)
	player:loadfromdatabase()
	return player
end

-- 角色不存在返回nil
function playermgr.recoverplayer(pid)
	assert(tonumber(pid),"invalid pid:" .. tostring(pid))
	assert(playermgr.getplayer(pid) == nil,"try recover a loaded player:" .. tostring(pid))
	local id = string.format("player.%s",pid)
	local ok,player = sync.once.Do(id,playermgr._loadplayer,pid)
	assert(ok,player)
	if player:isloaded() then
		return player
	else
		return nil
	end
end

function playermgr.isloading(pid)
	local id = string.format("player.%s",pid)
	if sync.once.tasks[id] then
		return true
	end
	return false
end

--/*
-- 转移标记
--*/
function playermgr.transfer_mark(player,linkobj)
	player.linktype = linkobj.linktype
	player.linkid = linkobj.linkid
	player.ip = linkobj.ip
	player.port = linkobj.port
	player.version = linkobj.version
	player.token = linkobj.token
	player.debuglogin = linkobj.debuglogin
	-- 跨服传递的数据
	player.kuafu_forward = linkobj.kuafu_forward
end

function playermgr.broadcast(func)
	for i,pid in ipairs(playermgr.allplayer()) do
		local player = playermgr.getplayer(pid)
		if player then
			xpcall(func,onerror,player)
		end
	end
end

-- 托管玩家数
function playermgr.tuoguannum()
	local tuoguannum = 0
	for pid,player in pairs(playermgr.players.objs) do
		if not player:isonline() then
			tuoguannum = tuoguannum + 1
		end
	end
	return tuoguannum
end

function playermgr.starttimer_log_status()
	local interval = 10
	timer.timeout("playermgr.starttimer_log_status",interval,playermgr.starttimer_log_status)
	playermgr._timercnt = (playermgr._timercnt or 0) + 1
	-- 计算每5分钟在线人数峰值，谷值
	if playermgr._timercnt % math.ceil(300,interval) == 0 then
		playermgr.min_onlinenum = nil
		playermgr.max_onlinenum = nil
	end
	playermgr.min_onlinenum = playermgr.min_onlinenum or playermgr.onlinenum
	playermgr.max_onlinenum = playermgr.max_onlinenum or playermgr.onlinenum
	if not playermgr.min_onlinenum or playermgr.onlinenum < playermgr.min_onlinenum then
		playermgr.min_onlinenum = playermgr.onlinenum
	end
	if not playermgr.max_onlinenum or playermgr.onlinenum > playermgr.max_onlinenum then
		playermgr.max_onlinenum = playermgr.onlinenum
	end
	local tuoguannum = playermgr.tuoguannum()
	local linknum = client.linkobjs and client.linkobjs.len or 0
	local mqlen = skynet.mqlen()
	local task = skynet.task()
	local serverid = skynet.getenv("id")
	logger.log("info","status","serverid=%s,onlinenum=%s,tuoguannum=%s,min_onlinenum=%s,max_onlinenum=%s,linknum=%s,onlinelimit=%s,mqlen=%s,task=%s",
		serverid,playermgr.onlinenum,tuoguannum,playermgr.min_onlinenum,playermgr.max_onlinenum,linknum,playermgr.onlinelimit,mqlen,task)
end

return playermgr
