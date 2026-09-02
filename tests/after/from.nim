from std/os import getCurrentDir, walkDir

for k, v in walkDir(getCurrentDir()):
  echo k
