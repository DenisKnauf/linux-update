
POSTINST_D ?= /etc/kernel/postinst.d
SBIN_D ?= /usr/local/sbin

all:
	@echo 'Nothing to do :)'

install:
	install --mode=0755 --directory $(D)$(POSTINST_D)
	install --mode=0755 postinst.d/* $(D)$(POSTINST_D)
	install --mode=0755 --directory $(D)$(SBIN_D)
	install --mode=0755 linux-update $(D)$(SBIN_D)
