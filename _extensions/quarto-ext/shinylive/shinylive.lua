-- Notes:
-- * 2023/10/04 - Barret:
--   Always use `callShinyLive()` to call a shinylive extension.
--   `callPythonShinyLive()` and `callRShinyLive()` should not be used directly.
--   Instead, always use `callShinyLive()`.
-- * 2023/10/04 - Barret:
--   I could not get `error(msg)` to quit the current function execution and
--   bubble up the stack and stop. Instead, I am using `assert(false, msg)` to
--   achieve the desired behavior. Multi-line error messages should start with a
--   `\n` to keep the message in the same readable area.



-- `table` to organize flags to have code only run once.
local hasDoneSetup = { base = false, r = false, python = false, python_version = false }
-- `table` to store `{ version, assets_version }` for each language's extension.
-- If both `r` and `python` are used in the same document, then the
-- `assets_version` for each language must be the same.
local versions = { r = nil, python = nil }
-- Global variable for the codeblock-to-json.js script file location
local codeblockScript = nil
-- Global hash table to store app specific dependencies to avoid calling
-- `quarto.doc.attach_to_dependency()` multiple times for the same dependency.
local appSpecificDeps = {}

-- Python specific method to call py-shinylive
-- @param args: list of string arguments to pass to py-shinylive
-- @param input: string to pipe into to py-shinylive
function callPythonShinylive(args, input)
  -- Try calling `pandoc.pipe('shinylive', ...)` and if it fails, print a message
  -- about installing shinylive python package.
  local res
  local status, err = pcall(
    function()
      res = pandoc.pipe("shinylive", args, input)
    end
  )

  if not status then
    print(err)
    assert(false, "Error running 'shinylive' command. Perhaps you need to install the 'shinylive' Python package?")
  end

  return res
end

-- R specific method to call {r-shinylive}
-- @param args: list of string arguments to pass to r-shinylive
-- @param input: string to pipe into to r-shinylive
function callRShinylive(args, input)
  args = { "-e",
    "shinylive:::quarto_ext()",
    table.unpack(args) }

  -- Try calling `pandoc.pipe('Rscript', ...)` and if it fails, print a message
  -- about installing shinylive R package.
  local res
  local status, err = pcall(
    function()
      res = pandoc.pipe("Rscript", args, input)
    end
  )

  if not status then
    print(err)
    assert(false,
      "Error running 'Rscript' command. Perhaps you need to install the 'shinylive' R package?")
  end

  return res
end

-- Returns decoded object
-- @param language: "python" or "r"
-- @param args, input: see `callPythonShinylive` and `callRShinylive`
function callShinylive(language, args, input)
  if input == nil then
    input = ""
  end
  local res
  -- print("Calling " .. language .. " shinylive with args: " .. table.concat(args, " "))
  if language == "python" then
    res = callPythonShinylive(args, input)
  elseif language == "r" then
    res = callRShinylive(args, input)
  else
    assert(false, "Unknown language: " .. language)
  end

  -- Remove any unwanted output before the first curly brace or square bracket.
  -- print("res: " .. string.sub(res, 1, math.min(string.len(res), 100)) .. "...")
  local curly_start = string.find(res, "{", 0, true)
  local brace_start = string.find(res, "[", 0, true)
  local min_start
  if curly_start == nil then
    min_start = brace_start
  elseif brace_start == nil then
    min_start = curly_start
  else
    min_start = math.min(curly_start, brace_start)
  end
  if min_start == nil then
    local res_str = res
    if string.len(res) > 100 then
      res_str = string.sub(res, 1, 100) .. "... [truncated]"
    end
    assert(false,
      "\nCould not find start curly brace or start brace in " .. language .. " shinylive response:\n" ..
      res_str
    )
  end
  if min_start > 1 then
    res = string.sub(res, min_start)
  end

  -- Decode JSON object
  local result
  local status, err = pcall(
    function()
      result = quarto.json.decode(res)
    end
  )
  if not status then
    print("JSON string being parsed:")
    print(res)
    print("Error:")
    print(err)
    assert(false, "Error decoding JSON response from `shinylive` " .. language .. " package.")
  end
  return result
end

-- Do one-time setup for language agnostic html dependencies.
-- This should only be called once per document
-- @param language: "python" or "r"
function ensureBaseSetup(language)
  -- Quit early if already done
  if hasDoneSetup.base then
    return
  end
  hasDoneSetup.base = true

  -- Find the path to codeblock-to-json.ts and save it for later use.
  local infoObj = callShinylive(language, { "extension", "info" })
  -- Store the path to codeblock-to-json.ts for later use
  codeblockScript = infoObj.scripts['codeblock-to-json']
  -- Store the version info for later use
  versions[language] = { version = infoObj.version, assets_version = infoObj.assets_version }

  -- Add language-agnostic dependencies
  local baseDeps = getShinyliveBaseDeps(language)
  for idx, dep in ipairs(baseDeps) do
    quarto.doc.add_html_dependency(dep)
  end

  -- Add ext css dependency
  quarto.doc.add_html_dependency(
    {
      name = "shinylive-quarto-css",
      stylesheets = { "resources/css/shinylive-quarto.css" }
    }
  )
end

-- Do one-time setup for language specific html dependencies.
-- This should only be called once per document
-- @param language: "python" or "r"
function ensureLanguageSetup(language)
  ensureInitSetup(language)

  if hasDoneSetup[language] then
    return
  end
  hasDoneSetup[language] = true

  -- Only get the asset version value if it hasn't been retrieved yet.
  if versions[language] == nil then
    local infoObj = callShinylive(language, { "extension", "info" })
    versions[language] = { version = infoObj.version, assets_version = infoObj.assets_version }
  end
  -- Verify that the r-shinylive and py-shinylive supported assets versions match
  if
      (versions.r and versions.python) and
      ---@diagnostic disable-next-line: undefined-field
      versions.r.assets_version ~= versions.python.assets_version
  then
    error(
      "The shinylive R and Python packages must support the same Shinylive Assets version to be used in the same quarto document." ..
      "\nR" ..
      ---@diagnostic disable-next-line: undefined-field
      "\n\tShinylive package version: " .. versions.r.version ..
      ---@diagnostic disable-next-line: undefined-field
      "\n\tSupported ssets version: " .. versions.r.assets_version ..
      "\nPython" ..
      ---@diagnostic disable-next-line: undefined-field
      "\n\tShinylive package version: " .. versions.python.version ..
      ---@diagnostic disable-next-line: undefined-field
      "\n\tSupported ssets version: " .. versions.python.assets_version
    )
  end

  -- Add language-specific dependencies
  local langResources = callShinylive(language, { "extension", "language-resources" })
  for idx, resourceDep in ipairs(langResources) do
    -- No need to check for uniqueness.
    -- Each resource is only be added once and should already be unique.
    quarto.doc.attach_to_dependency("shinylive", resourceDep)
  end
end

function getShinyliveBaseDeps(language)
  -- Relative path from the current page to the root of the site. This is needed
  -- to find out where shinylive-sw.js is, relative to the current page.
  if quarto.project.offset == nil then
    assert(false, "The shinylive extension must be used in a Quarto project directory (with a _quarto.yml file).")
  end
  local deps = callShinylive(
    language,
    { "extension", "base-htmldeps", "--sw-dir", quarto.project.offset },
    ""
  )
  return deps
end

return {
  {
    CodeBlock = function(el)
      if not el.attr then
        -- Not a shinylive codeblock, return
        return
      end

      local language
      if el.attr.classes:includes("{shinylive-r}") then
        language = "r"
      elseif el.attr.classes:includes("{shinylive-python}") then
        language = "python"
      else
        -- Not a shinylive codeblock, return
        return
      end
      -- Setup language and language-agnostic dependencies
      ensureLanguageSetup(language)

      -- Convert code block to JSON string in the same format as app.json.
      local parsedCodeblockJson = pandoc.pipe(
        "quarto",
        { "run", codeblockScript, language },
        el.text
      )

      -- This contains "files" and "quartoArgs" keys.
      local parsedCodeblock = quarto.json.decode(parsedCodeblockJson)

      -- Find Python package dependencies for the current app.
      local appDeps = callShinylive(
        language,
        { "extension", "app-resources" },
        -- Send as piped input to the shinylive command
        quarto.json.encode(parsedCodeblock["files"])
      )

      -- Add app specific dependencies
      for idx, dep in ipairs(appDeps) do
        if not appSpecificDeps[dep.name] then
          appSpecificDeps[dep.name] = true
          quarto.doc.attach_to_dependency("shinylive", dep)
        end
      end

      if el.attr.classes:includes("{shinylive-python}") then
        el.attributes.engine = "python"
        el.attr.classes = pandoc.List()
        el.attr.classes:insert("shinylive-python")
      elseif el.attr.classes:includes("{shinylive-r}") then
        el.attributes.engine = "r"
        el.attr.classes = pandoc.List()
        el.attr.classes:insert("shinylive-r")
      end
      return el
    end
  }
}
