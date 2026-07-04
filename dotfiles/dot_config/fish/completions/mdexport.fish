# Completions for mdexport / md2pdf / md2docx

# --- mdexport ---------------------------------------------------------------
complete -c mdexport -f
complete -c mdexport -s h -l help --description "Show help"
complete -c mdexport -s p -l pdf  --description "Export to PDF only"
complete -c mdexport -s d -l docx --description "Export to DOCX only"
complete -c mdexport -s o -l out  --description "Output base name" -r
# Complete Markdown files for the positional input argument.
complete -c mdexport -k -a "(__fish_complete_suffix .md)" --description "Markdown file"
complete -c mdexport -k -a "(__fish_complete_suffix .markdown)" --description "Markdown file"

# --- md2pdf -----------------------------------------------------------------
complete -c md2pdf -f
complete -c md2pdf -k -a "(__fish_complete_suffix .md)" --description "Markdown file"
complete -c md2pdf -k -a "(__fish_complete_suffix .markdown)" --description "Markdown file"

# --- md2docx ----------------------------------------------------------------
complete -c md2docx -f
complete -c md2docx -k -a "(__fish_complete_suffix .md)" --description "Markdown file"
complete -c md2docx -k -a "(__fish_complete_suffix .markdown)" --description "Markdown file"
