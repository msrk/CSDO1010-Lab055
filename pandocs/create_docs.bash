#!/bin/bash

pandoc README.md INSTRUCTIONS.md \
            --from=gfm \
            --toc \
            --syntax-highlighting=breezeDark \
            -V geometry:paperwidth=8.5in \
            -V geometry:paperheight=11in \
            -V geometry:margin=1in \
            --reference-doc=pandocs/ref04.docx \
            --output=CSDO1010-DevOps-ToolChain-Lab05-Instructions.docx

pandoc README.md INSTRUCTIONS.md \
            --from=gfm \
            --toc \
            --pdf-engine=xelatex \
            --syntax-highlighting=breezeDark \
            -V geometry:paperwidth=8.5in \
            -V geometry:paperheight=11in \
            -V geometry:margin=1in \
            -V fontsize=11pt \
            -H pandocs/header.tex \
            --output=CSDO1010-DevOps-ToolChain-Lab05-Instructions.pdf
