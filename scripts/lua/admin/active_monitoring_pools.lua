--
-- (C) 2019-20 - ntop.org
--
local dirs = ntop.getDirs()
package.path = dirs.installdir .. "/scripts/lua/modules/?.lua;" .. package.path
package.path = dirs.installdir .. "/scripts/lua/modules/pools/?.lua;" .. package.path

require "lua_utils"
local page_utils = require "page_utils"
local json = require "dkjson"
local template_utils = require "template_utils"
local active_monitoring_pools = require "active_monitoring_pools"

local s = active_monitoring_pools:create()

sendHTTPContentTypeHeader('text/html')

if not haveAdminPrivileges() then return end

page_utils.set_active_menu_entry(page_utils.menu_entries.pools_active_monitoring)

-- append the menu above the page
dofile(dirs.installdir .. "/scripts/lua/inc/menu.lua")

page_utils.print_page_title(i18n("pools.pool_names.active_monitoring"))

-- ************************************* ------
--

local context = {
    template_utils = template_utils,
    json = json,
    pool = {
        name = "active_monitoring",
        instance = s,
        all_members = s:get_all_members(),
        configsets = s:get_available_configset_ids(),
        assigned_members = s:get_assigned_members(),
        endpoints = {
            get_all_pools = "/lua/rest/v1/get/active_monitoring/pools.lua",
            add_pool = "/lua/rest/v1/add/active_monitoring/pool.lua",
            edit_pool = "/lua/rest/v1/edit/active_monitoring/pool.lua",
            delete_pool = "/lua/rest/v1/delete/active_monitoring/pool.lua",
        }
    }
}

print(template_utils.gen("pages/table_pools.template", context))

-- ************************************* ------

-- append the menu below the page
dofile(dirs.installdir .. "/scripts/lua/inc/footer.lua")
