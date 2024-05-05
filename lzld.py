import lief
import sys

bin = lief.parse(sys.argv[1])

bin.remove(lief.MachO.LOAD_COMMAND_TYPES.LOAD_DYLIB)
bin.write("./lzld")
