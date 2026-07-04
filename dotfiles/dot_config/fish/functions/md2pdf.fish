#!/usr/bin/env fish

# Convert a Markdown file into a styled PDF.
#   md2pdf input.md            -> writes input.pdf beside it
#   md2pdf input.md output.pdf -> explicit output path
#
# Pipeline: Markdown --(npx marked)--> HTML fragment
#           fragment --(wrap in GitHub-style CSS)--> full HTML
#           HTML --(google-chrome --headless --print-to-pdf)--> PDF

function md2pdf --description "Convert a Markdown file to a styled PDF via Chrome headless"
    # ----- argument handling --------------------------------------------------
    set -l input $argv[1]

    if test -z "$input"
        echo "Usage: md2pdf <input.md> [output.pdf]"
        return 1
    end

    if not test -f "$input"
        echo "Error: input file not found: $input"
        return 1
    end

    # Output path: 2nd arg if given, otherwise swap the extension for .pdf.
    set -l output $argv[2]
    if test -z "$output"
        set output (string replace -r '\.[^./]*$' '' -- $input).pdf
    end

    # ----- dependency checks --------------------------------------------------
    if not command -v npx >/dev/null 2>&1
        echo "Error: 'npx' not found. Install Node.js (provides npx)."
        echo "  pacman -S nodejs npm   # or your distro's package manager"
        return 1
    end

    # Find a Chromium-family browser that supports --headless --print-to-pdf.
    set -l chrome ""
    for candidate in google-chrome google-chrome-stable chromium chromium-browser brave
        if command -v $candidate >/dev/null 2>&1
            set chrome $candidate
            break
        end
    end
    if test -z "$chrome"
        echo "Error: no Chrome/Chromium browser found (tried google-chrome, chromium, brave)."
        return 1
    end

    # ----- stage 1: Markdown -> HTML fragment ---------------------------------
    echo "Converting $input ..."
    set -l fragment (npx --yes marked --gfm < "$input")
    if test $status -ne 0
        echo "Error: markdown conversion failed (npx marked)."
        return 1
    end

    # ----- stage 2: wrap fragment in a full, styled HTML document -------------
    set -l tmphtml (mktemp --suffix=.html)
    set -l title (basename "$input")

    printf '%s\n' '<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>'"$title"'</title>
<style>
  @page { size: Letter; margin: 2cm; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
    font-size: 11pt;
    line-height: 1.55;
    color: #24292f;
    max-width: 100%;
    margin: 0;
    word-wrap: break-word;
  }
  h1, h2, h3, h4, h5, h6 { margin-top: 1.4em; margin-bottom: 0.5em; font-weight: 600; line-height: 1.25; }
  h1 { font-size: 1.9em; border-bottom: 1px solid #d8dee4; padding-bottom: 0.3em; }
  h2 { font-size: 1.45em; border-bottom: 1px solid #d8dee4; padding-bottom: 0.3em; }
  h3 { font-size: 1.2em; }
  p, ul, ol, table, pre, blockquote { margin-top: 0; margin-bottom: 1em; }
  a { color: #0969da; text-decoration: none; }
  code {
    font-family: "SFMono-Regular", "Consolas", "Liberation Mono", monospace;
    font-size: 0.88em;
    background-color: rgba(175,184,193,0.2);
    padding: 0.2em 0.4em;
    border-radius: 6px;
  }
  pre {
    background-color: #f6f8fa;
    padding: 1em;
    border-radius: 6px;
    overflow: auto;
    line-height: 1.4;
  }
  pre code { background: none; padding: 0; font-size: 0.85em; }
  blockquote {
    color: #57606a;
    border-left: 0.25em solid #d0d7de;
    padding: 0 1em;
    margin-left: 0;
  }
  table { border-collapse: collapse; width: auto; }
  table th, table td { border: 1px solid #d0d7de; padding: 6px 13px; }
  table th { background-color: #f6f8fa; font-weight: 600; }
  table tr:nth-child(2n) { background-color: #f6f8fa; }
  img { max-width: 100%; }
  hr { height: 1px; border: 0; background-color: #d8dee4; margin: 1.5em 0; }
</style>
</head>
<body>' "$fragment" '</body>
</html>' > $tmphtml

    # ----- stage 3: HTML -> PDF via Chrome headless ---------------------------
    # Chrome needs an absolute file:// URL; relative paths silently fail.
    set -l absolute (realpath "$tmphtml")
    $chrome --headless --disable-gpu --no-pdf-header-footer \
        --print-to-pdf="$output" "file://$absolute" >/dev/null 2>&1
    set -l chrome_status $status

    rm -f $tmphtml

    if test $chrome_status -ne 0
        echo "Error: PDF generation failed ($chrome)."
        return 1
    end

    set_color green
    echo "Created "(realpath "$output")
    set_color normal
end
