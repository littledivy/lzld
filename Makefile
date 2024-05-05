liblzld.a:
	cc -c lzld.c -o lzld.o
	ar rcs liblzld.a lzld.o
