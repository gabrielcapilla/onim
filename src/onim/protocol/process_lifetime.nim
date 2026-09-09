import std/os except FileId

when defined(posix):
  import std/posix
elif defined(windows):
  import std/winlean

when defined(linux):
  proc setParentDeathSignal(
    option: cint, signal: culong, arg3, arg4, arg5: culong
  ): cint {.importc: "prctl", header: "<sys/prctl.h>".}

  const parentDeathSignalOption = 1.cint

proc terminateProcessNow*(code: int) {.noreturn.} =
  when defined(posix):
    posix.exitnow(cint(code))
  elif defined(windows):
    discard winlean.terminateProcess(winlean.getCurrentProcess(), code)
    quit(code)
  else:
    quit(code)

when defined(linux):
  proc bindToParentProcess*() {.inline.} =
    let parent = getppid()
    discard setParentDeathSignal(parentDeathSignalOption, culong(SIGTERM), 0, 0, 0)
    if getppid() != parent:
      exitnow(1)
