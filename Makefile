REPO		?= riak_search
SEARCH_TAG	 = $(shell git describe --tags)
REVISION	?= $(shell echo $(SEARCH_TAG) | sed -e 's/^$(REPO)-//')
PKG_VERSION	?= $(shell echo $(REVISION) | tr - .)

.PHONY: rel stagedevrel deps package pkgclean

all: deps compile

compile:
	./rebar compile
	make -C apps/qilr/java_src

deps:
	./rebar get-deps

clean:
	./rebar clean
	make -C apps/qilr/java_src clean

distclean: clean devclean relclean ballclean
	./rebar delete-deps

test:
	./rebar skip_deps=true eunit

##
## Release targets
##
rel: deps
	make -C apps/qilr/java_src
	./rebar compile generate

rellink:
	$(foreach app,$(wildcard apps/*), rm -rf rel/riaksearch/lib/$(shell basename $(app))* && ln -sf $(abspath $(app)) rel/riaksearch/lib;)
	$(foreach dep,$(wildcard deps/*), rm -rf rel/riaksearch/lib/$(shell basename $(dep))* && ln -sf $(abspath $(dep)) rel/riaksearch/lib;)

relclean:
	rm -rf rel/riaksearch

##
## Developer targets
##
stagedevrel: dev1 dev2 dev3
	$(foreach dev,$^,\
	  $(foreach dep,$(wildcard deps/*), rm -rf dev/$(dev)/lib/$(shell basename $(dep))-* && ln -sf $(abspath $(dep)) dev/$(dev)/lib;))
	$(foreach dev,$^,\
	  $(foreach dep,$(wildcard apps/*), rm -rf dev/$(dev)/lib/$(shell basename $(dep))-* && ln -sf $(abspath $(dep)) dev/$(dev)/lib;))

devrel: dev1 dev2 dev3

dev1 dev2 dev3:
	mkdir -p dev
	(cd rel && ../rebar generate target_dir=../dev/$@ overlay_vars=vars/$@_vars.config)

devclean: clean
	rm -rf dev

stage : rel
	$(foreach app,$(wildcard apps/*), rm -rf rel/riaksearch/lib/$(shell basename $(app))-* && ln -sf $(abspath $(app)) rel/riaksearch/lib;)
	$(foreach dep,$(wildcard deps/*), rm -rf rel/riaksearch/lib/$(shell basename $(dep))-* && ln -sf $(abspath $(dep)) rel/riaksearch/lib;)


##
## Doc targets
##
docs:
	./rebar skip_deps=true doc
	@cp -R apps/luke/doc doc/luke
	@cp -R apps/riak_core/doc doc/riak_core
	@cp -R apps/riak_kv/doc doc/riak_kv

orgs: orgs-doc orgs-README

orgs-doc:
	@emacs -l orgbatch.el -batch --eval="(riak-export-doc-dir \"doc\" 'html)"

orgs-README:
	@emacs -l orgbatch.el -batch --eval="(riak-export-doc-file \"README.org\" 'ascii)"
	@mv README.txt README

APPS = kernel stdlib sasl erts ssl tools os_mon runtime_tools crypto inets \
	xmerl webtool snmp public_key mnesia eunit syntax_tools compiler
COMBO_PLT = $(HOME)/.riak_search_combo_dialyzer_plt


check_plt: compile
	dialyzer --check_plt --plt $(COMBO_PLT) --apps $(APPS) \
		deps/*/ebin apps/*/ebin

build_plt: compile
	dialyzer --build_plt --output_plt $(COMBO_PLT) --apps $(APPS) \
		deps/*/ebin apps/*/ebin

dialyzer: compile
	@echo
	@echo Use "'make check_plt'" to check PLT prior to using this target.
	@echo Use "'make build_plt'" to build PLT prior to using this target.
	@echo
	dialyzer -Wno_return --plt $(COMBO_PLT) deps/*/ebin apps/*/ebin | \
	    fgrep -v -f ./dialyzer.ignore-warnings

cleanplt:
	@echo 
	@echo "Are you sure?  It takes about 1/2 hour to re-build."
	@echo Deleting $(COMBO_PLT) in 5 seconds.
	@echo 
	sleep 5
	rm $(COMBO_PLT)

# Release tarball creation
# Generates a tarball that includes all the deps sources so no checkouts are necessary
archivegit = git archive --format=tar --prefix=$(1)/ HEAD | (cd $(2) && tar xf -)
archivehg = hg archive $(2)/$(1)
archive = if [ -d ".git" ]; then \
		$(call archivegit,$(1),$(2)); \
	    else \
		$(call archivehg,$(1),$(2)); \
	    fi

buildtar = mkdir distdir && \
		 git clone . distdir/$(REPO)-clone && \
		 cd distdir/$(REPO)-clone && \
		 git checkout $(SEARCH_TAG) && \
		 $(call archive,$(SEARCH_TAG),..) && \
		 mkdir ../$(SEARCH_TAG)/deps && \
		 make deps; \
		 for dep in deps/*; do cd $${dep} && $(call archive,$${dep},../../../$(SEARCH_TAG)); cd ../..; done
					 
distdir:
	$(if $(SEARCH_TAG), $(call buildtar), $(error "You can't generate a release tarball from a non-tagged revision. Run 'git checkout <tag>', then 'make dist'"))

dist $(SEARCH_TAG).tar.gz: distdir
	cd distdir; \
	tar czf ../$(SEARCH_TAG).tar.gz $(SEARCH_TAG)

ballclean:
	rm -rf $(SEARCH_TAG).tar.gz distdir

package: dist
	$(MAKE) -C package package

pkgclean:
	$(MAKE) -C package pkgclean

export PKG_VERSION REPO REVISION SEARCH_TAG
