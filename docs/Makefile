# Web output
SPHINXBUILD			?= sphinx-build
SPHINXAUTOBUILD ?= sphinx-autobuild
HTML_BUILDDIR  	:= build/html

# PDF output
LATEX       	:= latexmk
PDF_TARGET  	:= main
PDF_BUILDDIR	:= build/pdf

SOURCEDIR 	:= src

# uv
UV := uv

$(BUILD_DIR)/$(TARGET).pdf: $(TARGET).tex $(PDF_BUILDDIR)
	$(LATEX) -output-directory=$(BUILD_DIR) -pdflua $(TARGET).tex

$(PDF_BUILDDIR) $(HTML_BUILDDIR):
	mkdir -p $@

htmllive: SPHINXBUILD=$(SPHINXAUTOBUILD)
htmllive: html

html: $(HTML_BUILDDIR)
	rm -rf $^
	$(UV) run $(SPHINXBUILD) -b html -n "$(SOURCEDIR)" "$^" -c .

pdflive: pdf
	make -C $(PDF_BUILDDIR)

pdf: $(PDF_BUILDDIR)
	rm -rf $^
	$(UV) run $(SPHINXBUILD) -b latex -n "$(SOURCEDIR)" "$^" -c .

clean:
	rm -rf $(HTML_BUILDDIR) $(PDF_BUILDDIR)

.PHONY: clean test html htmllive pdflive pdf
