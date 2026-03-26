local okUtf8, utf8lib = pcall(require, "utf8")
local utf8 = okUtf8 and utf8lib or _G.utf8

local Editor = {}
Editor.__index = Editor

local function clamp(v, lo, hi)
  if v < lo then
    return lo
  end
  if v > hi then
    return hi
  end
  return v
end

local function safeByteOffset(text, charIndex)
  if charIndex <= 0 then
    return 1
  end
  local offset = utf8 and utf8.offset and utf8.offset(text, charIndex + 1) or nil
  if offset then
    return offset
  end
  return #text + 1
end

local function charCount(text)
  if type(text) ~= "string" or text == "" then
    return 0
  end
  if utf8 and utf8.len then
    local len = utf8.len(text)
    if len then
      return len
    end
  end
  local count = 0
  for _ in text:gmatch("[\1-\127\194-\244][\128-\191]*") do
    count = count + 1
  end
  return count
end

local function sliceText(text, startIndex, endIndex)
  local startByte = safeByteOffset(text, startIndex)
  local endByte = safeByteOffset(text, endIndex + 1) - 1
  if endByte < startByte then
    return ""
  end
  return text:sub(startByte, endByte)
end

local function splitLines(text)
  local lines = {}
  local startByte = 1
  local startIndex = 0
  while true do
    local newlineByte = text:find("\n", startByte, true)
    if newlineByte then
      local segment = text:sub(startByte, newlineByte - 1)
      local len = charCount(segment)
      lines[#lines + 1] = {
        text = segment,
        startIndex = startIndex,
        length = len
      }
      startIndex = startIndex + len + 1
      startByte = newlineByte + 1
    else
      local segment = text:sub(startByte)
      local len = charCount(segment)
      lines[#lines + 1] = {
        text = segment,
        startIndex = startIndex,
        length = len
      }
      break
    end
  end
  if #lines == 0 then
    lines[1] = {
      text = "",
      startIndex = 0,
      length = 0
    }
  end
  return lines
end

local function isWordChar(ch)
  return ch:match("[%w_]") ~= nil
end

function Editor.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Editor)
  self.text = tostring(opts.text or "")
  self.placeholder = tostring(opts.placeholder or "")
  self.cursor = charCount(self.text)
  self.anchor = self.cursor
  self.focused = opts.focused == true
  self.dragging = false
  self.scrollX = 0
  self.scrollY = 0
  self.preferredColumn = nil
  self.preferredVisualX = nil
  self.rect = {
    x = 0,
    y = 0,
    w = 100,
    h = 32
  }
  self.paddingX = tonumber(opts.paddingX or 14) or 14
  self.paddingY = tonumber(opts.paddingY or 14) or 14
  self.lineGap = tonumber(opts.lineGap or 4) or 4
  self.scrollbarSize = tonumber(opts.scrollbarSize or 10) or 10
  self.font = opts.font
  self.softWrap = opts.softWrap ~= false
  self.tabString = tostring(opts.tabString or "  ")
  self.maxHistory = tonumber(opts.maxHistory or 200) or 200
  self.undoStack = {}
  self.redoStack = {}
  self.lastClickTime = 0
  self.lastClickIndex = -1
  self.clickCount = 0
  self._lines = nil
  self._visualLines = nil
  self._visualLayoutWidth = nil
  return self
end

function Editor:invalidateLayout()
  self._lines = nil
  self._visualLines = nil
  self._visualLayoutWidth = nil
end

function Editor:setFont(font)
  self.font = font
  self:invalidateLayout()
end

function Editor:setRect(x, y, w, h)
  self.rect.x = tonumber(x or 0) or 0
  self.rect.y = tonumber(y or 0) or 0
  self.rect.w = tonumber(w or 0) or 0
  self.rect.h = tonumber(h or 0) or 0
  self:invalidateLayout()
  self:ensureCursorVisible()
end

function Editor:getText()
  return self.text
end

function Editor:setText(text)
  self.text = tostring(text or "")
  self.cursor = charCount(self.text)
  self.anchor = self.cursor
  self.scrollX = 0
  self.scrollY = 0
  self.preferredColumn = nil
  self.preferredVisualX = nil
  self.undoStack = {}
  self.redoStack = {}
  self:invalidateLayout()
end

function Editor:clear()
  self:setText("")
end

function Editor:focus()
  self.focused = true
end

function Editor:blur()
  self.focused = false
  self.dragging = false
end

function Editor:hasSelection()
  return self.cursor ~= self.anchor
end

function Editor:getSelectionRange()
  if self.cursor < self.anchor then
    return self.cursor, self.anchor
  end
  return self.anchor, self.cursor
end

function Editor:selectAll()
  self.anchor = 0
  self.cursor = charCount(self.text)
  self:ensureCursorVisible()
end

function Editor:setCursor(index, keepSelection)
  local len = charCount(self.text)
  self.cursor = clamp(tonumber(index or 0) or 0, 0, len)
  if not keepSelection then
    self.anchor = self.cursor
  end
end

function Editor:getLines()
  if self._lines then
    return self._lines
  end
  self._lines = splitLines(self.text)
  return self._lines
end

function Editor:getLineHeight()
  if not self.font then
    return 16
  end
  return self.font:getHeight() + self.lineGap
end

function Editor:getViewportSize()
  local innerW = math.max(8, self.rect.w - self.paddingX * 2)
  local innerH = math.max(8, self.rect.h - self.paddingY * 2)
  local visualLines = self:getVisualLines(innerW)
  local needsV = self:getLineHeight() * #visualLines > innerH
  local wrapWidth = innerW - (needsV and self.scrollbarSize or 0)
  visualLines = self:getVisualLines(wrapWidth)
  local maxLineWidth = self:getLongestVisualLineWidth(visualLines)
  local needsH = (not self.softWrap) and maxLineWidth > wrapWidth
  if needsV then
    innerW = innerW - self.scrollbarSize
  end
  if needsH then
    innerH = innerH - self.scrollbarSize
  end
  return math.max(8, innerW), math.max(8, innerH), needsH, needsV
end

function Editor:getLongestVisualLineWidth(visualLines)
  if not self.font then
    return 0
  end
  local width = 0
  for i = 1, #visualLines do
    width = math.max(width, self.font:getWidth(visualLines[i].text))
  end
  return width
end

function Editor:getVisualLines(wrapWidth)
  local width = tonumber(wrapWidth or 0) or 0
  if width <= 0 then
    width = math.max(8, self.rect.w - self.paddingX * 2)
  end
  if self._visualLines and self._visualLayoutWidth == width then
    return self._visualLines
  end

  local logical = self:getLines()
  local visual = {}
  for i = 1, #logical do
    local line = logical[i]
    if not self.softWrap or not self.font or line.text == "" then
      visual[#visual + 1] = {
        text = line.text,
        startIndex = line.startIndex,
        length = line.length,
        logicalLine = i
      }
    else
      local _, wrapped = self.font:getWrap(line.text, width)
      if type(wrapped) ~= "table" or #wrapped == 0 then
        visual[#visual + 1] = {
          text = line.text,
          startIndex = line.startIndex,
          length = line.length,
          logicalLine = i
        }
      else
        local consumed = 0
        for j = 1, #wrapped do
          local seg = wrapped[j]
          local segLen = charCount(seg)
          visual[#visual + 1] = {
            text = seg,
            startIndex = line.startIndex + consumed,
            length = segLen,
            logicalLine = i
          }
          consumed = consumed + segLen
        end
        if consumed < line.length then
          visual[#visual + 1] = {
            text = sliceText(line.text, consumed, line.length - 1),
            startIndex = line.startIndex + consumed,
            length = line.length - consumed,
            logicalLine = i
          }
        end
      end
    end
  end
  if #visual == 0 then
    visual[1] = {
      text = "",
      startIndex = 0,
      length = 0,
      logicalLine = 1
    }
  end

  self._visualLines = visual
  self._visualLayoutWidth = width
  return visual
end

function Editor:getMaxScroll()
  local visibleW, visibleH = self:getViewportSize()
  local visualLines = self:getVisualLines(visibleW)
  local maxX = math.max(0, self:getLongestVisualLineWidth(visualLines) - visibleW)
  local maxY = math.max(0, #visualLines * self:getLineHeight() - visibleH)
  return maxX, maxY
end

function Editor:indexToLineColumn(index)
  local clamped = clamp(index, 0, charCount(self.text))
  local lines = self:getLines()
  for i = 1, #lines do
    local nextLine = lines[i + 1]
    if not nextLine or clamped < nextLine.startIndex then
      return i, clamp(clamped - lines[i].startIndex, 0, lines[i].length), lines[i]
    end
  end
  local last = lines[#lines]
  return #lines, last.length, last
end

function Editor:lineColumnToIndex(lineNumber, column)
  local lines = self:getLines()
  local line = lines[clamp(lineNumber, 1, #lines)]
  return line.startIndex + clamp(column, 0, line.length)
end

function Editor:getColumnWidth(lineText, column)
  if not self.font then
    return 0
  end
  return self.font:getWidth(sliceText(lineText, 0, column - 1))
end

function Editor:indexToVisualLine(index, wrapWidth)
  local clamped = clamp(index, 0, charCount(self.text))
  local visualLines = self:getVisualLines(wrapWidth)
  for i = 1, #visualLines do
    local line = visualLines[i]
    if clamped >= line.startIndex and clamped <= line.startIndex + line.length then
      return i, clamp(clamped - line.startIndex, 0, line.length), line
    end
  end
  local last = visualLines[#visualLines]
  return #visualLines, last.length, last
end

function Editor:visualLineColumnToIndex(visualLineNumber, column, wrapWidth)
  local visualLines = self:getVisualLines(wrapWidth)
  local line = visualLines[clamp(visualLineNumber, 1, #visualLines)]
  return line.startIndex + clamp(column, 0, line.length)
end

function Editor:pushUndoState()
  local snapshot = {
    text = self.text,
    cursor = self.cursor,
    anchor = self.anchor,
    scrollX = self.scrollX,
    scrollY = self.scrollY
  }
  local top = self.undoStack[#self.undoStack]
  if top and top.text == snapshot.text and top.cursor == snapshot.cursor and top.anchor == snapshot.anchor then
    return
  end
  self.undoStack[#self.undoStack + 1] = snapshot
  if #self.undoStack > self.maxHistory then
    table.remove(self.undoStack, 1)
  end
  self.redoStack = {}
end

function Editor:restoreSnapshot(snapshot)
  if type(snapshot) ~= "table" then
    return
  end
  self.text = tostring(snapshot.text or "")
  self.cursor = clamp(tonumber(snapshot.cursor or 0) or 0, 0, charCount(self.text))
  self.anchor = clamp(tonumber(snapshot.anchor or self.cursor) or self.cursor, 0, charCount(self.text))
  self.scrollX = math.max(0, tonumber(snapshot.scrollX or 0) or 0)
  self.scrollY = math.max(0, tonumber(snapshot.scrollY or 0) or 0)
  self.preferredColumn = nil
  self.preferredVisualX = nil
  self:invalidateLayout()
  self:ensureCursorVisible()
end

function Editor:undo()
  local snapshot = table.remove(self.undoStack)
  if not snapshot then
    return false
  end
  self.redoStack[#self.redoStack + 1] = {
    text = self.text,
    cursor = self.cursor,
    anchor = self.anchor,
    scrollX = self.scrollX,
    scrollY = self.scrollY
  }
  self:restoreSnapshot(snapshot)
  return true
end

function Editor:redo()
  local snapshot = table.remove(self.redoStack)
  if not snapshot then
    return false
  end
  self.undoStack[#self.undoStack + 1] = {
    text = self.text,
    cursor = self.cursor,
    anchor = self.anchor,
    scrollX = self.scrollX,
    scrollY = self.scrollY
  }
  self:restoreSnapshot(snapshot)
  return true
end

function Editor:deleteSelection()
  if not self:hasSelection() then
    return false
  end
  local startIndex, endIndex = self:getSelectionRange()
  local total = charCount(self.text)
  self.text = sliceText(self.text, 0, startIndex - 1) .. sliceText(self.text, endIndex, total - 1)
  self.cursor = startIndex
  self.anchor = startIndex
  self.preferredColumn = nil
  self.preferredVisualX = nil
  self:invalidateLayout()
  return true
end

function Editor:insertText(value)
  local insert = tostring(value or "")
  self:pushUndoState()
  self:deleteSelection()
  local cursor = self.cursor
  local total = charCount(self.text)
  self.text = sliceText(self.text, 0, cursor - 1) .. insert .. sliceText(self.text, cursor, total - 1)
  local added = charCount(insert)
  self.cursor = cursor + added
  self.anchor = self.cursor
  self.preferredColumn = nil
  self.preferredVisualX = nil
  self:invalidateLayout()
  self:ensureCursorVisible()
end

function Editor:getSelectedText()
  if not self:hasSelection() then
    return ""
  end
  local startIndex, endIndex = self:getSelectionRange()
  return sliceText(self.text, startIndex, endIndex - 1)
end

function Editor:selectWordAt(index)
  local total = charCount(self.text)
  local pos = clamp(index, 0, total)
  if total == 0 then
    self.anchor = 0
    self.cursor = 0
    return
  end
  if pos == total and pos > 0 then
    pos = pos - 1
  end
  local ch = sliceText(self.text, pos, pos)
  if ch == "" then
    return
  end
  local matcher = isWordChar(ch) and isWordChar or function(c)
    return c ~= "" and c ~= " " and c ~= "\n" and c ~= "\t"
  end
  local startIndex = pos
  while startIndex > 0 and matcher(sliceText(self.text, startIndex - 1, startIndex - 1)) do
    startIndex = startIndex - 1
  end
  local endIndex = pos + 1
  while endIndex < total and matcher(sliceText(self.text, endIndex, endIndex)) do
    endIndex = endIndex + 1
  end
  self.anchor = startIndex
  self.cursor = endIndex
  self:ensureCursorVisible()
end

function Editor:selectLineAt(index)
  local lineNumber, _, line = self:indexToLineColumn(index)
  self.anchor = line.startIndex
  self.cursor = line.startIndex + line.length
  if lineNumber < #self:getLines() then
    self.cursor = self.cursor + 1
  end
  self:ensureCursorVisible()
end

function Editor:ensureCursorVisible()
  local visibleW, visibleH = self:getViewportSize()
  local visualLineNumber, column, line = self:indexToVisualLine(self.cursor, visibleW)
  local cursorX = self:getColumnWidth(line.text, column)
  local cursorY = (visualLineNumber - 1) * self:getLineHeight()
  if not self.softWrap then
    if cursorX < self.scrollX then
      self.scrollX = cursorX
    elseif cursorX > self.scrollX + visibleW - 6 then
      self.scrollX = cursorX - visibleW + 6
    end
  else
    self.scrollX = 0
  end
  if cursorY < self.scrollY then
    self.scrollY = cursorY
  elseif cursorY + self:getLineHeight() > self.scrollY + visibleH then
    self.scrollY = cursorY + self:getLineHeight() - visibleH
  end
  local maxX, maxY = self:getMaxScroll()
  self.scrollX = clamp(self.scrollX, 0, maxX)
  self.scrollY = clamp(self.scrollY, 0, maxY)
end

function Editor:indexFromPoint(px, py)
  local visibleW, visibleH = self:getViewportSize()
  local visualLines = self:getVisualLines(visibleW)
  local maxWidth = self.softWrap and visibleW or math.max(visibleW, self:getLongestVisualLineWidth(visualLines))
  local localX = clamp(px - (self.rect.x + self.paddingX) + self.scrollX, 0, maxWidth)
  local localY = clamp(py - (self.rect.y + self.paddingY) + self.scrollY, 0, math.max(visibleH, #visualLines * self:getLineHeight()))
  local visualLineNumber = clamp(math.floor(localY / self:getLineHeight()) + 1, 1, #visualLines)
  local line = visualLines[visualLineNumber]
  local bestColumn = line.length
  local bestDistance = math.huge
  for column = 0, line.length do
    local width = self:getColumnWidth(line.text, column)
    local distance = math.abs(width - localX)
    if distance < bestDistance then
      bestDistance = distance
      bestColumn = column
    end
  end
  return self:visualLineColumnToIndex(visualLineNumber, bestColumn, visibleW)
end

function Editor:moveHorizontal(delta, keepSelection)
  if self:hasSelection() and not keepSelection then
    local startIndex, endIndex = self:getSelectionRange()
    if delta < 0 then
      self:setCursor(startIndex, false)
    else
      self:setCursor(endIndex, false)
    end
  else
    self:setCursor(self.cursor + delta, keepSelection)
  end
  self.preferredColumn = nil
  self.preferredVisualX = nil
  self:ensureCursorVisible()
end

function Editor:moveVertical(delta, keepSelection)
  local visibleW = self:getViewportSize()
  local visualLineNumber, column, line = self:indexToVisualLine(self.cursor, visibleW)
  if self.preferredVisualX == nil then
    self.preferredVisualX = self:getColumnWidth(line.text, column)
  end
  local nextVisual = clamp(visualLineNumber + delta, 1, #self:getVisualLines(visibleW))
  local visualLine = self:getVisualLines(visibleW)[nextVisual]
  local bestColumn = visualLine.length
  local bestDistance = math.huge
  for i = 0, visualLine.length do
    local width = self:getColumnWidth(visualLine.text, i)
    local distance = math.abs(width - self.preferredVisualX)
    if distance < bestDistance then
      bestDistance = distance
      bestColumn = i
    end
  end
  self:setCursor(visualLine.startIndex + bestColumn, keepSelection)
  self:ensureCursorVisible()
end

function Editor:scrollBy(dx, dy)
  local maxX, maxY = self:getMaxScroll()
  self.scrollX = clamp(self.scrollX + (dx or 0), 0, maxX)
  self.scrollY = clamp(self.scrollY + (dy or 0), 0, maxY)
end

function Editor:textinput(t)
  if not self.focused or type(t) ~= "string" or t == "" then
    return false
  end
  self:insertText(t)
  return true
end

function Editor:keypressed(key)
  if not self.focused then
    return false
  end
  local len = charCount(self.text)
  local shift = love.keyboard.isDown("lshift") or love.keyboard.isDown("rshift")
  local mod = love.keyboard.isDown("lgui") or love.keyboard.isDown("rgui") or love.keyboard.isDown("lctrl") or love.keyboard.isDown("rctrl")

  if mod and key == "z" and shift then
    return self:redo()
  end
  if mod and key == "z" then
    return self:undo()
  end
  if mod and key == "y" then
    return self:redo()
  end
  if mod and key == "a" then
    self:selectAll()
    return true
  end
  if mod and key == "c" then
    if love.system and love.system.setClipboardText then
      love.system.setClipboardText(self:getSelectedText())
    end
    return true
  end
  if mod and key == "x" then
    if love.system and love.system.setClipboardText then
      love.system.setClipboardText(self:getSelectedText())
    end
    if self:hasSelection() then
      self:pushUndoState()
      self:deleteSelection()
      self:ensureCursorVisible()
    end
    return true
  end
  if mod and key == "v" then
    if love.system and love.system.getClipboardText then
      local text = love.system.getClipboardText()
      if type(text) == "string" and text ~= "" then
        self:insertText(text:gsub("\r\n", "\n"))
      end
    end
    return true
  end
  if key == "tab" then
    self:insertText(self.tabString)
    return true
  end
  if key == "left" then
    if mod then
      local lineNumber = self:indexToLineColumn(self.cursor)
      self:setCursor(self:lineColumnToIndex(lineNumber, 0), shift)
      self:ensureCursorVisible()
      return true
    end
    self:moveHorizontal(-1, shift)
    return true
  end
  if key == "right" then
    if mod then
      local lineNumber, _, line = self:indexToLineColumn(self.cursor)
      self:setCursor(self:lineColumnToIndex(lineNumber, line.length), shift)
      self:ensureCursorVisible()
      return true
    end
    self:moveHorizontal(1, shift)
    return true
  end
  if key == "up" then
    self:moveVertical(-1, shift)
    return true
  end
  if key == "down" then
    self:moveVertical(1, shift)
    return true
  end
  if key == "home" then
    if mod then
      self:setCursor(0, shift)
    else
      local lineNumber = self:indexToLineColumn(self.cursor)
      self:setCursor(self:lineColumnToIndex(lineNumber, 0), shift)
    end
    self:ensureCursorVisible()
    return true
  end
  if key == "end" then
    if mod then
      self:setCursor(len, shift)
    else
      local lineNumber, _, line = self:indexToLineColumn(self.cursor)
      self:setCursor(self:lineColumnToIndex(lineNumber, line.length), shift)
    end
    self:ensureCursorVisible()
    return true
  end
  if key == "pageup" then
    local _, visibleH = self:getViewportSize()
    local linesPerPage = math.max(1, math.floor(visibleH / self:getLineHeight()))
    self:moveVertical(-linesPerPage, shift)
    return true
  end
  if key == "pagedown" then
    local _, visibleH = self:getViewportSize()
    local linesPerPage = math.max(1, math.floor(visibleH / self:getLineHeight()))
    self:moveVertical(linesPerPage, shift)
    return true
  end
  if key == "return" or key == "kpenter" then
    self:insertText("\n")
    return true
  end
  if key == "backspace" then
    self:pushUndoState()
    if not self:deleteSelection() and self.cursor > 0 then
      self.anchor = self.cursor - 1
      self:deleteSelection()
    end
    self:ensureCursorVisible()
    return true
  end
  if key == "delete" then
    self:pushUndoState()
    if not self:deleteSelection() and self.cursor < len then
      self.anchor = self.cursor + 1
      self:deleteSelection()
    end
    self:ensureCursorVisible()
    return true
  end
  return false
end

function Editor:mousepressed(x, y, button)
  if button ~= 1 then
    return false
  end
  local inside = x >= self.rect.x and x <= self.rect.x + self.rect.w and y >= self.rect.y and y <= self.rect.y + self.rect.h
  if not inside then
    self:blur()
    return false
  end
  self:focus()
  local now = love.timer.getTime() or 0
  local index = self:indexFromPoint(x, y)
  if now - self.lastClickTime < 0.35 and math.abs(index - self.lastClickIndex) <= 1 then
    self.clickCount = self.clickCount + 1
  else
    self.clickCount = 1
  end
  self.lastClickTime = now
  self.lastClickIndex = index

  if self.clickCount >= 3 then
    self:selectLineAt(index)
    self.dragging = false
    return true
  end
  if self.clickCount == 2 then
    self:selectWordAt(index)
    self.dragging = false
    return true
  end

  self.dragging = true
  local shift = love.keyboard.isDown("lshift") or love.keyboard.isDown("rshift")
  self:setCursor(index, shift)
  self.preferredColumn = nil
  self.preferredVisualX = nil
  self:ensureCursorVisible()
  return true
end

function Editor:mousemoved(x, y)
  if not self.dragging then
    return false
  end
  self.cursor = self:indexFromPoint(x, y)
  self.preferredColumn = nil
  self.preferredVisualX = nil
  self:ensureCursorVisible()
  return true
end

function Editor:mousereleased(_, _, button)
  if button == 1 then
    self.dragging = false
  end
end

function Editor:wheelmoved(dx, dy)
  local lineStep = self:getLineHeight() * 2
  if dy ~= 0 then
    self:scrollBy(0, -dy * lineStep)
    return true
  end
  if dx ~= 0 then
    self:scrollBy(-dx * 48, 0)
    return true
  end
  return false
end

function Editor:draw(theme)
  theme = theme or {}
  local bg = theme.bg or { 0.13, 0.17, 0.23, 1 }
  local border = theme.border or { 0.24, 0.31, 0.42, 1 }
  local accent = theme.accent or { 0.39, 0.67, 1, 1 }
  local textColor = theme.text or { 0.93, 0.96, 1, 1 }
  local muted = theme.muted or { 0.67, 0.74, 0.84, 1 }
  local selection = theme.selection or { accent[1], accent[2], accent[3], 0.28 }
  local cursorColor = theme.cursor or accent
  local placeholderColor = theme.placeholder or muted

  local borderColor = self.focused and accent or border
  love.graphics.setColor(bg)
  love.graphics.rectangle("fill", self.rect.x, self.rect.y, self.rect.w, self.rect.h, 12, 12)
  love.graphics.setColor(borderColor)
  love.graphics.rectangle("line", self.rect.x, self.rect.y, self.rect.w, self.rect.h, 12, 12)

  local visibleW, visibleH, needsH, needsV = self:getViewportSize()
  local visualLines = self:getVisualLines(visibleW)
  local lineHeight = self:getLineHeight()
  local textX = self.rect.x + self.paddingX
  local textY = self.rect.y + self.paddingY
  local selectionStart, selectionEnd = self:getSelectionRange()
  local hasSelection = self:hasSelection()
  local barInset = 2
  local trackRadius = 4
  local previousFont = love.graphics.getFont and love.graphics.getFont() or nil

  if self.font and love.graphics.setFont then
    love.graphics.setFont(self.font)
  end

  love.graphics.setScissor(textX, textY, visibleW, visibleH)
  if self.text == "" then
    love.graphics.setColor(placeholderColor)
    love.graphics.print(self.placeholder, textX, textY)
  else
    for i = 1, #visualLines do
      local line = visualLines[i]
      local drawY = textY + (i - 1) * lineHeight - self.scrollY
      if drawY + lineHeight >= textY and drawY <= textY + visibleH then
        if hasSelection then
          local lineStart = line.startIndex
          local lineEnd = line.startIndex + line.length
          local overlapStart = math.max(selectionStart, lineStart)
          local overlapEnd = math.min(selectionEnd, lineEnd)
          if overlapEnd > overlapStart then
            local startCol = overlapStart - lineStart
            local endCol = overlapEnd - lineStart
            local selStartX = textX + self:getColumnWidth(line.text, startCol) - self.scrollX
            local selEndX = textX + self:getColumnWidth(line.text, endCol) - self.scrollX
            love.graphics.setColor(selection)
            love.graphics.rectangle("fill", selStartX, drawY, math.max(2, selEndX - selStartX), lineHeight - 1, 4, 4)
          end
        end
        love.graphics.setColor(textColor)
        love.graphics.print(line.text, textX - self.scrollX, drawY)
      end
    end
  end

  if self.focused and (math.floor((love.timer.getTime() or 0) * 2) % 2 == 0) then
    local visualLineNumber, column, line = self:indexToVisualLine(self.cursor, visibleW)
    local cursorX = textX + self:getColumnWidth(line.text, column) - self.scrollX
    local cursorY = textY + (visualLineNumber - 1) * lineHeight - self.scrollY
    love.graphics.setColor(cursorColor)
    love.graphics.rectangle("fill", cursorX, cursorY, 2, self.font:getHeight())
  end
  love.graphics.setScissor()

  if previousFont and love.graphics.setFont then
    love.graphics.setFont(previousFont)
  end

  if needsV then
    local totalHeight = #visualLines * lineHeight
    local trackX = self.rect.x + self.rect.w - self.scrollbarSize - 4 + barInset
    local trackY = textY + barInset
    local trackW = math.max(4, self.scrollbarSize - barInset * 2)
    local trackH = math.max(12, visibleH - barInset * 2)
    local thumbH = math.max(28, trackH * (visibleH / math.max(visibleH, totalHeight)))
    local maxY = math.max(1, totalHeight - visibleH)
    local thumbY = trackY + (trackH - thumbH) * (self.scrollY / maxY)
    love.graphics.setColor(border)
    love.graphics.rectangle("fill", trackX, trackY, trackW, trackH, trackRadius, trackRadius)
    love.graphics.setColor(accent)
    love.graphics.rectangle("fill", trackX, thumbY, trackW, thumbH, trackRadius, trackRadius)
  end

  if needsH then
    local totalWidth = self:getLongestVisualLineWidth(visualLines)
    local trackX = textX + barInset
    local trackY = self.rect.y + self.rect.h - self.scrollbarSize - 4 + barInset
    local trackW = math.max(12, visibleW - barInset * 2)
    local trackH = math.max(4, self.scrollbarSize - barInset * 2)
    local thumbW = math.max(28, trackW * (visibleW / math.max(visibleW, totalWidth)))
    local maxX = math.max(1, totalWidth - visibleW)
    local thumbX = trackX + (trackW - thumbW) * (self.scrollX / maxX)
    love.graphics.setColor(border)
    love.graphics.rectangle("fill", trackX, trackY, trackW, trackH, trackRadius, trackRadius)
    love.graphics.setColor(accent)
    love.graphics.rectangle("fill", thumbX, trackY, thumbW, trackH, trackRadius, trackRadius)
  end
end

return Editor
