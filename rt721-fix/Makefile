KVER ?= $(shell uname -r)
KDIR ?= /usr/lib/modules/$(KVER)/build
all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules
clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
