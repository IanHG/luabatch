local M = {}

local filesystem = assert(require "lib.filesystem")
local class   = assert(require "lib.class")
local util    = assert(require "lib.util")
local path    = assert(require "lib.path")
local logging = assert(require "lib.logging")
local logger  = logging.logger
local execcmd = assert(require "lib.execcmd")
local luautil = assert(require "lib.luautil")

local function pack(...)
   return { ... }

   --if not table.pack then
   --   table.pack = function(...)
   --      return { n = select("#", ...), ...}
   --   end
   --end
end

local function dofile_into_environment(filename, env)
   function readall(file)
      local f = assert(io.open(file, "rb"))
      local content = f:read("*all")
      f:close()
      return content
   end

   setmetatable ( env, { __index = _G } )
   local status = nil
   local result = nil
   if luautil.version() == "Lua 5.1" then
      status, result = assert(pcall(setfenv(assert(loadfile(filename)), env)))
   else
      local content  = readall(filename)
      status, result = assert(pcall(load(content, nil, nil, env)))
   end
   setmetatable(env, nil)
   return result
end

local function get_name(batches_path)
   local p, f, e = path.split_filename(batches_path)
   return f:gsub("." .. e, "")
end

math.randomseed(os.clock()+os.time())

local function generate_uid(template)
   if util.isempty(template) then
      template ='xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
   end

   local random = math.random
   local function uuid()
      return string.gsub(template, '[xy]', function (c)
         local v = (c == 'x') and random(0, 0xf) or random(8, 0xb)
         return string.format('%x', v)
      end)
   end

   return uuid()
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

function symbol_table_class:add_symbol(symb, ssymb, overwrite, format_fcn)
   if not (type(symb) == "string") or util.isempty(symb) then
      logger:alert("Cannot add : Symbol is empty.")
      assert(false)
   end
   if not (type(ssymb) == "string") then
      ssymb = tostring(ssymb)
   end

   local symbol = self.sbeg .. symb .. self.send
   if (not self.symbols[symbol]) or overwrite then
      self.symbols[self.sbeg .. symb .. self.send] = { ssymb = ssymb, format_fcn = format_fcn }
   end
end

function symbol_table_class:remove_symbol(symb)
   if not (type(symb) == "string") or util.isempty(symb) then
      assert(false)
   end
   
   local symbol = self.sbeg .. symb .. self.send
   if self.symbols[symbol] then
      self.symbols[symbol] = nil
   end
end

function symbol_table_class:add_symbol_setter()
   return function(symb, ssymb, overwrite, format_fcn)
      self:add_symbol(symb, ssymb, overwrite, format_fcn)
      return self.ftable
   end
end

function symbol_table_class:escape(str)
   if type(str) ~= "string" then
      str = tostring(str)
   end

   local  pattern, _ = str:gsub("%%", "%%%%")
   return pattern
end

function symbol_table_class:substitute(str)
   local pattern = self:escape(self.sbeg .. ".+" .. self.send)
   
   -- Declare implementation function
   local function substitute_impl(str)
      if str:match(pattern) then
         -- loop over symbols
         for k, v in pairs(self.symbols) do
            if str:match(self:escape(k)) then
               local formatet_ssymb = v.ssymb
               
               if v.ssymb:match(pattern) then
                  formatet_ssymb = substitute_impl(formatet_ssymb)
               end

               if v.format_fcn then
                  formatet_ssymb = v.format_fcn(formatet_ssymb)
               end
               
               -- Do actual substitution
               str = string.gsub(str, self:escape(k), self:escape(formatet_ssymb))
            end
         end
      end
      

      return str
   end
   
   -- Call substitution implementation
   str = substitute_impl(str)

   return str
end

function symbol_table_class:merge(st)
   for k, v in pairs(st.symbols) do
      if not self.symbols[k] then
         self.symbols[k] = v
      end
   end
end

function symbol_table_class:check(str)
   -- Check for any missing substitutions
   local pattern = self:escape(self.sbeg .. ".+" .. self.send)
   if str:match(pattern) then
      logger:alert(" String '" .. str .. "' contains un-substitued symbols!")
      assert(false)
   end
end

function symbol_table_class:print()
   logger:message("   Symbol table : ")
   for k, v in pairs(self.symbols) do
      logger:message("      " .. k .. " : " .. v.ssymb)
   end
end

---
local path_handler_class = class.create_class()

function path_handler_class:__init()
   self.paths = {}

   self.symbol_table = symbol_table_class:create()
end

function path_handler_class:push(ppath)
   logger:message(" Pushing path : '" .. ppath .. "'.")
   
   if path.is_abs_path(ppath) then
      table.insert(self.paths, ppath)
   else
      table.insert(self.paths, path.join(self:current(), ppath))
   end

   self.symbol_table:add_symbol("cwd", self.paths[#self.paths], true)

   local status = filesystem.chdir(self.paths[#self.paths])
   if status == nil then
      assert(false)
   end
end

function path_handler_class:pop()
   if #self.paths > 0 then
      logger:message(" Popping path : '" .. self.paths[#self.paths] .. "'.")
      self.paths[#self.paths] = nil
      if #self.paths > 0 then
         self.symbol_table:add_symbol("cwd", self.paths[#self.paths], true)
         local status = filesystem.chdir(self.paths[#self.paths])
         if status == nil then
            assert(false)
         end
      end
   else
      logger:message(" Popping nothing.")
   end

   return #self.paths
end

function path_handler_class:pop_all()
   while (self:pop() > 0) do
   end
end

function path_handler_class:current()
   return self.paths[#self.paths]
end

function path_handler_class:print()
   for k, v in pairs(self.paths) do
      logger:message(" Path Handler : " .. v)
   end
end

-- Class for creating files from templates
local file_creator_class = class.create_class()

function file_creator_class:__init()
   self.path_handler = nil
   self.template     = nil
end

function file_creator_class:create_file(ttemplate, batch)
   self.template = ttemplate
   
   if self.path_handler == nil then
      logger:alert("Path handler not set in file_creator_class.")
      assert(false)
   end
   
   -- helper
   local function load_template(path)
      local f = io.open(path)
      
      if f == nil then
         logger:alert("Did not find template file '" .. path .. "'.")
         assert(false)
      end
      
      local  template = f:read("*all")
      return template
   end
   
   -- helper
   local function generate_template_path()
      local template_path = ""
      if not util.isempty(self.template.cpath) then
         template_path = self.template.cpath
      else
         local _, f,_  = path.split_filename(self.template.path)
         template_path = f:gsub(".template", "")
      end
      
      if path.is_rel_path(template_path) then
         template_path = path.join(self.path_handler:current(), template_path)
      end
      return batch.symbol_table:substitute(template_path)
   end
   
   -- helper
   local function write_file(template_path, template)
      local template_file = assert(io.open(template_path, "w"))
      template_file:write(template)
      template_file:close()
   end
   
   -- Create the file
   local template = ""
   if self.template.ttype == "inline" then
      if self.template.content then
         template = self.path_handler.symbol_table:substitute(batch.symbol_table:substitute(self.template.content))
      end
   elseif self.template.ttype == "file" then
      if self.template.path then
         template = self.path_handler.symbol_table:substitute(batch.symbol_table:substitute(load_template(self.template.path)))
      end
   else
      assert(false)
   end
   
   local template_path = generate_template_path()
   write_file(template_path, template)
end

--- Base class for the different batches classes.
-- Implemenents some general function for creating the
-- setter functions to be passed to the extern package.
--
local creator_class = class.create_class()

function creator_class:__init()
end

function creator_class:true_setter(var)
   return function()
      self[var] = true
      return self.ftable
   end
end

function creator_class:false_setter(var)
   return function()
      self[var] = false
      return self.ftable
   end
end

function creator_class:string_setter(...)
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

function creator_class:element_setter(var, num)
   assert(type(var) == "string")

   return function(...)
      local t_inner = pack(...)
      
      assert(#t_inner == num)

      table.insert(self[var], t_inner)

      return self.ftable
   end
end

function creator_class:print_setter()
   return function(...)
      local t_inner = pack( ... )

      for i = 1, #t_inner do
         logger:message(t_inner[i], self.log_format)
      end

      return self.ftable
   end
end

---
--
--
local variable_class = class.create_class()

function variable_class:__init()
   self.name       = ""
   self.variables  = {}
   self.format_fcn = nil
end

function variable_class:append(variables)
   if type(variables) == "string" then
      table.insert(self.variables, variables)
   elseif type(variables) == "table" then
      for k, v in pairs(variables) do
         table.insert(self.variables, v)
      end
   else
      assert(false)
   end
end

function variable_class:print()
   if type(self.name) == "table" then
      local first   = true
      local message = "{"
      for k, v in pairs(self.name) do
         if first then
            message = message .. v 
         else 
            message = message .. ", " .. v
         end
         first = false
      end
      message = message .. "}"

      logger:message(" Variable : " .. message)
      for k, v in pairs(self.variables) do
         local vfirst = true
         local vmessage = "{"
         for kk, vv in pairs(v) do
            if vfirst then
               vmessage = vmessage .. vv
            else
               vmessage = vmessage .. ", " .. vv
            end
            vfirst = false
         end
         vmessage = vmessage .. "}"
         logger:message("   " .. vmessage)
      end
   else
      logger:message(" Variable : " .. self.name)
      for k, v in pairs(self.variables) do
         logger:message("   " .. v)
      end
   end
end

---
--
--
local batch_class = class.create_class(creator_class)

function batch_class:__init()
   
   --
   self.symbol_table = symbol_table_class:create()

   self.ftable = {
      symbol_add = self:add_setter(),

      pop        = nil
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

local command_class = class.create_class()

function command_class:__init()
   -- command types:
   --    "exec"   : execute in shell
   --    "files"  : create all template files
   --    "file"   : create a single template file
   --    "mkdir"  : create directory
   --    "chdir"  : change working directory
   --    "popdir" : pop current directory
   self.type         = "nil"
   self.command      = ""
   self.path_handler = nil
end


function command_class:execute(batch, program)
   local command = batch.symbol_table:substitute(self.command)

   logger:message(" Executing command : [" .. self.type .. "] : '" .. command .. "'.")

   -- Load template

   if self.type == "exec" then
      local out    = { out = "" }
      local status = execcmd.execcmd_bashexec(command, out)
      local cmd_input = out.out 
      cmd_input = cmd_input:gsub("\n%+(.-)", "")
      cmd_input = cmd_input:gsub("^%+(.-)\n", "")
      batch.symbol_table:add_symbol("cmd_input", cmd_input, true)
      logger:message(out.out, "raw")
   elseif self.type == "files" then
      for k, v in pairs(program.templates) do
         local file_creator = file_creator_class:create()
         file_creator.path_handler = program.path_handler
         file_creator:create_file(v, batch)
      end
   elseif self.type == "file" then
      local file_creator = file_creator_class:create()
      file_creator.path_handler = self.path_handler
      local template = program:get_template(self.command)
      if self.path then
         template.cpath = self.path
      end
      file_creator:create_file(template, batch)
   elseif self.type == "mkdir" then
      filesystem.mkdir(batch.symbol_table:substitute(self.command))
   elseif self.type == "chdir" then
      self.path_handler:push(batch.symbol_table:substitute(self.command))
   elseif self.type == "popdir" then
      self.path_handler:pop()
   end
end

function command_class:print()
   logger:message("      Command : [" .. self.type .. "] '" .. self.command .. "'.")
end

---
--
--
local program_class = class.create_class(creator_class)

function program_class:__init()
   self.name      = ""

   self.templates = {}
   self.variables = nil

   self.commands  = {}
   self.options   = {}

   self.path_handler = nil
   self.symbol_table = symbol_table_class:create()

   self.ftable = {
      template       = self:template_setter(),
      command        = self:command_setter(),
      files          = self:files_setter(),
      file           = self:file_setter(),
      with_directory = self:with_directory_setter(),
      pop_directory  = self:pop_directory_setter(),
      define         = self:define_setter(),

      pop = nil,
   }
end

function program_class:create_command()
   local  command = command_class:create()
   command.path_handler = self.path_handler
   return command
end

function program_class:get_template(name)
   for k, v in pairs(self.templates) do
      if v.cpath == name then
         return v
      end
   end
   return nil
end

function program_class:template_setter()
   -- content can be content or path depending on ttype
   return function(ttype, content, cpath)
      if ttype == "inline" then
         table.insert(self.templates, { ttype = ttype, content = content, path = nil, cpath = cpath } )
      elseif ttype == "file" then
         local tpath = ""
         if path.is_abs_path(content) then
            tpath = content
         else
            self.path_handler:print()
            tpath = path.join(self.path_handler:current(), content)
         end
         table.insert(self.templates, { ttype = ttype, content = nil, path = tpath, cpath = cpath } )
      else
         logger:alert("Unknwown template type '" .. ttype .. "'.")
         assert(false)
      end
      return self.ftable
   end
end

function program_class:command_setter()
   return function(cmd)
      local command   = self:create_command() 
      command.type    = "exec"
      command.command = cmd
      table.insert(self.commands, command)
      return self.ftable
   end
end

function program_class:files_setter()
   return function()
      local command = self:create_command()
      command.type  = "files"
      table.insert(self.commands, command)
      return self.ftable
   end
end

function program_class:file_setter()
   return function(name, path)
      local command = self:create_command()
      command.type = "file"
      command.command = name
      command.path    = path
      table.insert(self.commands, command)
      return self.ftable
   end
end

function program_class:with_directory_setter()
   return function(dir)
      local command_mkdir   = self:create_command()
      command_mkdir.type    = "mkdir"
      command_mkdir.command = dir
      table.insert(self.commands, command_mkdir)
      
      local command_chdir   = self:create_command()
      command_chdir.type    = "chdir"
      command_chdir.command = dir
      table.insert(self.commands, command_chdir)

      return self.ftable
   end
end

function program_class:pop_directory_setter()
   return function()
      local command = self:create_command()
      command.type = "popdir"
      table.insert(self.commands, command)
      return self.ftable
   end
end

function program_class:define_setter()
   return function(symb, ssymb, format_fcn)
      self.symbol_table:add_symbol(symb, ssymb, true, format_fcn)
      return self.ftable
   end
end

function program_class:execute(batches, batch)
   if self.options.trigger then
      while not self.options.trigger() do
         print("sleeping")
         luautil.sleep(self.options.wait / 1000)
      end
   end
   
   for k, v in pairs(self.commands) do
      v:execute(batch, self)
   end
end

function program_class:print()
   logger:message(" Program : [" .. self.name .. "]")
   for k, v in pairs(self.templates) do
      logger:message("   Template : " .. v.ttype .. " " .. v.path)
   end
   if self.variables then
      if type(self.variables) == "table" then
         for k, v in pairs(self.variables) do
            logger:message("   Variable : " .. v)
         end
      end
   end
   self.symbol_table:print()
   logger:message("   Commands : ")
   for k, v in pairs(self.commands) do
      v:print()
   end
end

local function range(from, to)
   local t = {}
   for i = from, to do
      table.insert(t, i)
   end
   return t
end

local function wait_files_setter(...)
   local t_outer = pack( ... )
   return function()
      return util.check_all(t_outer, function(v) return filesystem.exists(v) end, "and")
   end
end

--local function wait_slurm_jobs_setter(...)
--   local t_outer = pack(...)
--   return function()
--      return check_all(t_outer, function(v) return slurm.job_completed(v) end, "and")
--   end
--end

---
--
--
local batches_class = class.create_class(creator_class)

function batches_class:__init()
   -- Util
   self.log_format = "newline"

   -- General stuff
   self.variables = { }
   self.directory = ""
   self.templates = { }
   
   -- 
   self.symbol_table = symbol_table_class:create()
   self.path_handler = path_handler_class:create()
   
   -- 
   --self.batches  = { }
   self.programs = { }
   
   -- Function table for loading package
   self.ftable = {
      --
      variable  = self:variable_setter(),
      --batch     = self:batches_setter(),
      program   = self:program_setter(),
      template  = self:element_setter("templates", 3),
      directory = self:string_setter ("directory"),
      define    = self:define_setter(),

      -- util
      print    = print,
      pairs    = pairs,
      range    = range,
      tonumber = tonumber,
      tostring = tostring,

      -- trigger functions
      wait_files      = wait_files_setter,
      --wait_slurm_jobs = wait_slurm_jobs_setter,

      --
      symbol = self.symbol_table.ftable,
   }
end

function batches_class:variable_setter()
   return function(name, variables, format_fcn)
      if self.variables[name] ~= nil then
         self.variables[name]:append(variables)
         if type(format_fcn) == "function" then
            if not self.variables[name].format_fcn then
               self.variables[name].format_fcn = format_fcn
            else
               logger:alert("Format function for variable '" .. name .. "' already set!")
               assert(false)
            end
         end
      else
         self.variables[name] = variable_class:create()
         self.variables[name].name       = name
         if type(format_fcn) == "function" then
            self.variables[name].format_fcn = format_fcn
         end
         self.variables[name]:append(variables)
      end
      return self.ftable
   end
end

function batches_class:batches_setter()
   return function(b)
      local batch = batch_class:create()
      for k, v in pairs(b) do
         batch.symbol_table:add_symbol(k, v)
      end
      batch.ftable.pop = self.ftable
      table.insert(self.batches, batch)
      return batch.ftable
   end
end

function batches_class:program_setter()
   return function(p, options, variables)
      if type(p) ~= "string" then
         assert(false)
      end

      local program = program_class:create()
      program.name         = p
      program.path_handler = self.path_handler
      program.ftable.pop   = self.ftable
      
      if options then
         if type(options) == "table" then
            program.options = options
         elseif type(options) == "string" then
            program.options = { options }
         else
            error("Unknown options type '" .. type(options) .. "'.")
         end
      end
      
      if variables then
         if type(variables) == "string" then
            if variables == "once" then
               program.variables = "once"
            else
               program.variables = { variables }
            end
         elseif type(variables) == "table" then
            program.variables = variables
         else
            error("Unknown options type '" .. type(options) .. "'.")
         end
      end

      table.insert(self.programs, program)
      return program.ftable
   end
end

function batches_class:define_setter()
   return function(symb, ssymb, format_fcn)
      self.symbol_table:add_symbol(symb, ssymb, true, format_fcn)
      return self.ftable
   end
end


---

function batches_class:map_all(fcn, tab, tabs)
   local function map_all_impl(fcn, tab, tabs, idx, ...) 
       if idx < 1 then
           fcn(...)
       else
           local t = tab[tabs[idx]]
           if not t then
              logger:alert("Variable : '" .. tabs[idx] .. "' not found.")
              assert(false)
           end
           for k, v in pairs(t.variables) do
              map_all_impl(fcn, tab, tabs, idx - 1, { key = t.name, value = v, format_fcn = t.format_fcn }, ...) 
           end
       end
   end

   if tabs == nil then
      tabs = {}
      for k, v in pairs(tab) do
         table.insert(tabs, k)
      end
   end

   map_all_impl(fcn, tab, tabs, #tabs)
end

function batches_class:count_all(tab, tabs)
   if tabs == nil then
      tabs = {}
      for k, v in pairs(tab) do
         table.insert(tabs, k)
      end
   end

   local count = 1
   for ktab, vtab in pairs(tab) do
      for ktabs, vtabs in pairs(tabs) do
         if ktab == vtabs then
            count = count * #(vtab.variables)
         end
      end
   end

   return count
end

--- Helper function for checking whether program should be run
--
local function check_program_match(vp, program)
   if util.is_empty(program) then
      if vp.options.callable then
         return false
      else
         return true
      end
   end
   
   for o_key, o_value in pairs(program) do
      if o_value == vp.name then
         return true
      end
   end

   return false
end

--- Execute dry run
--
--
function batches_class:execute_dry(program)
   local function run_program_dry(vp)
      local count = nil

      if vp.variables == nil then
         count = self:count_all(self.variables)
      elseif type(vp.variables) == "table" then
         count = self:count_all(self.variables, vp.variables)
      elseif type(vp.variables) == "string" then
         if vp.variables == "once" then
            count = self:count_all({ dummy = { name = "dummy", variables = { "dummy" } } })
         else
            logger:alert("Unknown string '" .. vp.variables .. "' for program varibales parameter.")
            assert(false)
         end
      else
         logger:alert("Program parameter 'variables' is unknown type.")
         assert(false)
      end

      logger:message("Program '" .. vp.name .. "' will be run " .. tostring(count) .. " times.")
   end

   for kp, vp in pairs(self.programs) do
      if check_program_match(vp, program) then
         run_program_dry(vp)
      end
   end
end

---
function batches_class:execute(program)
   logger:message("Executing batches.")

   for kp, vp in pairs(self.programs) do
      if check_program_match(vp, program) then
         local function run_batch(...)
            local p     = pack( ... )
            local batch = batch_class:create()
            for k, v in pairs(p) do
               if type(v.key) == "table" then
                  for kk, vk in pairs(v.key) do
                     batch.symbol_table:add_symbol(v.key[kk], v.value[kk], true, v.format_fcn)
                  end
               else
                  batch.symbol_table:add_symbol(v.key, v.value, true, v.format_fcn)
               end
            end
            batch.symbol_table:merge(vp.symbol_table)
            batch.symbol_table:merge(self.symbol_table)
            
            logger:message("Running batch ")
            batch:print()
            
            self.path_handler:pop_all()
            self.path_handler:push(self.directory)
            vp:execute(self, batch)
         end

         if vp.variables == nil then
            self:map_all(run_batch, self.variables)
         elseif type(vp.variables) == "table" then
            self:map_all(run_batch, self.variables, vp.variables)
         elseif type(vp.variables) == "string" then
            if vp.variables == "once" then
               self:map_all(run_batch, { dummy = { name = "dummy", variables = { "dummy" } } })
            else
               logger:alert("Unknown string '" .. vp.variables .. "' for program varibales parameter.")
               assert(false)
            end
         else
            logger:alert("Program parameter 'variables' is unknown type.")
            assert(false)
         end
      end
   end
end

function batches_class:load(batches_path, symbols)
   --assert(type(batches_path) == "string")
   self.name = "config"
   self.path_handler:pop_all()
   self.path_handler:push(filesystem.cwd())
   
   -- Load config files
   self.paths = {}
   for k, v in pairs(batches_path) do
      local batch_path = ""
      
      if path.is_abs_path(v) then
         batch_path = v
      else
         batch_path = path.join(filesystem.cwd(), v)
      end

      table.insert(self.paths, batch_path)
      
      local env  = self.ftable
      local file = dofile_into_environment(batch_path, env)
      
      if env[self.name] then
         env[self.name]()
      else
         logger:alert("Could not load.")
      end
   end

   -- Setup directory
   if util.isempty(self.directory) then
      self.directory = filesystem.cwd()
   end
   
   -- Fix symbol table
   for k, v in pairs(self.paths) do
      self.symbol_table:add_symbol("config_path_" .. tostring(k), v)
   end
   if #batches_path == 1 then -- backward compatibility
      self.symbol_table:add_symbol("config_path", self.paths[1])
   end
   
   self.symbol_table:add_symbol("uid", generate_uid("xxxx"))
   if symbols ~= nil then
      for k, v in pairs(symbols) do
         local s = util.split(v, "=")
         self.symbol_table:add_symbol(s[1], s[2], true)
      end
   end
end

--
function batches_class:print()
   logger:message(" Batches :")
   logger:message("   Directory : " .. self.directory)
   for k, v in pairs(self.templates) do
      logger:message("   Template : " .. v[1] .. " " .. v[2] .. " " .. v[3])
   end

   self.symbol_table:print()

   for k, v in pairs(self.variables) do
      v:print()
   end
   
   for k, v in pairs(self.programs) do
      v:print()
   end
end

local function load_batches(path, symbols)
   local bt = batches_class:create()
   bt:load(path, symbols)
   return bt
end

--- Create the module
M.load_batches       = load_batches

-- return module
return M
