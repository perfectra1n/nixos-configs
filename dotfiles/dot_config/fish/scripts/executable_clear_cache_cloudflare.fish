#!/usr/bin/env fish

# Define a function to purge cache and enable development mode
function purge_and_enable_dev_mode -a zone email api_key
  # Purge Cloudflare cache
  curl -X POST "https://api.cloudflare.com/client/v4/zones/$zone/purge_cache" \
      -H "X-Auth-Email: $email" \
      -H "X-Auth-Key: $api_key" \
      -H "Content-Type: application/json" \
      --data '{"purge_everything":true}' | jq

  # Check for successful cache purge response before proceeding
  if test $status -eq 0
      echo "Cache purged successfully."
  else
      echo "Failed to purge cache."
  end
end

# Check if the correct number of arguments are provided
if test (count $argv) -ne 3
  echo "Usage: $argv[1] <zone_id> <email> <api_key>"
  exit 1
end

# Call the function with provided arguments
purge_and_enable_dev_mode $argv[1] $argv[2] $argv[3]
