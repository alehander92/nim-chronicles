import
  times, strutils, typetraits, terminal, os,
  serialization/object_serialization, faststreams/[outputs, textio],
  chronicles/[options, log_output, textformats]

var outFile: File

type
  LogRecord*[OutputKind;
             timestamps: static[TimestampScheme],
             colors: static[ColorScheme]] = object
    output*: OutputStream
    levelText: string
    thread: string
    location: string
    content: string
    isLogGroup: bool
    logGroupName: string
    level: LogLevel
    taskId*: string
    when stackTracesEnabled:
      exception*: ref Exception

const
  minLevel = LogLevel.Debug

# const
#   # We work-around a Nim bug:
#   # The compiler claims that the `terminal` module is unused
#   styleBright = terminal.styleBright

# proc appendValueImpl[T](r: var LogRecord, value: T) =
#   mixin formatItIMPL

#   when value is ref Exception:
#     appendValueImpl(r, value.msg)
#     when stackTracesEnabled:
#       r.exception = value

#   elif value is SomeNumber:
#     r.add($value) # appendText(r, value)

#   elif value is object:
#     appendChar(r, '{')
#     var needsComma = false
#     enumInstanceSerializedFields(value, fieldName, fieldValue):
#       if needsComma: r.output.append ", "
#       append(r.output, fieldName)
#       append(r.output, ": ")
#       appendValueImpl(r, formatItIMPL fieldValue)
#       needsComma = true
#     appendChar(r, '}')

#   elif value is tuple:
#     discard

#   elif value is bool:
#     append(r.output, if value: "true" else: "false")

#   elif value is seq|array:
#     appendChar(r, '[')
#     for index, value in value.pairs:
#       if index > 0: r.output.append ", "
#       appendValueImpl(r, formatItIMPL value)
#     appendChar(r, ']')

#   elif value is string|cstring:
#     let
#       needsEscape = containsEscapedChars(value)
#       needsQuote = (value.find(quoteChars) > -1) or needsEscape
#     if needsQuote:
#       when r.output is OutputStream:
#         writeEscapedString(r.output, value)
#       else:
#         var quoted = ""
#         quoted.addQuoted value
#         r.output.append quoted
#     else:
#       r.output.append value

#   elif value is enum:
#     append(r.output, $value)

#   elif value is ref:
#     appendValueImpl(r, value[])
#   else:
#     const typeName = typetraits.name(T)
#     {.fatal: "The textlines format does not support the '" & typeName & "' type".}

# template appendValue(r: var LogRecord, value: auto) =
#   mixin formatItIMPL
#   appendValueImpl(r, formatItIMPL value)

# when false:
#   proc quoteIfNeeded(r: var LogRecord, value: ref Exception) =
#     r.stream.writeText value.name
#     r.stream.writeText '('
#     r.quoteIfNeeded value.msg
#     when not defined(js) and not defined(nimscript) and hostOS != "standalone":
#       r.stream.writeText ", "
#       r.quoteIfNeeded getStackTrace(value).strip
#     r.stream.writeText ')'

# proc appendFieldName*(r: var LogRecord, name: string) =
#   mixin append
#   r.output.append " "
#   when r.colors != NoColors:
#     let (color, bright) = levelToStyle(r.level)
#     setFgColor r, color, bright
#   r.output.append name
#   resetColors r
#   r.output.append "="

const
  # no good way to tell how much padding is going to be needed so we
  # choose an arbitrary number and use that - should be fine even for
  # 80-char terminals
  msgWidth = 32
  spaces = repeat(' ', msgWidth)
  threadColumnWidth = 8
  locationWidth = 32
  logGroupAroundNameWidth = 20

proc initLogRecord*(r: var LogRecord,
                    level: LogLevel,
                    topics, msg: string) {.gcsafe.} =
  {.gcsafe.}:
    if outFile.isNil:
        let logOutPath = if outPath == "": getAppFilename().extractFilename & ".log" else: outPath
        writeFile(logOutPath, "")
        outFile = open(logOutPath, fmAppend)

    r.level = level

    r.output = fileOutput(outFile)

    r.thread = "_".alignLeft(threadColumnWidth)
    r.levelText = ($level).capitalizeAscii

    let msgLen = msg.len
    if msgLen < msgWidth:
        r.content.add(msg)
        r.content.add(spaces[0 .. msgWidth - msgLen])
    else:
        r.content.add(msg[0 .. msgWidth - 3]) # .toOpenArray(0, msgWidth - 3))
        r.content.add(".. ")

    #   if topics.len > 0:
    #     r.output.append " topics=\""
    #     setFgColor(r, topicsColor, true)
    #     r.output.append topics
    #     resetColors(r)
    #     r.output.append "\""

proc setProperty*(r: var LogRecord, name: string, value: auto) =
  if r.level < minLevel: # LogLevel.Debug:
    return
#   r.appendFieldName name
  if name == "file":
    r.location = $value
  elif name == "threadName":
    r.thread = $value
  elif name == "tid":
    discard
  elif name == "logGroup":
    r.isLogGroup = true
    r.logGroupName = $value
  elif name == "repr" and r.content.strip == "send!":
    when value is string:
      r.content = value
  elif name == "taskId":
    r.taskId = $value
  else:
    when value is object:
      r.content.add(name & "=" & $value & " ")
    elif value is ref|ptr:
      r.content.add(name & "=" & value.repr & " ")
    elif value is string:
      r.content.add(name & "=\"" & $value & "\" ")
    else:
      r.content.add(name & "=" & value.repr & " ")
#   r.setFgColor propColor, true
#   r.appendValue value
#   r.resetColors

# copied and adapted from log_output
# with changed colors for TRACE/DEBUG
template localLevelToStyle(lvl: LogLevel): untyped =
  # Bright Black is gray
  # Light green doesn't display well on white consoles
  # Light yellow doesn't display well on white consoles
  # Light cyan is darker than green

  case lvl
  of TRACE: (fgBlack, true) # Bright Black is gray
  of DEBUG: (fgGreen, true)
  of INFO:  (fgWhite, false)
  of NOTICE:(fgMagenta, false)
  of WARN:  (fgYellow, false)
  of ERROR: (fgRed, true)
  of FATAL: (fgRed, false)
  of DEFAULT, NONE: (fgWhite, false)

# time |
proc flushRecord*(r: var LogRecord) =
  # <time:18> | <level:5> | <task-id:17> | <file:line:28> | ([<indentation space>]<message>:50)[<args>()]
  # for now no <thread>
  if r.level < minLevel: # Debug:
    return
  if not r.isLogGroup:
    # let (color, bright) = localLevelToStyle(r.level)
    # setFgColor(r, color, bright)
    when r.timestamps == UnixTime:
      let t = $epochTime()
    else:
      let t = "-1.0"
    r.output.append t.alignLeft(18) &  " | "
    r.output.append r.levelText.alignLeft(5) & " | "
    # r.output.append r.thread
    r.output.append r.taskId.alignLeft(17) & " | "
    r.output.append r.location.alignLeft(28) & " | "
    # r.resetColors
    r.output.append r.content
    # adapted from json_records.nim
    # echo r.timestamps == UnixTime
    r.output.append "\n"
  else:
    let repeatingCharacter = if r.content.len > 0: r.content[0] else: '='
    r.content = repeat(repeatingCharacter, logGroupAroundNameWidth) &
        " " & r.logGroupName & " " &
        repeat(repeatingCharacter, logGroupAroundNameWidth)
    r.output.append r.content
    r.output.append "\n"

  when stackTracesEnabled:
    if r.exception != nil:
      appendStackTrace(r)

  r.output.flush()
  # flushOutput r.OutputKind, r.output


