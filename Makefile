### Configuration
#
# These are standard options to make Make sane:
# <http://clarkgrubb.com/makefile-style-guide#toc2>
MAKEFLAGS += --warn-undefined-variables
SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := all
.DELETE_ON_ERROR:
.SUFFIXES:
.SECONDARY:

OBO := http://purl.obolibrary.org/obo
DATE = $(shell date +'%Y-%m-%d')
ROBOT := java -jar build/robot.jar

all: test build/report.tsv cob.owl cob.tsv

build:
	mkdir $@

build/robot.jar: | build
	curl -L -o $@ https://build.obolibrary.io/job/ontodev/job/robot/job/master/lastSuccessfulBuild/artifact/bin/robot.jar

# -- MAIN RELEASE PRODUCTS --

# create report and fail if errors introduced
build/report.tsv: cob-edit.owl | build/robot.jar
	$(ROBOT) report \
	--input $^ \
	--labels true \
	--output $@

# build main release product
cob.owl: cob-edit.owl | build/robot.jar
	$(ROBOT) reason --input $< --reasoner hermit \
	annotate \
	--ontology-iri "http://purl.obolibrary.org/obo/$@" \
	--annotation owl:versionInfo $(DATE) \
	--output $@

# base file is main cob plus linking axioms
cob-base.owl: cob.owl cob-to-external.owl
	$(ROBOT) merge $(patsubst %, -i %, $^) -o $@

# TSV export (may depend on dev version of robot export)
cob.tsv: cob.owl
	$(ROBOT) export -i $<  -c "ID|ID [LABEL]|definition|subClassOf [ID NAMED]|subClassOf [LABEL NAMED]|subClassOf [ID ANON]|subClassOf [LABEL ANON]" -e $@
#	$(ROBOT) export -i $< --entity-select NAMED -c "ID|ID [LABEL]|definition|subClassOf [ID]|subClassOf [LABEL]|subClassOf [ID ANON]|subClassOf [LABEL ANON]" -e $@

# -- MAPPINGS TO OBO --
#
#  the source file is cob-to-external.tsv
#
#  OWL is generated from this
#
# this is a really hacky way to do this, replace with robot report?
cob-to-external.ttl: cob-to-external.tsv
	./util/tsv2rdf.pl $< > $@.tmp && mv $@.tmp $@
cob-to-external.owl: cob-to-external.ttl
	$(ROBOT) convert -i $< -o $@

# -- TESTING --

# in addition to standard testing, we also perform integration tests.
#
# here we join cob, cob-to-external (bridge ontology) and OBO ontology O;
# we then test this merged product for coherency.
#
# these tests are divided in two:
#
#  if an ontology that is known to be compliant is INCOHERENT, this is a failure
#  if an ontology that is known to be NON-compliant is unexpectedly COHERENT, this is a failure
#
# See https://github.com/OBOFoundry/COB/issues/71 for discussion
#
# Note that in addition to coherency testing, we also want to do orphan testing.
# No ontologies should have orphans - classes should have subClass ancestry to a COB class
#
# these list are incomplete: it can easily be added to:

COB_COMPLIANT = pato go cl uberon po uberon+cl ro envo ogms hp mp caro ido zfa xao bco fbbt mco nbo peco ecto so
COB_NONCOMPLIANT =  doid chebi obi mondo eco  maxo
ALL_ONTS = $(COB_COMPLIANT) $(COB_NONCOMPLIANT)

test: main_test itest
main_test: build/report.tsv cob.owl

# integration tests
itest: itest_compliant itest_noncompliant #superclass_test

itest_compliant: $(patsubst %, build/reasoned-%.owl, $(COB_COMPLIANT))
itest_noncompliant: $(patsubst %, build/incoherent-%.owl, $(COB_NONCOMPLIANT))

# currently almost ALL ontologies fail this.
#
# Recommended:
#
#   make -k superclass_test
#
# PASSES: ENVO
# FAILS: anything with stages (PO, UBERON, ...): https://github.com/OBOFoundry/COB/issues/40
# FAILS: PATO we need characteristic https://github.com/OBOFoundry/COB/issues/65
superclass_test: $(patsubst %, build/no-orphans-%.txt, $(ALL_ONTS))

# cache ontology locally; by default we use main product...
build/source-%.owl:
	curl -L -s $(OBO)/$*.owl > $@.tmp && mv $@.tmp $@
.PRECIOUS: build/source-%.owl

# overrides for ontologies with bases
# TODO: we should use the registry for this
# see https://github.com/OBOFoundry/OBO-Dashboard/issues/20
build/source-go.owl:
	curl -L -s $(OBO)/go/go-base.owl > $@.tmp && mv $@.tmp $@
build/source-uberon.owl:
	curl -L -s $(OBO)/uberon/uberon-base.owl > $@.tmp && mv $@.tmp $@
build/source-cl.owl:
	curl -L -s $(OBO)/cl/cl-base.owl > $@.tmp && mv $@.tmp $@
build/source-envo.owl:
	curl -L -s $(OBO)/envo/envo-base.owl > $@.tmp && mv $@.tmp $@
build/source-hp.owl:
	curl -L -s $(OBO)/hp/hp-base.owl > $@.tmp && mv $@.tmp $@
build/source-mp.owl:
	curl -L -s $(OBO)/mp/mp-base.owl > $@.tmp && mv $@.tmp $@
build/source-ncbitaxon.owl:
	curl -L -s $(OBO)/ncbitaxon/taxslim.owl > $@.tmp && mv $@.tmp $@

# special cases
build/source-uberon+cl.owl: build/source-cl.owl build/source-uberon.owl
	$(ROBOT) merge $(patsubst %, -i %, $^) -o $@

# merged product to be tested
build/merged-%.owl: build/source-%.owl cob.owl cob-to-external.owl
	$(ROBOT) merge -i $< -i cob.owl -i cob-to-external.owl --collapse-import-closure true -o $@
.PRECIOUS: build/merged-%.owl

# reasoned product; this will FAIL if incoherent
build/reasoned-%.owl: build/merged-%.owl
	touch $@.RUN && $(ROBOT) reason --reasoner ELK -i $< -o $@ && rm $@.RUN

# incoherent product; we EXPECT to be incoherent. If it is not, then we FAIL
build/incoherent-%.owl: build/merged-%.owl
	touch $@.RUN && $(ROBOT) reason --reasoner ELK -D $@ -i $< -o $@ || rm $@.RUN

# TODO: implement https://github.com/ontodev/robot/issues/686
# then explain all incoherencies. use owltools for now
#build/incoherent-%.md: build/incoherent-%.owl
#	$(ROBOT) explain --reasoner ELK -i $< -o $@
build/incoherent-%.md: build/incoherent-%.owl
	owltools $< --run-reasoner -r elk -u -e | grep ^UNSAT > $@

# test to see if the ontology has any classes that are not inferred subclasses of a COB
# class. Exceptions made for BFO which largely sits above COB.
# note that for 'reasoning' we use only subClassOf and equivalentClasses;
# this should be sufficient if input ontologies are pre-reasoned, and cob-to-external
# is all sub/equiv axioms
build/no-orphans-%.txt: build/merged-%.owl
	robot verify -i $< -q sparql/no-cob-ancestor.rq >& build/orphans-$*.txt && touch $@


# -- EXEMPLAR ONTOLOGY --

DEMO_ONTS = go chebi envo ncbitaxon cl pr

DEMO_ONT_FILES = $(patsubst %,build/subset-%.owl,$(DEMO_ONTS))

# merge subsets together with cob;
# remove disjointness, for now we want to 'pass' ontologies for demo purposes
build/demo-cob-init.owl: $(DEMO_ONT_FILES)
	robot merge $(patsubst %, -i build/subset-%.owl,$(DEMO_ONTS)) \
              remove --axioms disjoint \
	      -o $@
.PRECIOUS: build/demo-cob-init.owl

# TODO: do this with robot somehow.
# equivalence pairs ugly for browsing; merge into COB
build/demo-cob-merged.owl: build/demo-cob-init.owl
	owltools $< --reasoner elk --merge-equivalence-sets -s COB 10 -l COB 10 -d COB 10  -o $@

# remove redundancy
# todo: remove danglers in fiinal release (use a SPARQL update), but produce a report
products/demo-cob.owl: build/demo-cob-merged.owl
	robot reason -r ELK -s true -i $< annotate -O $(OBO)/cob/demo-cob.owl -o $@

build/subset-%.owl: build/merged-%.owl subsets/terms_%.txt 
	robot extract -m BOT -i $< -T subsets/terms_$*.txt -o $@
