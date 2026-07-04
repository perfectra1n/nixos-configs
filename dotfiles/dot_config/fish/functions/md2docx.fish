#!/usr/bin/env fish

# Convert a Markdown file into a Word .docx, retaining as much formatting as possible.
#   md2docx input.md             -> writes input.docx beside it
#   md2docx input.md output.docx -> explicit output path
#
# Engine: prefers pandoc (best mapping to native Word styles: headings, tables,
#         lists, code blocks, footnotes). Falls back to LibreOffice headless
#         (via an intermediate HTML render with `npx marked`) when pandoc is
#         not installed.

function md2docx --description "Convert a Markdown file to a .docx (pandoc, or LibreOffice fallback)"
    # ----- argument handling --------------------------------------------------
    set -l input $argv[1]

    if test -z "$input"
        echo "Usage: md2docx <input.md> [output.docx]"
        return 1
    end

    if not test -f "$input"
        echo "Error: input file not found: $input"
        return 1
    end

    # Output path: 2nd arg if given, otherwise swap the extension for .docx.
    set -l output $argv[2]
    if test -z "$output"
        set output (string replace -r '\.[^./]*$' '' -- $input).docx
    end

    echo "Converting $input ..."

    # ----- preferred engine: pandoc -------------------------------------------
    if command -v pandoc >/dev/null 2>&1
        # Pandoc's default table style has no cell borders (just a header
        # underline), which looks "floating". Use a cached reference document
        # whose Table style has full single borders so tables get gridlines.
        set -l refdoc (__md2docx_reference_doc)

        set -l refargs
        if test -n "$refdoc"
            set refargs --reference-doc "$refdoc"
        end

        pandoc "$input" \
            --from gfm \
            --to docx \
            --standalone \
            --highlight-style tango \
            $refargs \
            --output "$output"
        if test $status -ne 0
            echo "Error: pandoc conversion failed."
            return 1
        end
        set_color green
        echo "Created "(realpath "$output")" (via pandoc)"
        set_color normal
        return 0
    end

    # ----- fallback engine: LibreOffice via HTML ------------------------------
    echo "pandoc not found; falling back to LibreOffice."

    if not command -v npx >/dev/null 2>&1
        echo "Error: fallback needs 'npx' (Node.js) to render Markdown to HTML."
        echo "  Install pandoc for best results: pacman -S pandoc"
        return 1
    end

    set -l soffice ""
    for candidate in libreoffice soffice
        if command -v $candidate >/dev/null 2>&1
            set soffice $candidate
            break
        end
    end
    if test -z "$soffice"
        echo "Error: neither pandoc nor LibreOffice found."
        echo "  Install one: pacman -S pandoc   (or)   pacman -S libreoffice-fresh"
        return 1
    end

    # Render Markdown -> HTML fragment, then wrap as a minimal HTML document.
    set -l fragment (npx --yes marked --gfm < "$input")
    if test $status -ne 0
        echo "Error: markdown conversion failed (npx marked)."
        return 1
    end

    set -l tmphtml (mktemp --suffix=.html)
    printf '%s\n' '<!DOCTYPE html><html><head><meta charset="utf-8"></head><body>' \
        "$fragment" '</body></html>' > $tmphtml

    # LibreOffice writes the .docx into --outdir using the source basename, so
    # convert into a temp dir then move it to the requested output path.
    set -l tmpdir (mktemp -d)
    $soffice --headless --convert-to docx --outdir $tmpdir $tmphtml >/dev/null 2>&1
    set -l conv_status $status

    set -l produced $tmpdir/(basename $tmphtml .html).docx
    if test $conv_status -ne 0 -o ! -f "$produced"
        rm -rf $tmphtml $tmpdir
        echo "Error: LibreOffice conversion failed."
        return 1
    end

    mv -f "$produced" "$output"
    rm -rf $tmphtml $tmpdir

    set_color green
    echo "Created "(realpath "$output")" (via LibreOffice)"
    set_color normal
end

# Build (and cache) a pandoc reference document whose table style has full
# borders, so generated tables show gridlines instead of just a header rule.
# Prints the path to the cached .docx on stdout, or nothing if it can't be
# built (callers then fall back to pandoc's default styling).
function __md2docx_reference_doc
    set -l cachedir "$HOME/.cache/md2docx"
    set -l refdoc "$cachedir/reference-bordered.docx"

    # Reuse the cached file if it already exists.
    if test -f "$refdoc"
        echo "$refdoc"
        return 0
    end

    # Need zip/unzip to patch the .docx (a zip archive); bail quietly if absent.
    if not command -v unzip >/dev/null 2>&1; or not command -v zip >/dev/null 2>&1
        return 1
    end

    mkdir -p "$cachedir"
    set -l work (mktemp -d)

    # Start from pandoc's own default reference document and unzip it.
    if not pandoc -o "$work/reference.docx" --print-default-data-file reference.docx 2>/dev/null
        rm -rf $work
        return 1
    end
    if not unzip -q "$work/reference.docx" -d "$work/ext" 2>/dev/null
        rm -rf $work
        return 1
    end

    set -l styles "$work/ext/word/styles.xml"
    if not test -f "$styles"
        rm -rf $work
        return 1
    end

    # Inject full single borders as the first child of the Table style's
    # <w:tblPr>. (?s) makes . match newlines; .*? keeps the match inside the
    # Table style block.
    set -l borders '<w:tblBorders><w:top w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:left w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:bottom w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:right w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:insideH w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:insideV w:val="single" w:sz="4" w:space="0" w:color="auto"/></w:tblBorders>'

    set -l xml (cat "$styles" | string collect)
    set -l patched (string replace -r '(?s)(w:styleId="Table".*?<w:tblPr>)' '$1'"$borders" -- "$xml" | string collect)

    # If the substitution didn't change anything, the Table style layout was
    # unexpected; give up and let pandoc use its default.
    if test "$patched" = "$xml"
        rm -rf $work
        return 1
    end
    printf '%s' "$patched" > "$styles"

    # Rezip the directory tree back into a .docx (member order is irrelevant).
    # zip writes relative to CWD, so run it from inside the extracted dir.
    rm -f "$refdoc"
    pushd "$work/ext" >/dev/null
    zip -qr "$refdoc" . 2>/dev/null
    set -l zip_status $status
    popd >/dev/null

    rm -rf $work

    if test $zip_status -ne 0 -o ! -f "$refdoc"
        return 1
    end

    echo "$refdoc"
end
