# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config

--path:"src"

# Snapshot observers copy owned strings and sequences across thread boundaries.
switch("deepcopy", "on")
