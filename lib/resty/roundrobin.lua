local pairs = pairs
local next = next
local tonumber = tonumber
local setmetatable = setmetatable
local math_random = math.random
local error = error
local utils = require "resty.balancer.utils"

local copy = utils.copy
local nkeys = utils.nkeys

local _M = {}
local mt = { __index = _M }

local _gcd
_gcd = function(a, b)
    if b == 0 then
        return a
    end

    return _gcd(b, a % b)
end


local function get_gcd(nodes)
    local first_id, max_weight = next(nodes)
    if not first_id then
        return error("empty nodes")
    end

    local only_key = first_id
    local gcd = max_weight
    for _, weight in next, nodes, first_id do
        only_key = nil
        gcd = _gcd(gcd, weight)
        max_weight = weight > max_weight and weight or max_weight
    end

    return only_key, gcd, max_weight
end

local function get_block_height(response)
    -- moniker = '' then latest_block_height is at 705, we start at 600 is quite safe
    local _, start_ind = string.find(response, "latest_block_height", 600)
    if start_ind == nil then
        return 0
    else
        start_ind = start_ind + 5
    end

    local _, end_ind = string.find(response, "\"", start_ind)
    if end_ind == nil then
        return 0
    else
        end_ind = end_ind - 1
    end

    return tonumber(string.sub(response, start_ind, end_ind))
end

local function get_max_height(self)
    local max_height = 0
    for _, height in next, self.heights do
        if height > max_height then
            max_height = height
        end
    end
    return max_height
end

local function get_random_node_id(nodes)
    local count = nkeys(nodes)

    local id = nil
    local random_index = math_random(count)

    for _ = 1, random_index do
        id = next(nodes, id)
    end

    return id
end


function _M.new(_, nodes)
    local newnodes = copy(nodes)
    -- by default height is weight
    local heights = copy(nodes)
    local only_key, gcd, max_weight = get_gcd(newnodes)
    local last_id = get_random_node_id(nodes)

    local self = {
        heights = heights, -- ip => block_height
        nodes = newnodes, -- it's safer to copy one
        only_key = only_key,
        max_weight = max_weight,
        gcd = gcd,
        cw = max_weight,
        last_id = last_id,
    }
    return setmetatable(self, mt)
end

function _M.reinit(self, nodes)
    local newnodes = copy(nodes)
    self.only_key, self.gcd, self.max_weight = get_gcd(newnodes)

    self.nodes = newnodes
    self.last_id = get_random_node_id(nodes)
    self.cw = self.max_weight
end

local function _delete(self, id)
    local nodes = self.nodes

    nodes[id] = nil

    self.only_key, self.gcd, self.max_weight = get_gcd(nodes)

    if id == self.last_id then
        self.last_id = nil
    end

    if self.cw > self.max_weight then
        self.cw = self.max_weight
    end
end
_M.delete = _delete


local function _decr(self, id, w)
    local weight = tonumber(w) or 1
    local nodes = self.nodes

    local old_weight = nodes[id]
    if not old_weight then
        return
    end

    if old_weight <= weight then
        return _delete(self, id)
    end

    nodes[id] = old_weight - weight

    self.only_key, self.gcd, self.max_weight = get_gcd(nodes)

    if self.cw > self.max_weight then
        self.cw = self.max_weight
    end
end
_M.decr = _decr


local function _incr(self, id, w)
    local weight = tonumber(w) or 1
    local nodes = self.nodes

    nodes[id] = (nodes[id] or 0) + weight

    self.only_key, self.gcd, self.max_weight = get_gcd(nodes)
end
_M.incr = _incr



function _M.set(self, id, w)
    local new_weight = tonumber(w) or 0
    local old_weight = self.nodes[id] or 0

    if old_weight == new_weight then
        return
    end

    if old_weight < new_weight then
        return _incr(self, id, new_weight - old_weight)
    end

    return _decr(self, id, old_weight - new_weight)
end

local function update(self)
    local httpc = require("resty.http").new()
    for id, _ in next, self.heights do
        -- query block height to update the heights
        local res, _ = httpc:request_uri('http://' .. id .. ':26657/status', {
                method = "GET",
            })
        if res then
            local new_block_height = get_block_height(res.body)
            if new_block_height > 0 then
                self.heights[id] = new_block_height
            end
        end
    end
end

local function find(self)
    local only_key = self.only_key
    if only_key then
        return only_key
    end

    local nodes = self.nodes
    local last_id, cw, weight = self.last_id, self.cw, 0
    local max_height = self:get_max_height()

    while true do
        while true do
            last_id, weight = next(nodes, last_id)
            if not last_id then
                break
            end

            if self.heights[last_id] >= max_height and weight >= cw then
                self.cw = cw
                self.last_id = last_id
                return last_id
            end
        end

        cw = cw - self.gcd
        if cw <= 0 then
            cw = self.max_weight
        end
    end
end
_M.next = find
_M.update = update
_M.get_max_height = get_max_height
return _M
