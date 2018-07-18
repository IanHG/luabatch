local M = {}

-- Define version number
local version = {  
   major = 0,
   minor = 1,
   patch = 0,
}

-- Define description
local description = {
   name = "luabatch - Lua script for generating files and submitting batch calculations.",
   desc = "<see above! (hopefully)>",
}

--- Get version number.
--
-- @return{String} Version number.
local function get_version_number()
   return version.major .. "." .. version.minor .. "." .. version.patch
end

--- Get name and version of program.
--
-- @return{String} Name and version.
local function get_version()
   return description.name .. " Vers. " .. get_version_number()
end

--- Generate description of script from script name.
--
-- @param{String} name    Name of script.
--
-- @return{Table}   Returns description.
local function get_description(name)
   local d = description
   d.script_name = name
   return d
end

-- Load module
M.get_version_number = get_version_number
M.get_version        = get_version
M.get_description    = get_description

return M
