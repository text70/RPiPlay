obj-m += snd-soc-pcm512x.o
snd-soc-pcm512x-objs := pcm512x.o

all:
	$(MAKE) -C /lib/modules/$(shell uname -r)/build M=$(PWD) modules
