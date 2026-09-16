function trilium-note --description "Create a Trilium note from piped input or editor"
    # Check for required dependencies
    for cmd in curl jq file
        if not command -sq $cmd
            echo "Error: Required command '$cmd' not found. Please install it first."
            return 1
        end
    end
    
    # Configuration variables
    set -l trilium_url "$TRILIUM_PERSONAL_URL/etapi" # Default Trilium server URL (base from the encrypted fish env channel)
    set -l auth_token "" # Your ETAPI auth token
    set -l parent_note_id "pfrpbjovkqMj" # Default parent note ID
    
    # Parse arguments
    argparse --name=trilium-note 'h/help' 'u/url=' 't/token=' 'p/parent=' 'T/title=' 'P/password=' -- $argv
    or return 1
    
    if set -q _flag_help
        echo "Usage: trilium-note [OPTIONS] [TITLE]"
        echo "Create a note in Trilium using piped input or your preferred text editor"
        echo
        echo "Options:"
        echo "  -h, --help           Show this help message"
        echo "  -u, --url URL        Trilium server URL (default: http://localhost:37740/etapi)"
        echo "  -t, --token TOKEN    ETAPI authentication token"
        echo "  -P, --password PASS  Trilium password (to obtain a token if none provided)"
        echo "  -p, --parent ID      Parent note ID (default: root)"
        echo "  -T, --title TITLE    Note title (alternative to providing as argument)"
        echo
        echo "Examples:"
        echo "  echo 'Note content' | trilium-note 'My Title'"
        echo "  trilium-note 'My Title'  # Opens editor for content"
        return 0
    end
    
    # Override defaults with provided options
    if set -q _flag_url
        set trilium_url $_flag_url
    end
    
    # Handle authentication
    if set -q _flag_token
        set auth_token $_flag_token
    else if set -q TRILIUM_TOKEN
        set auth_token $TRILIUM_TOKEN
    else if set -q _flag_password
        # Obtain token using password
        echo "Obtaining ETAPI token using password..."
        set -l login_response (echo "{\"password\": \"$_flag_password\"}" | curl -s -X POST "$trilium_url/auth/login" \
            -H "Content-Type: application/json" \
            -d @-)
        
        if echo $login_response | grep -q "\"authToken\""
            set auth_token (echo $login_response | jq -r '.authToken')
            echo "Token obtained successfully."
        else
            echo "Error obtaining token: $login_response"
            return 1
        end
    else
        echo "Error: ETAPI token is required. Provide it with -t/--token, set TRILIUM_TOKEN environment variable, or use -P/--password."
        return 1
    end
    
    if set -q _flag_parent
        set parent_note_id $_flag_parent
    end
    
    # Get title from arguments or flag
    set -l title ""
    if set -q _flag_title
        set title $_flag_title
    else if test (count $argv) -gt 0
        set title $argv[1]
    else
        # If no title provided, prompt for one
        read -P "Enter note title: " title
        if test -z "$title"
            echo "Error: Note title is required."
            return 1
        end
    end
    
    # Check if input is piped or coming from stdin
    set -l temp_input ""
    set -l detected_mime ""
    if not isatty stdin
        # Read piped input to a temp file for safety
        set temp_input (mktemp /tmp/trilium-input.XXXXXX)
        cat > $temp_input
        
        # Check if file has content
        if test ! -s $temp_input
            echo "Error: No content received from pipe."
            rm $temp_input
            return 1
        end
        
        # Detect MIME type
        set detected_mime (file --mime-type -b $temp_input)
    else
        # No piped input, use editor
        set temp_input (mktemp /tmp/trilium-note.XXXXXX)
        
        # Open editor
        if set -q EDITOR
            eval $EDITOR $temp_input
        else if command -sq vim
            vim $temp_input
        else if command -sq nano
            nano $temp_input
        else
            echo "Error: No text editor found. Set the EDITOR environment variable."
            rm $temp_input
            return 1
        end
        
        # Check if file has content
        if test ! -s $temp_input
            echo "Note creation cancelled - empty content."
            rm $temp_input
            return 1
        end
        
        # Detect MIME type
        set detected_mime (file --mime-type -b $temp_input)
    end
    
    # Create JSON payload - pipe directly from file to preserve formatting
    set -l json_payload ""
    set -l note_type "text"
    
    # Determine note type based on MIME type
    switch $detected_mime
        case "text/x-shellscript" "text/x-python" "text/x-c" "text/x-c++" "text/x-java" "text/x-ruby" "text/x-perl" "application/javascript" "application/json" "application/xml" "text/css"
            # Programming languages should be code type with MIME
            set note_type "code"
            set json_payload (cat $temp_input | jq -Rs --arg parent "$parent_note_id" --arg title "$title" --arg ntype "$note_type" --arg mime "$detected_mime" '{parentNoteId: $parent, title: $title, type: $ntype, content: ., mime: $mime}')
            if test $status -ne 0
                echo "Error: Failed to create JSON payload"
                rm $temp_input
                return 1
            end
        case "text/html"
            # HTML can be rendered
            set note_type "render"
            set json_payload (cat $temp_input | jq -Rs --arg parent "$parent_note_id" --arg title "$title" --arg ntype "$note_type" '{parentNoteId: $parent, title: $title, type: $ntype, content: ., mime: "text/html"}')
            if test $status -ne 0
                echo "Error: Failed to create JSON payload"
                rm $temp_input
                return 1
            end
        case "text/plain"
            # Enhanced markdown detection - check file extension or content patterns
            set -l is_markdown 0
            
            # Check if title suggests markdown file
            if string match -q "*.md" "$title"; or string match -q "*.markdown" "$title"
                set is_markdown 1
            # Check content for markdown patterns (more comprehensive)
            else if cat $temp_input | head -30 | grep -qE '^#{1,6}\s|^\*\s|^\-\s|^\d+\.\s|^\[.+\]\(.+\)|^```|^\|.*\|.*\|'
                set is_markdown 1
            end
            
            if test $is_markdown -eq 1
                # Markdown should be text type for proper rendering in Trilium
                set note_type "text"
                set json_payload (cat $temp_input | jq -Rs --arg parent "$parent_note_id" --arg title "$title" --arg ntype "$note_type" '{parentNoteId: $parent, title: $title, type: $ntype, content: .}')
                if test $status -ne 0
                    echo "Error: Failed to create JSON payload"
                    rm $temp_input
                    return 1
                end
            else
                # Plain text
                set json_payload (cat $temp_input | jq -Rs --arg parent "$parent_note_id" --arg title "$title" --arg ntype "$note_type" '{parentNoteId: $parent, title: $title, type: $ntype, content: .}')
                if test $status -ne 0
                    echo "Error: Failed to create JSON payload"
                    rm $temp_input
                    return 1
                end
            end
        case "image/*"
            # Images - skip for now as binary handling needs base64 encoding
            echo "Error: Image files are not yet supported. Please upload directly in Trilium."
            rm $temp_input
            return 1
        case '*'
            # Default case - treat as text
            set json_payload (cat $temp_input | jq -Rs --arg parent "$parent_note_id" --arg title "$title" --arg ntype "$note_type" '{parentNoteId: $parent, title: $title, type: $ntype, content: .}')
            if test $status -ne 0
                echo "Error: Failed to create JSON payload"
                rm $temp_input
                return 1
            end
    end
    
    # Clean up temp file
    rm $temp_input
    
    # Send request to Trilium API with authentication
    set -l response (curl -s -X POST "$trilium_url/create-note" \
        -H "Authorization: $auth_token" \
        -H "Content-Type: application/json" \
        -d "$json_payload")
    
    # Check response
    if echo $response | grep -q "\"noteId\""
        set -l note_id (echo $response | jq -r '.note.noteId')
        echo "Note created successfully with ID: $note_id"
        return 0
    else
        echo "Error creating note: $response"
        return 1
    end
end
