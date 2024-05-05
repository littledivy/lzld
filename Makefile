liblzld.a:
	cc -c lzld.m -o lzld.o
	ar rcs liblzld.a lzld.o
