local M = {}

local filesystem = assert(require "lib.filesystem")
local class   = assert(require "lib.class")
local util    = assert(require "lib.util")
local path    = assert(require "lib.path")
local logging = assert(require "lib.logging")
local logger  = logging.logger

local function pack(...)
   return { ... }

   --if not table.pack then
   --   table.pack = function(...)
   --      return { n = select("#", ...), ...}
   --   end
   --end
end

local function dofile_into_environment(filename, env)
    setmetatable ( env, { __index = _G } )
    local status, result = assert(pcall(setfenv(assert(loadfile(filename)), env)))
    setmetatable(env, nil)
    return result
end

local function get_name(batches_path)
   local p, f, e = path.split_filename(batches_path)
   return f:gsub("." .. e, "")
end

--- Class to implement a simple symbol table,
-- which can be used for string substitution.
--
local symbol_table_class = class.create_class()

function symbol_table_class:__init()
   self.sbeg    = "%"
   self.send    = "%"
   self.symbols = { }

   self.ftable = {
      add = self:add_symbol_setter(),
   }
end

function symbol_table_class:add_symbol(symb, ssymb)
   if not (type(symb) == "string") or util.isempty(symb) then
      assert(false)
   end
   if not (type(ssymb) == "string") then
      assert(false)
   end

   local symbol = self.sbeg .. symb .. self.send
   if not self.symbols[symbol] then
      self.symbols[self.sbeg .. symb .. self.send] = ssymb
   end
end

function symbol_table_class:add_symbol_setter()
   return function(symb, ssymb)
      self:add_symbol(symb, ssymb)
      return self.ftable
   end
end

function symbol_table_class:substitute(str)
   local function escape(k)
      return k:gsub("%%", "%%%%")
   end

   for k, v in pairs(self.symbols) do
      str = string.gsub(str, escape(k), v)
   end
   
   return str
end

function symbol_table_class:merge(st)
   for k, v in pairs(st.symbols) do
      if not self.symbols[k] then
         self.symbols[k] = v
      end
   end
end

function symbol_table_class:print()
   logger:message("   Symbol table : ")
   for k, v in pairs(self.symbols) do
      logger:message("      " .. k .. " : " .. v)
   end
end

--- Base class for the different batches classes.
-- Implemenents some general function for creating the
-- setter functions to be passed to the extern package.
--
local batches_creator_class = class.create_class()

function batches_creator_class:__init()
end

function batches_creator_class:true_setter(var)
   return function()
      self[var] = true
      return self.ftable
   end
end

function batches_creator_class:false_setter(var)
   return function()
      self[var] = false
      return self.ftable
   end
end

function batches_creator_class:string_setter(...)
   local t_outer = pack( ... )
   return function(...)
      local t_inner = pack( ... )

      -- Check sizes fit
      if #t_inner > #t_outer then
         assert(false)
      end

      -- Check all are strings, and set.
      for i = 1, #t_inner do
         if not (type(t_inner[i]) == "string") then
            assert(false) -- for now we just crash
         end
         self[t_outer[i]] = t_inner[i]
      end
      return self.ftable
   end
end

function batches_creator_class:element_setter(var, num)
   assert(type(var) == "string")

   return function(...)
      local t_inner = pack(...)
      
      assert(#t_inner == num)

      table.insert(self[var], t_inner)

      return self.ftable
   end
end

function batches_creator_class:print_setter()
   return function(...)
      local t_inner = pack( ... )

      for i = 1, #t_inner do
         logger:message(t_inner[i], self.log_format)
      end

      return self.ftable
   end
end


---
local batch_class = class.create_class(batches_creator_class)

function batch_class:__init()
   
   --
   self.symbol_table = symbol_table_class:create()

   self.ftable = {
      symbol_add = self:add_setter(),
   }
end

function batch_class:add_setter()
   return function(symb, ssymb)
      self.symbol_table:add_symbol(symb, ssymb)
      return self.ftable
   end
end

function batch_class:print()
   self.symbol_table:print()
end

---
--
--
local batches_class = class.create_class(batches_creator_class)

function batches_class:__init()
   -- Util
   self.log_format = "newline"
   self.path       = ""

   -- General stuff
   self.directory = ""
   self.templates = { }
   
   -- 
   self.symbol_table = symbol_table_class:create()
   
   -- Lmod 
   self.batches = { }
   
   -- Function table for loading package
   self.ftable = {
      --
      batch     = self:batches_setter(),
      template  = self:element_setter("templates", 3),
      directory = self:string_setter ("directory"),

      -- util
      print    = print,
      pairs    = pairs,

      --
      symbol = self.symbol_table.ftable,
   }
end

function batches_class:batches_setter()
   return function(b)
      local batch = batch_class:create()
      for k, v in pairs(b) do
         batch.symbol_table:add_symbol(k, v)
      end
      table.insert(self.batches, batch)
      return batch.ftable
   end
end

function batches_class:load(batches_path)
   assert(type(batches_path) == "string")
   self.path = batches_path
   self.name = "config"
   
   local env  = self.ftable
   local file = dofile_into_environment(self.path, env)
   
   if env[self.name] then
      env[self.name]()
   else
      logger:alert("Could not load.")
   end
   
   --for k, v in pairs(self) do
   --   if type(v) == "string" then
   --      self[k] = self.symbol_table:substitute(v)
   --   end
   --end

   --for k, v in pairs(self.lmod) do
   --   if type(v) == "string" then
   --      self.lmod[k] = self.symbol_table:substitute(v)
   --   end
   --end
end

--
function batches_class:print()
   logger:message(" Batches :")
   logger:message("   Directory : " .. self.directory)
   for k, v in pairs(self.templates) do
      logger:message("   Template : " .. v[1] .. " " .. v[2] .. " " .. v[3])
   end

   self.symbol_table:print()

   for k, v in pairs(self.batches) do
      v:print()
   end
end

local function load_batches(path)
   local bt = batches_class:create()
   bt:load(path)
   return bt
end

--- Create the module
M.load_batches       = load_batches

-- return module
return M
