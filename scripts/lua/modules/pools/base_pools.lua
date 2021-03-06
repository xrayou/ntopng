--
-- (C) 2017-20 - ntop.org
--

-- Module to keep things in common across pools of various type

require "lua_utils"
local user_scripts = require "user_scripts"
local json = require "dkjson"

-- ##############################################

local base_pools = {}

-- ##############################################

function base_pools:create(args)
   if args then
      -- We're being sub-classed
      if not args.key then
	 return nil
      end
   end

   local this = args or {key = "base"}

   setmetatable(this, self)
   self.__index = self

   return this
end

-- ##############################################

function base_pools:_get_pools_prefix_key()
   local key = string.format("ntopng.pools.%s_pools", self.key)
   -- e.g.:
   --  ntopng.pools.interface_pools
   --  ntopng.pools.snmp_device_pools
   --  ntopng.pools.network_pools

   return key
end

-- ##############################################

function base_pools:_get_pool_ids_key()
   local key = string.format("%s.pool_ids", self:_get_pools_prefix_key())
   -- e.g.:
   --  ntopng.pools.interface_pools.pool_ids

   return key
end

-- ##############################################

function base_pools:_get_next_pool_id_key()
   local key = string.format("%s.next_pool_id", self:_get_pools_prefix_key())
   -- e.g.:
   --  ntopng.pools.interface_pools.next_pool_id

   return key
end

-- ##############################################

function base_pools:_get_pool_lock_key()
   local key = string.format("%s.pool_lock", self:_get_pools_prefix_key())
   -- e.g.:
   --  ntopng.pools.interface_pools.pool_lock

   return key
end

-- ##############################################

function base_pools:_get_pool_details_key(pool_id)
   if not pool_id then
      -- A pool id is always needed
      return nil
   end

   local key = string.format("%s.pool_id_%d.details", self:_get_pools_prefix_key(), pool_id)

   return key
end

-- ##############################################

function base_pools:_assign_pool_id()
   local next_pool_id_key = self:_get_next_pool_id_key()
   -- Atomically assign a new pool id
   local next_pool_id = ntop.incrCache(next_pool_id_key)

   -- Add the atomically assigned pool id to the set of current pool ids (set wants a string)
   ntop.setMembersCache(self:_get_pool_ids_key(), string.format("%d", next_pool_id))

   -- tprint({next_pool_id = next_pool_id, pool_ids = ntop.getMembersCache(self:_get_pool_ids_key())})
   return next_pool_id
end

-- ##############################################

function base_pools:_lock()
   local max_lock_duration = 5 -- seconds
   local max_lock_attempts = 5 -- give up after at most this number of attempts
   local lock_key = self:_get_pool_lock_key()

   for i = 1, max_lock_attempts do
      local value_set = ntop.setnxCache(lock_key, "1", max_lock_duration)

      if value_set then
	 return true -- lock acquired
      end

      ntop.msleep(1000)
   end

   return false -- lock not acquired
end

-- ##############################################

function base_pools:_unlock()
   ntop.delCache(self:_get_pool_lock_key())
end

-- ##############################################

-- @brief Persist pool details to disk. Possibly assign a pool id
-- @param pool_id The pool_id of the pool which needs to be persisted. If nil, a new pool id is assigned
function base_pools:_persist(pool_id, name, members, configset_id)
   -- self:cleanup()

   local pool_details_key = self:_get_pool_details_key(pool_id)
   local pool_details = {
      name = name,
      members = members,
      configset_id = configset_id
   }
   ntop.setCache(pool_details_key, json.encode(pool_details))

   -- Return the assigned pool_id
   return pool_id
end

-- ##############################################

function base_pools:add_pool(name, members, configset_id)
   local pool_id

   local locked = self:_lock()

   if locked and name and members and configset_id then
      local checks_ok = true

      -- Check if duplicate names exist
      local same_name_pool = self:get_pool_by_name(name)
      if same_name_pool then checks_ok = false end

      -- Check if members are valid
      if not self:are_valid_members(members) then checks_ok = false end

      -- Check if members do not belong to any other pool
      if checks_ok then
	 local assigned_members = self:get_assigned_members()

	 for _, member in pairs(members) do
	    if assigned_members[member] then
	       -- Member already existing in another pool
	       checks_ok = false
	       break
	    end
	 end
      end

      -- Check if the configset_id is valid
      if checks_ok then
	 local available_configsets = self:get_available_configset_ids()

	 if not available_configsets[configset_id] then
	    -- Configset id not found
	    checks_ok = false
	 end
      end

      if checks_ok then
	 -- All the checks have succeeded
	 -- Now that everything is ok, the id can be assigned and the pool can be persisted with the assigned id
	 pool_id = self:_assign_pool_id()

	 self:_persist(pool_id, name, members, configset_id)
      end
   end

   self:_unlock()

   return pool_id
end

-- ##############################################

function base_pools:edit_pool(pool_id, new_name, new_members, new_configset_id)
   local ret = false

   local locked = self:_lock()

   -- Make sure the pool exists
   local cur_pool_details = self:get_pool(pool_id)

   -- If here, pool_id has been found
   if locked and cur_pool_details and new_name and new_members and new_configset_id then
      local checks_ok = true

      -- Check if new_name is not the name of any other existing pool
      local same_name_pool = self:get_pool_by_name(new_name)
      if same_name_pool and same_name_pool.pool_id ~= pool_id then checks_ok = false end

      -- Check if members are valid
      if not self:are_valid_members(new_members) then checks_ok = false end

      -- Check if none of new_members belongs to any other exsiting pool
      if checks_ok then
	 local assigned_members = self:get_assigned_members()

	 for _, member in pairs(new_members) do
	    if assigned_members[member] and assigned_members[member] ~= pool_id then
	       -- Member already existing in another pool
	       checks_ok = false
	       break
	    end
	 end
      end

      -- Check if the configset_id is valid
      if checks_ok then
	 local available_configsets = self:get_available_configset_ids()

	 if not available_configsets[new_configset_id] then
	    -- Configset id not found
	    checks_ok = false
	 end
      end

      if checks_ok then
	 -- If here, all checks are valid and the pool can be edited
	 self:_persist(pool_id, new_name, new_members, new_configset_id)

	 -- Pool edited successfully
	 ret = true
      end
   end

   self:_unlock()

   return ret
end

-- ##############################################

function base_pools:delete_pool(pool_id)
   local ret = false

   local locked = self:_lock()

   -- Make sure the pool exists
   local cur_pool_details = self:get_pool(pool_id)

   if locked and cur_pool_details then
      -- Remove the key with all the pool details (e.g., with members, and configset_id)
      ntop.delCache(self:_get_pool_details_key(pool_id))

      -- Remove the pool_id from the set of all currently existing pool ids
      ntop.delMembersCache(self:_get_pool_ids_key(), string.format("%d", pool_id))

      ret = true
   end

   self:_unlock()

   return ret
end

-- ##############################################

-- @brief Returns all the defined pools. Pools are returned in a lua table with pool ids as keys
function base_pools:get_all_pools()
   local cur_pool_ids = ntop.getMembersCache(self:_get_pool_ids_key())
   local res = {}

   for _, pool_id in pairs(cur_pool_ids) do
      local pool_details = self:get_pool(pool_id)

      if pool_details then
	 res[#res + 1] = pool_details
      end
   end

   return res
end

-- ##############################################

function base_pools:get_pool(pool_id)
   local pool_details
   local pool_details_key = self:_get_pool_details_key(pool_id)

   -- Attempt at retrieving the pool details key and at decoding it from JSON
   if pool_details_key then
      local pool_details_str = ntop.getCache(pool_details_key)
      pool_details = json.decode(pool_details_str)

      if pool_details then
	 -- Add the integer pool id
	 pool_details["pool_id"] = tonumber(pool_id)

	 if pool_details["members"] then
	    -- Add a new table with member details
	    -- Table keys are members, table values are member details
	    pool_details["member_details"] = {}
	    for _, member in pairs(pool_details["members"]) do
	       pool_details["member_details"][member] = self:get_member_details(member)
	    end
	 end

	 if pool_details["configset_id"] then
	    local configset_id = pool_details["configset_id"]
	    local config_sets = user_scripts.getConfigsets()

	    -- Add a new (small) table with configset details, including the name
	    if config_sets[configset_id] and config_sets[configset_id]["name"] then
	       pool_details["configset_details"] = {name = config_sets[configset_id]["name"]}
	    end
	 end
      end
   end

   -- Upon success, pool details are returned, otherwise nil
   return pool_details
end

-- ##############################################

function base_pools:get_pool_by_name(name)
   local cur_pool_ids = ntop.getMembersCache(self:_get_pool_ids_key())

   for _, pool_id in pairs(cur_pool_ids) do
      local pool_details = self:get_pool(pool_id)

      if pool_details and pool_details["name"] and pool_details["name"] == name then
	 return pool_details
      end
   end

   return nil
end

-- ##############################################

function base_pools:get_pools_by_configset_id(configset_id)
   local cur_pool_ids = ntop.getMembersCache(self:_get_pool_ids_key())
   local res = {}

   for _, pool_id in pairs(cur_pool_ids) do
      local pool_details = self:get_pool(pool_id)

      if pool_details and pool_details["configset_id"] and pool_details["configset_id"] == configset_id then
	 res[#res + 1] = pool_details
      end
   end

   return res
end

-- ##############################################

-- @brief Returns a flattened table with pool_member->pool_id pairs
function base_pools:get_assigned_members()
   local cur_pool_ids = ntop.getMembersCache(self:_get_pool_ids_key())
   local res = {}

   for _, pool_id in pairs(cur_pool_ids) do
      local pool_details = self:get_pool(pool_id)

      if pool_details and pool_details["members"] then
	 for _, member in pairs(pool_details["members"]) do
	    res[member] = tonumber(pool_id)
	 end
      end
   end

   return res
end

-- ##############################################

function base_pools:cleanup()
   local locked = self:_lock()

   if locked then
      -- Delete pool details
      local cur_pool_ids = ntop.getMembersCache(self:_get_pool_ids_key())
      for _, pool_id in pairs(cur_pool_ids) do
	 ntop.delCache(self:_get_pool_details_key(pool_id))
      end

      -- Delete pool ids
      ntop.delCache(self:_get_pool_ids_key())
      ntop.delCache(self:_get_next_pool_id_key())
   end

   self:_unlock()
end

-- ##############################################

-- @brief Returns a boolean indicating whether the member is a valid pool member
function base_pools:is_valid_member(member)
   local all_members = self:get_all_members()
   return all_members[member] ~= nil
end

-- ##############################################

-- @brief Returns a boolean indicating whether the array of members passed contains all valid members
function base_pools:are_valid_members(members)
   for _, member in pairs(members) do
      if not self:is_valid_member(member) then
	 return false
      end
   end

   return true
end

-- ##############################################

-- @brief Parses members submitted via HTTP (validated as `pool_members` in `http_lint.lua`) into a table of members
function base_pools:parse_members(members_string)
   local members = {}

   if isEmptyString(members_string) then
      return members
   end

   -- Unfold the members csv
   members = members_string:split(",") or {members_string}

   return members
end

-- ##############################################

-- @brief Returns available members which don't already belong to any defined pool
function base_pools:get_available_members()
   local assigned_members = self:get_assigned_members()
   local all_members = self:get_all_members()

   local res = {}
   for member, member_details in pairs(all_members) do
--      tprint("checking.."..member)
--      tprint(member)
      if not assigned_members[member] then
	 res[member] = member_details
      end
   end

   return res
end

-- ##############################################

-- @brief Returns available confset ids which can be added to a pool
function base_pools:get_available_configset_ids()
   -- Currently, confset_ids are shared across pools of all types
   -- so all the confset_ids can be returned here without distinction
   local config_sets = user_scripts.getConfigsets()
   local res = {}

   for _, configset in pairs(config_sets) do
      res[configset.id] = {configset_id = configset.id, configset_name = configset.name}
   end

   return res
end

-- ##############################################

return base_pools
