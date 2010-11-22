--[[============================================================================
main.lua
============================================================================]]--

-- internal state

local dialog = nil
local vb = nil

_AUTO_RELOAD_DEBUG = function()
  dialog = nil
  vb = nil
end


--------------------------------------------------------------------------------
-- Menu entries
--------------------------------------------------------------------------------

renoise.tool():add_menu_entry {
  name = "Scripting Menu:File:Create New Tool...",
  invoke = function()
    show_dialog()
  end
}

renoise.tool():add_menu_entry {
  name = "Scripting Menu:File:Export to XRNX file...",
  invoke = function()
    show_zip_dialog()
  end
}

--[[ require ("formbuilder")

renoise.tool():add_menu_entry {
  name = "Main Menu:Tools:Development:Create Form...",
  invoke = function()
    show_builder()
  end
}

--]]


--------------------------------------------------------------------------------
-- Preferences (form defaults)
--------------------------------------------------------------------------------

local options = renoise.Document.create("ScriptingToolPreferences") {    
  ConfirmOverwrite = true,  
  Domain = "YourDomain",
  DefaultDomain = true,
  TLD = "com", 
  TLD_id = 1, 
  Email = "you@yourdomain.xyz",
  Desc = renoise.Document.ObservableStringList(),
  -- export options
  ExportOverwrite = true,
  ExportDefaultDestination = true
}
options:add_property("Name", "The Tool Name")
options:add_property("Id", "com.myorg.ToolName")        
options:add_property("Author", "My Name")
options:add_property("Category", "In Progress")
options:add_property("Description",  "Too lazy")
options:add_property("Homepage", "http://tools.renoise.com")
options:add_property("Icon", "")  

local categories = {"Pattern Editor", "Sample Editor", "Instruments", "Algorithmic composition"}

renoise.tool().preferences = options


--------------------------------------------------------------------------------
-- Manifest Document Structure
--------------------------------------------------------------------------------

class "RenoiseScriptingTool"(renoise.Document.DocumentNode)

  function RenoiseScriptingTool:__init()
  
    renoise.Document.DocumentNode.__init(self)     
    
    self:add_property("Name", "")
    self:add_property("Id", "")        
    self:add_property("Version", 1)
    self:add_property("ApiVersion", 1)
    self:add_property("Author", "")
    self:add_property("Category", "")
    self:add_property("Description", "Too lazy")
    self:add_property("Homepage", "")
    self:add_property("Icon", "")
  end
  
  function RenoiseScriptingTool:validate()
  end
  
  function RenoiseScriptingTool:update()      
    
    -- pre-processed fields
    self.Id.value = vb.views.name_preview.text:sub(1,-6)
    self.ApiVersion = renoise.API_VERSION       
    if (trim(options.Email.value) ~= "" and 
      options.Email.value ~= "you@yourdomain.xyz") then
      self.Author.value = options.Author.value .. " | " .. options.Email.value      
    else
      self.Author.value = options.Author.value    
    end
    
    -- copied fields
    self.Name.value = options.Name.value    
    self.Description.value = options.Description.value
    self.Category.value = options.Category.value    
    self.Homepage.value = options.Homepage.value
    self.Icon.value = options.Icon.value        
  end
  

local manifest = RenoiseScriptingTool()

  
--------------------------------------------------------------------------------
-- I/O and file system functions
--------------------------------------------------------------------------------

local MYTOOLS = "__MyTools__"

local SEP = "/"
if (os.platform() == "WINDOWS") then
  SEP = "\\"
end

-- Return the path of the "Tools" folder
-- The behavior of this function in situations involving symlinks 
--  or junctions was not determined.
function get_tools_root()    
  local dir = renoise.tool().bundle_path
  return dir:sub(1,dir:find("Tools")+5)      
end

local function create_folder(parent, child)
  if (parent == nil) then
    renoise.app():show_error("Parent folder was empty: " .. child)  
    return
  end
  local sep = ""
  if (parent:sub(-1) ~= SEP) then  
    sep = SEP
  end
  local path = parent..sep..child
  if (not io.exists(path)) then  
    if (not os.mkdir(path)) then
      renoise.app():show_error("Could not create the folder: " .. path)
      return
    end
  end    
  return path
end

-- If file exists, popup a modal dialog asking permission to overwrite.
local function may_overwrite(path)
  local overwrite = true
  if (io.exists(path) and options.ConfirmOverwrite.value) then
    local buttons = {"Overwrite", "Keep existing file" ,"Always Overwrite"}
    local choice = renoise.app():show_prompt("File exists", "The file\n\n " ..path .. " \n\n"
      .. "already exists. Overwrite existing file?", buttons)
    if (choice==buttons[3]) then 
       options.ConfirmOverwrite.value = false
    end
    overwrite = (choice~=buttons[2])
  end  
  return overwrite
end

-- Reads entire file into a string
-- (this function is binary safe)
local function file_get_contents(file_path)
  local mode = "rb"  
  local file_ref,err = io.open(file_path, mode)
  if not err then
    local data=file_ref:read("*all")        
    io.close(file_ref)    
    return data
  else
    return nil,err;
  end
end

-- Writes a string to a file
-- (this function is binary safe)
local function file_put_contents(file_path, data)
  local mode = "w+b" -- all previous data is erased
  local file_ref,err = io.open(file_path, mode)
  if not err then
    local ok=file_ref:write(data)
    io.flush(file_ref)
    io.close(file_ref)    
    return ok
  else
    return nil,err;
  end
end


local ERROR = {OK=1, FATAL=2, USER=3}
-- Copies the contents of one file into another file.
local function copy_file_to(source, target)      
  local error = nil
  local code = ERROR.OK
  if (not io.exists(source)) then    
    error = "The source file\n\n" .. source .. "\n\ndoes not exist"
    code = ERROR.FATAL
  end
  if (not error and may_overwrite(target)) then
    local source_data = file_get_contents(source, true)    
    local ok,err = file_put_contents(target, source_data)        
    error = err          
  else 
    code = ERROR.USER
  end
  return not error, error, code
end


--------------------------------------------------------------------------------
-- Tool creation functions
--------------------------------------------------------------------------------

local function create_tool()
  local root = get_tools_root()  
  local folder_name = vb.views.name_preview.text
  local my_tools = create_folder(root, MYTOOLS)
  local target_folder = create_folder(my_tools, folder_name)
  if (not target_folder) then
    return
  end
  
  manifest:update()
  
  if (may_overwrite(target_folder..SEP.."manifest.xml") and 
    not manifest:save_as(target_folder..SEP.."manifest.xml")) then
      renoise.app():show_error ("Could not create the manifest.xml file") 
      return
  end
  
  local lua_template = renoise.tool().bundle_path ..SEP.. "templates"..SEP.."main.lua"
  
  local ok, err, code = copy_file_to(lua_template, target_folder..SEP.."main.lua")
  if (err and code ~= ERROR.USER) then 
      renoise.app():show_error(err)  
      return
  end
  renoise.app():show_message("Your new Tool has been created: \n\n" .. target_folder)
end

function trim(s)  
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function clean_component(str)
  --str = str:gsub("[/\\%.;:%*%?%<%|%z=\"%[%]'&]+", "")
  str = str:gsub("[^%s%w-_!]", "")  
  return str
end

local function camel_case(str)  
  str = str or ""    
  local function tchelper(first, rest)
    return first:upper()..rest:lower()
  end
  -- Add extra characters to the pattern if you need to. _ and ' are
  --  found in the middle of identifiers and English words.
  -- We must also put %w_' into [%w_'] to make it handle normal stuff
  -- and extra stuff the same.
  -- This also turns hex numbers into, eg. 0Xa7d4  
  str = str:gsub("(%a)([%w_']*)", tchelper)
    
    -- Remove spaces
  str = str:gsub("%s+", "")
  return str
end


--------------------------------------------------------------------------------
-- GUI
--------------------------------------------------------------------------------

local DIALOG_BUTTON_HEIGHT = renoise.ViewBuilder.DEFAULT_DIALOG_BUTTON_HEIGHT
local DEFAULT_DIALOG_MARGIN = renoise.ViewBuilder.DEFAULT_DIALOG_MARGIN
local DEFAULT_CONTROL_SPACING = renoise.ViewBuilder.DEFAULT_CONTROL_SPACING

local function is_form_complete()
  local ok = false  
  ok = (nil ~= vb.views.name_preview.text:match("^[%w]+%.[%w%-_!]+%.[%w%-_!]+%.xrnx$"))  
  ok = ok and (trim(options.Description.value) ~= "")
  return ok
end

function autocomplete(text)  
  if (true or #text < 1) then return end
  local i = 1  
  while (categories[i]) do    
    local c = categories[i]    
    if (c:match("^"..text)) then
      --print(text .. " resembles " .. c)
      --vb.views.category_text:add_line(c)  
    end
    i = i+1
  end
end

function show_dialog()

  if dialog and dialog.visible then
    dialog:show()
    return
  end

  vb = renoise.ViewBuilder()

  local TEXT_ROW_WIDTH = 100
  local WIDE = 180

  local dialog_title = "Create New Tool"
  local dialog_buttons = {"Close"};
  
  -- view functions
  
  local function get_tld()
    local raw = nil
    if (vb.views.tld_text.visible) then
      raw = vb.views.tld_text.text
    else
      local id = vb.views.tld_popup.value      
      raw = vb.views.tld_popup.items[id]
    end
    raw = clean_component(raw)
    return trim(raw:gsub("[%s%-]+", ""):lower())
  end
  
  local function get_domain()
    local raw = nil
    if (not options.DefaultDomain.value) then
      raw = vb.views.domain_text.text  
    else 
      raw = vb.views.author_text.text
    end
    raw = clean_component(raw)
    return trim(raw:gsub("%s+", ""):lower())
  end
  
  local function get_tool_name()
    local raw = vb.views.tool_name_text.text  
    raw = clean_component(raw)    
    return camel_case(raw)
  end
  
  local function get_email()
    local raw = trim(vb.views.email_text.text)    
    if (raw ~= "" and not raw:match(
      "[A-Za-z0-9%.%%%+%-]+@[A-Za-z0-9%.%%%+%-]+%.%w%w%w?%w?"
      )) then
      renoise.app():show_warning("Invalid e-mail address")
    end
    return raw
  end
  
  local function update_preview()    
    vb.views.email_text.value = get_email()
    vb.views.author_text.value = trim(options.Author.value)      
    vb.views.tool_name_text.value = trim(options.Name.value)
    
    vb.views.name_preview.text = ("%s.%s.%s.xrnx"):format(                   
      get_tld(),
      get_domain(),
      get_tool_name()
    )
    
    options.TLD.value = get_tld()
    options.Domain.value = get_domain()
    options.Homepage.value = trim(vb.views.homepage_text.text)
    options.Category.value = trim(vb.views.category_text.text)
    options.Description.value = trim(vb.views.description_text.text)
    vb.views.save_button.active = is_form_complete()
  end


  -- dialog content

  local dialog_content = vb:column {
    margin = DEFAULT_DIALOG_MARGIN,
    spacing = DEFAULT_CONTROL_SPACING,
    uniform = true,      
    
    vb:column {            
      style = "panel",
      margin = 5,
      
      vb:text { 
        font = "bold",
        text = "Preview Package Name"       
      },     
      vb:text {
        id = "name_preview",
        text = "",
        font = "mono"
      },
       vb:text { 
        font = "italic", 
        text = "(Any disallowed characters are filtered out)" 
      }
    },
      
    vb:column {
      style = "group",
      margin = 5,      
      width = 240, -- prevent resize
      
      vb:text {
        text = "Give your new Tool a name",
        font = "bold"
      },
      
      vb:text { text = "Tool Name" },
      vb:textfield { 
        id = "tool_name_text", 
        bind = options.Name, 
        notifier = update_preview,                
      },
      
      vb:text {text= "Author"},
      vb:textfield { 
        id = "author_text",
        notifier = update_preview,
        bind = options.Author
      }, 
      
      vb:row {
        vb:text { text = "Domain/Organisation" },            
        vb:bitmap {bitmap = "images/info.bmp",  mode = "body_color"},
        tooltip = 
[[Companies use their reversed Internet domain name to begin their package 
names—for example, com.example.orion for a package named orion created by 
a programmer at example.com. 

The name of a package is not meant to imply where the package is stored within 
the Internet; for example, a package named edu.cmu.cs.bovik.cheese is not 
necessarily obtainable from Internet address cmu.edu or from cs.cmu.edu or 
from bovik.cs.cmu.edu. The suggested convention for generating unique package 
names is merely a way to piggyback a package naming convention on top of an 
existing, widely known unique name registry instead of having to create a 
separate registry for package names.]]
      },
      vb:row{
        vb:textfield { 
          id = "domain_text", 
          bind = options.Domain,
          visible = not options.DefaultDomain.value,
          notifier = update_preview,          
        },
        vb:checkbox { 
          id = "domain_checkbox",
          bind = options.DefaultDomain,
          notifier = function(c)
           vb.views.domain_text.visible = not options.DefaultDomain.value   
           update_preview()
          end 
        },      
        vb:text { text = "Same as Author"},              
           
      },
      
      vb:row { 
        vb:text {text= "Top Level Domain (TLD)"},
        vb:bitmap {bitmap = "images/info.bmp", mode = "body_color"},
        tooltip =  
[[The first component of a unique package name is always written in 
all-lowercase ASCII letters and should be one of the top level domain names, 
currently com, edu, gov, mil, net, org, or one of the English two-letter 
codes identifying countries as specified in ISO Standard 3166, 1981. For more 
information, refer to the documents stored at ftp://rs.internic.net/rfc, for 
example, rfc920.txt and rfc1032.txt.]]
      },
      vb:row {
        vb:textfield { 
          id ="tld_text", 
          visible = false,
          notifier = update_preview,          
          bind = options.TLD,
        },      
        vb:popup { id = "tld_popup", items = 
          {"com", "org", "net", "edu", "de", "nl", "fr", "it", "es", "uk", "Other..."},
          notifier = function(i)            
            vb.views.tld_text.visible = (i==#vb.views.tld_popup.items)                        
            update_preview()            
          end,
          bind = options.TLD_id
        },
      },      
    },      
    
    vb:column {
      style = "group",
      margin = 5,
      uniform = true,
    
      vb:text { 
        font = "bold",
        text = "Mandatory Manifest Fields",        
      },    
    
      vb:text { text = "Description" },
      vb:multiline_textfield  {
        id = "description_text",      
        height = 60, 
        bind = options.Desc,        
        notifier = function()           
           update_preview()
        end 
        --text = options.Description.value,               
      }    
    },
    
    vb:column {
      style = "group",
      margin = 5,
      uniform = true,
    
      vb:text { 
        font = "bold",
        text = "Optional Manifest Fields",        
      },    
      
      vb:text { text = "E-Mail" },
      vb:textfield {
        id = "email_text",
        bind = options.Email,
        notifier = update_preview
      },
      
      vb:text { text = "Homepage" },
      vb:textfield {
        id = "homepage_text",
        bind = options.Homepage,
        notifier = update_preview
      },     
      
      vb:text { text = "Category" },
      vb:textfield {        
        id = "category_text",        
        bind = options.Category,
        notifier = function(text)         
          autocomplete(text)
          update_preview()
        end
      }
    },
    vb:row{
      vb:button {
        id = "save_button",
        text = "Save and Create Tool",
        height = DIALOG_BUTTON_HEIGHT,
        active = is_form_complete(),
        notifier = function()        
          create_tool()
        end        
      },
      vb:button {
        text = "Preferences",
        height = DIALOG_BUTTON_HEIGHT,
        notifier = function()
          local vb = renoise.ViewBuilder()
          local content = vb:column {
            margin = 5,
            vb:horizontal_aligner {
              spacing = 5,              
              vb:checkbox {                
                bind = options.ConfirmOverwrite
              },
              vb:text { 
                text = "Ask before overwriting files and folders"
              }
            }
          }
          renoise.app():show_custom_prompt(
            "Preferences for the 'Create New Tool' Tool", content, {"Save and Close"})
        end        
      }
    }
  }
  
  
  -- init    
  if (options.TLD_id.value == #vb.views.tld_popup.items) then
    table.insert(vb.views.tld_popup.items, 1, options.TLD.value)    
    vb.views.tld_text.visible = true
  end        
  
  update_preview()

  -- key_handler
  local function key_handler(dialog, key)

  end


  -- show
  dialog = renoise.app():show_custom_dialog(
    dialog_title, dialog_content, key_handler)

end


--------------------------------------------------------------------------------
-- Export Tool folder to XRNX file (ZIP)
--------------------------------------------------------------------------------

local zip_dialog = nil

require "zip"

-- Create an XRNX file by ZIP'ing the Tool within the __MyTools__ folder
function zip_tool(path)      
  local source_folder = get_tools_root() .. MYTOOLS .. SEP .. path 
  local target_folder = get_tools_root()..MYTOOLS..SEP.."XRNX"
  
  -- browse to custom output folder 
  if (not options.ExportDefaultDestination.value) then
    target_folder = renoise.app():prompt_for_path("Choose")      
    print(type(target_folder), target_folder)
    if (not target_folder or target_folder == "") then
       return false, "Export operation was cancelled."
    end          
  end
  
  -- create output folder if it does not exist
  if (not io.exists(target_folder)) then
    os.mkdir(target_folder)
  end  
  
  -- strip trailing slash
  if (target_folder:sub(-1) == SEP) then
    target_folder = target_folder:sub(1,-2)
  end
  
  -- construct absolute output file path
  local destination = target_folder..SEP..path    
  
  -- ask to overwrite
  if (options.ExportOverwrite.value == false and io.exists(destination)) then
    local choice = renoise.app():show_prompt(
      "File exists", 
      "The file\n\n"..destination.."\n\nalready exists. Overwrite existing file?", 
      {"Overwrite", "Cancel"})
    if (choice ~= "Overwrite") then
      return false, "Export operation was cancelled."
    end
  end
  
  -- zip
  local ok, err = zip(source_folder, destination)
  if (not ok) then                      
    renoise.app():show_error(err)
  else
    local msg = "The XRNX file was succesfully created at the following location:\n\n"
      .. destination 
    renoise.app():show_message(msg)
  end
  return ok, err
end

-- Returns a list of Tool folders in the __MyTools__ folder
function get_mytools()
  local path = get_tools_root() .. MYTOOLS
  if (not io.exists(path)) then
    return {}
  end
  local t = os.dirnames(path)
  local list = table.create()
  for _,v in ipairs(t) do
    if (v:match("xrnx$")) then
      list:insert(v)
    end
  end      
  return list
end


-- GUI -----------

function show_zip_dialog()

  if zip_dialog and zip_dialog.visible then
    zip_dialog:show()
    return
  end

  vb = renoise.ViewBuilder()
  
  local dialog_title = "Export Tool folder to XRNX file"
  local dialog_content = vb:column {
    margin = DEFAULT_DIALOG_MARGIN,
    spacing = DEFAULT_CONTROL_SPACING,    
    
    vb:text {
      text = "Choose folder to export:"
    },   
    vb:popup {
      id = "mytools",
      items = get_mytools(),
      width = 260
    },
    vb:row { 
      spacing = DEFAULT_CONTROL_SPACING,
      vb:checkbox {                
        bind = options.ExportOverwrite
      },
      vb:text {
        text = "Overwrite existing files",        
      }
    },
    vb:row { 
      spacing = DEFAULT_CONTROL_SPACING,
      vb:checkbox {                
        bind = options.ExportDefaultDestination
      },
      vb:text {
        text = "Save files into default XRNX export folder",
      }
    },    
    vb:row {
      spacing = DEFAULT_CONTROL_SPACING,
      vb:button {
        text = "Export folder",
        height = DIALOG_BUTTON_HEIGHT,        
        notifier = function()
          local items = vb.views.mytools.items
          local id = vb.views.mytools.value        
          local ok,err = zip_tool(items[id])          
        end
      },
      vb:button {
        text = "Browse default XRNX export folder",
        height = DIALOG_BUTTON_HEIGHT,
        notifier = function()
          local path = get_tools_root()..MYTOOLS..SEP.."XRNX"
          if (not io.exists(path)) then
            os.mkdir(path)
          end
          renoise.app():open_path(path)
        end
      }
    }
  }
  
  zip_dialog = renoise.app():show_custom_dialog(
    dialog_title, dialog_content)

end  