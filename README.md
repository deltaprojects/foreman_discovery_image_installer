# image installer for foreman discovery image

# TODO
fix readme.

### parted
parted v3.2 is built with following
edit parted/Makefile.am and find parted_LDFLAGS = $(PARTEDLDFLAGS)
add ' -all-static' to the line.
and patch http://www.linuxfromscratch.org/patches/blfs/7.6/parted-3.2-devmapper-1.patch
(http://www.linuxfromscratch.org/blfs/view/7.6/postlfs/parted.html)

./configure --disable-shared --disable-dynamic-loading --enable-static --enable-static=parted --enable-device-mapper=no
