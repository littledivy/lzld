liblzld.a:
	cc -c lzld.m -o lzld.o
	ar rcs liblzld.a lzld.o

clean:
	rm -f liblzld.a lzld.o

all: liblzld.a

.PHONY: clean all
