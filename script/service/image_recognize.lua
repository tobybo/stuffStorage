local skynet = require "skynet"
local socket = require "skynet.socket"
local httpd = require "http.httpd"
local httpc = require "http.httpc"
local sockethelper = require "http.sockethelper"
local urllib = require "http.url"
local json = require "json"
local table = table
local string = string

local mode, protocol, access_token = ...
protocol = protocol or "http"

db = db or nil

if mode == "agent" then

img_url = string.format("https://aip.baidubce.com/rest/2.0/image-classify/v2/advanced_general?access_token=%s", access_token)

local function response(id, write, ...)
	local ok, err = httpd.write_response(write, ...)
	if not ok then
		-- if err == sockethelper.socket_error , that means socket closed.
		skynet.error(string.format("fd = %d, %s", id, err))
	end
end


local SSLCTX_SERVER = nil
local function gen_interface(protocol, fd)
	if protocol == "http" then
		return {
			init = nil,
			close = nil,
			read = sockethelper.readfunc(fd),
			write = sockethelper.writefunc(fd),
		}
	elseif protocol == "https" then
		local tls = require "http.tlshelper"
		if not SSLCTX_SERVER then
			SSLCTX_SERVER = tls.newctx()
			-- gen cert and key
			-- openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout server-key.pem -out server-cert.pem
			local certfile = skynet.getenv("certfile") or "./server-cert.pem"
			local keyfile = skynet.getenv("keyfile") or "./server-key.pem"
			print(certfile, keyfile)
			SSLCTX_SERVER:set_cert(certfile, keyfile)
		end
		local tls_ctx = tls.newtls("server", SSLCTX_SERVER)
		return {
			init = tls.init_responsefunc(fd, tls_ctx),
			close = tls.closefunc(tls_ctx),
			read = tls.readfunc(fd, tls_ctx),
			write = tls.writefunc(fd, tls_ctx),
		}
	else
		error(string.format("Invalid protocol: %s", protocol))
	end
end

local function escape(s)
	return (string.gsub(s, "([^A-Za-z0-9_])", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

local API_HANDLERS = {
    ["/api/recognize"] = function(url, method, header, body)
        local db_data = skynet.call(db, "lua", "find", {coll_name = "player", filter = {_id = device_id}, projection = {use_times = 1, tm_use = 1}})
        db_data.use_times = db_data.use_times or 0
        skynet.error(string.format("recognize, usetimes,%s", db_data.use_times))
        if db_data.use_times < 10 then
            local tab = urllib.parse_query(body)
            local device_id = tab.device_id
            db_data.use_times = db_data.use_times + 1
            skynet.call(db, "lua", "update", {coll_name = "player", _id = device_id, chgs = {use_times = db_data.use_times, tm_use = skynet.time()}})
            local header = {
                ["content-type"] = "application/x-www-form-urlencoded"
            }
            local recvheader = {}
            local status, res_body = httpc.post_any("POST", "https://aip.baidubce.com", img_url, recvheader, header, body)
            skynet.error(string.format("status:%s, res_body:%s", status, res_body))
            local header = {}
            header["Content-Type"] = "application/json"
            return status, res_body, header
        else
            return 404
        end
    end,
    ["/api/req_times"] = function(url, method, header, body)
        local tab = urllib.parse_query(body)
        local device_id = tab.device_id
	    skynet.error(string.format("req_times, device_id:%s, body,%s", device_id, body))
        local ret = skynet.call(db, "lua", "find", {coll_name = "player", filter = {_id = device_id}, projection = {use_times = 1, tm_use = 1}})
        skynet.error(string.format("dbret:%s", json.encode(ret)))
        local now = skynet.time()
        local tm_use = ret.tm_use or now
        if math.floor(now / 86400) ~= math.floor(tm_use / 86400) then
            ret.use_times = 0
        end
        tab.UseTimes = ret.use_times or 0
        tab.LimitTimes = 10
        local header = {}
        header["Content-Type"] = "application/json"
        return 200, json.encode(tab), header
    end,
}

skynet.start(function()
    skynet.dispatch("lua", function (_,_,cmd,param)
        if cmd == "init" then
            db = param.db
        elseif cmd == "work" then
            local id = param
            socket.start(id)
            local interface = gen_interface(protocol, id)
            if interface.init then
                interface.init()
            end
            -- limit request body size to 8192 (you can pass nil to unlimit)
            local code, url, method, header, body = httpd.read_request(interface.read, 8192000)
            skynet.error(string.format("code:%s, url:%s, method:%s, header:%s", code, url, method, header))
            if code then
                if code ~= 200 then
                    response(id, interface.write, code)
                else
                    if API_HANDLERS[url] then
                        code, body, header = API_HANDLERS[url](url, method, header, body)
                        response(id, interface.write, code, body, header)
                    else
                        response(id, interface.write, 404)
                    end
                end
            else
                if url == sockethelper.socket_error then
                    skynet.error("socket closed")
                else
                    skynet.error(url)
                end
            end
            socket.close(id)
            if interface.close then
                interface.close()
            end
        end
	end)
end)

else

skynet.start(function()
    local access_token = ""
	local file = io.open("accesstoken.txt", "r")
	if file then
		-- 读取一行数据
		local line = file:read("*l")
        access_token = line
		-- 关闭文件
		file:close()
	else
		skynet.error("无法打开token文件")
		skynet.exit()
	end
    local db = skynet.newservice("image_db")
	local agent = {}
	local protocol = "http"
	for i= 1, 20 do
		agent[i] = skynet.newservice(SERVICE_NAME, "agent", protocol, access_token)
        skynet.send(agent[i], "lua", "init", { db = db })
	end
	local balance = 1
	local id = socket.listen("0.0.0.0", 8001)
	skynet.error(string.format("Listen web port 8001 protocol:%s, SERVICE_NAME:%s", protocol, SERVICE_NAME))
	socket.start(id , function(id, addr)
		skynet.error(string.format("%s connected, pass it to agent :%08x", addr, agent[balance]))
		skynet.send(agent[balance], "lua", "work", id)
		balance = balance + 1
		if balance > #agent then
			balance = 1
		end
	end)
end)

end
