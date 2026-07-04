#!/usr/bin/env fish

# Export a Markdown file to PDF and/or DOCX in one go.
#   mdexport notes.md                  -> notes.pdf AND notes.docx
#   mdexport --pdf  notes.md           -> only the PDF
#   mdexport --docx notes.md           -> only the DOCX
#   mdexport notes.md --out report     -> report.pdf / report.docx
#   mdexport --help
#
# Thin wrapper over md2pdf and md2docx (same directory).

function mdexport --description "Export a Markdown file to PDF and/or DOCX"
    # ----- parse options ------------------------------------------------------
    set -l input ""
    set -l outbase ""
    set -l want_pdf 0
    set -l want_docx 0
    set -l expect_out 0

    for arg in $argv
        if test $expect_out -eq 1
            set outbase $arg
            set expect_out 0
            continue
        end
        switch $arg
            case -h --help
                _mdexport_help
                return 0
            case --pdf -p
                set want_pdf 1
            case --docx -d
                set want_docx 1
            case --out -o
                set expect_out 1
            case '-*'
                echo "Unknown option: $arg"
                echo "Try 'mdexport --help'."
                return 1
            case '*'
                if test -z "$input"
                    set input $arg
                else
                    echo "Error: more than one input file given ('$input' and '$arg')."
                    echo "Try 'mdexport --help'."
                    return 1
                end
        end
    end

    if test $expect_out -eq 1
        echo "Error: --out requires a value (e.g. --out report)."
        return 1
    end

    # ----- validate input -----------------------------------------------------
    if test -z "$input"
        _mdexport_help
        return 1
    end

    if not test -f "$input"
        echo "Error: input file not found: $input"
        return 1
    end

    # Default: produce BOTH when neither format flag is given.
    if test $want_pdf -eq 0 -a $want_docx -eq 0
        set want_pdf 1
        set want_docx 1
    end

    # Resolve the output base name (no extension).
    if test -z "$outbase"
        set outbase (string replace -r '\.[^./]*$' '' -- $input)
    end

    # ----- run the requested conversions --------------------------------------
    set -l ok
    set -l failed

    if test $want_pdf -eq 1
        if md2pdf "$input" "$outbase.pdf"
            set ok $ok "$outbase.pdf"
        else
            set failed $failed PDF
        end
    end

    if test $want_docx -eq 1
        if md2docx "$input" "$outbase.docx"
            set ok $ok "$outbase.docx"
        else
            set failed $failed DOCX
        end
    end

    # ----- summary ------------------------------------------------------------
    echo ""
    if test (count $ok) -gt 0
        set_color green
        echo "✓ Exported "(count $ok)" file(s):"
        set_color normal
        for f in $ok
            echo "    "(realpath "$f")
        end
    end

    if test (count $failed) -gt 0
        set_color red
        echo "✗ Failed: $failed"
        set_color normal
        return 1
    end

    return 0
end

# Help text, kept separate so both --help and the no-arg case can show it.
function _mdexport_help
    echo "mdexport — export a Markdown file to PDF and/or DOCX"
    echo ""
    echo "Usage:"
    echo "  mdexport <input.md>              Export to BOTH .pdf and .docx"
    echo "  mdexport --pdf  <input.md>       Export to .pdf only"
    echo "  mdexport --docx <input.md>       Export to .docx only"
    echo "  mdexport <input.md> --out NAME   Use NAME.pdf / NAME.docx as output"
    echo ""
    echo "Options:"
    echo "  -p, --pdf        Produce a PDF (Chrome headless)"
    echo "  -d, --docx       Produce a DOCX (pandoc, LibreOffice fallback)"
    echo "  -o, --out NAME   Output base name (extension added automatically)"
    echo "  -h, --help       Show this help"
    echo ""
    echo "With no format flag, both formats are produced."
end
